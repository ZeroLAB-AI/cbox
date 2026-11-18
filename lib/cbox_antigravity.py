import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit


MAX_RELEASE_BYTES = 512 * 1024 * 1024
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?")
SHA512 = re.compile(r"[a-f0-9]{128}")
SHA256 = re.compile(r"[a-f0-9]{64}")


def release_pin(pin):
    if not isinstance(pin, dict) or not all(isinstance(pin.get(key), str) for key in ("version", "url", "sha512")):
        raise ValueError("release pin needs version, url and sha512 strings")
    version, url, sha512 = (pin[key] for key in ("version", "url", "sha512"))
    if not VERSION.fullmatch(version) or not SHA512.fullmatch(sha512):
        raise ValueError("release pin must contain an exact version and lowercase SHA512")
    if not url.isascii() or any(ord(char) <= 32 or ord(char) == 127 for char in url):
        raise ValueError("invalid release URL")
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("release URL must be HTTPS without credentials or fragment")
    return {"version": version, "url": url, "sha512": sha512}


def read_json(path):
    with path.open("rb") as stream:
        data = stream.read(16385)
    if len(data) > 16384:
        raise ValueError("release metadata is too large")
    return json.loads(data)


def digest(stream, algorithm):
    return hashlib.file_digest(stream, algorithm).hexdigest()


def verify_release(path):
    path = Path(path).absolute()
    if path != path.resolve(strict=True) or not path.is_dir() or not SHA512.fullmatch(path.name):
        raise ValueError("use the canonical digest-named release directory")
    manifest = path / "provenance.json"
    binary = path / "agy"
    if manifest.is_symlink() or binary.is_symlink() or not manifest.is_file() or not binary.is_file():
        raise ValueError("release files must be regular files")
    data = read_json(manifest)
    pin = release_pin(data)
    binary_sha = data.get("binary_sha256")
    info = binary.stat()
    if (pin["sha512"] != path.name or not isinstance(binary_sha, str) or not SHA256.fullmatch(binary_sha)
            or not 0 < info.st_size <= MAX_RELEASE_BYTES or not info.st_mode & stat.S_IXUSR):
        raise ValueError("release provenance or binary permissions are invalid")
    with binary.open("rb") as stream:
        if digest(stream, "sha256") != binary_sha:
            raise ValueError("release binary digest mismatch")
    return binary


def stage_binary(payload, pin, staging):
    fd = os.open(payload, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream, tempfile.TemporaryFile(dir=staging) as archive:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_RELEASE_BYTES:
            raise ValueError("release artifact must be a bounded regular file")
        remaining = info.st_size
        while remaining:
            block = stream.read(min(remaining, 1024 * 1024))
            if not block:
                break
            archive.write(block)
            remaining -= len(block)
        if remaining or stream.read(1):
            raise ValueError("release artifact changed while copying")
        archive.seek(0)
        if digest(archive, "sha512") != pin["sha512"]:
            raise ValueError("release artifact SHA512 mismatch")
        archive.seek(0)
        with (staging / "agy").open("xb") as binary:
            if urlsplit(pin["url"]).path.endswith(".tar.gz"):
                with tarfile.open(fileobj=archive, mode="r|gz") as package:
                    member = package.next()
                    if (member is None or member.name != "antigravity" or not member.isreg()
                            or not 0 < member.size <= MAX_RELEASE_BYTES):
                        raise ValueError("archive must contain the vendor's regular antigravity binary")
                    with package.extractfile(member) as extracted:
                        shutil.copyfileobj(extracted, binary, length=1024 * 1024)
                    if package.next() is not None or binary.tell() != member.size:
                        raise ValueError("unexpected content in release archive")
            else:
                shutil.copyfileobj(archive, binary, length=1024 * 1024)
    binary_path = staging / "agy"
    binary_path.chmod(0o555)
    with binary_path.open("rb") as binary:
        if binary.read(4) != b"\x7fELF":
            raise ValueError("offline Linux release must contain an ELF executable")
        binary.seek(0)
        provenance = {**pin, "binary_sha256": digest(binary, "sha256")}
    manifest = staging / "provenance.json"
    manifest.write_text(json.dumps(provenance, indent=2) + "\n", encoding="ascii")
    manifest.chmod(0o444)


@contextmanager
def locked_store(store):
    store = store.absolute()
    if store.resolve() != store:
        raise ValueError("release store must be a canonical directory")
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    if store.stat().st_uid != os.getuid() or store.stat().st_mode & 0o022:
        raise ValueError("release store must belong to the current user and forbid peer writes")
    fd = os.open(store / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield store


def selection(store):
    path = store / "selected.json"
    if path.is_symlink():
        raise ValueError("release selection must be a regular file")
    try:
        state = read_json(path)
    except FileNotFoundError:
        return {"current": None, "previous": None}
    if not isinstance(state, dict) or set(state) != {"current", "previous"} or any(
        entry is not None and (not isinstance(entry, str) or not SHA512.fullmatch(entry))
        for entry in state.values()
    ):
        raise ValueError("invalid release selection")
    return state


def select_release(store, current, previous):
    with tempfile.TemporaryDirectory(dir=store, prefix="selection-") as directory:
        path = Path(directory) / "selected.json"
        path.write_text(json.dumps({"current": current, "previous": previous}) + "\n", encoding="ascii")
        path.replace(store / path.name)


def prepare_release(store, pin_path, payload):
    pin = release_pin(read_json(pin_path))
    with locked_store(store) as store:
        selected = selection(store)
        with tempfile.TemporaryDirectory(dir=store, prefix="release-") as temp:
            staged = Path(temp) / "release"
            staged.mkdir()
            stage_binary(payload, pin, staged)
            destination = store / pin["sha512"]
            if destination.exists():
                verify_release(destination)
                if read_json(destination / "provenance.json") != read_json(staged / "provenance.json"):
                    raise ValueError("release digest already recorded with different provenance")
            else:
                staged.rename(destination)
            if selected["current"] != destination.name:
                select_release(store, destination.name, selected["current"])
    return destination


def rollback(store):
    with locked_store(store) as store:
        selected = selection(store)
        if selected["previous"] is None:
            raise ValueError("no previous Antigravity release")
        previous = store / selected["previous"]
        verify_release(previous)
        select_release(store, selected["previous"], selected["current"])
        return previous


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cbox isolation agy-release")
    commands = parser.add_subparsers(dest="action", required=True)
    prepare = commands.add_parser("prepare", help="verify and stage a pinned, local vendor artifact")
    prepare.add_argument("--store", required=True, type=Path)
    prepare.add_argument("--pin", required=True, type=Path)
    prepare.add_argument("--artifact", required=True, type=Path)
    check = commands.add_parser("verify")
    check.add_argument("release", type=Path)
    revert = commands.add_parser("rollback")
    revert.add_argument("--store", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare":
            result = prepare_release(args.store, args.pin, args.artifact)
        elif args.action == "verify":
            result = verify_release(args.release)
        else:
            result = rollback(args.store)
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as exc:
        parser.error(str(exc))
    print(result)
    return 0
