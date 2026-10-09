import os
import sys


def main(argv):
    lib = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, lib)
    try:
        import cbox_hub
        entry = cbox_hub.main
    except Exception:
        return 97
    try:
        rc = entry(argv)
    except KeyboardInterrupt:
        return 130
    except SystemExit as exc:
        code = exc.code
        if code is None:
            return 0
        if isinstance(code, int):
            return code
        sys.stderr.write("%s\n" % code)
        return 1
    except Exception as exc:
        sys.stderr.write("cbox_hub: unhandled failure: %s\n" % exc)
        return 97
    return 0 if rc is None else rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
