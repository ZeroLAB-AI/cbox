#!/usr/bin/env python3
import json
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

TOP_KEYS = {"schema", "engines"}
ENGINE_REQUIRED_KEYS = {"bin", "install", "probe", "version_vars", "enabled_var", "login"}
ENGINE_OPTIONAL_KEYS = {"preassign_id", "resume_argv", "seed_channel", "history_read"}
ENGINE_KEYS = ENGINE_REQUIRED_KEYS | ENGINE_OPTIONAL_KEYS
INSTALL_VALUES = {"bins-volume", "image"}
LOGIN_PREFIXES = ("oauth-bridge", "port-bridge:", "none")
SEED_CHANNEL_VALUES = {"sessionstart-hook", "pointer-prompt", "ephemeral-system-prompt"}
HISTORY_READ_VALUES = {"claude-jsonl", "codex-jsonl", "hermes-sqlite"}

PROBE_KEYS_EXE_STAMP = {"kind", "stamp", "infra_filter_argv1"}
PROBE_KEYS_CANONICAL_PATHS = {"kind", "exe_realpath_prefix", "argv0_prefix", "argv1"}


class RegistryError(ValueError):
    pass


def _require(cond, msg):
    if not cond:
        raise RegistryError(msg)


def _check_login(name, login):
    _require(isinstance(login, str), "engine %s: login must be a string" % name)
    ok = login == "none" or login == "oauth-bridge" or login.startswith("port-bridge:")
    _require(ok, "engine %s: login value not recognized: %r" % (name, login))
    if login.startswith("port-bridge:"):
        port = login[len("port-bridge:"):]
        _require(port.isdigit(), "engine %s: login port-bridge port not numeric: %r" % (name, login))


def _check_probe(name, probe):
    _require(isinstance(probe, dict), "engine %s: probe must be an object" % name)
    _require("kind" in probe, "engine %s: probe missing kind" % name)
    kind = probe["kind"]
    _require(isinstance(kind, str), "engine %s: probe.kind must be a string" % name)
    if kind == "exe-stamp":
        extra = set(probe.keys()) - PROBE_KEYS_EXE_STAMP
        _require(not extra, "engine %s: probe has unknown keys for exe-stamp: %s" % (name, sorted(extra)))
        missing = PROBE_KEYS_EXE_STAMP - set(probe.keys())
        _require(not missing, "engine %s: probe missing keys for exe-stamp: %s" % (name, sorted(missing)))
        _require(isinstance(probe["stamp"], str) and probe["stamp"], "engine %s: probe.stamp must be a non-empty string" % name)
        argv1 = probe["infra_filter_argv1"]
        _require(isinstance(argv1, list) and all(isinstance(x, str) for x in argv1), "engine %s: probe.infra_filter_argv1 must be a list of strings" % name)
    elif kind == "canonical-paths":
        extra = set(probe.keys()) - PROBE_KEYS_CANONICAL_PATHS
        _require(not extra, "engine %s: probe has unknown keys for canonical-paths: %s" % (name, sorted(extra)))
        missing = PROBE_KEYS_CANONICAL_PATHS - set(probe.keys())
        _require(not missing, "engine %s: probe missing keys for canonical-paths: %s" % (name, sorted(missing)))
        _require(isinstance(probe["exe_realpath_prefix"], str) and probe["exe_realpath_prefix"], "engine %s: probe.exe_realpath_prefix must be a non-empty string" % name)
        _require(isinstance(probe["argv0_prefix"], str) and probe["argv0_prefix"], "engine %s: probe.argv0_prefix must be a non-empty string" % name)
        argv1 = probe["argv1"]
        _require(isinstance(argv1, list) and all(isinstance(x, str) for x in argv1) and argv1, "engine %s: probe.argv1 must be a non-empty list of strings" % name)
    else:
        raise RegistryError("engine %s: probe.kind must be exe-stamp or canonical-paths, got %r" % (name, kind))


def _check_capabilities(name, spec):
    if "preassign_id" in spec:
        _require(isinstance(spec["preassign_id"], bool), "engine %s: preassign_id must be a boolean" % name)

    if "resume_argv" in spec:
        ra = spec["resume_argv"]
        _require(ra is None or (isinstance(ra, str) and ra), "engine %s: resume_argv must be null or a non-empty string" % name)

    if "seed_channel" in spec:
        sc = spec["seed_channel"]
        _require(sc is None or (isinstance(sc, str) and sc in SEED_CHANNEL_VALUES),
                  "engine %s: seed_channel must be null or one of %s" % (name, sorted(SEED_CHANNEL_VALUES)))

    if "history_read" in spec:
        hr = spec["history_read"]
        _require(hr is None or (isinstance(hr, str) and hr in HISTORY_READ_VALUES),
                  "engine %s: history_read must be null or one of %s" % (name, sorted(HISTORY_READ_VALUES)))


def _check_engine(name, spec):
    _require(isinstance(spec, dict), "engine %s: must be an object" % name)
    extra = set(spec.keys()) - ENGINE_KEYS
    _require(not extra, "engine %s: unknown keys %s" % (name, sorted(extra)))
    missing = ENGINE_REQUIRED_KEYS - set(spec.keys())
    _require(not missing, "engine %s: missing keys %s" % (name, sorted(missing)))

    _require(isinstance(spec["bin"], str) and spec["bin"], "engine %s: bin must be a non-empty string" % name)

    _require(isinstance(spec["install"], str), "engine %s: install must be a string" % name)
    _require(spec["install"] in INSTALL_VALUES, "engine %s: install must be one of %s" % (name, sorted(INSTALL_VALUES)))

    _check_probe(name, spec["probe"])

    vv = spec["version_vars"]
    _require(isinstance(vv, list) and vv and all(isinstance(x, str) and x for x in vv), "engine %s: version_vars must be a non-empty list of non-empty strings" % name)

    ev = spec["enabled_var"]
    _require(ev is None or (isinstance(ev, str) and ev), "engine %s: enabled_var must be null or a non-empty string" % name)

    _check_login(name, spec["login"])

    _check_capabilities(name, spec)


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    _require(isinstance(data, dict), "top level must be an object")
    extra = set(data.keys()) - TOP_KEYS
    _require(not extra, "unknown top-level keys %s" % sorted(extra))
    missing = TOP_KEYS - set(data.keys())
    _require(not missing, "missing top-level keys %s" % sorted(missing))

    _require(type(data["schema"]) is int and data["schema"] == 1, "schema must be 1, got %r" % (data["schema"],))

    engines = data["engines"]
    _require(isinstance(engines, dict) and engines, "engines must be a non-empty object")
    for name, spec in engines.items():
        _require(isinstance(name, str) and NAME_RE.match(name or ""), "engine name must match %s, got %r" % (NAME_RE.pattern, name))
        _check_engine(name, spec)

    return data


def _cmd_validate(path):
    try:
        load(path)
    except RegistryError as e:
        print("invalid: %s" % e, file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as e:
        print("invalid: %s" % e, file=sys.stderr)
        return 2
    print("valid: %s" % path)
    return 0


def _cmd_names(path):
    data = load(path)
    for name in data["engines"]:
        print(name)
    return 0


def _cmd_get(path, engine, dotted_key):
    data = load(path)
    if engine not in data["engines"]:
        print("no such engine: %s" % engine, file=sys.stderr)
        return 2
    node = data["engines"][engine]
    for part in dotted_key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            print("no such key: %s" % dotted_key, file=sys.stderr)
            return 2
    if isinstance(node, (dict, list)):
        print(json.dumps(node))
    elif node is None:
        print("null")
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: engines_registry.py <validate|names|get> <path> [engine] [dotted.key]", file=sys.stderr)
        return 2
    cmd = argv[0]
    path = argv[1]
    try:
        if cmd == "validate":
            return _cmd_validate(path)
        if cmd == "names":
            return _cmd_names(path)
        if cmd == "get":
            if len(argv) != 4:
                print("usage: engines_registry.py get <path> <engine> <dotted.key>", file=sys.stderr)
                return 2
            return _cmd_get(path, argv[2], argv[3])
        print("unknown command: %s" % cmd, file=sys.stderr)
        return 2
    except RegistryError as e:
        print("invalid: %s" % e, file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
