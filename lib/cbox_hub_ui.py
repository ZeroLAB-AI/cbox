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
        self._pending = bytearray()
        self._pending_pos = 0
        self._pushback_end = None

    def push_back(self, data):
        if not data:
            return
        if self._pushback_end is None:
            self._pushback_end = self._pending_pos
        end = self._pushback_end
        self._pending[end:end] = data
        self._pushback_end = end + len(data)

    def _read_byte(self, fd, timeout=None):
        if self._pending_pos < len(self._pending):
            data = bytes(self._pending[self._pending_pos:self._pending_pos + 1])
            self._pending_pos += 1
            self._pushback_end = None
            if self._pending_pos == len(self._pending):
                self._pending.clear()
                self._pending_pos = 0
            return data
        if timeout is not None:
            import select
            if not select.select([fd], [], [], timeout)[0]:
                return b""
        return os.read(fd, 1)

    def _read_escape_sequence(self, fd):
        data = self._read_byte(fd, 0.05)
        if data not in (b"[", b"O"):
            if data:
                self.push_back(data)
            return "\x1b"
        sequence = b"\x1b" + data
        for index in range(16):
            byte = self._read_byte(fd, 0.05)
            if not byte:
                break
            value = byte[0]
            if 0x40 <= value <= 0x7e:
                sequence += byte
                break
            if not 0x20 <= value <= 0x3f:
                self.push_back(byte)
                break
            if index == 15:
                self.push_back(byte)
                break
            sequence += byte
        return sequence.decode("ascii", "replace")

    def _read_utf8_char(self, fd, first):
        lead = first[0]
        if 0xc2 <= lead <= 0xdf:
            size = 2
        elif 0xe0 <= lead <= 0xef:
            size = 3
        elif 0xf0 <= lead <= 0xf4:
            size = 4
        else:
            return first.decode("utf-8", "replace")
        data = first
        while len(data) < size:
            byte = self._read_byte(fd, 0.05)
            if not byte:
                break
            if byte[0] & 0xc0 != 0x80:
                self.push_back(byte)
                break
            data += byte
        return data.decode("utf-8", "replace")

    def read_key(self):
        import termios
        import tty
        fd = self.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd, termios.TCSANOW)
            data = self._read_byte(fd)
            if not data or data in (b"\x04", b"\x03"):
                return None
            if data == b"\x1b":
                return self._read_escape_sequence(fd)
            if data[0] >= 0x80:
                return self._read_utf8_char(fd, data)
            return data.decode("utf-8", "replace")
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

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
        if ch.startswith("\x1b"):
            stdout.write("\n")
            return "escape"
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


def _unread_byte(keys, data):
    keys.push_back(data)


def _sync_pending(stdin):
    pending = getattr(stdin, "pending", None)
    pos = getattr(stdin, "pos", None)
    if isinstance(pending, (bytes, bytearray)) and isinstance(pos, int):
        stdin.pending = bytes(pending[pos:])
        stdin.pos = 0


def _drain_pending_newlines(keys):
    stdin = keys.stdin
    try:
        fd = stdin.fileno()
    except Exception:
        return
    try:
        import select
        while select.select([fd], [], [], 0)[0]:
            data = os.read(fd, 1)
            if not data:
                break
            if data in (b"\r", b"\n"):
                continue
            _unread_byte(keys, data)
            break
    except Exception:
        pass
    finally:
        _sync_pending(stdin)


def confirm(keys, stdout, prompt):
    stdout.write("%s [y/N] " % prompt)
    if isinstance(keys, RawKeys):
        ch = keys.read_key()
        _drain_pending_newlines(keys)
        if ch is None:
            stdout.write("\n")
            return None
        shown = "" if ch in ("\r", "\n") or ch.startswith("\x1b") else ch
        stdout.write(shown + "\n")
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
