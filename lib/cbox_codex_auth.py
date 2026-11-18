import argparse
import fcntl
import os
from pathlib import Path
import stat
import tempfile


STORE = "cbox-container-home"


def private_file(path):
    info = path.lstat()
    forbidden = 0o022 if path.name == "auth.lock" else 0o077
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & forbidden:
        raise ValueError(f"{path.name} must be a private regular file owned by the current user")
    return info


def link_target(source, target):
    return source.is_symlink() and os.readlink(source) == os.path.relpath(target, source.parent)


def check_pair(source, target):
    if link_target(source, target):
        private_file(target)
        return
    private_file(source)
    if target.exists() or target.is_symlink():
        private_file(target)
        if not source.samefile(target):
            raise ValueError(f"the Codex container already has its own {target.name}")


def share_file(source, target, staging):
    if link_target(source, target):
        return
    link = staging / source.name
    link.symlink_to(os.path.relpath(target, source.parent))
    created = False
    if not target.exists():
        os.link(source, target, follow_symlinks=False)
        created = True
    try:
        link.replace(source)
    except BaseException:
        if created:
            target.unlink()
        raise


def share(home):
    if not home.is_absolute() or home.resolve(strict=True) != home:
        raise ValueError("provide the canonical absolute host Codex directory")
    info = home.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("host Codex directory must belong to the current user and forbid peer writes")
    store = home / STORE
    if store.is_symlink():
        raise ValueError("Codex container home must not be a symlink")
    source = home / "auth.json"
    target = store / source.name
    check_pair(source, target)
    if not private_file(target if source.is_symlink() else source).st_size:
        raise ValueError("host Codex has no saved file-based login")
    store.mkdir(mode=0o700, exist_ok=True)
    info = store.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Codex container home must be private to the current user")
    old_lock = home / "auth.lock"
    new_lock = store / old_lock.name
    lock = new_lock if link_target(old_lock, new_lock) else old_lock
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb+") as lock_file:
        check_pair(old_lock, new_lock)
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Codex is updating authentication; close running sessions and retry") from exc
        with tempfile.TemporaryDirectory(dir=home, prefix=".cbox-auth-") as directory:
            share_file(old_lock, new_lock, Path(directory))
            check_pair(source, target)
            share_file(source, target, Path(directory))


def main():
    parser = argparse.ArgumentParser(prog="cbox codex-auth-share")
    parser.add_argument("home", type=Path)
    args = parser.parse_args()
    try:
        share(args.home)
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, "cbox codex-auth-share: " + str(exc) + "\n")
    print("Host and container Codex now use the same file-based grant and refresh lock.")


if __name__ == "__main__":
    main()
