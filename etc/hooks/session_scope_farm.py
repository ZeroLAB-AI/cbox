#!/usr/bin/env python3
import fcntl
import json
import os
import re
import shutil
import sys
import time

CFG = os.environ.get("CLAUDE_CONFIG_DIR", "")
ROOT = os.environ.get("CBOX_SCOPE_ROOT", "").rstrip("/")
SLUG = os.environ.get("CBOX_SCOPE_SLUG", "")
LOCAL_STATE = "/tmp/cbox-scope-watch-%d" % os.getuid()
SID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SLUG_RE = re.compile(r"^[A-Za-z0-9-]{1,192}$")
ABSORB_SETTLE_SECONDS = 60


def env_ok():
    if not CFG or not ROOT or not SLUG:
        return False
    if os.path.basename(CFG.rstrip("/")) != ".claude-cbox":
        return False
    return os.path.isdir(CFG)


def applicable():
    return env_ok() and os.path.isdir(os.path.join(CFG, ".host-projects"))


def cwd_in_root(cwd):
    cwd = os.path.normpath(cwd)
    return cwd == ROOT or cwd.startswith(ROOT + "/")


def entries(path):
    try:
        return [n for n in os.listdir(path) if not n.startswith(".")]
    except OSError:
        return []


def read_project_cwd(project_dir):
    paths = []
    for n in entries(project_dir):
        if not n.endswith(".jsonl"):
            continue
        p = os.path.join(project_dir, n)
        try:
            paths.append((os.path.getmtime(p), p))
        except OSError:
            continue
    paths.sort(reverse=True)
    for _, p in paths[:3]:
        try:
            with open(p, "rb") as fh:
                for i, raw in enumerate(fh):
                    if i >= 20:
                        break
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        entry = json.loads(raw)
                    except ValueError:
                        continue
                    cwd = entry.get("cwd")
                    if cwd:
                        return cwd
        except OSError:
            continue
    return None


def slug_in_scope(name, host_dir):
    if name == SLUG:
        return True
    if not name.startswith(SLUG + "-"):
        return False
    cwd = read_project_cwd(os.path.join(host_dir, name))
    if cwd is None:
        return False
    return cwd_in_root(cwd)


def has_open_fds(path):
    prefix = os.path.realpath(path) + os.sep
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fddir = "/proc/%s/fd" % pid
        try:
            fds = os.listdir(fddir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(os.path.join(fddir, fd))
            except OSError:
                continue
            if target.startswith(prefix):
                return True
    return False


def make_link(link, target):
    if os.path.islink(link):
        if os.readlink(link) == target:
            return
        try:
            os.unlink(link)
        except OSError:
            return
    elif os.path.lexists(link):
        return
    try:
        os.symlink(target, link)
    except OSError:
        pass


def recently_written(path):
    cutoff = time.time() - ABSORB_SETTLE_SECONDS
    for dirpath, _, filenames in os.walk(path):
        for name in filenames:
            try:
                if os.path.getmtime(os.path.join(dirpath, name)) > cutoff:
                    return True
            except OSError:
                return True
    return False


def merge_file(src, name, dfd):
    cutoff = time.time() - ABSORB_SETTLE_SECONDS
    try:
        src_mtime = os.path.getmtime(src)
        dst_mtime = os.lstat(name, dir_fd=dfd).st_mtime
    except OSError:
        return False
    if src_mtime > cutoff or dst_mtime > cutoff:
        return False
    if src_mtime > dst_mtime:
        try:
            os.replace(src, name, dst_dir_fd=dfd)
        except OSError:
            return False
        return True
    return False


def absorb_dir(local, hostdir, target, allow_convert, merge=False):
    try:
        if os.path.ismount(local):
            return
    except OSError:
        return
    try:
        names = os.listdir(local)
    except OSError:
        return
    if names:
        if not allow_convert:
            return
        if recently_written(local) or has_open_fds(local):
            return
    if os.path.islink(hostdir):
        return
    try:
        os.makedirs(hostdir, exist_ok=True)
        dfd = os.open(hostdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        return
    try:
        clean = True
        for name in names:
            src = os.path.join(local, name)
            try:
                os.lstat(name, dir_fd=dfd)
                collides = True
            except OSError:
                collides = False
            if collides:
                if not merge or not merge_file(src, name, dfd):
                    clean = False
                continue
            try:
                os.rename(src, name, dst_dir_fd=dfd)
            except OSError:
                clean = False
        if clean:
            try:
                os.rmdir(local)
                os.symlink(target, local)
            except OSError:
                pass
    finally:
        os.close(dfd)


def prune_dangling(farm):
    for name in entries(farm):
        link = os.path.join(farm, name)
        if os.path.islink(link) and not os.path.exists(link):
            try:
                os.unlink(link)
            except OSError:
                pass


def refresh_projects(allow_convert):
    host = os.path.join(CFG, ".host-projects")
    farm = os.path.join(CFG, "projects")
    os.makedirs(farm, exist_ok=True)
    scoped = set()
    for name in entries(host):
        if not os.path.isdir(os.path.join(host, name)):
            continue
        if not slug_in_scope(name, host):
            continue
        scoped.add(name)
        link = os.path.join(farm, name)
        target = "../.host-projects/" + name
        if os.path.isdir(link) and not os.path.islink(link):
            absorb_dir(link, os.path.join(host, name), target, allow_convert)
        else:
            make_link(link, target)
    for name in entries(farm):
        link = os.path.join(farm, name)
        if os.path.islink(link) or not os.path.isdir(link):
            continue
        cwd = read_project_cwd(link)
        if allow_convert and cwd and cwd_in_root(cwd):
            absorb_dir(link, os.path.join(host, name),
                       "../.host-projects/" + name, True)
        scoped.add(name)
    prune_dangling(farm)
    return scoped


def session_slug_in_farm(sid):
    farm = os.path.join(CFG, "projects")
    for name in entries(farm):
        if os.path.exists(os.path.join(farm, name, sid + ".jsonl")):
            return name
    return None


def refresh_tasks(allow_convert):
    host = os.path.join(CFG, ".host-tasks")
    farm = os.path.join(CFG, "tasks")
    if not os.path.isdir(host):
        return
    os.makedirs(farm, exist_ok=True)
    for name in entries(host):
        if not SID_RE.match(name):
            continue
        if session_slug_in_farm(name) is None:
            continue
        link = os.path.join(farm, name)
        target = "../.host-tasks/" + name
        if os.path.isdir(link) and not os.path.islink(link):
            absorb_dir(link, os.path.join(host, name), target, allow_convert)
        else:
            make_link(link, target)
    if allow_convert:
        for name in entries(farm):
            link = os.path.join(farm, name)
            if os.path.islink(link) or not os.path.isdir(link):
                continue
            owner = session_slug_in_farm(name)
            if owner and os.path.islink(os.path.join(CFG, "projects", owner)):
                absorb_dir(link, os.path.join(host, name),
                           "../.host-tasks/" + name, True)
    prune_dangling(farm)


def job_state(job_dir):
    try:
        with open(os.path.join(job_dir, "state.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def job_ref(job_dir):
    state = job_state(job_dir)
    if state is None:
        return None
    path = state.get("linkScanPath") or ""
    marker = "/projects/"
    idx = path.rfind(marker)
    if idx < 0:
        return None
    rest = path[idx + len(marker):]
    parts = rest.split("/")
    if len(parts) != 2 or not parts[1].endswith(".jsonl"):
        return None
    slug, sid = parts[0], parts[1][:-6]
    if not SLUG_RE.match(slug) or not SID_RE.match(sid):
        return None
    return slug, sid


def job_in_scope(job_dir, scoped):
    ref = job_ref(job_dir)
    if ref is not None:
        slug, sid = ref
        if slug not in scoped:
            return False
        return os.path.exists(os.path.join(CFG, "projects", slug, sid + ".jsonl"))
    state = job_state(job_dir)
    if state is None:
        return False
    sid = str(state.get("sessionId") or "")
    return bool(SID_RE.match(sid)) and session_slug_in_farm(sid) is not None


def job_terminal(job_dir):
    state = job_state(job_dir)
    if state is None:
        return False
    return state.get("state") in ("done", "failed", "killed")


def jobs_sync(host, farm, relbase, allow_convert, scoped):
    os.makedirs(farm, exist_ok=True)
    for name in entries(host):
        if name == "settled":
            continue
        full = os.path.join(host, name)
        if not os.path.isdir(full):
            continue
        if not job_in_scope(full, scoped):
            continue
        link = os.path.join(farm, name)
        target = relbase + "/" + name
        if os.path.isdir(link) and not os.path.islink(link):
            if job_terminal(link):
                absorb_dir(link, full, target, allow_convert, True)
        else:
            make_link(link, target)
    if allow_convert:
        for name in entries(farm):
            if name == "settled":
                continue
            link = os.path.join(farm, name)
            if os.path.islink(link) or not os.path.isdir(link):
                continue
            if not job_in_scope(link, scoped):
                continue
            if not job_terminal(link):
                continue
            absorb_dir(link, os.path.join(host, name),
                       relbase + "/" + name, True, True)
    prune_dangling(farm)


def refresh_jobs(allow_convert, scoped):
    host = os.path.join(CFG, ".host-jobs")
    farm = os.path.join(CFG, "jobs")
    if not os.path.isdir(host):
        return
    jobs_sync(host, farm, "../.host-jobs", allow_convert, scoped)
    refresh_jobs_files(host, farm)
    settled = os.path.join(host, "settled")
    if os.path.isdir(settled):
        jobs_sync(settled, os.path.join(farm, "settled"),
                  "../../.host-jobs/settled", allow_convert, scoped)


def refresh_jobs_files(host, farm):
    for name in entries(host):
        full = os.path.join(host, name)
        if os.path.isdir(full) or name.endswith(".tmp"):
            continue
        make_link(os.path.join(farm, name), "../.host-jobs/" + name)


def refresh_all():
    if not applicable():
        return
    scoped = refresh_projects(True)
    refresh_tasks(True)
    refresh_jobs(True, scoped)


def try_lock(name):
    os.makedirs(LOCAL_STATE, mode=0o700, exist_ok=True)
    fh = open(os.path.join(LOCAL_STATE, name), "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    return fh


def main(argv):
    if "--once" in argv:
        lock = try_lock("farm.lock")
        if lock is None:
            return 0
        refresh_all()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
