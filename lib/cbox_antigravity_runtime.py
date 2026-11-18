import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile

from cbox_antigravity import read_json, verify_release
from cbox_isolation import PROFILE, render, readonly_bind, workspace_path


BINARY = "/opt/antigravity/agy"
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")
MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}")
DOMAIN = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}")
EFFORTS = ("low", "medium", "high", "xhigh", "max")


def workspace():
    result = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
    return Path(workspace_path(result.stdout.rstrip("\n")))


def state_dir(root):
    key = hashlib.sha256(os.fsencode(root)).hexdigest()[:24]
    return Path.home().resolve() / ".config" / "cbox" / "antigravity" / key


def owner_directory(path, create=False):
    if path.resolve() != path:
        raise ValueError("Antigravity configuration directory must not be a symlink")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Antigravity configuration directory must be private to the current user")


def image_id(value):
    if not value or value.startswith("-") or not value.isascii() or any(char.isspace() for char in value):
        raise ValueError("provide an existing local image reference")
    result = subprocess.run(["docker", "image", "inspect", "--format", "{{.Id}}", "--", value], check=True,
                            stdout=subprocess.PIPE, text=True, timeout=15)
    ident = result.stdout.strip()
    if not IMAGE_ID.fullmatch(ident):
        raise ValueError("Docker did not return an immutable image ID")
    return ident


def require_local_docker():
    endpoint = os.environ.get("DOCKER_HOST", "") if not os.environ.get("DOCKER_CONTEXT") else ""
    if not endpoint:
        result = subprocess.run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                                check=True, stdout=subprocess.PIPE, text=True, timeout=10)
        endpoint = result.stdout.strip()
    if not endpoint.startswith("unix:///") or "\n" in endpoint:
        raise ValueError("Antigravity bind mounts require a local Docker Unix socket context")


def validate_config(doc):
    keys = {"schema", "engine_image", "proxy_image", "release", "binary_sha256", "domains"}
    if not isinstance(doc, dict) or set(doc) != keys or type(doc["schema"]) is not int or doc["schema"] != 1:
        raise ValueError("invalid Antigravity configuration schema")
    if not all(isinstance(doc[key], str) and IMAGE_ID.fullmatch(doc[key]) for key in ("engine_image", "proxy_image")):
        raise ValueError("runtime images must be pinned by immutable Docker IDs")
    domains = doc["domains"]
    if not isinstance(domains, list) or not 1 <= len(domains) <= 64 or any(
        not isinstance(domain, str) or len(domain) > 253 or not DOMAIN.fullmatch(domain)
        for domain in domains
    ) or len(set(domains)) != len(domains):
        raise ValueError("supply a distinct list of exact DNS names for Antigravity egress")
    if not isinstance(doc["release"], str) or not Path(doc["release"]).is_absolute():
        raise ValueError("Antigravity release directory must be absolute")
    binary = verify_release(doc["release"])
    if read_json(binary.with_name("provenance.json"))["binary_sha256"] != doc["binary_sha256"]:
        raise ValueError("Antigravity release differs from the configured binary digest")
    return doc


def config(path):
    try:
        owner_directory(path)
        manifest = path / "runtime.json"
        info = manifest.lstat()
    except FileNotFoundError as exc:
        raise ValueError("Antigravity is disabled for this workspace; use 'cbox isolation agy configure'") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Antigravity configuration must be an owner-only regular file")
    return validate_config(read_json(manifest))


def fingerprint(doc):
    return hashlib.sha256(json.dumps(doc, sort_keys=True).encode("ascii")).hexdigest()


def require_probe(path, doc):
    stamp = path / "probe.json"
    if not stamp.is_symlink():
        try:
            if read_json(stamp) == {"configuration": fingerprint(doc)}:
                return
        except (FileNotFoundError, ValueError):
            pass
    raise ValueError("run 'cbox isolation agy probe' on the host before using this release")


@contextmanager
def exclusive(path, create=False):
    owner_directory(path, create)
    fd = os.open(path / "runtime.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Antigravity is already active in this workspace") from exc
        yield


def write_config(path, doc, filename="runtime.json"):
    fd, name = tempfile.mkstemp(dir=path, prefix="runtime-")
    staged = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            json.dump(doc, stream, ensure_ascii=True)
            stream.write("\n")
        staged.replace(path / filename)
    finally:
        staged.unlink(missing_ok=True)


def egress_files(directory, domains):
    filters = directory / "domains"
    filters.write_text("".join("^" + domain.replace(".", "[.]") + "$\n" for domain in domains), encoding="ascii")
    settings = directory / "tinyproxy.conf"
    settings.write_text(
        'Port 8888\nTimeout 120\nMaxClients 16\nLogLevel Error\nLogFile "/dev/null"\n'
        'PidFile "/tmp/tinyproxy.pid"\nDisableViaHeader Yes\nFilterExtended On\nFilterURLs Off\n'
        'FilterDefaultDeny Yes\nFilter "/etc/cbox-egress/domains"\nConnectPort 443\n', encoding="ascii",
    )
    return (readonly_bind(settings, "/etc/cbox-egress/tinyproxy.conf"), readonly_bind(filters, "/etc/cbox-egress/domains"))


def compose_document(root, doc, directory, operation, uid, gid):
    offline = operation == "probe"
    plan = render(str(root), doc["engine_image"], "agy-smoke" if offline else "agy-runtime", ["antigravity"],
                  uid, gid, runtime=True, release=doc["release"])
    worker = plan["services"]["antigravity"]
    worker["working_dir"] = "/home/cbox" if operation in ("probe", "login") else str(root)
    worker["entrypoint"] = [BINARY]
    worker.pop("command")
    worker["volumes"] = [mount for mount in worker["volumes"] if mount["target"] != "/workspace"]
    if operation in ("cli", "acp"):
        for protected in (Path("/home/cbox"), Path("/opt/cbox-runtime"), Path(BINARY).parent):
            if root.is_relative_to(protected) or protected.is_relative_to(root):
                raise ValueError("workspace overlaps an Antigravity runtime path")
        bind = readonly_bind(root, str(root))
        bind["read_only"] = False
        worker["volumes"].append(bind)
        worker["environment"]["CBOX_RUNTIME_WORKSPACE"] = str(root)
    if offline:
        return plan
    worker.pop("network_mode")
    worker["networks"] = ["client"]
    worker["dns"] = ["127.0.0.1"]
    worker["environment"].update(HTTP_PROXY="http://gateway:8888", HTTPS_PROXY="http://gateway:8888",
                                 http_proxy="http://gateway:8888", https_proxy="http://gateway:8888",
                                 BROWSER="/bin/false", SSH_CONNECTION="127.0.0.1 1 127.0.0.1 1")
    worker["depends_on"]["gateway"] = {"condition": "service_healthy"}
    plan["services"]["gateway"] = {
        "image": doc["proxy_image"], "pull_policy": "never", "profiles": [PROFILE],
        "networks": ["client", "external-egress"], "user": str(uid) + ":" + str(gid),
        "entrypoint": ["tinyproxy", "-d", "-c", "/etc/cbox-egress/tinyproxy.conf"],
        "read_only": True, "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
        "tmpfs": ["/tmp:rw,nosuid,nodev,noexec,mode=1777,size=1048576"],
        "volumes": list(egress_files(directory, doc["domains"])),
        "healthcheck": {"test": ["CMD", "nc", "-z", "127.0.0.1", "8888"], "interval": "1s", "timeout": "1s", "retries": 10},
    }
    plan["networks"] = {
        "client": {"internal": True, "driver": "bridge", "enable_ipv6": False, "driver_opts": {
            "com.docker.network.bridge.gateway_mode_ipv4": "isolated",
        }},
        "external-egress": {"driver": "bridge"},
    }
    plan["x-cbox-isolation"]["stage"] = "antigravity-opt-in"
    return plan


class StopLaunch(Exception):
    def __init__(self, signum):
        self.signum = signum


def compose_call(command):
    child = subprocess.Popen(command)
    try:
        return child.wait()
    except BaseException:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        raise


def launch(root, path, operation, arguments):
    if not path.is_dir():
        config(path)
    with exclusive(path):
        doc = config(path)
        if operation != "probe":
            require_probe(path, doc)
        with tempfile.TemporaryDirectory(dir=path, prefix="compose-") as name:
            directory = Path(name)
            plan = compose_document(root, doc, directory, operation, os.getuid(), os.getgid())
            source = directory / "compose.json"
            source.write_text(json.dumps(plan), encoding="ascii")
            prefix = ["docker", "compose", "--progress", "quiet", "--project-name", plan["name"],
                      "-f", str(source), "--profile", PROFILE]
            command = [*prefix, "run", "--rm"]
            if operation in ("probe", "acp") or not sys.stdin.isatty():
                command.append("-T")
            command.append("antigravity")
            try:
                if operation == "probe":
                    rc = compose_call([*command, "--version"])
                    rc = rc or compose_call([*command, "acp", "--help"])
                    if not rc:
                        write_config(path, {"configuration": fingerprint(doc)}, "probe.json")
                    return rc
                if operation == "login":
                    if not (sys.stdin.isatty() and sys.stdout.isatty()):
                        raise ValueError("run Antigravity login from a host terminal")
                    return compose_call([*command, "acp", "--login"])
                if operation == "acp":
                    return compose_call([*command, "acp"])
                return compose_call([*command, *arguments])
            finally:
                subprocess.run([*prefix, "down", "--remove-orphans"], stdout=sys.stderr,
                               stderr=sys.stderr, timeout=30, check=False)


def editor(root, path, install):
    require_probe(path, config(path))
    proxy = install / "lib" / "cbox_acp_proxy.py"
    os.execv(sys.executable, [sys.executable, str(proxy), "--root", str(root), "--project-root", str(root),
                             "--engine", "antigravity", "--log", str(path / "acp-blocked.log"), "--",
                             sys.executable, str(Path(__file__).resolve()), "backend"])


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cbox isolation agy")
    commands = parser.add_subparsers(dest="operation", required=True)
    prepare = commands.add_parser("configure", help="pin the isolated images, release, and vendor allowlist for this workspace")
    prepare.add_argument("--image", required=True)
    prepare.add_argument("--proxy-image", required=True)
    prepare.add_argument("--release", type=Path, required=True)
    prepare.add_argument("--allow-domain", action="append", required=True)
    console = commands.add_parser("cli")
    console.add_argument("--model")
    console.add_argument("--effort", choices=EFFORTS)
    for name in ("probe", "login", "acp", "backend", "status"):
        commands.add_parser(name)
    args = parser.parse_args(argv)

    def stop(signum, _frame):
        raise StopLaunch(signum)

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, stop)
    try:
        root = workspace()
        path = state_dir(root)
        if args.operation == "status":
            if not (path / "runtime.json").exists():
                print("disabled")
                return 0
            doc = config(path)
            try:
                require_probe(path, doc)
            except ValueError:
                print("configured; offline probe pending")
            else:
                print("configured; offline probe passed")
            return 0
        if os.environ.get("CBOX_RUNTIME") == "container":
            raise ValueError("run Antigravity configuration and launch commands from the host")
        if args.operation == "configure":
            require_local_docker()
            release = verify_release(args.release).parent
            pin = read_json(release / "provenance.json")
            doc = validate_config({"schema": 1, "engine_image": image_id(args.image), "proxy_image": image_id(args.proxy_image),
                                   "release": str(release), "binary_sha256": pin["binary_sha256"],
                                   "domains": sorted(set(args.allow_domain))})
            with exclusive(path, create=True):
                write_config(path, doc)
            print("Antigravity configuration saved; run 'cbox isolation agy probe' then 'cbox isolation agy login'")
            return 0
        if args.operation == "acp":
            editor(root, path, Path(__file__).resolve().parents[1])
        if not (path / "runtime.json").exists():
            config(path)
        if args.operation == "cli":
            if args.model is not None and not MODEL.fullmatch(args.model):
                raise ValueError("invalid Antigravity model name")
            flags = []
            for key in ("model", "effort"):
                if getattr(args, key) is not None:
                    flags.extend(["--" + key, getattr(args, key)])
            require_local_docker()
            return launch(root, path, "cli", flags)
        require_local_docker()
        return launch(root, path, "acp" if args.operation == "backend" else args.operation, [])
    except FileNotFoundError:
        parser.exit(1, "cbox isolation agy: Docker or the configured runtime state is unavailable\n")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.exit(1, "cbox isolation agy: " + str(exc) + "\n")
    except StopLaunch as exc:
        return 128 + exc.signum


if __name__ == "__main__":
    raise SystemExit(main())
