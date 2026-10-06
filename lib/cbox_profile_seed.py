#!/usr/bin/env python3
import errno
import json
import math
import os
import re
import stat
import sys
import tempfile


MAX_BYTES = 4 * 1024 * 1024
MAX_DEPTH = 32
MAX_STRING = 2048
MAX_ACCOUNT_STRING = 256

SEED_KEYS = frozenset((
    "additionalModelOptionsAnsweredAt",
    "agentLastUsed",
    "announcementImpressions",
    "autoCompactEnabled",
    "bypassPermissionsModeAccepted",
    "btwUseCount",
    "changelogLastFetched",
    "closedIssuesLastChecked",
    "diffSidebarOpen",
    "diffTool",
    "editorMode",
    "firstStartTime",
    "hasAcknowledgedCostThreshold",
    "hasCompletedOnboarding",
    "hasIdeOnboardingBeenShown",
    "hasOpenedAgentsView",
    "hasResetAutoModeOptInForDefaultOffer",
    "hasSeenAutoDefaultNudge",
    "hasSeenAutoModeEntryWarning",
    "hasSeenEffortMediumNudge",
    "hasSeenEffortMediumNudgeByModel",
    "hasSeenTasksHint",
    "lastClawdEntranceVersion",
    "lastPlanModeUse",
    "lastReleaseNotesSeen",
    "migrationVersion",
    "numStartups",
    "officialMarketplaceAutoInstallAttempted",
    "officialMarketplaceAutoInstalled",
    "opusProMigrationComplete",
    "optionAsMetaKeyInstalled",
    "pluginUsage",
    "pluginUsageLspGraceAppliedIds",
    "preferredNotifChannel",
    "projects",
    "promptQueueUseCount",
    "rcLongTurnNudgeSeenCount",
    "remoteDialogSeen",
    "resumeReturnDismissed",
    "seenNotifications",
    "shiftEnterKeyBindingInstalled",
    "showTurnDuration",
    "skillUsage",
    "sonnet1m45MigrationComplete",
    "theme",
    "tipLifetimeShownCounts",
    "tipsHistory",
    "tipsHistoryByCommand",
    "unpinFable5LaunchEffort",
    "unpinOpus47LaunchEffort",
    "unpinOpus48LaunchEffort",
    "verbose",
))

PROJECT_KEYS = frozenset((
    "hasClaudeMdExternalIncludesApproved",
    "hasClaudeMdExternalIncludesWarningShown",
    "hasCompletedProjectOnboarding",
    "hasTrustDialogAccepted",
    "projectOnboardingSeenCount",
))

SECRET_NAME = re.compile(
    r"mcp|env|secret|token|passw|credential|auth|cookie|email|account|apikey|api_key|(?:^|[^a-z])key(?:$|[^a-z])",
    re.IGNORECASE,
)

ACCOUNT_KEYS = (
    "accountCreatedAt",
    "accountUuid",
    "billingType",
    "displayName",
    "emailAddress",
    "hasExtraUsageEnabled",
    "organizationName",
    "organizationRole",
    "organizationUuid",
    "subscriptionCreatedAt",
    "workspaceRole",
)


class Refused(Exception):
    pass


_DROP = object()


def depth_ok(value):
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if depth > MAX_DEPTH:
            return False
        if isinstance(item, dict):
            stack.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list):
            stack.extend((v, depth + 1) for v in item)
    return True


def read_object(path, missing_ok):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        if missing_ok:
            return None
        raise Refused("file is missing: %s" % path)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise Refused("refusing a symlink: %s" % path)
        raise Refused("cannot open %s: %s" % (path, exc.strerror))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused("not a regular file: %s" % path)
        if st.st_uid != os.geteuid():
            raise Refused("file is owned by another user: %s" % path)
        if st.st_size > MAX_BYTES:
            raise Refused("file is larger than %d bytes: %s" % (MAX_BYTES, path))
        with os.fdopen(fd, "rb", closefd=False) as fh:
            raw = fh.read(MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > MAX_BYTES:
        raise Refused("file is larger than %d bytes: %s" % (MAX_BYTES, path))
    try:
        data = json.loads(raw.decode("utf-8"))
        ok = isinstance(data, dict) and depth_ok(data)
    except (ValueError, RecursionError):
        ok = False
    if not ok:
        raise Refused("not a readable JSON object of sane depth: %s" % path)
    return data


def atomic_write_json(path, data):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".cbox-profile-seed-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fchmod(fh.fileno(), 0o600)
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def scrub(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if not isinstance(key, str) or SECRET_NAME.search(key):
                continue
            cleaned = scrub(item)
            if cleaned is not _DROP:
                out[key] = cleaned
        return out
    if isinstance(value, list):
        out = []
        for item in value:
            cleaned = scrub(item)
            if cleaned is not _DROP:
                out.append(cleaned)
        return out
    if isinstance(value, str):
        return value if len(value) <= MAX_STRING else _DROP
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else _DROP
    return _DROP


def scrub_projects(value):
    if not isinstance(value, dict):
        return _DROP
    out = {}
    for path, entry in value.items():
        if not isinstance(path, str) or not isinstance(entry, dict):
            continue
        kept = {}
        for key in PROJECT_KEYS:
            item = entry.get(key)
            if isinstance(item, (bool, int)):
                kept[key] = item
        if kept:
            out[path] = kept
    return out


def filter_seed(data):
    out = {}
    for key in sorted(SEED_KEYS):
        if key not in data:
            continue
        if key == "projects":
            cleaned = scrub_projects(data[key])
        else:
            cleaned = scrub(data[key])
        if cleaned is not _DROP:
            out[key] = cleaned
    return out


def clean_text(value, limit):
    text = "".join(ch for ch in value if ord(ch) >= 32 and not 127 <= ord(ch) < 160)
    return text[:limit]


def clean_account(value):
    out = {}
    if not isinstance(value, dict):
        return out
    for key in ACCOUNT_KEYS:
        item = value.get(key)
        if isinstance(item, str):
            out[key] = clean_text(item, MAX_ACCOUNT_STRING)
        elif isinstance(item, bool):
            out[key] = item
        elif isinstance(item, int) or (isinstance(item, float) and math.isfinite(item)):
            out[key] = item
    return out


def cmd_seed(src, dst, refresh):
    parent = os.path.dirname(os.path.abspath(dst))
    if os.path.islink(parent) or os.path.islink(dst):
        raise Refused("refusing symlinked destination or destination directory: %s" % dst)
    existed = os.path.lexists(dst)
    if existed and not refresh:
        sys.stdout.write("exists\n")
        return 0
    if existed and not stat.S_ISREG(os.lstat(dst).st_mode):
        raise Refused("destination is not a regular file: %s" % dst)
    data = read_object(src, True)
    if data is None:
        data = {}
    atomic_write_json(dst, filter_seed(data))
    sys.stdout.write("refreshed\n" if existed else "seeded\n")
    return 0


def cmd_harvest(state_json, profile_json):
    try:
        st = os.lstat(profile_json)
    except OSError:
        raise Refused("profile file is missing: %s" % profile_json)
    if not stat.S_ISREG(st.st_mode):
        raise Refused("profile file is not a regular non-symlink file: %s" % profile_json)
    profile = read_object(profile_json, False)
    try:
        state = read_object(state_json, True)
    except Refused as exc:
        sys.stderr.write("cbox_profile_seed: ignoring state file: %s\n" % exc)
        sys.stdout.write("empty\n")
        return 0
    if state is None or not isinstance(state.get("oauthAccount"), dict):
        sys.stdout.write("empty\n")
        return 0
    account = clean_account(state["oauthAccount"])
    if not account:
        sys.stdout.write("empty\n")
        return 0
    user_id = state.get("userID")
    if isinstance(user_id, str):
        user_id = clean_text(user_id, MAX_ACCOUNT_STRING)
    else:
        user_id = None
    engines = profile.get("engines")
    if engines is None:
        engines = {}
    if not isinstance(engines, dict):
        raise Refused("profile engines is not an object: %s" % profile_json)
    engines["claude"] = {
        "status": "ready",
        "account": {
            "oauthAccount": account,
            "userID": user_id,
        },
    }
    profile["engines"] = engines
    atomic_write_json(profile_json, profile)
    sys.stdout.write("ready\n")
    return 0


def usage():
    sys.stderr.write(
        "usage: cbox_profile_seed.py seed [--refresh] <src_claude_json> <dst_claude_json>\n"
        "       cbox_profile_seed.py harvest <statedir_claude_json> <profile_json>\n"
    )
    return 2


def main(argv):
    args = argv[1:]
    if not args or args[0] not in ("seed", "harvest"):
        return usage()
    verb = args[0]
    rest = args[1:]
    refresh = False
    if verb == "seed" and rest and rest[0] == "--refresh":
        refresh = True
        rest = rest[1:]
    if len(rest) != 2:
        return usage()
    try:
        if verb == "seed":
            return cmd_seed(rest[0], rest[1], refresh)
        return cmd_harvest(rest[0], rest[1])
    except Refused as exc:
        sys.stderr.write("cbox_profile_seed: %s\n" % exc)
        return 2
    except OSError as exc:
        sys.stderr.write("cbox_profile_seed: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
