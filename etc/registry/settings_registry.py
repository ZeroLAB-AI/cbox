#!/usr/bin/env python3
import json
import re
import sys

TOP_KEYS = {"schema_version", "sections", "dependency_text", "doctor_extra_rows", "variables"}

SECTION_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
VAR_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
DEP_REASON_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
UNSAFE_DEFAULT_RE = re.compile(r"\$\(|`|;|&|\n")
DEP_KIND_VALUES = {"dictate", "disable"}
APPLY_CLASS_VALUES = {"none", "shell", "restart", "recreate", "topology", "rebuild", "infra-reconcile"}
PROFILE_VALUES = {"ask", "auto", "skip"}
SCOPE_VALUES = {"project", "machine"}
ROLE_VALUES = {"setting", "internal"}

SECTION_REQUIRED_KEYS = {
    "id", "title", "description", "apply_class", "profile", "scope",
    "dependencies", "doctor_rows",
}

VAR_REQUIRED_KEYS = {
    "key", "section", "type", "default", "role", "export", "prompt", "help", "validator",
}

NAMED_VALIDATORS = {
    "no-validator",
    "hermes-version",
    "claude-target",
    "codex-version",
    "ollama-image",
    "ollama-keep-alive",
    "wg-address-cidr",
    "wg-peer-address-cidr",
    "wg-hostport-or-empty",
    "wg-pubkey-or-empty",
    "ipv4-or-empty",
    "path-slash-or-empty",
    "unvalidated-legacy-gap",
    "ipv4-list",
    "kernel-lang",
    "codex-model-slug",
}

NAMED_RESOLVERS = {
    "workdir_from_first_workspace",
    "ssh_agent_dir_default",
}

BUILTIN_TYPE_KINDS = {
    "enum", "enum-or-empty",
    "uint", "uint-or-empty", "uint-min", "uint-range",
    "port",
    "path", "path-or-empty",
    "url-or-empty",
    "string", "nonempty-string",
    "path-list", "network-name-list", "cidr-list", "apt-package-list", "wg-forward-list",
    "canonical-name-list",
    "hermes-version", "claude-target", "codex-version", "ollama-image",
    "wg-address-cidr", "wg-peer-address-cidr", "wg-hostport-or-empty",
    "wg-pubkey-or-empty", "ipv4-or-empty",
}


class RegistryError(ValueError):
    pass


def _require(cond, msg):
    if not cond:
        raise RegistryError(msg)


def _check_dependency(sec_id, dep):
    _require(isinstance(dep, dict), "section %s: dependency entry must be an object" % sec_id)
    extra = set(dep.keys()) - {"kind", "reason"}
    _require(not extra, "section %s: dependency has unknown keys %s" % (sec_id, sorted(extra)))
    missing = {"kind", "reason"} - set(dep.keys())
    _require(not missing, "section %s: dependency missing keys %s" % (sec_id, sorted(missing)))
    _require(dep["kind"] in DEP_KIND_VALUES, "section %s: dependency.kind must be one of %s" % (sec_id, sorted(DEP_KIND_VALUES)))
    _require(isinstance(dep["reason"], str) and DEP_REASON_RE.match(dep["reason"]),
              "section %s: dependency.reason must match %s" % (sec_id, DEP_REASON_RE.pattern))


def _check_section(spec):
    _require(isinstance(spec, dict), "section entry must be an object")
    extra = set(spec.keys()) - SECTION_REQUIRED_KEYS
    _require(not extra, "section has unknown keys %s" % sorted(extra))
    missing = SECTION_REQUIRED_KEYS - set(spec.keys())
    _require(not missing, "section missing keys %s: %r" % (sorted(missing), spec.get("id")))

    sec_id = spec["id"]
    _require(isinstance(sec_id, str) and SECTION_ID_RE.match(sec_id), "section id must match %s, got %r" % (SECTION_ID_RE.pattern, sec_id))
    _require(isinstance(spec["title"], str) and spec["title"], "section %s: title must be a non-empty string" % sec_id)
    _require(isinstance(spec["description"], str) and spec["description"], "section %s: description must be a non-empty string" % sec_id)
    _require(spec["apply_class"] in APPLY_CLASS_VALUES, "section %s: apply_class must be one of %s" % (sec_id, sorted(APPLY_CLASS_VALUES)))
    _require(spec["profile"] in PROFILE_VALUES, "section %s: profile must be one of %s" % (sec_id, sorted(PROFILE_VALUES)))
    _require(spec["scope"] in SCOPE_VALUES, "section %s: scope must be one of %s" % (sec_id, sorted(SCOPE_VALUES)))

    deps = spec["dependencies"]
    _require(isinstance(deps, list), "section %s: dependencies must be a list" % sec_id)
    for dep in deps:
        _check_dependency(sec_id, dep)

    rows = spec["doctor_rows"]
    _require(rows is None or (isinstance(rows, list) and all(isinstance(r, str) and r for r in rows)),
              "section %s: doctor_rows must be null or a list of non-empty strings" % sec_id)

    return sec_id


def _check_type(var_key, type_spec):
    _require(isinstance(type_spec, dict), "variable %s: type must be an object" % var_key)
    _require("kind" in type_spec, "variable %s: type missing kind" % var_key)
    kind = type_spec["kind"]
    _require(isinstance(kind, str), "variable %s: type.kind must be a string" % var_key)
    _require(kind in BUILTIN_TYPE_KINDS, "variable %s: unknown type.kind %r" % (var_key, kind))

    if kind in ("enum", "enum-or-empty"):
        values = type_spec.get("values")
        _require(isinstance(values, list) and values and all(isinstance(x, str) for x in values),
                  "variable %s: type.values must be a non-empty list of strings" % var_key)
        extra = set(type_spec.keys()) - {"kind", "values", "escape_hatch"}
        _require(not extra, "variable %s: enum type has unknown keys %s" % (var_key, sorted(extra)))
    elif kind == "uint-range":
        extra = set(type_spec.keys()) - {"kind", "min", "max"}
        _require(not extra, "variable %s: uint-range type has unknown keys %s" % (var_key, sorted(extra)))
        _require("min" in type_spec and "max" in type_spec, "variable %s: uint-range type requires min and max" % var_key)
        _require(isinstance(type_spec["min"], int) and isinstance(type_spec["max"], int) and type_spec["min"] <= type_spec["max"],
                  "variable %s: uint-range min/max must be integers with min <= max" % var_key)
    elif kind == "uint-min":
        extra = set(type_spec.keys()) - {"kind", "min"}
        _require(not extra, "variable %s: uint-min type has unknown keys %s" % (var_key, sorted(extra)))
        _require("min" in type_spec and isinstance(type_spec["min"], int), "variable %s: uint-min type requires an integer min" % var_key)
    elif kind == "cidr-list":
        extra = set(type_spec.keys()) - {"kind", "min_prefix"}
        _require(not extra, "variable %s: cidr-list type has unknown keys %s" % (var_key, sorted(extra)))
        if "min_prefix" in type_spec:
            _require(isinstance(type_spec["min_prefix"], int), "variable %s: cidr-list min_prefix must be an integer" % var_key)
    elif kind == "wg-address-cidr":
        extra = set(type_spec.keys()) - {"kind", "min_prefix", "escape_hatch"}
        _require(not extra, "variable %s: wg-address-cidr type has unknown keys %s" % (var_key, sorted(extra)))
        if "min_prefix" in type_spec:
            _require(isinstance(type_spec["min_prefix"], int), "variable %s: wg-address-cidr min_prefix must be an integer" % var_key)
    else:
        extra = set(type_spec.keys()) - {"kind", "escape_hatch"}
        _require(not extra, "variable %s: type %s has unknown keys %s" % (var_key, kind, sorted(extra)))

    if "escape_hatch" in type_spec:
        eh = type_spec["escape_hatch"]
        _require(isinstance(eh, str) and eh in NAMED_VALIDATORS, "variable %s: escape_hatch %r is not a bound named validator" % (var_key, eh))


def _check_literal_value_safe(var_key, value):
    if not isinstance(value, str):
        return
    _require(not UNSAFE_DEFAULT_RE.search(value),
              "variable %s: literal default %r contains an unsafe shell metacharacter ($( ` ; & or newline)" % (var_key, value))


def _check_default(var_key, default):
    if isinstance(default, dict):
        extra = set(default.keys()) - {"kind", "value", "name"}
        _require(not extra, "variable %s: default has unknown keys %s" % (var_key, sorted(extra)))
        _require("kind" in default, "variable %s: default object missing kind" % var_key)
        if default["kind"] == "literal":
            _require("value" in default, "variable %s: literal default missing value" % var_key)
            _check_literal_value_safe(var_key, default["value"])
        elif default["kind"] == "resolver":
            name = default.get("name")
            _require(isinstance(name, str) and name, "variable %s: resolver default missing name" % var_key)
            _require(name in NAMED_RESOLVERS, "variable %s: resolver %r is not a bound named resolver" % (var_key, name))
        else:
            raise RegistryError("variable %s: default.kind must be literal or resolver, got %r" % (var_key, default["kind"]))
    else:
        _require(isinstance(default, (str, int)), "variable %s: default must be a string, integer, or object" % var_key)
        _check_literal_value_safe(var_key, default)


def _check_variable(spec, section_ids):
    _require(isinstance(spec, dict), "variable entry must be an object")
    extra = set(spec.keys()) - VAR_REQUIRED_KEYS
    _require(not extra, "variable has unknown keys %s" % sorted(extra))
    missing = VAR_REQUIRED_KEYS - set(spec.keys())
    _require(not missing, "variable missing keys %s: %r" % (sorted(missing), spec.get("key")))

    key = spec["key"]
    _require(isinstance(key, str) and VAR_KEY_RE.match(key), "variable key must match %s, got %r" % (VAR_KEY_RE.pattern, key))

    section = spec["section"]
    _require(isinstance(section, str) and section, "variable %s: section must be a non-empty string" % key)
    _require(section in section_ids, "variable %s: references unknown section %r" % (key, section))

    _check_type(key, spec["type"])
    _check_default(key, spec["default"])

    _require(spec["role"] in ROLE_VALUES, "variable %s: role must be one of %s" % (key, sorted(ROLE_VALUES)))
    _require(isinstance(spec["export"], bool), "variable %s: export must be a boolean" % key)

    _require(spec["prompt"] is None or isinstance(spec["prompt"], str), "variable %s: prompt must be null or a string" % key)
    _require(spec["help"] is None or isinstance(spec["help"], str), "variable %s: help must be null or a string" % key)

    validator = spec["validator"]
    if validator is not None:
        _require(isinstance(validator, str) and validator in NAMED_VALIDATORS,
                  "variable %s: validator %r is not a bound named validator" % (key, validator))

    return key


def _check_default_against_type(var):
    key = var["key"]
    type_spec = var["type"]
    default = var["default"]
    if isinstance(default, dict):
        return
    kind = type_spec["kind"]
    val = str(default)
    if kind == "enum":
        _require(val in type_spec["values"], "variable %s: default %r fails its own enum type" % (key, default))
    elif kind == "enum-or-empty":
        _require(val == "" or val in type_spec["values"], "variable %s: default %r fails its own enum-or-empty type" % (key, default))
    elif kind in ("uint", "uint-min"):
        _require(val.isdigit(), "variable %s: default %r fails its own uint type" % (key, default))
        if kind == "uint-min":
            _require(int(val) >= type_spec["min"], "variable %s: default %r below uint-min %s" % (key, default, type_spec["min"]))
    elif kind == "uint-range":
        _require(val.isdigit(), "variable %s: default %r fails its own uint-range type" % (key, default))
        _require(type_spec["min"] <= int(val) <= type_spec["max"], "variable %s: default %r out of uint-range" % (key, default))
    elif kind == "port":
        _require(val.isdigit() and 1 <= int(val) <= 65535, "variable %s: default %r fails its own port type" % (key, default))
    elif kind == "nonempty-string":
        _require(val != "", "variable %s: default is empty but type is nonempty-string" % key)


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    _require(isinstance(data, dict), "top level must be an object")
    extra = set(data.keys()) - TOP_KEYS
    _require(not extra, "unknown top-level keys %s" % sorted(extra))
    required_top = {"schema_version", "sections", "variables"}
    missing = required_top - set(data.keys())
    _require(not missing, "missing top-level keys %s" % sorted(missing))

    _require(type(data["schema_version"]) is int and data["schema_version"] == 1,
              "schema_version must be 1, got %r" % (data["schema_version"],))

    sections = data["sections"]
    _require(isinstance(sections, list) and sections, "sections must be a non-empty list")
    section_ids = []
    for spec in sections:
        sid = _check_section(spec)
        _require(sid not in section_ids, "duplicate section id %r" % sid)
        section_ids.append(sid)
    section_id_set = set(section_ids)

    dep_text = data.get("dependency_text", {})
    _require(isinstance(dep_text, dict), "dependency_text must be an object")
    for k, v in dep_text.items():
        _require(isinstance(k, str) and isinstance(v, str) and v, "dependency_text entries must be string:non-empty-string, got %r:%r" % (k, v))

    for spec in sections:
        for dep in spec["dependencies"]:
            token = "%s:%s" % (dep["kind"], dep["reason"])
            _require(token in dep_text, "section %s: dependency %r has no dependency_text entry" % (spec["id"], token))

    extra_rows = data.get("doctor_extra_rows", [])
    _require(isinstance(extra_rows, list) and all(isinstance(r, str) and r for r in extra_rows),
              "doctor_extra_rows must be a list of non-empty strings")

    variables = data["variables"]
    _require(isinstance(variables, list) and variables, "variables must be a non-empty list")
    seen_keys = {}
    for spec in variables:
        key = _check_variable(spec, section_id_set)
        _require(key not in seen_keys, "variable %s is declared more than once (owned by %s and %s)" % (key, seen_keys.get(key), spec["section"]))
        seen_keys[key] = spec["section"]
        _check_default_against_type(spec)

    return data


def sections_in_order(data):
    return data["sections"]


def variables_for_section(data, section_id):
    return [v for v in data["variables"] if v["section"] == section_id]


def variables_in_section_order(data, scope=None):
    out = []
    for s in sections_in_order(data):
        if scope is not None and s["scope"] != scope:
            continue
        out.extend(variables_for_section(data, s["id"]))
    return out


def all_variable_keys(data):
    return [v["key"] for v in data["variables"]]


def dependency_text(data):
    return data.get("dependency_text", {})


def doctor_extra_rows(data):
    return data.get("doctor_extra_rows", [])


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


def _cmd_sections(path):
    data = load(path)
    for s in data["sections"]:
        print(s["id"])
    return 0


def _cmd_vars(path):
    data = load(path)
    for v in data["variables"]:
        print(v["key"])
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: settings_registry.py <validate|sections|vars> <path>", file=sys.stderr)
        return 2
    cmd = argv[0]
    path = argv[1]
    try:
        if cmd == "validate":
            return _cmd_validate(path)
        if cmd == "sections":
            return _cmd_sections(path)
        if cmd == "vars":
            return _cmd_vars(path)
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
