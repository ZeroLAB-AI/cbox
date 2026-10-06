#!/usr/bin/env python3
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import urllib.response
from email.message import Message
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etc" / "hooks" / "claude_usage_refresh.py"
TOKEN = "tok-SECRET-abc123XYZ"
NOW = 1_800_000_000.0

SCRUBBED_ENV = (
    "CBOX_USAGE_DIR",
    "CBOX_CLAUDE_USAGE_REFRESH",
    "CBOX_CLAUDE_USAGE_REFRESH_SEC",
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
)


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeResponse:
    def __init__(self, body, status=200):
        self._body = body
        self.status = status
        self.read_sizes = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, n=-1):
        self.read_sizes.append(n)
        if n is None or n < 0:
            return self._body
        return self._body[:n]


def api_body(five=0.0, seven=17.0, five_reset="2026-10-01T16:59:59.582681+00:00",
             seven_reset="2026-10-04T19:59:59.582703+00:00", extra=True):
    doc = {
        "five_hour": {"utilization": five, "resets_at": five_reset},
        "seven_day": {"utilization": seven, "resets_at": seven_reset},
    }
    if extra:
        doc["seven_day_opus"] = None
        doc["extra_usage"] = {"is_enabled": False}
    return json.dumps(doc).encode()


def http_error(code, retry_after=None):
    headers = Message()
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return urllib.error.HTTPError("https://example.invalid/", code, "x", headers, None)


class RefreshBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = os.path.join(self._tmp.name, "home")
        self.secure = os.path.join(self._tmp.name, "secure")
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.home)
        os.makedirs(self.secure)
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in SCRUBBED_ENV:
            os.environ.pop(name, None)
        os.environ["HOME"] = self.home
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        os.environ["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = self.secure
        self.mod = load_module("claude_usage_refresh_%d" % id(self))

    def tearDown(self):
        self._tmp.cleanup()

    def write_creds(self, directory=None, expires_ms=None, token=TOKEN):
        directory = directory or self.secure
        if expires_ms is None:
            expires_ms = (NOW + 3600) * 1000
        doc = {"claudeAiOauth": {"accessToken": token, "refreshToken": "refresh-SECRET-zzz",
                                 "expiresAt": expires_ms, "scopes": ["user:inference"]}}
        path = os.path.join(directory, ".credentials.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f)
        os.chmod(path, 0o600)
        return path

    def path(self, name):
        return os.path.join(self.usage_dir, name)

    def read_json(self, name):
        with open(self.path(name), "r", encoding="utf-8") as f:
            return json.load(f)

    def write_json(self, name, doc):
        os.makedirs(self.usage_dir, exist_ok=True)
        with open(self.path(name), "w", encoding="utf-8") as f:
            json.dump(doc, f)

    def fake_opener(self, response=None, error=None):
        opener = mock.MagicMock()
        if error is not None:
            opener.open.side_effect = error
        else:
            opener.open.return_value = response
        return opener

    def run_once(self, response=None, error=None, now=NOW):
        opener = self.fake_opener(response, error)
        with mock.patch.object(self.mod, "_build_opener", return_value=opener):
            result = self.mod.run_once(now)
        return result, opener.open

    def all_usage_text(self):
        out = []
        if not os.path.isdir(self.usage_dir):
            return ""
        for name in os.listdir(self.usage_dir):
            p = os.path.join(self.usage_dir, name)
            if os.path.isfile(p):
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    out.append(f.read())
        return "\n".join(out)


class TokenGateTests(RefreshBase):
    def test_missing_credentials_makes_no_request(self):
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "no-token")
        urlopen.assert_not_called()
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_expired_token_makes_no_request(self):
        self.write_creds(expires_ms=(NOW - 10) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "expired")
        urlopen.assert_not_called()

    def test_token_expiring_within_a_minute_makes_no_request(self):
        self.write_creds(expires_ms=(NOW + 59) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "expired")
        urlopen.assert_not_called()

    def test_token_just_outside_the_margin_is_used(self):
        self.write_creds(expires_ms=(NOW + 61) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")
        urlopen.assert_called_once()

    def test_malformed_credentials_make_no_request(self):
        path = os.path.join(self.secure, ".credentials.json")
        for body in ("{{{", "[]", json.dumps({"claudeAiOauth": "x"}),
                     json.dumps({"claudeAiOauth": {"accessToken": "", "expiresAt": NOW * 1000 + 10 ** 7}}),
                     json.dumps({"claudeAiOauth": {"accessToken": "a b", "expiresAt": NOW * 1000 + 10 ** 7}}),
                     json.dumps({"claudeAiOauth": {"accessToken": "ab\ncd", "expiresAt": NOW * 1000 + 10 ** 7}}),
                     json.dumps({"claudeAiOauth": {"accessToken": "abcd", "expiresAt": "soon"}})):
            with self.subTest(body=body[:30]):
                with open(path, "w", encoding="utf-8") as f:
                    f.write(body)
                result, urlopen = self.run_once(FakeResponse(api_body()))
                self.assertEqual(result, "no-token")
                urlopen.assert_not_called()

    def test_symlinked_credentials_are_not_followed(self):
        real = self.write_creds(directory=self._tmp.name)
        os.symlink(real, os.path.join(self.secure, ".credentials.json"))
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "no-token")
        urlopen.assert_not_called()

    def test_home_credentials_are_the_fallback(self):
        os.makedirs(os.path.join(self.home, ".claude"))
        self.write_creds(directory=os.path.join(self.home, ".claude"))
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")
        urlopen.assert_called_once()

    def test_securestorage_dir_wins_over_home(self):
        os.makedirs(os.path.join(self.home, ".claude"))
        self.write_creds(directory=os.path.join(self.home, ".claude"), token="home-token-1")
        self.write_creds(token="secure-token-1")
        result, urlopen = self.run_once(FakeResponse(api_body()))
        req = urlopen.call_args[0][0]
        self.assertEqual(req.get_header("Authorization"), "Bearer secure-token-1")

    def test_credentials_file_is_never_modified(self):
        path = self.write_creds()
        with open(path, "rb") as f:
            before = f.read()
        mtime = os.stat(path).st_mtime_ns
        self.run_once(FakeResponse(api_body()))
        self.run_once(error=http_error(401), now=NOW + 1000)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)
        self.assertEqual(os.stat(path).st_mtime_ns, mtime)

    def test_source_never_touches_the_refresh_token(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("refreshToken", text)
        self.assertNotIn("refresh_token", text)


class RequestShapeTests(RefreshBase):
    def test_request_carries_the_expected_endpoint_headers_and_timeout(self):
        self.write_creds()
        result, urlopen = self.run_once(FakeResponse(api_body()))
        req = urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://api.anthropic.com/api/oauth/usage")
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(req.get_header("Anthropic-beta"), "oauth-2025-04-20")
        self.assertEqual(req.get_header("Content-type"), "application/json")
        self.assertEqual(urlopen.call_args[1].get("timeout"), 5)
        self.assertNotIn("Authorization", req.headers)
        self.assertEqual(req.unredirected_hdrs.get("Authorization"), "Bearer " + TOKEN)

    def test_response_read_is_capped_at_64k(self):
        self.write_creds()
        resp = FakeResponse(api_body())
        self.run_once(resp)
        self.assertEqual(resp.read_sizes, [65537])


class ParseTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()

    def test_ok_response_writes_the_shared_snapshot(self):
        result, _ = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertEqual(snap["source"], "claude-api")
        self.assertEqual(snap["captured_at"], NOW)
        self.assertEqual(snap["five_hour"]["used_percentage"], 0.0)
        self.assertEqual(snap["seven_day"]["used_percentage"], 17.0)
        self.assertAlmostEqual(snap["five_hour"]["resets_at"], 1790873999.582681, places=3)
        self.assertAlmostEqual(snap["seven_day"]["resets_at"], 1791143999.582703, places=3)
        self.assertEqual(set(snap), {"source", "captured_at", "five_hour", "seven_day"})
        mode = stat.S_IMODE(os.stat(self.path("claude.json")).st_mode)
        self.assertEqual(mode, 0o600)

    def test_budget_reader_accepts_the_polled_snapshot(self):
        self.run_once(FakeResponse(api_body(five=12.5, seven=40.0, five_reset=NOW + 3000, seven_reset=NOW + 400000)))
        budget = self.mod._budget()
        m = budget.source_metrics("claude", NOW + 30)
        self.assertIsNotNone(m)
        self.assertEqual(m["captured_at"], NOW)
        self.assertEqual(m["five_hour"]["used_percentage"], 12.5)
        self.assertEqual(m["seven_day"]["used_percentage"], 40.0)

    def test_numeric_epoch_resets_are_accepted(self):
        body = api_body(five_reset=1790874000, seven_reset=1791144000.5)
        self.run_once(FakeResponse(body))
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"]["resets_at"], 1790874000.0)
        self.assertEqual(snap["seven_day"]["resets_at"], 1791144000.5)

    def test_null_resets_is_accepted_as_unknown_reset(self):
        self.run_once(FakeResponse(api_body(five_reset=None)))
        snap = self.read_json("claude.json")
        self.assertIsNone(snap["five_hour"]["resets_at"])
        self.assertEqual(snap["five_hour"]["used_percentage"], 0.0)

    def test_missing_window_keeps_the_previous_snapshot_window(self):
        self.write_json("claude.json", {
            "source": "claude", "captured_at": NOW - 1000,
            "five_hour": {"used_percentage": 33.0, "resets_at": NOW + 500},
            "seven_day": {"used_percentage": 1.0, "resets_at": NOW + 5000},
        })
        body = json.dumps({"five_hour": None,
                           "seven_day": {"utilization": 18.0,
                                         "resets_at": NOW + 5000}}).encode()
        result, _ = self.run_once(FakeResponse(body))
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"],
                         {"used_percentage": 33.0, "resets_at": NOW + 500, "captured_at": NOW - 1000})
        self.assertEqual(snap["seven_day"]["used_percentage"], 18.0)
        self.assertEqual(snap["seven_day"]["captured_at"], NOW)
        self.assertEqual(snap["captured_at"], NOW)

    def test_invalid_numbers_are_rejected(self):
        bad_values = ["101", "-1", "NaN", "Infinity", "true", '"50"', "null", "[]"]
        for value in bad_values:
            with self.subTest(utilization=value):
                body = ('{"five_hour": {"utilization": %s, "resets_at": null},'
                        ' "seven_day": {"utilization": %s, "resets_at": null}}' % (value, value)).encode()
                result, _ = self.run_once(FakeResponse(body))
                self.assertEqual(result, "invalid")
                self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_invalid_resets_rejects_that_window_only(self):
        body = json.dumps({
            "five_hour": {"utilization": 10.0, "resets_at": "not a date"},
            "seven_day": {"utilization": 20.0, "resets_at": 1791144000},
        }).encode()
        result, _ = self.run_once(FakeResponse(body))
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertIsNone(snap["five_hour"])
        self.assertEqual(snap["seven_day"]["used_percentage"], 20.0)

    def test_oversize_response_is_rejected(self):
        pad = "x" * 70000
        body = json.dumps({"five_hour": {"utilization": 1.0, "resets_at": None}, "pad": pad}).encode()
        result, _ = self.run_once(FakeResponse(body))
        self.assertEqual(result, "invalid")
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_response_at_the_cap_is_still_parsed(self):
        base = json.dumps({"five_hour": {"utilization": 1.0, "resets_at": None}, "pad": ""}).encode()
        pad = "x" * (65536 - len(base))
        body = json.dumps({"five_hour": {"utilization": 1.0, "resets_at": None}, "pad": pad}).encode()
        self.assertEqual(len(body), 65536)
        result, _ = self.run_once(FakeResponse(body))
        self.assertEqual(result, "ok")

    def test_garbage_bodies_are_rejected(self):
        for body in (b"", b"not json", b"[]", b"42", b"\xff\xfe", b"{}"):
            with self.subTest(body=body[:10]):
                result, _ = self.run_once(FakeResponse(body))
                self.assertEqual(result, "invalid")
                self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_non_200_success_status_is_not_trusted(self):
        result, _ = self.run_once(FakeResponse(api_body(), status=204))
        self.assertEqual(result, "http")
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_transport_error_is_swallowed_and_stamped(self):
        result, _ = self.run_once(error=urllib.error.URLError("dns"))
        self.assertEqual(result, "error")
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["ts"], NOW)
        self.assertNotIn("backoff_until", stamp)
        self.assertFalse(os.path.exists(self.path("claude.json")))


class BackoffTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()

    def test_429_honors_retry_after_seconds(self):
        result, _ = self.run_once(error=http_error(429, "120"))
        self.assertEqual(result, "http")
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["backoff_until"], NOW + 120)
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_429_without_retry_after_backs_off_fifteen_minutes(self):
        self.run_once(error=http_error(429))
        self.assertEqual(self.read_json("claude_refresh_attempt.json")["backoff_until"], NOW + 900)

    def test_403_stops_like_401_and_never_backs_off(self):
        self.run_once(error=http_error(403, "300"))
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["stop_expires_at"], (NOW + 3600) * 1000)
        self.assertNotIn("backoff_until", stamp)
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 1000)
        self.assertEqual(result, "stopped")
        urlopen.assert_not_called()
        self.write_creds(expires_ms=(NOW + 9000) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 1000)
        self.assertEqual(result, "ok")

    def test_retry_after_is_clamped(self):
        self.run_once(error=http_error(429, "1"))
        self.assertEqual(self.read_json("claude_refresh_attempt.json")["backoff_until"], NOW + 60)
        self.run_once(error=http_error(429, "99999999"), now=NOW + 100)
        self.assertEqual(self.read_json("claude_refresh_attempt.json")["backoff_until"],
                         NOW + 100 + 6 * 3600)

    def test_retry_after_http_date_is_understood(self):
        stamp = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(NOW + 600))
        self.run_once(error=http_error(429, stamp))
        until = self.read_json("claude_refresh_attempt.json")["backoff_until"]
        self.assertAlmostEqual(until, NOW + 600, delta=2)

    def test_garbage_retry_after_uses_the_default(self):
        self.run_once(error=http_error(429, "soon-ish"))
        self.assertEqual(self.read_json("claude_refresh_attempt.json")["backoff_until"], NOW + 900)

    def test_backoff_blocks_the_next_request_until_it_passes(self):
        self.run_once(error=http_error(429, "600"))
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 599)
        self.assertEqual(result, "backoff")
        urlopen.assert_not_called()
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 601)
        self.assertEqual(result, "ok")
        urlopen.assert_called_once()
        self.assertNotIn("backoff_until", self.read_json("claude_refresh_attempt.json"))

    def test_server_error_stamps_without_backoff(self):
        result, _ = self.run_once(error=http_error(500))
        self.assertEqual(result, "http")
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["ts"], NOW)
        self.assertNotIn("backoff_until", stamp)
        self.assertNotIn("stop_expires_at", stamp)

    def test_401_stops_until_the_expiry_changes(self):
        path = os.path.join(self.secure, ".credentials.json")
        self.run_once(error=http_error(401))
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["stop_expires_at"], (NOW + 3600) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 5000 - 4000)
        self.assertEqual(result, "stopped")
        urlopen.assert_not_called()
        self.write_creds(expires_ms=(NOW + 9000) * 1000)
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 1000)
        self.assertEqual(result, "ok")
        urlopen.assert_called_once()
        self.assertNotIn("stop_expires_at", self.read_json("claude_refresh_attempt.json"))
        self.assertTrue(os.path.exists(path))


class SafetyTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()

    def test_token_never_reaches_stdout_stderr_or_files(self):
        out, err = io.StringIO(), io.StringIO()
        scenarios = [
            dict(response=FakeResponse(api_body())),
            dict(error=http_error(429, "60")),
            dict(error=http_error(401)),
            dict(error=Exception("boom " + TOKEN)),
            dict(error=ValueError("Invalid header value b'Bearer %s'" % TOKEN)),
            dict(response=FakeResponse(b"junk " + TOKEN.encode())),
        ]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            for i, kwargs in enumerate(scenarios):
                self.run_once(now=NOW + i * 10000, **kwargs)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "")
        self.assertNotIn(TOKEN, self.all_usage_text())
        self.assertNotIn("refresh-SECRET", self.all_usage_text())

    def test_main_swallows_unexpected_errors_silently(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                mock.patch.object(self.mod, "_build_opener", return_value=self.fake_opener(error=RuntimeError(TOKEN))):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertEqual(out.getvalue() + err.getvalue(), "")
        self.assertNotIn(TOKEN, self.all_usage_text())

    def test_state_files_are_private(self):
        self.run_once(FakeResponse(api_body()))
        self.assertEqual(stat.S_IMODE(os.stat(self.path("claude_refresh_attempt.json")).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.usage_dir).st_mode), 0o700)


class MainFlowTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds(expires_ms=(time.time() + 3600) * 1000)

    def run_main(self, response=None, error=None):
        opener = self.fake_opener(response, error)
        with mock.patch.object(self.mod, "_build_opener", return_value=opener):
            rc = self.mod.main()
        return rc, opener.open

    def test_disabled_via_env_makes_no_request(self):
        os.environ["CBOX_CLAUDE_USAGE_REFRESH"] = "off"
        rc, urlopen = self.run_main(FakeResponse(api_body()))
        self.assertEqual(rc, 0)
        urlopen.assert_not_called()
        self.assertFalse(os.path.exists(self.usage_dir))

    def test_main_writes_snapshot_and_releases_the_lock(self):
        rc, urlopen = self.run_main(FakeResponse(api_body()))
        self.assertEqual(rc, 0)
        urlopen.assert_called_once()
        self.assertEqual(self.read_json("claude.json")["source"], "claude-api")
        self.assertFalse(os.path.exists(self.path("claude_refresh.lock")))

    def test_held_lock_blocks_a_second_flight(self):
        os.makedirs(self.usage_dir, mode=0o700)
        fd = os.open(self.path("claude_refresh.lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        old = time.time() - 120
        os.utime(self.path("claude_refresh.lock"), (old, old))
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, urlopen = self.run_main(FakeResponse(api_body()))
        finally:
            os.close(fd)
        self.assertEqual(rc, 0)
        urlopen.assert_not_called()

    def test_recent_lock_file_blocks_a_second_flight(self):
        os.makedirs(self.usage_dir, mode=0o700)
        with open(self.path("claude_refresh.lock"), "w", encoding="utf-8") as f:
            f.write("1")
        rc, urlopen = self.run_main(FakeResponse(api_body()))
        urlopen.assert_not_called()

    def test_fresh_snapshot_skips_the_request(self):
        self.write_json("claude.json", {
            "source": "claude", "captured_at": time.time() - 5,
            "five_hour": {"used_percentage": 1.0, "resets_at": None}, "seven_day": None,
        })
        rc, urlopen = self.run_main(FakeResponse(api_body()))
        urlopen.assert_not_called()

    def test_wall_cap_timer_is_armed_and_kills_the_process(self):
        with mock.patch.object(self.mod.threading, "Timer") as timer, \
                mock.patch.object(self.mod, "_build_opener", return_value=self.fake_opener(FakeResponse(api_body()))):
            self.mod.main()
        self.assertEqual(timer.call_args[0][0], 10)
        self.assertIs(timer.call_args[0][1], self.mod._hard_exit)
        timer.return_value.start.assert_called_once()
        timer.return_value.cancel.assert_called_once()

    def test_hard_exit_releases_the_lock_and_exits(self):
        handle = self.mod._acquire_lock()
        self.assertIsNotNone(handle)
        self.mod._LOCK_HANDLE[0] = handle
        with mock.patch.object(self.mod.os, "_exit") as hard:
            self.mod._hard_exit()
        hard.assert_called_once_with(0)
        self.assertFalse(os.path.exists(self.path("claude_refresh.lock")))


class RecordingHttps(urllib.request.HTTPSHandler):
    def __init__(self, log):
        super().__init__()
        self.log = log

    def https_open(self, req):
        self.log.append((req.full_url, req.get_header("Authorization")))
        headers = Message()
        headers["Location"] = "http://redirect-target.invalid/collect"
        resp = urllib.response.addinfourl(io.BytesIO(b""), headers, req.full_url, 302)
        resp.msg = "Found"
        return resp


class RecordingHttp(urllib.request.HTTPHandler):
    def __init__(self, log):
        super().__init__()
        self.log = log

    def http_open(self, req):
        self.log.append((req.full_url, req.get_header("Authorization")))
        resp = urllib.response.addinfourl(io.BytesIO(b"{}"), Message(), req.full_url, 200)
        resp.msg = "OK"
        return resp


class RedirectTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()
        self.log = []

    def test_redirect_is_refused_and_the_bearer_is_never_resent(self):
        opener = urllib.request.build_opener(
            self.mod._NoRedirect(), RecordingHttps(self.log), RecordingHttp(self.log))
        with mock.patch.object(self.mod, "_build_opener", return_value=opener):
            result = self.mod.run_once(NOW)
        self.assertEqual(result, "http")
        self.assertEqual(len(self.log), 1)
        self.assertEqual(self.log[0][0], "https://api.anthropic.com/api/oauth/usage")
        self.assertFalse(os.path.exists(self.path("claude.json")))
        stamp = self.read_json("claude_refresh_attempt.json")
        self.assertEqual(stamp["ts"], NOW)
        self.assertNotIn("stop_expires_at", stamp)
        self.assertNotIn("backoff_until", stamp)

    def test_default_redirect_handling_would_not_resend_the_bearer_either(self):
        req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage")
        req.add_unredirected_header("Authorization", "Bearer " + TOKEN)
        handler = urllib.request.HTTPRedirectHandler()
        new = handler.redirect_request(req, io.BytesIO(b""), 302, "Found", Message(),
                                       "http://redirect-target.invalid/collect")
        self.assertIsNotNone(new)
        self.assertIsNone(new.get_header("Authorization"))

    def test_real_opener_is_built_with_the_refusing_handler(self):
        opener = self.mod._build_opener()
        kinds = [type(h) for h in opener.handlers]
        self.assertIn(self.mod._NoRedirect, kinds)
        self.assertNotIn(urllib.request.HTTPRedirectHandler, kinds)
        self.assertIsNone(self.mod._NoRedirect().redirect_request(None, None, 302, "x", None, "http://x/"))


class SnapshotRulesTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()

    def seed(self, five=None, seven=None, captured=NOW - 1000):
        self.write_json("claude.json", {
            "source": "claude", "captured_at": captured, "five_hour": five, "seven_day": seven,
        })

    def api(self, five=None, seven=None):
        doc = {}
        if five is not None:
            doc["five_hour"] = {"utilization": five[0], "resets_at": five[1]}
        if seven is not None:
            doc["seven_day"] = {"utilization": seven[0], "resets_at": seven[1]}
        return FakeResponse(json.dumps(doc).encode())

    def test_per_window_stamps_and_top_level_max(self):
        self.seed(five={"used_percentage": 10.0, "resets_at": NOW + 3000, "captured_at": NOW - 500},
                  seven={"used_percentage": 20.0, "resets_at": NOW + 400000, "captured_at": NOW - 900})
        result, _ = self.run_once(self.api(five=(15.0, NOW + 3000)))
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertEqual(snap["captured_at"], NOW)
        self.assertEqual(snap["five_hour"]["captured_at"], NOW)
        self.assertEqual(snap["seven_day"],
                         {"used_percentage": 20.0, "resets_at": NOW + 400000, "captured_at": NOW - 900})

    def test_every_accepted_window_is_stamped_now(self):
        result, _ = self.run_once(self.api(five=(1.0, NOW + 3000), seven=(2.0, NOW + 400000)))
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"]["captured_at"], NOW)
        self.assertEqual(snap["seven_day"]["captured_at"], NOW)

    def test_lower_usage_in_the_same_window_is_never_written(self):
        self.seed(five={"used_percentage": 40.0, "resets_at": NOW + 3000, "captured_at": NOW - 100})
        before = os.stat(self.path("claude.json")).st_mtime_ns
        result, _ = self.run_once(self.api(five=(30.0, NOW + 3020)))
        self.assertEqual(result, "unchanged")
        self.assertEqual(os.stat(self.path("claude.json")).st_mtime_ns, before)
        self.assertEqual(self.read_json("claude.json")["five_hour"]["used_percentage"], 40.0)

    def test_higher_usage_in_the_same_window_is_written(self):
        self.seed(five={"used_percentage": 40.0, "resets_at": NOW + 3000, "captured_at": NOW - 100})
        self.run_once(self.api(five=(45.0, NOW + 3020)))
        self.assertEqual(self.read_json("claude.json")["five_hour"]["used_percentage"], 45.0)

    def test_a_real_roll_is_written_even_with_lower_usage(self):
        self.seed(five={"used_percentage": 90.0, "resets_at": NOW - 100, "captured_at": NOW - 1000})
        self.run_once(self.api(five=(1.0, NOW + 18000 - 100)))
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"]["used_percentage"], 1.0)

    def test_unknown_resets_never_replaces_a_known_resets(self):
        self.seed(five={"used_percentage": 10.0, "resets_at": NOW + 3000, "captured_at": NOW - 100})
        result, _ = self.run_once(self.api(five=(50.0, None)))
        self.assertEqual(result, "unchanged")
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"]["used_percentage"], 10.0)
        self.assertEqual(snap["five_hour"]["resets_at"], NOW + 3000)

    def test_future_stamped_existing_window_is_replaced(self):
        self.seed(five={"used_percentage": 90.0, "resets_at": NOW + 3000, "captured_at": NOW + 10 ** 6},
                  captured=NOW + 10 ** 6)
        result, _ = self.run_once(self.api(five=(5.0, NOW + 3000)))
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertEqual(snap["five_hour"]["used_percentage"], 5.0)
        self.assertEqual(snap["captured_at"], NOW)

    def test_implausible_api_resets_rejects_that_window(self):
        body = self.api(five=(10.0, NOW + 5 * 3600 + 120), seven=(20.0, NOW + 400000))
        result, _ = self.run_once(body)
        self.assertEqual(result, "ok")
        snap = self.read_json("claude.json")
        self.assertIsNone(snap["five_hour"])
        self.assertEqual(snap["seven_day"]["used_percentage"], 20.0)

    def test_all_windows_implausible_writes_nothing(self):
        result, _ = self.run_once(self.api(five=(10.0, NOW + 10 ** 7), seven=(20.0, NOW + 10 ** 9)))
        self.assertEqual(result, "invalid")
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_implausible_existing_window_is_not_carried_over(self):
        self.seed(five={"used_percentage": 99.0, "resets_at": NOW + 10 ** 7, "captured_at": NOW - 100})
        self.run_once(self.api(seven=(20.0, NOW + 400000)))
        snap = self.read_json("claude.json")
        self.assertIsNone(snap["five_hour"])

    def test_held_snapshot_lock_skips_the_write_quickly(self):
        os.makedirs(self.usage_dir, mode=0o700, exist_ok=True)
        fd = os.open(self.path("claude.json.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            started = time.monotonic()
            result, _ = self.run_once(self.api(five=(10.0, NOW + 3000)))
            elapsed = time.monotonic() - started
        finally:
            os.close(fd)
        self.assertEqual(result, "unchanged")
        self.assertLess(elapsed, 1.5)
        self.assertFalse(os.path.exists(self.path("claude.json")))


class StampBoundsTests(RefreshBase):
    def setUp(self):
        super().setUp()
        self.write_creds()

    def test_absurd_backoff_stamp_is_ignored(self):
        self.write_json("claude_refresh_attempt.json", {"ts": NOW - 5000, "backoff_until": NOW + 10 ** 9})
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")
        urlopen.assert_called_once()

    def test_backoff_at_the_upper_bound_still_blocks(self):
        self.write_json("claude_refresh_attempt.json", {"ts": NOW - 5000, "backoff_until": NOW + 6 * 3600})
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "backoff")
        urlopen.assert_not_called()

    def test_stop_marker_without_a_sane_stop_time_is_ignored(self):
        expires = (NOW + 3600) * 1000
        self.write_json("claude_refresh_attempt.json", {"stop_expires_at": expires})
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")
        self.write_json("claude_refresh_attempt.json", {"stop_expires_at": expires, "stop_at": NOW + 10 ** 6})
        for f in ("claude.json",):
            os.unlink(self.path(f))
        result, urlopen = self.run_once(FakeResponse(api_body()), now=NOW + 1)
        self.assertEqual(result, "ok")

    def test_stop_marker_with_a_past_stop_time_blocks(self):
        expires = (NOW + 3600) * 1000
        self.write_json("claude_refresh_attempt.json", {"stop_expires_at": expires, "stop_at": NOW - 10})
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "stopped")
        urlopen.assert_not_called()


class DeepNestingTests(RefreshBase):
    def test_deeply_nested_credentials_are_unreadable_not_fatal(self):
        with open(os.path.join(self.secure, ".credentials.json"), "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        result, urlopen = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "no-token")
        urlopen.assert_not_called()

    def test_deeply_nested_response_is_invalid_not_fatal(self):
        self.write_creds()
        result, _ = self.run_once(FakeResponse(b"[" * 60000))
        self.assertEqual(result, "invalid")

    def test_deeply_nested_stamp_is_ignored(self):
        self.write_creds()
        os.makedirs(self.usage_dir, mode=0o700, exist_ok=True)
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        result, _ = self.run_once(FakeResponse(api_body()))
        self.assertEqual(result, "ok")


class LockHardeningTests(RefreshBase):
    def test_fifo_at_the_lock_path_does_not_hang(self):
        os.makedirs(self.usage_dir, mode=0o700)
        os.mkfifo(self.path("claude_refresh.lock"))
        old = time.time() - 120
        os.utime(self.path("claude_refresh.lock"), (old, old))
        out = []
        t = threading.Thread(target=lambda: out.append(self.mod._acquire_lock()), daemon=True)
        t.start()
        t.join(3)
        self.assertFalse(t.is_alive())
        self.assertIsNone(out[0])

    def test_non_regular_lock_target_is_refused(self):
        os.makedirs(self.usage_dir, mode=0o700)
        real_open = os.open

        def fake_open(path, flags, mode=0o777):
            if str(path).endswith("claude_refresh.lock"):
                return real_open("/dev/null", os.O_WRONLY)
            return real_open(path, flags, mode)

        with mock.patch.object(self.mod.os, "open", side_effect=fake_open):
            self.assertIsNone(self.mod._acquire_lock())

    def test_lock_is_opened_nonblocking_and_nofollow(self):
        os.makedirs(self.usage_dir, mode=0o700)
        seen = []
        real_open = os.open

        def spy(path, flags, mode=0o777):
            seen.append(flags)
            return real_open(path, flags, mode)

        with mock.patch.object(self.mod.os, "open", side_effect=spy):
            handle = self.mod._acquire_lock()
        self.mod._release_lock(handle)
        self.assertTrue(seen[0] & os.O_NONBLOCK)
        self.assertTrue(seen[0] & os.O_NOFOLLOW)

    def test_wall_cap_timer_starts_before_the_lock_is_taken(self):
        order = []
        timer = mock.MagicMock()
        timer.start.side_effect = lambda: order.append("timer")

        def fake_acquire():
            order.append("lock")
            return None

        with mock.patch.object(self.mod.threading, "Timer", return_value=timer), \
                mock.patch.object(self.mod, "_acquire_lock", side_effect=fake_acquire):
            self.mod.main()
        self.assertEqual(order, ["timer", "lock"])
        timer.cancel.assert_called_once()


class ProcessSmokeTests(RefreshBase):
    def _env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k not in SCRUBBED_ENV}
        env["HOME"] = self.home
        env["CBOX_USAGE_DIR"] = self.usage_dir
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = self.secure
        env.update(extra)
        return env

    def test_disabled_process_exits_clean_without_files(self):
        proc = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, timeout=30,
                              env=self._env(CBOX_CLAUDE_USAGE_REFRESH="off"))
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout + proc.stderr, "")
        self.assertFalse(os.path.exists(self.usage_dir))

    def test_process_without_credentials_exits_clean_and_silent(self):
        proc = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, timeout=30,
                              env=self._env())
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout + proc.stderr, "")
        self.assertFalse(os.path.exists(self.path("claude.json")))

    def test_process_with_an_expired_token_makes_no_request(self):
        self.write_creds(expires_ms=(time.time() - 100) * 1000)
        proc = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, timeout=30,
                              env=self._env())
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout + proc.stderr, "")
        self.assertFalse(os.path.exists(self.path("claude.json")))
        self.assertFalse(os.path.exists(self.path("claude_refresh_attempt.json")))


if __name__ == "__main__":
    unittest.main()
