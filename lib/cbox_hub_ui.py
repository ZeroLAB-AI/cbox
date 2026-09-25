import os


class Action(object):
    def __init__(self, key, label, kind="run", argv=None, argv_builder=None,
                 prompt=None, confirm=False, confirm_prompt=None, hint=None,
                 submenu=None, force_token=None):
        self.key = key
        self.label = label
        self.kind = kind
        self.argv = argv
        self.argv_builder = argv_builder
        self.prompt = prompt
        self.confirm = confirm
        self.confirm_prompt = confirm_prompt or ("%s - are you sure?" % label)
        if hint is not None:
            self.hint = hint
        elif argv:
            self.hint = " ".join(argv)
        else:
            self.hint = label
        self.submenu = submenu
        self.force_token = force_token


def plain_forced():
    return os.environ.get("CBOX_HUB_PLAIN", "") == "1"


def raw_keys_available(stdin, stdout):
    if plain_forced():
        return False
    if os.environ.get("TERM", "") == "dumb":
        return False
    try:
        if not stdin.isatty() or not stdout.isatty():
            return False
    except Exception:
        return False
    try:
        import termios
        fd = stdin.fileno()
        termios.tcgetattr(fd)
    except Exception:
        return False
    return True


class LineKeys(object):
    mode = "line"

    def __init__(self, stdin, stdout):
        self.stdin = stdin
        self.stdout = stdout

    def read_line(self, prompt=""):
        if prompt:
            self.stdout.write(prompt)
        line = self.stdin.readline()
        if line == "":
            return None
        return line.rstrip("\n").rstrip("\r")

    def read_key(self):
        line = self.read_line()
        if line is None:
            return None
        return line.strip()


class RawKeys(object):
    mode = "raw"

    def __init__(self, stdin, stdout):
        self.stdin = stdin
        self.stdout = stdout

    def read_key(self):
        import termios
        import tty
        fd = self.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd, termios.TCSANOW)
            data = os.read(fd, 1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        if not data or data in (b"\x04", b"\x03"):
            return None
        return data.decode("utf-8", "replace")

    def read_line(self, prompt=""):
        return LineKeys(self.stdin, self.stdout).read_line(prompt)


def make_keys(stdin, stdout):
    if raw_keys_available(stdin, stdout):
        return RawKeys(stdin, stdout)
    return LineKeys(stdin, stdout)


def read_selection(keys, stdout, default_key):
    if isinstance(keys, RawKeys):
        stdout.write("> ")
        ch = keys.read_key()
        if ch is None:
            return None
        if ch in ("\r", "\n"):
            stdout.write("\n")
            return default_key
        stdout.write(ch + "\n")
        return ch
    line = keys.read_line("> ")
    if line is None:
        return None
    line = line.strip()
    if line == "":
        return default_key
    return line


def read_text(keys, stdout, prompt):
    line = keys.read_line(prompt)
    if line is None:
        return None
    return line.strip()


def _drain_pending_newlines(stdin):
    try:
        fd = stdin.fileno()
    except Exception:
        return
    try:
        import termios
        termios.tcflush(fd, termios.TCIFLUSH)
        return
    except Exception:
        pass
    try:
        import select
        while select.select([fd], [], [], 0)[0]:
            os.read(fd, 256)
    except Exception:
        pass


def confirm(keys, stdout, prompt):
    stdout.write("%s [y/N] " % prompt)
    if isinstance(keys, RawKeys):
        ch = keys.read_key()
        _drain_pending_newlines(keys.stdin)
        if ch is None:
            stdout.write("\n")
            return None
        stdout.write(("" if ch in ("\r", "\n") else ch) + "\n")
        return ch.lower() == "y"
    line = keys.read_line("")
    if line is None:
        return None
    return line.strip().lower() == "y"


def find_action(actions, sel):
    for a in actions:
        if a.key == sel:
            return a
    for a in actions:
        if a.key.lower() == sel.lower():
            return a
    return None
