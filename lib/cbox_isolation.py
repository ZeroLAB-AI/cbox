import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


ENGINES = ("claude", "codex", "hermes")
EXPERIMENTAL_ENGINES = (*ENGINES, "antigravity")
PROFILE = "engine-isolation"
RUNTIME_HOME = "/home/cbox"
RUNTIME_ROOT = "/opt/cbox-runtime"
RUNTIME_FILES = (
    "etc/hooks/continuity_session_start.py",
    "etc/hooks/conduct-kernel.txt",
    "etc/hooks/session-core.txt",
    "etc/hooks/rm_glob_guard.py",
)


def readonly_bind(source, target):
    source = str(source)
    if any(ord(char) < 32 or ord(char) == 127 or char == "$" for char in source):
        raise ValueError("bind source must not contain control characters or Compose interpolation")
    return {
        "type": "bind", "source": source, "target": target,
        "read_only": True, "bind": {"create_host_path": False},
    }


def runtime_files(files):
    install = Path(__file__).resolve().parents[1]
    mounts = []
    for relative, target in files:
        source = install / relative
        if source.resolve(strict=True) != source or not source.is_file():
            raise ValueError("runtime file must be a regular file inside CBOX: " + relative)
        mounts.append(readonly_bind(source, target))
    return mounts


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


def render(workspace, image, session, engines, uid, gid, *, runtime=False, release=None):
    workspace = workspace_path(workspace)
    if runtime and not (Path(workspace) / ".git").is_dir():
        raise ValueError("offline runtime requires a checkout with local .git metadata, not a linked worktree")
    if not isinstance(session, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", session):
        raise ValueError("session must be 1-32 lowercase letters, digits or hyphens")
    if not isinstance(image, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._/:@-]{0,254}", image):
        raise ValueError("image must be a literal local image reference")
    for key, value in (("uid", uid), ("gid", gid)):
        if type(value) is not int or not 1 <= value <= 2147483647:
            raise ValueError(key + " must be a positive non-root numeric identity")
    supported = EXPERIMENTAL_ENGINES if runtime else ENGINES
    if not engines or len(set(engines)) != len(engines) or any(engine not in supported for engine in engines):
        raise ValueError("select distinct supported engines: " + ", ".join(supported))
    if release is not None and (not runtime or "antigravity" not in engines):
        raise ValueError("a release requires --runtime and --engine antigravity")
    bundle = runtime_files((file, RUNTIME_ROOT + "/" + file) for file in RUNTIME_FILES) if runtime else []
    antigravity_mounts = []
    if "antigravity" in engines:
        antigravity_mounts = runtime_files((
            ("etc/hooks/antigravity_guard.py", RUNTIME_ROOT + "/etc/hooks/antigravity_guard.py"),
            ("etc/antigravity/hooks.json", RUNTIME_HOME + "/.gemini/config/hooks.json"),
        ))
        if release is not None:
            from cbox_antigravity import verify_release
            antigravity_mounts.append(readonly_bind(verify_release(release), "/opt/antigravity/agy"))
    digest = hashlib.sha256(workspace.encode()).hexdigest()[:16]
    project = ("cbox-runtime-" if runtime else "cbox-isolation-") + session + "-" + digest
    services = {}
    volumes = {}
    for engine in supported:
        if engine not in engines:
            continue
        state = engine + "-home"
        prepare = engine + "-home-init"
        labels = {"cbox.kind": "offline-runtime" if runtime else "isolation-lab", "cbox.engine": engine, "cbox.session": session}
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
            "environment": {"HOME": RUNTIME_HOME, "CBOX_ENGINE": engine, "CBOX_RUNTIME": labels["cbox.kind"]},
            "depends_on": {prepare: {"condition": "service_completed_successfully"}},
            "tmpfs": ["/tmp:rw,nosuid,nodev,noexec,mode=1777,size=67108864"],
            "volumes": [mount, readonly_bind(workspace, "/workspace"), *bundle],
        }
        if engine == "antigravity":
            services[engine]["volumes"].extend(antigravity_mounts)
    return {
        "name": project,
        "services": services,
        "volumes": volumes,
        "x-cbox-isolation": {"stage": "offline-runtime" if runtime else "offline-lab", "schema": 1, "runtime_ready": False},
    }


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["agy-release"]:
        from cbox_antigravity import main as release_main
        return release_main(argv[1:])
    if argv[:1] == ["agy"]:
        from cbox_antigravity_runtime import main as runtime_main
        return runtime_main(argv[1:])
    parser = argparse.ArgumentParser(prog="cbox isolation", description="Render an offline engine isolation lab; never launch containers or import credentials.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("render", help="print an independent Compose JSON document")
    command.add_argument("--experimental", action="store_true", help="acknowledge the offline lab stage")
    command.add_argument("--workspace", required=True)
    command.add_argument("--image", required=True, help="existing local CBOX image; no build or pull")
    command.add_argument("--session", required=True)
    command.add_argument("--engine", choices=EXPERIMENTAL_ENGINES, action="append", dest="engines")
    command.add_argument("--runtime", action="store_true", help="include the allowlisted offline runtime files")
    command.add_argument("--antigravity-release", type=Path, help="verified release prepared by agy-release")
    command.add_argument("--uid", type=int, default=os.getuid())
    command.add_argument("--gid", type=int, default=os.getgid())
    commands.add_parser("agy-release", help="prepare, verify or roll back an offline Antigravity release")
    commands.add_parser("agy", help="configure, probe and start the isolated Antigravity engine")
    args = parser.parse_args(argv)
    if not args.experimental:
        parser.error("render requires --experimental; normal cbox run is unchanged")
    try:
        document = render(args.workspace, args.image, args.session, args.engines or ENGINES,
                          args.uid, args.gid, runtime=args.runtime, release=args.antigravity_release)
    except (OSError, ValueError, RuntimeError) as exc:
        parser.error(str(exc))
    json.dump(document, sys.stdout, indent=2, ensure_ascii=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
