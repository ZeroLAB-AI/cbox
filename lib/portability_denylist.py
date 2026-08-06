#!/usr/bin/env python3
import json
import os
import re
import sys

INSTALL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY_PATH = os.path.join(INSTALL_DIR, "etc", "registry", "file_inventory.json")
BASELINE_PATH = os.path.join(INSTALL_DIR, "lib", "fixtures", "portability_denylist_baseline.json")

CONSTRUCTS = [
    ("declare_a", r'\bdeclare\s+(-\S+\s+)*-A\b'),
    ("nameref", r'\b(declare|local)\s+(-\S+\s+)*-n\b'),
    ("mapfile", r'(?<![\w./-])mapfile\b'),
    ("caret_expansion", r'\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?(\^\^?|,,?)[^}]*\}'),
    ("stat_c", r'(?<![\w./-])stat\s+(-\S+\s+)*-c\b'),
    ("sed_i", r'(?<![\w./-])sed\b[^|;&<>#\n]*\s-i(?!nteractive)\b'),
    ("sha256sum", r'(?<![\w./-])sha256sum\b'),
    ("xargs_r", r'(?<![\w./-])xargs\s+(-\S+\s+)*-r\b'),
    ("raw_timeout", r'(?<![\w./-])timeout\s+((-\S+\s+)(\S+\s+)?)*["\']?[\$\d]'),
    ("raw_realpath", r'(?<![\w./-])realpath\b'),
    ("raw_flock", r'(?<![\w./-])flock\b'),
    ("mountpoint", r'(?<![\w./-])mountpoint\b'),
    ("proc_path", r'/proc/'),
    ("xdg_runtime_dir", r'\bXDG_RUNTIME_DIR\b'),
    ("ip_route", r'(?<![\w./-])ip\s+route\b'),
]
CONSTRUCT_ORDER = [name for name, _ in CONSTRUCTS]
CONSTRUCT_RX = [(name, re.compile(pattern)) for name, pattern in CONSTRUCTS]

DISCOVERABLE_SUFFIXES = (".sh", ".py")

SCAN_EXEMPT = frozenset(
    [
        "lib/portability_denylist.py",
        "lib/portable_preflight.sh",
        "lib/portable.sh",
        "lib/cbox_host.py",
    ]
)


def load_inventory():
    with open(INVENTORY_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def host_layer_files(inventory):
    return sorted(
        path
        for path, meta in inventory["files"].items()
        if meta["layer"] == "host" and path not in SCAN_EXEMPT
    )


def is_discoverable(path):
    base = os.path.basename(path)
    if base.endswith(DISCOVERABLE_SUFFIXES):
        return True
    if ".sh" in base:
        return True
    try:
        with open(path, "rb") as fh:
            head = fh.read(2)
    except OSError:
        return False
    return head == b"#!"


EXCLUDED_DIRS = frozenset([".git", "generated"])


def discover_tree_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir != "." and rel_dir.split(os.sep)[0] in EXCLUDED_DIRS:
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if is_discoverable(os.path.join(dirpath, name)):
                found.append(rel)
    return sorted(found)


def inventory_coverage_gaps(inventory):
    tree_files = set(discover_tree_files(INSTALL_DIR))
    inv_files = set(inventory["files"].keys())
    missing_from_inventory = sorted(tree_files - inv_files)
    missing_from_tree = sorted(inv_files - tree_files)
    return missing_from_inventory, missing_from_tree


def count_file(path):
    abs_path = os.path.join(INSTALL_DIR, path)
    with open(abs_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    hits = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for name, rx in CONSTRUCT_RX:
            found = len(rx.findall(line))
            if found:
                hits[name] = hits.get(name, 0) + found
    return hits


def scan(inventory):
    per_file = {}
    for path in host_layer_files(inventory):
        hits = count_file(path)
        if hits:
            per_file[path] = hits
    return per_file


def totals_from_per_file(per_file):
    totals = {}
    for hits in per_file.values():
        for name, count in hits.items():
            totals[name] = totals.get(name, 0) + count
    return totals


def load_baseline():
    with open(BASELINE_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def write_baseline(per_file):
    totals = totals_from_per_file(per_file)
    out = {
        "schema_version": 1,
        "regen_command": "python3 lib/portability_denylist.py regen",
        "note": "pinned occurrence counts for the GNU/bashism denylist over host-layer files (cbox/docs/MULTIPLATFORM_DESIGN.md section 4 step 0a); a new occurrence anywhere fails the ratchet, a reduced count fails too until this baseline is regenerated",
        "totals": totals,
        "per_file": per_file,
    }
    with open(BASELINE_PATH, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True, ensure_ascii=True)
        fh.write("\n")
    return out


def diff_against_baseline(current, baseline):
    problems = []
    baseline_per_file = baseline["per_file"]
    all_files = sorted(set(current.keys()) | set(baseline_per_file.keys()))
    for path in all_files:
        cur_hits = current.get(path, {})
        base_hits = baseline_per_file.get(path, {})
        names = sorted(set(cur_hits.keys()) | set(base_hits.keys()))
        for name in names:
            cur_count = cur_hits.get(name, 0)
            base_count = base_hits.get(name, 0)
            if cur_count > base_count:
                problems.append(
                    "%s: new %s occurrence(s): baseline=%d current=%d"
                    % (path, name, base_count, cur_count)
                )
            elif cur_count < base_count:
                problems.append(
                    "%s: %s occurrence count dropped without a baseline regen: baseline=%d current=%d"
                    % (path, name, base_count, cur_count)
                )
    return problems


def cmd_check():
    inventory = load_inventory()
    missing_from_inventory, missing_from_tree = inventory_coverage_gaps(inventory)
    if missing_from_inventory:
        sys.stderr.write(
            "portability_denylist: file(s) present in the tree but absent from etc/registry/file_inventory.json:\n"
        )
        for path in missing_from_inventory:
            sys.stderr.write("  %s\n" % path)
        return 1
    if missing_from_tree:
        sys.stderr.write(
            "portability_denylist: file(s) listed in etc/registry/file_inventory.json but absent from the tree:\n"
        )
        for path in missing_from_tree:
            sys.stderr.write("  %s\n" % path)
        return 1

    current = scan(inventory)
    baseline = load_baseline()
    problems = diff_against_baseline(current, baseline)
    if problems:
        sys.stderr.write("portability_denylist: baseline ratchet violated:\n")
        for p in problems:
            sys.stderr.write("  %s\n" % p)
        sys.stderr.write(
            "regenerate the baseline only after confirming the change is an intended reduction: python3 lib/portability_denylist.py regen\n"
        )
        return 1

    totals = totals_from_per_file(current)
    sys.stdout.write(
        "portability_denylist: %d host-layer files, %d files with hits, totals=%s\n"
        % (len(host_layer_files(inventory)), len(current), json.dumps(totals, sort_keys=True))
    )
    return 0


def cmd_regen():
    inventory = load_inventory()
    missing_from_inventory, missing_from_tree = inventory_coverage_gaps(inventory)
    if missing_from_inventory or missing_from_tree:
        sys.stderr.write(
            "portability_denylist: refusing to regenerate the baseline while the inventory is out of sync with the tree\n"
        )
        return 1
    per_file = scan(inventory)
    out = write_baseline(per_file)
    sys.stdout.write(
        "portability_denylist: baseline regenerated, totals=%s\n"
        % json.dumps(out["totals"], sort_keys=True)
    )
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd == "check":
        return cmd_check()
    if cmd == "regen":
        return cmd_regen()
    sys.stderr.write("usage: portability_denylist.py [check|regen]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
