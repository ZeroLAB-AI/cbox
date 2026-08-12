#!/usr/bin/env python3
import json
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

TOP_KEYS = {"schema", "capabilities"}
CAPABILITY_REQUIRED_KEYS = {"class", "enforcement", "audience", "planes", "bindings", "degrade_floor"}
CAPABILITY_OPTIONAL_KEYS = {"sources", "enabled_when_env"}
CAPABILITY_KEYS = CAPABILITY_REQUIRED_KEYS | CAPABILITY_OPTIONAL_KEYS

CLASS_VALUES = {"context", "guard", "observe", "tool", "lifecycle"}
ENFORCEMENT_VALUES = {"hard", "behavioral", "advisory"}
AUDIENCE_VALUES = {"all", "driver", "delegate"}
PLANE_VALUES = {"substrate", "mediated", "native"}
DEGRADE_FLOOR_VALUES = {"advisory-text", "mine-history", "feature-off", "block-start", "none"}
BINDING_STATUS_LITERAL_VALUES = {"live", "declined"}
BINDING_REQUIRED_KEYS = {"mechanism", "status"}
BINDING_OPTIONAL_KEYS = {"matcher", "artifact"}
BINDING_KEYS = BINDING_REQUIRED_KEYS | BINDING_OPTIONAL_KEYS


class RegistryError(ValueError):
    pass


def _require(cond, msg):
    if not cond:
        raise RegistryError(msg)


def _check_rel_path(where, value):
    _require(isinstance(value, str) and value, "%s must be a non-empty string" % where)
    _require(not value.startswith("/"), "%s must be a relative path, got absolute %r" % (where, value))
    _require(".." not in value.replace("\\", "/").split("/"), "%s must not contain a parent-directory segment, got %r" % (where, value))


def _check_binding_status(cap_id, engine, status):
    _require(isinstance(status, str) and status, "capability %s: binding %s: status must be a non-empty string" % (cap_id, engine))
    if status in BINDING_STATUS_LITERAL_VALUES:
        return
    _require(status.startswith("gated:") and len(status) > len("gated:"),
              "capability %s: binding %s: status must be one of %s or gated:<experiment>, got %r" % (cap_id, engine, sorted(BINDING_STATUS_LITERAL_VALUES), status))


def _check_binding(cap_id, engine, spec):
    _require(isinstance(engine, str) and NAME_RE.match(engine or ""), "capability %s: binding engine name must match %s, got %r" % (cap_id, NAME_RE.pattern, engine))
    _require(isinstance(spec, dict), "capability %s: binding %s: must be an object" % (cap_id, engine))
    extra = set(spec.keys()) - BINDING_KEYS
    _require(not extra, "capability %s: binding %s: unknown keys %s" % (cap_id, engine, sorted(extra)))
    missing = BINDING_REQUIRED_KEYS - set(spec.keys())
    _require(not missing, "capability %s: binding %s: missing keys %s" % (cap_id, engine, sorted(missing)))

    _require(isinstance(spec["mechanism"], str) and spec["mechanism"], "capability %s: binding %s: mechanism must be a non-empty string" % (cap_id, engine))

    if "matcher" in spec:
        _require(isinstance(spec["matcher"], str) and spec["matcher"], "capability %s: binding %s: matcher must be a non-empty string" % (cap_id, engine))

    if "artifact" in spec:
        _check_rel_path("capability %s: binding %s: artifact" % (cap_id, engine), spec["artifact"])

    _check_binding_status(cap_id, engine, spec["status"])


def _check_capability(cap_id, spec):
    _require(isinstance(spec, dict), "capability %s: must be an object" % cap_id)
    extra = set(spec.keys()) - CAPABILITY_KEYS
    _require(not extra, "capability %s: unknown keys %s" % (cap_id, sorted(extra)))
    missing = CAPABILITY_REQUIRED_KEYS - set(spec.keys())
    _require(not missing, "capability %s: missing keys %s" % (cap_id, sorted(missing)))

    _require(spec["class"] in CLASS_VALUES, "capability %s: class must be one of %s, got %r" % (cap_id, sorted(CLASS_VALUES), spec["class"]))
    _require(spec["enforcement"] in ENFORCEMENT_VALUES, "capability %s: enforcement must be one of %s, got %r" % (cap_id, sorted(ENFORCEMENT_VALUES), spec["enforcement"]))
    _require(spec["audience"] in AUDIENCE_VALUES, "capability %s: audience must be one of %s, got %r" % (cap_id, sorted(AUDIENCE_VALUES), spec["audience"]))

    planes = spec["planes"]
    _require(isinstance(planes, list) and planes, "capability %s: planes must be a non-empty list" % cap_id)
    for p in planes:
        _require(p in PLANE_VALUES, "capability %s: planes member must be one of %s, got %r" % (cap_id, sorted(PLANE_VALUES), p))

    _require(spec["degrade_floor"] in DEGRADE_FLOOR_VALUES, "capability %s: degrade_floor must be one of %s, got %r" % (cap_id, sorted(DEGRADE_FLOOR_VALUES), spec["degrade_floor"]))

    if "sources" in spec:
        sources = spec["sources"]
        _require(isinstance(sources, list) and sources, "capability %s: sources must be a non-empty list" % cap_id)
        for src in sources:
            _check_rel_path("capability %s: sources entry" % cap_id, src)

    if "enabled_when_env" in spec:
        ewe = spec["enabled_when_env"]
        _require(ewe is None or (isinstance(ewe, list) and ewe and all(isinstance(x, str) and x for x in ewe)),
                  "capability %s: enabled_when_env must be null or a non-empty list of non-empty strings" % cap_id)

    bindings = spec["bindings"]
    _require(isinstance(bindings, dict), "capability %s: bindings must be an object" % cap_id)
    for engine, bspec in bindings.items():
        _check_binding(cap_id, engine, bspec)


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    _require(isinstance(data, dict), "top level must be an object")
    extra = set(data.keys()) - TOP_KEYS
    _require(not extra, "unknown top-level keys %s" % sorted(extra))
    missing = TOP_KEYS - set(data.keys())
    _require(not missing, "missing top-level keys %s" % sorted(missing))

    _require(type(data["schema"]) is int and data["schema"] == 1, "schema must be 1, got %r" % (data["schema"],))

    capabilities = data["capabilities"]
    _require(isinstance(capabilities, dict) and capabilities, "capabilities must be a non-empty object")
    for cap_id, spec in capabilities.items():
        _require(isinstance(cap_id, str) and NAME_RE.match(cap_id or ""), "capability id must match %s, got %r" % (NAME_RE.pattern, cap_id))
        _check_capability(cap_id, spec)

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
    for name in data["capabilities"]:
        print(name)
    return 0


def _cmd_get(path, cap_id, dotted_key):
    data = load(path)
    if cap_id not in data["capabilities"]:
        print("no such capability: %s" % cap_id, file=sys.stderr)
        return 2
    node = data["capabilities"][cap_id]
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
        print("usage: capability_registry.py <validate|names|get> <path> [capability] [dotted.key]", file=sys.stderr)
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
                print("usage: capability_registry.py get <path> <capability> <dotted.key>", file=sys.stderr)
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
