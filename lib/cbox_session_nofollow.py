#!/usr/bin/env python3
import os
import stat
import sys


def _open_root(root):
    return os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def _path_parts(relpath):
    if not relpath or os.path.isabs(relpath):
        raise RuntimeError("path must be relative")
    parts = relpath.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise RuntimeError("path contains an unsafe component")
    return parts


def _open_or_make_dir(parent_fd, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        os.close(fd)
    except FileNotFoundError:
        try:
            os.mkdir(name, 0o755, dir_fd=parent_fd)
        except FileExistsError:
            pass
    except NotADirectoryError:
        raise
    st = os.lstat(name, dir_fd=parent_fd)
    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError("refusing to traverse symlink at path component %r" % (name,))
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError("path component %r is not a directory" % (name,))
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def _walk_dirs(root, relparts):
    fd = _open_root(root)
    try:
        for part in relparts:
            nfd = _open_or_make_dir(fd, part)
            os.close(fd)
            fd = nfd
        return fd
    except Exception:
        os.close(fd)
        raise


def _walk_existing_dirs(root, relparts):
    fd = _open_root(root)
    try:
        for part in relparts:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except Exception:
        os.close(fd)
        raise


def _leaf_is_symlink(dirfd, name):
    try:
        st = os.lstat(name, dir_fd=dirfd)
    except FileNotFoundError:
        return False
    return stat.S_ISLNK(st.st_mode)


def _leaf_is_regular_or_absent(dirfd, name):
    try:
        st = os.lstat(name, dir_fd=dirfd)
    except FileNotFoundError:
        return True
    return stat.S_ISREG(st.st_mode)


def write_atomic(root, relpath, content):
    parts = _path_parts(relpath)
    leaf = parts[-1]
    dirparts = parts[:-1]
    dirfd = _walk_dirs(root, dirparts)
    try:
        if _leaf_is_symlink(dirfd, leaf):
            sys.stderr.write("cbox: refusing to write through symlink at %s\n" % relpath)
            return 1
        if not _leaf_is_regular_or_absent(dirfd, leaf):
            sys.stderr.write("cbox: refusing to write - %s exists and is not a regular file\n" % relpath)
            return 1
        tmp_name = ".cbox.%d.tmp" % os.getpid()
        tries = 0
        while True:
            try:
                fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=dirfd)
                break
            except FileExistsError:
                tries += 1
                tmp_name = ".cbox.%d.%d.tmp" % (os.getpid(), tries)
                if tries > 50:
                    sys.stderr.write("cbox: could not allocate a temp file name\n")
                    return 1
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(content.encode("utf-8"))
                fh.flush()
                os.fsync(fh.fileno())
        except Exception:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except OSError:
                pass
            raise
        if _leaf_is_symlink(dirfd, leaf):
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except OSError:
                pass
            sys.stderr.write("cbox: refusing to write - %s became a symlink during write\n" % relpath)
            return 1
        os.replace(tmp_name, leaf, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        return 0
    finally:
        os.close(dirfd)


def mkdir_nofollow(root, relpath):
    relparts = _path_parts(relpath)
    fd = _walk_dirs(root, relparts)
    os.close(fd)
    return 0


def create_new_dir(root, relpath):
    parts = _path_parts(relpath)
    leaf = parts[-1]
    dirparts = parts[:-1]
    dirfd = _walk_dirs(root, dirparts)
    try:
        try:
            os.lstat(leaf, dir_fd=dirfd)
            sys.stderr.write("cbox: refusing - %s already exists\n" % relpath)
            return 1
        except FileNotFoundError:
            pass
        os.mkdir(leaf, 0o755, dir_fd=dirfd)
        return 0
    finally:
        os.close(dirfd)


def gitignore_ensure(root, relpath):
    parts = _path_parts(relpath)
    leaf = parts[-1]
    dirparts = parts[:-1]
    dirfd = _walk_dirs(root, dirparts)
    try:
        if _leaf_is_symlink(dirfd, leaf):
            sys.stderr.write("cbox: warning: %s is a symlink - refusing to write\n" % relpath)
            return 1
        existing = ""
        try:
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
            try:
                with os.fdopen(fd, "rb") as fh:
                    existing = fh.read().decode("utf-8", "replace")
            except Exception:
                pass
        except FileNotFoundError:
            existing = None
        except OSError:
            existing = None
        required = ["runtime/", "sessions/*/distillates/"]
        if existing is not None and all(line in existing.splitlines() for line in required):
            return 0
        body = existing or ""
        if body and not body.endswith("\n"):
            body += "\n"
        lines = body.splitlines()
        for line in required:
            if line not in lines:
                body += line + "\n"
    finally:
        os.close(dirfd)
    return write_atomic(root, relpath, body)


def chmod_readonly(root, relpath):
    parts = _path_parts(relpath)
    leaf = parts[-1]
    dirfd = _walk_dirs(root, parts[:-1])
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise RuntimeError("target is not a regular file")
            os.fchmod(fd, 0o444)
        finally:
            os.close(fd)
        return 0
    finally:
        os.close(dirfd)


def read_nofollow(root, relpath):
    parts = _path_parts(relpath)
    dirfd = _walk_existing_dirs(root, parts[:-1])
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise RuntimeError("target is not a regular file")
            while True:
                data = os.read(fd, 65536)
                if not data:
                    break
                sys.stdout.buffer.write(data)
        finally:
            os.close(fd)
        return 0
    finally:
        os.close(dirfd)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: cbox_session_nofollow.py {write|gitignore-ensure} <root> <relpath>\n")
        return 2
    cmd, root, relpath = argv[0], argv[1], argv[2]
    root = os.path.realpath(root)
    if cmd == "write":
        content = sys.stdin.read()
        return write_atomic(root, relpath, content)
    if cmd == "gitignore-ensure":
        return gitignore_ensure(root, relpath)
    if cmd == "mkdir":
        return mkdir_nofollow(root, relpath)
    if cmd == "create-new-dir":
        return create_new_dir(root, relpath)
    if cmd == "chmod-readonly":
        return chmod_readonly(root, relpath)
    if cmd == "read":
        return read_nofollow(root, relpath)
    sys.stderr.write("cbox: unknown nofollow-helper command %r\n" % (cmd,))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, OSError) as exc:
        sys.stderr.write("cbox: %s\n" % exc)
        sys.exit(1)
