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

DEFAULT_HOSTS_PATH = "/etc/hosts"
HOST_ALIAS_LOOPBACK_IPS = {"127.0.0.1", "::1"}
HOST_ALIAS_EXCLUDE_EXACT = {"localhost", "localhost.localdomain", "broadcasthost"}
HOST_ALIAS_RESERVED_NAMES = {
    "cbox-proxy-internal", "host.docker.internal", "proxy", "cbox",
    "ollama", "wg-remote-ollama",
}
MAX_HOST_ALIAS_NAMES = 64
MAX_HOST_ALIAS_PORTS = 64
MAX_HOST_ALIAS_SKIPPED = 64
MAX_NOT_GRANTED_DETAIL = 64
MAX_NETWORKS_PER_ENTRY = 16


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


def cap_network_list(networks, limit=MAX_NETWORKS_PER_ENTRY):
    names = sorted(networks)
    if len(names) <= limit:
        return names
    capped = names[:limit]
    capped.append("+%d" % (len(names) - limit))
    return capped


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


def parse_etc_hosts(path):
    names = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return names
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        ip = parts[0]
        if ip not in HOST_ALIAS_LOOPBACK_IPS:
            continue
        for name in parts[1:]:
            name_lower = name.lower()
            if name_lower in HOST_ALIAS_EXCLUDE_EXACT:
                continue
            if name_lower in HOST_ALIAS_RESERVED_NAMES:
                continue
            if name_lower.startswith("ip6-"):
                continue
            if not valid_hostname(name):
                continue
            names.append(name)
    return list(dict.fromkeys(names))


def select_host_alias_names(spec, hosts_path=DEFAULT_HOSTS_PATH):
    spec = (spec or "off").strip()
    if spec == "off" or spec == "":
        return []
    if spec == "auto":
        names = parse_etc_hosts(hosts_path)
    else:
        names = []
        for raw in spec.split(","):
            if not raw:
                raise ValueError("empty entry in host alias list")
            if not valid_hostname(raw):
                raise ValueError("invalid host alias name: %s" % raw)
            if raw.lower() in HOST_ALIAS_EXCLUDE_EXACT or raw.lower() in HOST_ALIAS_RESERVED_NAMES:
                raise ValueError("reserved host alias name: %s" % raw)
            names.append(raw)
        names = list(dict.fromkeys(names))
    if len(names) > MAX_HOST_ALIAS_NAMES:
        names = names[:MAX_HOST_ALIAS_NAMES]
    return names


def container_published_tcp_ports(container_entry):
    if not isinstance(container_entry, dict):
        return {}
    settings = container_entry.get("NetworkSettings") if isinstance(container_entry.get("NetworkSettings"), dict) else {}
    ports = settings.get("Ports") if isinstance(settings.get("Ports"), dict) else {}
    result = {}
    for spec, bindings in ports.items():
        if not isinstance(bindings, list):
            continue
        if not valid_port_spec(str(spec)):
            continue
        proto = str(spec).rsplit("/", 1)[1]
        container_port = int(str(spec).split("/", 1)[0])
        for binding in bindings:
            if not isinstance(binding, dict):
                continue
            host_ip = str(binding.get("HostIp") or "")
            host_port_raw = str(binding.get("HostPort") or "")
            if host_ip not in ("", "0.0.0.0", "127.0.0.1", "::", "::1"):
                continue
            if not host_port_raw.isdigit():
                continue
            host_port = int(host_port_raw)
            if not (1 <= host_port <= 65535):
                continue
            result.setdefault(host_port, []).append((proto, container_port))
    return result


def list_running_container_ids(docker_bin):
    result = []
    for cid in run(docker_bin, ["ps", "-q"]).splitlines():
        cid = cid.strip()
        if cid:
            result.append(cid)
    return result


def build_host_aliases(docker_bin, names, selected, proxy_container_id):
    result = {"names": list(names), "ports": {}, "skipped": [], "skipped_not_granted": 0}
    if not names:
        return result
    try:
        ids = [cid for cid in list_running_container_ids(docker_bin) if cid != proxy_container_id]
    except Exception as exc:
        result["skipped"].append({"host_port": "", "container": "", "reason": sanitize_reason("docker ps failed: %s" % exc)})
        return result
    infos = batched_container_info(docker_bin, ids)
    granted = set(selected)
    dropped = 0
    skipped_dropped = 0
    not_granted = 0
    entries = []
    for cid, info in infos.items():
        cname = str(info.get("Name") or "").lstrip("/")
        settings = info.get("NetworkSettings") if isinstance(info.get("NetworkSettings"), dict) else {}
        networks = settings.get("Networks") if isinstance(settings.get("Networks"), dict) else {}
        container_networks = set(networks.keys())
        shared = sorted(container_networks & granted)
        published = container_published_tcp_ports(info)
        if not shared:
            for host_port, bindings in published.items():
                not_granted += len(bindings)
            continue
        for host_port, bindings in published.items():
            for proto, container_port in bindings:
                if proto != "tcp":
                    if len(result["skipped"]) >= MAX_HOST_ALIAS_SKIPPED:
                        skipped_dropped += 1
                        continue
                    result["skipped"].append({
                        "host_port": str(host_port),
                        "container": cname,
                        "reason": "non-tcp port publish (%s)" % proto,
                    })
                    continue
                entries.append((host_port, {
                    "container": cname,
                    "container_port": container_port,
                    "network": shared[0],
                }))
    entries.sort(key=lambda item: item[0])
    seen_ports = set()
    for host_port, entry in entries:
        if host_port in seen_ports:
            continue
        seen_ports.add(host_port)
        if len(result["ports"]) >= MAX_HOST_ALIAS_PORTS:
            dropped += 1
            continue
        result["ports"][str(host_port)] = entry
    if dropped:
        result["dropped"] = dropped
    if skipped_dropped:
        result["skipped_dropped"] = skipped_dropped
    result["skipped_not_granted"] = not_granted
    return result


def status_not_granted_detail(docker_bin, selected, proxy_container_id):
    detail = []
    try:
        ids = [cid for cid in list_running_container_ids(docker_bin) if cid != proxy_container_id]
    except Exception as exc:
        return [{"host_port": "", "container": "", "container_port": "", "networks": [],
                  "reason": sanitize_reason("docker ps failed: %s" % exc)}]
    infos = batched_container_info(docker_bin, ids)
    granted = set(selected)
    overflow = 0
    for _cid, info in infos.items():
        cname = sanitize_reason(str(info.get("Name") or "").lstrip("/"), 80)
        settings = info.get("NetworkSettings") if isinstance(info.get("NetworkSettings"), dict) else {}
        networks = settings.get("Networks") if isinstance(settings.get("Networks"), dict) else {}
        container_networks = set(networks.keys())
        if container_networks & granted:
            continue
        published = container_published_tcp_ports(info)
        if not published:
            continue
        sanitized_networks = cap_network_list(sanitize_reason(n, 60) for n in container_networks)
        for host_port, bindings in sorted(published.items(), key=lambda x: int(x[0]) if str(x[0]).isdigit() else 0):
            for proto, container_port in bindings:
                if proto != "tcp":
                    continue
                if len(detail) >= MAX_NOT_GRANTED_DETAIL:
                    overflow += 1
                    continue
                detail.append({
                    "host_port": sanitize_reason(str(host_port), 12),
                    "container": cname,
                    "container_port": container_port,
                    "networks": sanitized_networks,
                    "reason": sanitize_reason("not on a granted network"),
                })
    if overflow:
        detail.append({
            "host_port": "", "container": "", "container_port": "", "networks": [],
            "reason": sanitize_reason("%d more" % overflow),
        })
    return detail


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


def build_netmap(docker_bin, scope, selected, skipped, docs, proxy_container_id, proxy_url, raw_cidrs, host_aliases=None):
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
    if not isinstance(host_aliases, dict):
        host_aliases = {"names": [], "ports": {}, "skipped": []}
    return {
        "version": 2,
        "generated_at": generated_at,
        "proxy": {"url": proxy_url, "host": proxy_host, "port": proxy_port},
        "scope": scope,
        "networks": networks,
        "cidrs": list(raw_cidrs),
        "skipped": [{"network": item.get("network", ""), "reason": item.get("reason", "")} for item in skipped],
        "host_aliases": host_aliases,
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
    host_alias_names = select_host_alias_names(getattr(args, "host_aliases", "") or "off", getattr(args, "hosts_path", DEFAULT_HOSTS_PATH))
    host_aliases = build_host_aliases(args.docker_bin, host_alias_names, still_selected, args.container)
    netmap = build_netmap(args.docker_bin, args.scope, still_selected, skipped, docs, args.container, args.proxy_url, raw_cidrs, host_aliases)
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
        host_alias_names = select_host_alias_names(getattr(args, "host_aliases", "") or "off", getattr(args, "hosts_path", DEFAULT_HOSTS_PATH))
        host_aliases = build_host_aliases(args.docker_bin, host_alias_names, selected, args.container)
        netmap = build_netmap(args.docker_bin, args.scope, selected, skipped, docs, args.container, proxy_url, raw_cidrs, host_aliases)
        write_netmap(netmap_out, netmap)
    return {
        "internalIp": internal_ip,
        "internalCidr": internal_cidr,
        "appliedNetworks": selected,
        "targets": targets,
        "skipped": skipped,
    }


def print_host_alias_names(args):
    names = select_host_alias_names(args.host_aliases or "off", args.hosts_path)
    for name in names:
        print(name)
    return 0


def print_status_not_granted(args):
    proxy_id = args.container or ""
    if proxy_id and not NAME_RE.fullmatch(proxy_id):
        raise ValueError("invalid proxy container ID")
    detail = status_not_granted_detail(args.docker_bin, args.network, proxy_id)
    print(json.dumps(detail, ensure_ascii=True, separators=(",", ":")))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--docker-bin", default="docker")
    parser.add_argument("--container")
    parser.add_argument("--state-dir")
    parser.add_argument("--scope", choices=("all", "list"))
    parser.add_argument("--network", action="append", default=[])
    parser.add_argument("--cidr", action="append", default=[])
    parser.add_argument("--netmap-out", default="")
    parser.add_argument("--proxy-url", default="")
    parser.add_argument("--netmap-only", action="store_true")
    parser.add_argument("--host-aliases", default="off")
    parser.add_argument("--hosts-path", default=DEFAULT_HOSTS_PATH)
    parser.add_argument("--print-host-alias-names", action="store_true")
    parser.add_argument("--status-not-granted", action="store_true")
    args = parser.parse_args(argv)
    if args.print_host_alias_names:
        return print_host_alias_names(args)
    if args.status_not_granted:
        return print_status_not_granted(args)
    if not args.container or not NAME_RE.fullmatch(args.container):
        raise ValueError("invalid proxy container ID")
    if not args.state_dir:
        raise ValueError("--state-dir is required")
    if not args.scope:
        raise ValueError("--scope is required")
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
