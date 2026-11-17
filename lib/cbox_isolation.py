import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


ENGINES = ("claude", "codex", "hermes")
PROFILE = "engine-isolation"
RUNTIME_HOME = "/home/cbox"


def workspace_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("workspace must be an absolute path without parent traversal")
    if any(ord(char) < 32 or ord(char) == 127 for char in value) or "$" in value:
        raise ValueError("workspace must not contain control characters or Compose interpolation")
    if path != path.resolve() or not path.is_dir():
        raise ValueError("workspace must be an existing directory without symlink components")
    owner_home = Path.home().resolve()
    if path == owner_home or path in owner_home.parents:
        raise ValueError("workspace must not expose the host home or its parent")
    for parent in ("/etc", "/proc", "/sys", "/dev", "/run", "/var/run"):
        reserved = Path(parent)
        if path == reserved or reserved in path.parents:
            raise ValueError("workspace must not expose host system paths")
    for name in (".claude", ".claude-cbox", ".codex", ".gemini", ".hermes", ".hermes-cbox", ".ssh", ".config", ".gnupg", ".docker"):
        private = owner_home / name
        if path == private or private in path.parents:
            raise ValueError("workspace must not expose host credential or configuration paths")
    marker = path / ".git"
    if marker.is_symlink() or not (marker.is_file() or marker.is_dir()):
        raise ValueError("workspace must be a git work-tree root")
    return str(path)


def render(workspace, image, session, engines, uid, gid):
    workspace = workspace_path(workspace)
    if not isinstance(session, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", session):
        raise ValueError("session must be 1-32 lowercase letters, digits or hyphens")
    if not isinstance(image, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,254}", image):
        raise ValueError("image must be a literal local image reference")
    for key, value in (("uid", uid), ("gid", gid)):
        if type(value) is not int or not 1 <= value <= 2147483647:
            raise ValueError(key + " must be a positive non-root numeric identity")
    if not engines or len(set(engines)) != len(engines) or any(engine not in ENGINES for engine in engines):
        raise ValueError("select distinct supported engines: " + ", ".join(ENGINES))
    digest = hashlib.sha256(workspace.encode()).hexdigest()[:16]
    project = "cbox-isolation-" + session + "-" + digest
    services = {}
    volumes = {}
    for engine in ENGINES:
        if engine not in engines:
            continue
        state = engine + "-home"
        prepare = engine + "-home-init"
        labels = {"cbox.kind": "isolation-lab", "cbox.engine": engine, "cbox.session": session}
        mount = {"type": "volume", "source": state, "target": RUNTIME_HOME, "volume": {"nocopy": True}}
        volumes[state] = {"labels": labels}
        common = {
            "image": image,
            "pull_policy": "never",
            "profiles": [PROFILE],
            "network_mode": "none",
            "read_only": True,
            "cap_drop": ["ALL"],
            "security_opt": ["no-new-privileges:true"],
            "restart": "no",
            "healthcheck": {"disable": True},
            "labels": labels,
        }
        services[prepare] = {
            **common,
            "user": "0:0",
            "cap_add": ["CHOWN"],
            "entrypoint": ["/bin/chown"],
            "command": [str(uid) + ":" + str(gid), RUNTIME_HOME],
            "volumes": [mount],
        }
        services[engine] = {
            **common,
            "user": str(uid) + ":" + str(gid),
            "init": True,
            "entrypoint": ["/bin/sleep"],
            "command": ["infinity"],
            "working_dir": "/workspace",
            "environment": {"HOME": RUNTIME_HOME, "CBOX_ENGINE": engine, "CBOX_RUNTIME": "isolation-lab"},
            "depends_on": {prepare: {"condition": "service_completed_successfully"}},
            "tmpfs": ["/tmp:rw,nosuid,nodev,noexec,mode=1777,size=67108864"],
            "volumes": [mount, {
                "type": "bind", "source": workspace, "target": "/workspace",
                "read_only": True, "bind": {"create_host_path": False},
            }],
        }
    return {
        "name": project,
        "services": services,
        "volumes": volumes,
        "x-cbox-isolation": {"stage": "offline-lab", "schema": 1, "runtime_ready": False},
    }


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cbox isolation", description="Render an offline engine isolation lab; never launch containers or import credentials.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("render", help="print an independent Compose JSON document")
    command.add_argument("--experimental", action="store_true", help="acknowledge the offline lab stage")
    command.add_argument("--workspace", required=True)
    command.add_argument("--image", required=True, help="existing local CBOX image; no build or pull")
    command.add_argument("--session", required=True)
    command.add_argument("--engine", choices=ENGINES, action="append", dest="engines")
    command.add_argument("--uid", type=int, default=os.getuid())
    command.add_argument("--gid", type=int, default=os.getgid())
    args = parser.parse_args(argv)
    if not args.experimental:
        parser.error("render requires --experimental; normal cbox run is unchanged")
    try:
        document = render(args.workspace, args.image, args.session, args.engines or ENGINES, args.uid, args.gid)
    except (OSError, ValueError, RuntimeError) as exc:
        parser.error(str(exc))
    json.dump(document, sys.stdout, indent=2, ensure_ascii=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
