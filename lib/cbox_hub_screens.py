import unicodedata
from cbox_hub_ui import Action

COLS = 80

MAIN_AREAS = [
    ("e", "sessions", "sessions"),
    ("n", "network", "network"),
    ("o", "ollama", "ollama"),
    ("h", "hyperqwen", "hyperqwen"),
    ("l", "llm", "llm"),
    ("w", "wireguard", "wireguard"),
    ("s", "settings", "settings"),
    ("m", "maintenance", "maintenance"),
]

CONFIRM_DEFAULT_PROMPTS = {
    "down-force": "a session looks live - type FORCE to stop anyway, anything else to cancel",
    "wg-up": "start wireguard (opens a port)",
    "wg-remove-client": "remove this wireguard client",
    "wg-plain": "print a client config that leaves its private key on disk",
    "images-rm": "remove this image",
    "bins-rollback": "roll back to the previous binary",
    "gc": "garbage-collect unused images/volumes",
    "session-close": "close this session",
}


def _char_width(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def display_width(text):
    return sum(_char_width(ch) for ch in text)


def _truncate(text, width, suffix="..."):
    if display_width(text) <= width:
        return text
    out = ""
    suffix_width = display_width(suffix)
    if suffix_width > width:
        suffix = ""
        suffix_width = 0
    limit = width - suffix_width
    used = 0
    for ch in text:
        cw = _char_width(ch)
        if used + cw > limit:
            break
        out += ch
        used += cw
    return out + suffix


def _row(text):
    return _truncate(text, COLS)


def _key_column(key):
    return " " + key + (" " * max(0, 3 - display_width(key))) + " "


def render_main(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    root = ctx.get("root") or "."
    mode = ctx.get("mode", "none")
    lines = []
    head = "cbox  %s  %s" % (root, mode)
    profile = ctx.get("profile")
    if profile and profile != "default":
        head += "  profile %s" % profile
    elif ctx.get("profile_error"):
        head += "  profile ?"
    lines.append(_row(head))
    lines.append("-" * COLS)

    status = []
    container_state = snapshot.get("container_state")
    if container_state:
        status.append("container  %s" % container_state)
    doctor_warnings = snapshot.get("doctor_warnings")
    if doctor_warnings:
        status.append("doctor: %d warning%s" % (
            doctor_warnings, "" if doctor_warnings == 1 else "s"))
    for s in status:
        lines.append(_row(s))
    if status:
        lines.append("")

    actions = []
    engine_names = snapshot.get("engine_names") or []
    engine_state = snapshot.get("engine_state") or {}
    engine_rows = []
    for i, name in enumerate(engine_names[:9], start=1):
        state = engine_state.get(name, "unknown")
        verb = "attach" if state == "running" else "start"
        argv = [cbox_path, "run", name]
        actions.append(Action(str(i), name, kind="run", argv=argv))
        engine_rows.append(" %d " % i + name +
                           (" " * max(0, 9 - display_width(name))) + " " + verb)

    area_rows = []
    for key, label, submenu in MAIN_AREAS:
        if key == "s":
            actions.append(Action(key, label, kind="settings"))
        else:
            actions.append(Action(key, label, kind="submenu", submenu=submenu,
                                   hint="%s %s" % (cbox_path, submenu)))
        area_rows.append(" %s %s" % (key, label))

    shell_argv = [cbox_path, "shell"]
    actions.append(Action("t", "shell", kind="run", argv=shell_argv))
    area_rows.append(" t shell")
    actions.append(Action("q", "quit", kind="quit", hint="quit"))
    area_rows.append(" q quit")

    n = max(len(engine_rows), len(area_rows))
    for idx in range(n):
        left = engine_rows[idx] if idx < len(engine_rows) else ""
        right = area_rows[idx] if idx < len(area_rows) else ""
        padding = " " * max(0, 30 - display_width(left))
        lines.append(_row((left + padding + right).rstrip()))
    lines.append("")

    actions.append(Action("r", "refresh", kind="refresh", hint="refresh status"))
    actions.append(Action("?", "commands", kind="hints", hint="show command hints"))

    default = actions[0] if actions else None
    footer_left = "Enter=%s   ?=commands" % (default.key if default else "")
    cmd_hint = "cmd: %s" % (default.hint if default else "")
    budget = COLS - display_width(footer_left) - 1
    if budget < 4:
        budget = 4
    cmd_hint = _truncate(cmd_hint, budget)
    pad = max(1, COLS - display_width(footer_left) - display_width(cmd_hint))
    footer_line = footer_left + (" " * pad) + cmd_hint
    lines.append(_row(footer_line))

    text = "\n".join(lines) + "\n"
    return text, actions


def render_hints(actions):
    lines = ["command hints", "-" * COLS]
    for a in actions:
        label_padding = " " * max(0, 14 - display_width(a.label))
        lines.append(_row(_key_column(a.key) + a.label + label_padding + " " + a.hint))
    lines.append("")
    lines.append("press any key to go back")
    return "\n".join(lines) + "\n"


def _submenu_header(title, ctx):
    root = ctx.get("root") or "."
    lines = [_row("cbox %s  %s  %s" % (title, root, ctx.get("mode", "none"))),
             "-" * COLS]
    return lines


def render_sessions(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("sessions", ctx)
    actions = [
        Action("l", "list", kind="run", argv=[cbox_path, "session", "list"]),
        Action("n", "new", kind="run", argv=[cbox_path, "session", "new"]),
        Action("s", "show", kind="run",
               argv_builder=lambda sid: [cbox_path, "session", "show", sid],
               prompt="session id: ",
               hint="%s session show <id>" % cbox_path),
        Action("c", "close", kind="run",
               argv_builder=lambda sid: [cbox_path, "session", "close", sid],
               prompt="session id: ", confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["session-close"],
               hint="%s session close <id>" % cbox_path),
        Action("r", "run --session", kind="run",
               argv_builder=lambda text: _session_run_argv(cbox_path, text),
               prompt="session id and engine (e.g. abc123 claude): ",
               hint="%s run --session <id> <bin>" % cbox_path),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


def _session_run_argv(cbox_path, text):
    parts = text.split()
    if len(parts) != 2:
        return None
    sid, engine = parts
    return [cbox_path, "run", "--session", sid, engine]


def render_network(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("network", ctx)
    actions = [
        Action("s", "status", kind="run", argv=[cbox_path, "netaccess", "status"]),
        Action("a", "allow", kind="run",
               argv_builder=lambda t: [cbox_path, "netaccess", "allow", t],
               prompt="target (network, container or CIDR): ",
               hint="%s netaccess allow <target>" % cbox_path),
        Action("x", "deny", kind="run",
               argv_builder=lambda t: [cbox_path, "netaccess", "deny", t],
               prompt="target (network, container or CIDR): ",
               hint="%s netaccess deny <target>" % cbox_path),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


def render_ollama(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("ollama", ctx)
    actions = [
        Action("s", "status", kind="run", argv=[cbox_path, "ollama", "status"]),
        Action("p", "ps", kind="run", argv=[cbox_path, "ollama", "ps"]),
        Action("u", "up", kind="run", argv=[cbox_path, "ollama", "up"]),
        Action("d", "down", kind="run", argv=[cbox_path, "ollama", "down"]),
        Action("l", "pull", kind="run",
               argv_builder=lambda m: [cbox_path, "ollama", "pull", m],
               prompt="model: ",
               hint="%s ollama pull <model>" % cbox_path),
        Action("r", "reconcile", kind="run", argv=[cbox_path, "ollama", "reconcile"]),
        Action("g", "gpu-check", kind="run", argv=[cbox_path, "ollama", "gpu-check"]),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


def render_hyperqwen(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("hyperqwen", ctx)
    actions = [
        Action("s", "status", kind="run", argv=[cbox_path, "hyperqwen", "status"]),
        Action("p", "ps", kind="run", argv=[cbox_path, "hyperqwen", "ps"]),
        Action("u", "up", kind="run", argv=[cbox_path, "hyperqwen", "up"]),
        Action("d", "down", kind="run", argv=[cbox_path, "hyperqwen", "down"]),
        Action("a", "prepare", kind="run", argv=[cbox_path, "hyperqwen", "prepare"]),
        Action("r", "reconcile", kind="run", argv=[cbox_path, "hyperqwen", "reconcile"]),
        Action("l", "logs", kind="run", argv=[cbox_path, "hyperqwen", "logs"]),
        Action("g", "gpu-check", kind="run", argv=[cbox_path, "hyperqwen", "gpu-check"]),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


LLM_BACKENDS = ("ollama", "hyperqwen")


def _llm_use_argv(cbox_path, text):
    parts = text.split()
    if len(parts) != 2:
        return None
    backend, model = parts
    if backend not in LLM_BACKENDS or model.startswith("-"):
        return None
    return [cbox_path, "llm", "use", backend, "--model", model]


def render_llm(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("llm", ctx)
    actions = [
        Action("s", "status", kind="run", argv=[cbox_path, "llm", "status"]),
        Action("o", "use ollama", kind="run", argv=[cbox_path, "llm", "use", "ollama"]),
        Action("h", "use hyperqwen", kind="run", argv=[cbox_path, "llm", "use", "hyperqwen"]),
        Action("m", "use with model", kind="run",
               argv_builder=lambda text: _llm_use_argv(cbox_path, text),
               prompt="backend and model (e.g. ollama qwen2.5:7b): ",
               hint="%s llm use <backend> --model <name>" % cbox_path),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


def render_wireguard(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    lines = _submenu_header("wireguard", ctx)
    actions = [
        Action("s", "status", kind="run", argv=[cbox_path, "wg", "status"]),
        Action("u", "up", kind="run", argv=[cbox_path, "wg", "up"], confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["wg-up"]),
        Action("d", "down", kind="run", argv=[cbox_path, "wg", "down"]),
        Action("a", "add client", kind="run",
               argv_builder=lambda n: [cbox_path, "wg", "server", "add-client", n],
               prompt="client name: ",
               hint="%s wg server add-client <name>" % cbox_path),
        Action("p", "add client --plain", kind="run",
               argv_builder=lambda n: [cbox_path, "wg", "server", "add-client", n, "--plain"],
               prompt="client name: ", confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["wg-plain"],
               hint="%s wg server add-client <name> --plain" % cbox_path),
        Action("x", "remove client", kind="run",
               argv_builder=lambda n: [cbox_path, "wg", "peer", "rm", n],
               prompt="client name: ", confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["wg-remove-client"],
               hint="%s wg peer rm <name>" % cbox_path),
        Action("j", "join (client)", kind="run",
               argv_builder=lambda t: [cbox_path, "wg", "client", "join", t],
               prompt="paste invite token: ",
               hint="%s wg client join <token>" % cbox_path),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


def render_maintenance(snapshot):
    ctx = snapshot["ctx"]
    cbox_path = snapshot["cbox_path"]
    engine_state = snapshot.get("engine_state") or {}
    any_running = any(v == "running" for v in engine_state.values())
    lines = _submenu_header("maintenance", ctx)
    actions = [
        Action("d", "down", kind="run", argv=[cbox_path, "down"],
               confirm=any_running,
               force_token="FORCE" if any_running else None,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["down-force"]),
        Action("r", "restart", kind="run", argv=[cbox_path, "restart"]),
        Action("o", "doctor", kind="run", argv=[cbox_path, "doctor"]),
        Action("l", "logs", kind="run", argv=[cbox_path, "logs"]),
        Action("u", "update", kind="run",
               argv=[cbox_path, "reinstall-bins", "--if-stale"]),
        Action("y", "bins status", kind="run", argv=[cbox_path, "bins", "status"]),
        Action("z", "bins rollback", kind="run", argv=[cbox_path, "bins", "rollback"],
               confirm=True, confirm_prompt=CONFIRM_DEFAULT_PROMPTS["bins-rollback"]),
        Action("g", "images", kind="run", argv=[cbox_path, "images", "list"]),
        Action("x", "images rm", kind="run",
               argv_builder=lambda h: [cbox_path, "images", "rm", h],
               prompt="image hash: ", confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["images-rm"],
               hint="%s images rm <hash>" % cbox_path),
        Action("c", "gc", kind="run", argv=[cbox_path, "gc"], confirm=True,
               confirm_prompt=CONFIRM_DEFAULT_PROMPTS["gc"]),
        Action("k", "backup", kind="run", argv=[cbox_path, "backup"]),
        Action("f", "net-refresh", kind="run", argv=[cbox_path, "net-refresh"]),
        Action("p", "projects", kind="run", argv=[cbox_path, "ls"]),
        Action("t", "remote access", kind="run",
               argv=[cbox_path, "session-broker", "status"]),
        Action("h", "install-hooks", kind="run", argv=[cbox_path, "install-hooks"]),
        Action("b", "back", kind="back"),
    ]
    for a in actions:
        lines.append(_key_column(a.key) + a.label)
    return "\n".join(lines) + "\n", actions


RENDERERS = {
    "sessions": render_sessions,
    "network": render_network,
    "ollama": render_ollama,
    "hyperqwen": render_hyperqwen,
    "llm": render_llm,
    "wireguard": render_wireguard,
    "maintenance": render_maintenance,
}


CONFIRM_KEYS = frozenset(
    [
        ("maintenance", "d"),
        ("wireguard", "x"),
        ("wireguard", "p"),
        ("wireguard", "u"),
        ("maintenance", "x"),
        ("maintenance", "z"),
        ("maintenance", "c"),
        ("sessions", "c"),
    ]
)
