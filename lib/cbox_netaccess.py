#!/usr/bin/env python3
import argparse
import datetime
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
ALLOWED_DRIVERS = {"bridge", "overlay"}

HOSTNAME_LABEL_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
PORT_SPEC_RE = re.compile(r"^([0-9]{1,5})/(tcp|udp|sctp)$")
MAX_ALIASES_PER_CONTAINER = 16
MAX_PORTS_PER_CONTAINER = 32
MAX_CONTAINERS_PER_NETWORK = 512


def valid_hostname(name):
    if not isinstance(name, str) or not name or len(name) > 253:
        return False
    for label in name.split("."):
        if not HOSTNAME_LABEL_RE.fullmatch(label):
            return False
    return True


def valid_port_spec(spec):
    if not isinstance(spec, str):
        return False
    match = PORT_SPEC_RE.fullmatch(spec)
    if not match:
        return False
    return 1 <= int(match.group(1)) <= 65535


def run(docker_bin, args, timeout=15):
    proc = subprocess.run(
        [docker_bin] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        error = proc.stderr.decode("utf-8", "replace")[:1000].strip()
        raise RuntimeError(error or "docker command failed")
    return proc.stdout.decode("utf-8", "replace")


def run_json(docker_bin, args):
    raw = run(docker_bin, args)
    if len(raw) > 8 * 1024 * 1024:
        raise RuntimeError("docker response exceeds limit")
    return json.loads(raw)


def inspect_one(docker_bin, args):
    value = run_json(docker_bin, args)
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise RuntimeError("invalid docker inspect response")
    return value[0]


def list_networks(docker_bin):
    result = []
    for name in run(docker_bin, ["network", "ls", "--format", "{{.Name}}"]).splitlines():
        name = name.strip()
        if NAME_RE.fullmatch(name):
            result.append(name)
    return list(dict.fromkeys(result))


def endpoint_networks(container):
    settings = container.get("NetworkSettings") if isinstance(container.get("NetworkSettings"), dict) else {}
    value = settings.get("Networks") if isinstance(settings.get("Networks"), dict) else {}
    return value


def network_subnets(doc):
    ipam = doc.get("IPAM") if isinstance(doc.get("IPAM"), dict) else {}
    config = ipam.get("Config") if isinstance(ipam.get("Config"), list) else []
    result = []
    for item in config:
        if not isinstance(item, dict):
            continue
        raw = item.get("Subnet")
        try:
            subnet = ipaddress.ip_network(raw, strict=False)
        except (TypeError, ValueError):
            continue
        if subnet.version == 4 and 8 <= subnet.prefixlen < 32:
            result.append(str(subnet))
    return result


def compose_network_kind(doc, project):
    labels = doc.get("Labels") if isinstance(doc.get("Labels"), dict) else {}
    if labels.get("com.docker.compose.project") != project:
        return ""
    kind = labels.get("com.docker.compose.network")
    return kind if kind in ("internal", "egress") else ""


def cbox_infra_network(doc):
    labels = doc.get("Labels") if isinstance(doc.get("Labels"), dict) else {}
    return labels.get("cbox.kind") == "infra"


def sanitize_reason(text, limit=120):
    value = "".join(ch if ch.isprintable() and ord(ch) < 127 else " " for ch in str(text))
    value = " ".join(value.split())
    if len(value) > limit:
        value = value[:limit].rstrip() + "..."
    return value


def select_networks(docker_bin, scope, requested, project):
    names = list_networks(docker_bin) if scope == "all" else requested
    selected = []
    docs = {}
    skipped = []
    for name in names:
        if not NAME_RE.fullmatch(name):
            raise ValueError("invalid network name: %s" % name)
        try:
            doc = inspect_one(docker_bin, ["network", "inspect", name])
        except Exception as exc:
            detail = sanitize_reason(exc, 90)
            kind = "not present" if "no such network" in detail.lower() else "inspect failed"
            skipped.append({
                "network": name,
                "reason": "%s: %s" % (kind, detail),
                "requested": scope == "list",
            })
            continue
        if name in ("host", "none", "ingress") or doc.get("Driver") not in ALLOWED_DRIVERS:
            reason = "unsupported network driver"
        elif compose_network_kind(doc, project):
            reason = "cbox infrastructure network"
        elif cbox_infra_network(doc):
            reason = "cbox infrastructure network (per-scope model network)"
        elif not network_subnets(doc):
            reason = "no eligible IPv4 subnet"
        else:
            reason = ""
        if reason:
            if scope == "list":
                raise PermissionError("network %s: %s" % (name, reason))
            skipped.append({"network": name, "reason": reason, "requested": False})
            continue
        selected.append(name)
        docs[name] = doc
    return list(dict.fromkeys(selected)), docs, skipped


def safe_state_dir(path):
    absolute = os.path.abspath(path)
    if path != absolute or os.path.realpath(path) != absolute:
        raise PermissionError("netaccess state directory path is unsafe")
    os.makedirs(absolute, mode=0o700, exist_ok=True)
    info = os.lstat(absolute)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise PermissionError("netaccess state directory is unsafe")
    os.chmod(absolute, 0o700)


def safe_netmap_dir(path):
    absolute = os.path.abspath(path)
    if path != absolute or os.path.realpath(path) != absolute:
        raise PermissionError("netaccess netmap directory path is unsafe")
    os.makedirs(absolute, mode=0o755, exist_ok=True)
    info = os.lstat(absolute)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise PermissionError("netaccess netmap directory is unsafe")
    os.chmod(absolute, 0o755)


def write_netmap(path, data):
    directory = os.path.dirname(path)
    safe_netmap_dir(directory)
    fd, tmp = tempfile.mkstemp(prefix=".cbox-netmap-", dir=directory)
    try:
        os.fchmod(fd, 0o644)
        raw = (json.dumps(data, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp, path)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def proxy_url_parts(proxy_url):
    host = ""
    port = 0
    if proxy_url:
        try:
            parsed = urlsplit(proxy_url)
            host = parsed.hostname or ""
            port = parsed.port or 0
        except ValueError:
            host = ""
            port = 0
    return host, port


def batched_container_info(docker_bin, ids):
    if not ids:
        return {}
    raw = run_json(docker_bin, ["inspect"] + list(ids))
    if not isinstance(raw, list):
        raise RuntimeError("invalid docker inspect response")
    result = {}
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        cid = entry.get("Id") or ""
        if cid:
            result[cid] = entry
    return result


def alias_list(container_entry, network_name, container_id, container_name):
    if not isinstance(container_entry, dict):
        return [], 0
    settings = container_entry.get("NetworkSettings") if isinstance(container_entry.get("NetworkSettings"), dict) else {}
    net_map = settings.get("Networks") if isinstance(settings.get("Networks"), dict) else {}
    endpoint = net_map.get(network_name) if isinstance(net_map.get(network_name), dict) else {}
    raw = []
    aliases = endpoint.get("Aliases")
    if isinstance(aliases, list):
        raw.extend(aliases)
    dns_names = endpoint.get("DNSNames")
    if isinstance(dns_names, list):
        raw.extend(dns_names)
    cid_lower = str(container_id).lower()
    seen = set()
    valid = []
    dropped = 0
    for item in raw:
        if not isinstance(item, str) or not item:
            continue
        item_lower = item.lower()
        if len(item_lower) >= 8 and cid_lower.startswith(item_lower):
            continue
        if item_lower in seen:
            continue
        seen.add(item_lower)
        if not valid_hostname(item):
            dropped += 1
            continue
        if "." in item:
            dropped += 1
            continue
        valid.append(item)
    if len(valid) > MAX_ALIASES_PER_CONTAINER:
        dropped += len(valid) - MAX_ALIASES_PER_CONTAINER
        valid = valid[:MAX_ALIASES_PER_CONTAINER]
    return valid, dropped


def exposed_ports(container_entry):
    if not isinstance(container_entry, dict):
        return [], 0
    config = container_entry.get("Config") if isinstance(container_entry.get("Config"), dict) else {}
    ports = config.get("ExposedPorts")
    if not isinstance(ports, dict):
        return [], 0
    valid = []
    dropped = 0
    for key in ports.keys():
        key = str(key)
        if valid_port_spec(key):
            valid.append(key)
        else:
            dropped += 1
    valid = sorted(set(valid))
    if len(valid) > MAX_PORTS_PER_CONTAINER:
        dropped += len(valid) - MAX_PORTS_PER_CONTAINER
        valid = valid[:MAX_PORTS_PER_CONTAINER]
    return valid, dropped


def build_netmap(docker_bin, scope, selected, skipped, docs, proxy_container_id, proxy_url, raw_cidrs):
    networks = []
    all_ids = []
    seen_ids = set()
    per_network = []
    for name in selected:
        doc = docs.get(name)
        if not isinstance(doc, dict):
            continue
        subnets = network_subnets(doc)
        subnet = subnets[0] if subnets else ""
        containers_field = doc.get("Containers") if isinstance(doc.get("Containers"), dict) else {}
        ids = []
        base_entries = {}
        net_dropped = 0
        for cid, info in containers_field.items():
            if cid == proxy_container_id:
                continue
            if not isinstance(info, dict):
                continue
            if len(ids) >= MAX_CONTAINERS_PER_NETWORK:
                net_dropped += 1
                continue
            ipv4 = str(info.get("IPv4Address") or "")
            if "/" in ipv4:
                ipv4 = ipv4.split("/", 1)[0]
            cname = str(info.get("Name") or "").lstrip("/")
            base_entries[cid] = {"name": cname, "ipv4": ipv4}
            ids.append(cid)
            if cid not in seen_ids:
                seen_ids.add(cid)
                all_ids.append(cid)
        per_network.append({"name": name, "subnet": subnet, "ids": ids, "base": base_entries, "dropped": net_dropped})
    info_by_id = batched_container_info(docker_bin, all_ids)
    for net in per_network:
        containers = []
        dropped_total = net["dropped"]
        for cid in net["ids"]:
            base = net["base"][cid]
            info = info_by_id.get(cid)
            aliases, alias_dropped = alias_list(info, net["name"], cid, base["name"])
            ports, port_dropped = exposed_ports(info)
            dropped_total += alias_dropped + port_dropped
            containers.append({
                "name": base["name"],
                "aliases": aliases,
                "ipv4": base["ipv4"],
                "ports": ports,
                "name_routable": "." not in base["name"],
            })
        networks.append({"name": net["name"], "subnet": net["subnet"], "containers": containers, "dropped": dropped_total})
    proxy_host, proxy_port = proxy_url_parts(proxy_url)
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "version": 1,
        "generated_at": generated_at,
        "proxy": {"url": proxy_url, "host": proxy_host, "port": proxy_port},
        "scope": scope,
        "networks": networks,
        "cidrs": list(raw_cidrs),
        "skipped": [{"network": item.get("network", ""), "reason": item.get("reason", "")} for item in skipped],
    }


def netmap_only(args):
    container = inspect_one(args.docker_bin, ["inspect", args.container])
    config = container.get("Config") if isinstance(container.get("Config"), dict) else {}
    labels = config.get("Labels") if isinstance(config.get("Labels"), dict) else {}
    project = labels.get("com.docker.compose.project")
    if not isinstance(project, str) or not project:
        raise RuntimeError("proxy container has no Compose project label")
    selected, docs, skipped = select_networks(args.docker_bin, args.scope, args.network, project)
    attached = endpoint_networks(container)
    still_selected = []
    for name in selected:
        if name in attached:
            still_selected.append(name)
        else:
            skipped.append({
                "network": name,
                "reason": "granted but not attached (refresh only, no connect)",
                "requested": True,
            })
    raw_cidrs = validate_cidrs(args.cidr)
    netmap = build_netmap(args.docker_bin, args.scope, still_selected, skipped, docs, args.container, args.proxy_url, raw_cidrs)
    write_netmap(args.netmap_out, netmap)
    return netmap


def read_applied(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return []
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise PermissionError("netaccess state is not a regular file")
        with os.fdopen(fd, "r", encoding="ascii") as handle:
            fd = -1
            value = json.load(handle)
    finally:
        if fd >= 0:
            os.close(fd)
    if not isinstance(value, list) or not all(isinstance(x, str) and NAME_RE.fullmatch(x) for x in value):
        raise ValueError("invalid netaccess state")
    return list(dict.fromkeys(value))


def write_applied(path, value):
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".cbox-netaccess-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        raw = (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp, path)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def subnet_for_ip(ip, subnets):
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return ""
    for raw in subnets:
        if address in ipaddress.ip_network(raw, strict=False):
            return raw
    return ""


def validate_cidrs(values):
    result = []
    for raw in values:
        try:
            value = ipaddress.ip_network(raw, strict=False)
        except ValueError:
            raise ValueError("invalid target CIDR: %s" % raw)
        if value.version != 4 or value.prefixlen < 8 or value.prefixlen == 0:
            raise ValueError("target CIDR is too broad or non-IPv4: %s" % raw)
        result.append(str(value))
    return list(dict.fromkeys(result))


def apply(args):
    safe_state_dir(args.state_dir)
    container = inspect_one(args.docker_bin, ["inspect", args.container])
    config = container.get("Config") if isinstance(container.get("Config"), dict) else {}
    labels = config.get("Labels") if isinstance(config.get("Labels"), dict) else {}
    project = labels.get("com.docker.compose.project")
    if not isinstance(project, str) or not project:
        raise RuntimeError("proxy container has no Compose project label")
    selected, docs, skipped = select_networks(args.docker_bin, args.scope, args.network, project)
    state_path = os.path.join(args.state_dir, "applied-networks.json")
    previous = read_applied(state_path)
    attached = endpoint_networks(container)
    newly_connected = []
    try:
        for name in selected:
            if name not in attached:
                run(args.docker_bin, ["network", "connect", name, args.container])
                newly_connected.append(name)
        container = inspect_one(args.docker_bin, ["inspect", args.container])
        attached = endpoint_networks(container)
        internal = None
        egress = None
        for name, endpoint in attached.items():
            try:
                doc = docs.get(name) or inspect_one(args.docker_bin, ["network", "inspect", name])
            except Exception:
                continue
            kind = compose_network_kind(doc, project)
            if kind == "internal":
                internal = (name, endpoint, doc)
            elif kind == "egress":
                egress = (name, endpoint, doc)
        if not internal:
            raise RuntimeError("proxy internal network is missing")
        internal_ip = str(internal[1].get("IPAddress") or "")
        internal_cidr = subnet_for_ip(internal_ip, network_subnets(internal[2]))
        if not internal_cidr:
            raise RuntimeError("proxy internal IPv4 route is missing")
        targets = []
        for name in selected:
            endpoint = attached.get(name) if isinstance(attached.get(name), dict) else {}
            ip = str(endpoint.get("IPAddress") or "")
            subnet = subnet_for_ip(ip, network_subnets(docs[name]))
            if not ip or not subnet:
                raise RuntimeError("proxy endpoint is missing on network %s" % name)
            targets.append({"network": name, "externalIp": ip, "cidr": subnet})
        raw_cidrs = validate_cidrs(args.cidr)
        if raw_cidrs:
            if not egress:
                raise RuntimeError("proxy egress network is required for raw CIDRs")
            egress_ip = str(egress[1].get("IPAddress") or "")
            if not egress_ip:
                raise RuntimeError("proxy egress IPv4 address is missing")
            for cidr in raw_cidrs:
                targets.append({"network": "", "externalIp": egress_ip, "cidr": cidr})
        for name in previous:
            if name not in selected and name in attached:
                run(args.docker_bin, ["network", "disconnect", "-f", name, args.container])
        write_applied(state_path, selected)
    except Exception:
        for name in reversed(newly_connected):
            try:
                run(args.docker_bin, ["network", "disconnect", "-f", name, args.container])
            except Exception:
                pass
        raise
    netmap_out = getattr(args, "netmap_out", None)
    if netmap_out:
        proxy_url = getattr(args, "proxy_url", "") or ""
        netmap = build_netmap(args.docker_bin, args.scope, selected, skipped, docs, args.container, proxy_url, raw_cidrs)
        write_netmap(netmap_out, netmap)
    return {
        "internalIp": internal_ip,
        "internalCidr": internal_cidr,
        "appliedNetworks": selected,
        "targets": targets,
        "skipped": skipped,
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--docker-bin", default="docker")
    parser.add_argument("--container", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--scope", choices=("all", "list"), required=True)
    parser.add_argument("--network", action="append", default=[])
    parser.add_argument("--cidr", action="append", default=[])
    parser.add_argument("--netmap-out", default="")
    parser.add_argument("--proxy-url", default="")
    parser.add_argument("--netmap-only", action="store_true")
    args = parser.parse_args(argv)
    if not NAME_RE.fullmatch(args.container):
        raise ValueError("invalid proxy container ID")
    if args.netmap_only:
        if not args.netmap_out:
            raise ValueError("--netmap-only requires --netmap-out")
        print(json.dumps(netmap_only(args), ensure_ascii=True, separators=(",", ":")))
        return 0
    print(json.dumps(apply(args), ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write("cbox-netaccess: %s\n" % exc)
        sys.exit(2)
