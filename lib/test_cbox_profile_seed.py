#!/usr/bin/env python3
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest


HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cbox_profile_seed.py")

SRC = {
    "oauthAccount": {"emailAddress": "a@example.com"},
    "userID": "u-1",
    "machineID": "m-1",
    "modelAccessCache": {"x": 1},
    "cachedUsageUtilization": {"y": 2},
    "cachedExtraUsageDisabledReason": "z",
    "groveConfigCache": {"a": 1},
    "passesEligibilityCache": {"a": 1},
    "metricsStatusCacheByPrincipal": {"a": 1},
    "orgModelDefaultCache": {"a": 1},
    "clientDataCacheSlots": {"a": 1},
    "cachedGrowthBookFeatures": {"a": 1},
    "cachedExperimentData": {"a": 1},
    "additionalModelOptionsCache": {"a": 1},
    "promoStartupStatusCache": {"a": 1},
    "cachedArtifactRoster": {"a": 1},
    "mcpServers": {"s": {"env": {"TOKEN": "t"}}},
    "futureUnknownKey": "x",
    "theme": "dark",
    "hasCompletedOnboarding": True,
    "numStartups": 7,
    "tipsHistory": {"tip-a": 3},
    "projects": {
        "/p": {
            "hasTrustDialogAccepted": True,
            "mcpServers": {"s": {"env": {"TOKEN": "t"}}},
            "enabledMcpjsonServers": ["x"],
            "env": {"A": "b"},
            "apiKeyHelper": "k",
            "lastSessionId": "sid",
            "k": 1,
        },
        "/empty": {"k": 1},
    },
}

SEEDED = {
    "theme": "dark",
    "hasCompletedOnboarding": True,
    "numStartups": 7,
    "tipsHistory": {"tip-a": 3},
    "projects": {"/p": {"hasTrustDialogAccepted": True}},
}


def run(*args):
    return subprocess.run(
        [sys.executable, "-I", HELPER] + list(args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh)


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


class SeedTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.d = self._td.name
        self.src = os.path.join(self.d, "src.json")
        self.dst = os.path.join(self.d, "dst.json")

    def test_allowlist_keeps_only_ui_keys(self):
        write_json(self.src, SRC)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "seeded")
        with open(self.dst, encoding="utf-8") as fh:
            out = json.load(fh)
        self.assertEqual(out, SEEDED)

    def test_allowlist_drops_each_account_key(self):
        write_json(self.src, SRC)
        self.assertEqual(run("seed", self.src, self.dst).returncode, 0)
        with open(self.dst, encoding="utf-8") as fh:
            out = json.load(fh)
        for key in (
            "oauthAccount", "userID", "machineID", "modelAccessCache", "cachedUsageUtilization",
            "cachedExtraUsageDisabledReason", "groveConfigCache", "passesEligibilityCache",
            "metricsStatusCacheByPrincipal", "orgModelDefaultCache", "clientDataCacheSlots",
            "cachedGrowthBookFeatures", "cachedExperimentData", "additionalModelOptionsCache",
            "promoStartupStatusCache", "cachedArtifactRoster", "mcpServers", "futureUnknownKey",
        ):
            self.assertNotIn(key, out)
        self.assertNotIn("a@example.com", json.dumps(out))

    def test_nested_secret_named_keys_dropped_in_kept_values(self):
        write_json(self.src, {"tipsHistory": {"ok": 1, "apiKey": "s", "authToken": "t", "n": {"mcpX": 1, "v": 2}}})
        self.assertEqual(run("seed", self.src, self.dst).returncode, 0)
        with open(self.dst, encoding="utf-8") as fh:
            out = json.load(fh)
        self.assertEqual(out, {"tipsHistory": {"ok": 1, "n": {"v": 2}}})

    def test_nonfinite_float_dropped(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write('{"numStartups": NaN, "theme": "dark"}')
        self.assertEqual(run("seed", self.src, self.dst).returncode, 0)
        with open(self.dst, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), {"theme": "dark"})

    def test_mode_0600(self):
        write_json(self.src, SRC)
        self.assertEqual(run("seed", self.src, self.dst).returncode, 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.dst).st_mode), 0o600)

    def test_existing_dst_untouched(self):
        write_json(self.src, SRC)
        with open(self.dst, "wb") as fh:
            fh.write(b'{"keep":  "me"}\n')
        before = read_bytes(self.dst)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "exists")
        self.assertEqual(read_bytes(self.dst), before)

    def test_missing_src_gives_empty_object(self):
        r = run("seed", os.path.join(self.d, "nope.json"), self.dst)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.dst, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), {})

    def test_non_object_src_refused(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write("[1, 2]")
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_refresh_rewrites_existing_destination(self):
        write_json(self.src, SRC)
        with open(self.dst, "wb") as fh:
            fh.write(b'{"stale": "snapshot"}\n')
        r = run("seed", "--refresh", self.src, self.dst)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "refreshed")
        with open(self.dst, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), SEEDED)
        self.assertEqual(stat.S_IMODE(os.stat(self.dst).st_mode), 0o600)
        self.assertEqual([n for n in os.listdir(self.d) if n.startswith(".cbox-profile-seed-")], [])

    def test_refresh_creates_missing_destination(self):
        write_json(self.src, SRC)
        r = run("seed", "--refresh", self.src, self.dst)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "seeded")

    def test_refresh_follows_same_destination_rules(self):
        write_json(self.src, SRC)
        target = os.path.join(self.d, "target.json")
        with open(target, "wb") as fh:
            fh.write(b'{"keep": 1}\n')
        os.symlink(target, self.dst)
        r = run("seed", "--refresh", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(read_bytes(target), b'{"keep": 1}\n')

    def test_refresh_refuses_symlinked_source(self):
        real = os.path.join(self.d, "real.json")
        write_json(real, {"theme": "x"})
        os.symlink(real, self.src)
        with open(self.dst, "wb") as fh:
            fh.write(b'{"keep": 1}\n')
        r = run("seed", "--refresh", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(read_bytes(self.dst), b'{"keep": 1}\n')

    def test_symlinked_source_refused_and_nothing_leaks(self):
        creds = os.path.join(self.d, "other-profile.credentials.json")
        write_json(creds, {"theme": "dark", "claudeAiOauth": {"accessToken": "SECRET-TOKEN"}})
        os.symlink(creds, self.src)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))
        self.assertNotIn("SECRET-TOKEN", r.stdout + r.stderr)

    def test_dangling_symlinked_source_refused(self):
        os.symlink(os.path.join(self.d, "nowhere.json"), self.src)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_fifo_source_refused_without_hanging(self):
        os.mkfifo(self.src)
        try:
            r = subprocess.run(
                [sys.executable, "-I", HELPER, "seed", self.src, self.dst],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            self.fail("seed hung on a FIFO source")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_directory_source_refused(self):
        os.mkdir(self.src)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_oversized_source_refused(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write('{"theme": "' + "a" * (4 * 1024 * 1024) + '"}')
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_source_just_under_cap_accepted(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write('{"verbose": true, "pad": "' + "a" * (1024 * 1024) + '"}')
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_deep_nesting_refused(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write('{"theme": ' + "[" * 200000 + "]" * 200000 + "}")
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("Traceback", r.stderr)
        self.assertFalse(os.path.lexists(self.dst))

    def test_moderate_nesting_over_guard_refused(self):
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write('{"theme": ' + "[" * 100 + "]" * 100 + "}")
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_invalid_utf8_source_refused(self):
        with open(self.src, "wb") as fh:
            fh.write(b'{"theme": "\xff\xfe"}')
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("Traceback", r.stderr)

    def test_foreign_owned_source_refused(self):
        if os.geteuid() != 0:
            self.skipTest("needs root to chown")
        write_json(self.src, SRC)
        os.chown(self.src, 4242, 4242)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.dst))

    def test_usage_errors(self):
        self.assertEqual(run("seed", self.src).returncode, 2)
        self.assertEqual(run("seed", "--refresh", self.src).returncode, 2)
        self.assertEqual(run("bogus", self.src, self.dst).returncode, 2)
        self.assertEqual(run().returncode, 2)

    def test_symlink_dst_refused(self):
        write_json(self.src, SRC)
        target = os.path.join(self.d, "target.json")
        os.symlink(target, self.dst)
        r = run("seed", self.src, self.dst)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.exists(target))

    def test_symlink_parent_refused(self):
        write_json(self.src, SRC)
        real = os.path.join(self.d, "real")
        os.mkdir(real)
        link = os.path.join(self.d, "link")
        os.symlink(real, link)
        r = run("seed", self.src, os.path.join(link, "dst.json"))
        self.assertEqual(r.returncode, 2)
        self.assertEqual(os.listdir(real), [])


class HarvestTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.d = self._td.name
        self.state = os.path.join(self.d, "state.json")
        self.profile = os.path.join(self.d, "profile.json")

    def test_ready_with_account_and_userid(self):
        write_json(self.state, SRC)
        write_json(self.profile, {"name": "work", "engines": {"codex": {"status": "ready"}}})
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ready")
        with open(self.profile, encoding="utf-8") as fh:
            out = json.load(fh)
        self.assertEqual(out["name"], "work")
        self.assertEqual(out["engines"]["codex"], {"status": "ready"})
        self.assertEqual(
            out["engines"]["claude"],
            {
                "status": "ready",
                "account": {
                    "oauthAccount": {"emailAddress": "a@example.com"},
                    "userID": "u-1",
                },
            },
        )
        self.assertEqual(stat.S_IMODE(os.stat(self.profile).st_mode), 0o600)

    def test_creates_engines_and_null_userid(self):
        write_json(self.state, {"oauthAccount": {"emailAddress": "e@example.com"}})
        write_json(self.profile, {"name": "p"})
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.profile, encoding="utf-8") as fh:
            out = json.load(fh)
        self.assertEqual(out["name"], "p")
        self.assertIsNone(out["engines"]["claude"]["account"]["userID"])

    def test_nested_unknown_and_control_fields_dropped(self):
        account = {
            "accountUuid": "uuid-1",
            "emailAddress": "a\x1b[31m@example.com\x00\n",
            "organizationName": "O" * 1000,
            "hasExtraUsageEnabled": True,
            "billingType": 3,
            "organizationRole": {"nested": "object"},
            "displayName": ["list"],
            "accessToken": "SECRET-TOKEN",
            "refreshToken": "SECRET-REFRESH",
            "unknownField": "x",
            "organizationUuid": None,
        }
        write_json(self.state, {"oauthAccount": account, "userID": "u\x07-1", "mcpServers": {"x": 1}})
        write_json(self.profile, {"name": "p"})
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ready")
        with open(self.profile, encoding="utf-8") as fh:
            out = json.load(fh)
        got = out["engines"]["claude"]["account"]
        self.assertEqual(
            got["oauthAccount"],
            {
                "accountUuid": "uuid-1",
                "emailAddress": "a[31m@example.com",
                "organizationName": "O" * 256,
                "hasExtraUsageEnabled": True,
                "billingType": 3,
            },
        )
        self.assertEqual(got["userID"], "u-1")
        self.assertNotIn("SECRET", json.dumps(out))

    def test_account_without_allowed_fields_is_empty(self):
        write_json(self.state, {"oauthAccount": {"accessToken": "SECRET-TOKEN"}})
        with open(self.profile, "wb") as fh:
            fh.write(b'{"name":   "p"}\n')
        before = read_bytes(self.profile)
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.stdout.strip(), "empty")
        self.assertEqual(read_bytes(self.profile), before)

    def test_symlinked_state_ignored_and_not_followed(self):
        creds = os.path.join(self.d, "creds.json")
        write_json(creds, {"oauthAccount": {"emailAddress": "victim@example.com"}})
        os.symlink(creds, self.state)
        write_json(self.profile, {"name": "p"})
        before = read_bytes(self.profile)
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "empty")
        self.assertEqual(read_bytes(self.profile), before)

    def test_fifo_state_does_not_hang(self):
        os.mkfifo(self.state)
        write_json(self.profile, {"name": "p"})
        try:
            r = subprocess.run(
                [sys.executable, "-I", HELPER, "harvest", self.state, self.profile],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            self.fail("harvest hung on a FIFO state file")
        self.assertEqual(r.stdout.strip(), "empty")

    def test_oversized_and_deep_state_ignored(self):
        write_json(self.profile, {"name": "p"})
        before = read_bytes(self.profile)
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write('{"oauthAccount": {"emailAddress": "' + "a" * (4 * 1024 * 1024) + '"}}')
        self.assertEqual(run("harvest", self.state, self.profile).stdout.strip(), "empty")
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write('{"oauthAccount": ' + "[" * 200000 + "]" * 200000 + "}")
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.stdout.strip(), "empty")
        self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(read_bytes(self.profile), before)

    def test_without_oauth_account_is_empty(self):
        write_json(self.state, {"theme": "dark"})
        with open(self.profile, "wb") as fh:
            fh.write(b'{"name":   "p"}\n')
        before = read_bytes(self.profile)
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "empty")
        self.assertEqual(read_bytes(self.profile), before)

    def test_missing_state_is_empty(self):
        write_json(self.profile, {"name": "p"})
        before = read_bytes(self.profile)
        r = run("harvest", os.path.join(self.d, "nope.json"), self.profile)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "empty")
        self.assertEqual(read_bytes(self.profile), before)

    def test_symlink_profile_refused(self):
        write_json(self.state, SRC)
        real = os.path.join(self.d, "real.json")
        write_json(real, {"name": "p"})
        before = read_bytes(real)
        os.symlink(real, self.profile)
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(read_bytes(real), before)

    def test_missing_profile_exit_2(self):
        write_json(self.state, SRC)
        r = run("harvest", self.state, self.profile)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.lexists(self.profile))


if __name__ == "__main__":
    unittest.main()
