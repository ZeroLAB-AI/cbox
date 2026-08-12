#!/usr/bin/env python3
import importlib.util
import json
import os
import sqlite3
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("bridge", os.path.join(HERE, "cbox_session_bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class SessionBridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "project")
        self.other = os.path.join(self.tmp.name, "other")
        self.claude = os.path.join(self.tmp.name, "claude")
        self.codex = os.path.join(self.tmp.name, "codex")
        self.hermes = os.path.join(self.tmp.name, "hermes")
        for path in (self.root, self.other, self.claude, self.codex, self.hermes):
            os.makedirs(path)
        os.environ["CLAUDE_CONFIG_DIR"] = self.claude
        os.environ["CODEX_HOME"] = self.codex
        os.environ["HERMES_HOME"] = self.hermes
        self.claude_id = "11111111-1111-4111-8111-111111111111"
        self.codex_id = "22222222-2222-4222-8222-222222222222"
        self.hermes_id = "33333333-3333-4333-8333-333333333333"
        self._write_claude()
        self._write_codex()
        self._write_hermes()

    def tearDown(self):
        self.tmp.cleanup()

    def _write_jsonl(self, path, rows):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row) + "\n")

    def _write_claude(self):
        path = os.path.join(self.claude, "projects", "-project", self.claude_id + ".jsonl")
        self._write_jsonl(path, [
            {"type": "user", "sessionId": self.claude_id, "cwd": self.root, "timestamp": "2026-07-21T10:00:00Z", "uuid": "c1", "message": {"role": "user", "content": "claude request"}},
            {"type": "assistant", "sessionId": self.claude_id, "cwd": self.root, "timestamp": "2026-07-21T10:01:00Z", "uuid": "c2", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "hidden"}, {"type": "text", "text": "claude answer"}]}},
            {"type": "user", "sessionId": self.claude_id, "cwd": self.root, "timestamp": "2026-07-21T10:02:00Z", "uuid": "c3", "message": {"role": "user", "content": [{"type": "tool_result", "content": "skip"}]}},
        ])
        other_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        self._write_jsonl(os.path.join(self.claude, "projects", "-other", other_id + ".jsonl"), [
            {"type": "user", "sessionId": other_id, "cwd": self.other, "timestamp": "2026-07-21T10:00:00Z", "message": {"role": "user", "content": "outside"}},
        ])

    def _write_codex(self):
        path = os.path.join(self.codex, "sessions", "2026", "07", "21", "rollout.jsonl")
        self._write_jsonl(path, [
            {"timestamp": "2026-07-21T11:00:00Z", "type": "session_meta", "payload": {"id": self.codex_id, "cwd": self.root, "source": "cli"}},
            {"timestamp": "2026-07-21T11:00:01Z", "type": "response_item", "payload": {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "skip"}]}},
            {"timestamp": "2026-07-21T11:01:00Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "codex request"}]}},
            {"timestamp": "2026-07-21T11:02:00Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "codex answer"}]}},
        ])
        self._write_jsonl(os.path.join(self.codex, "history.jsonl"), [
            {"session_id": self.codex_id, "ts": 1, "text": "codex runtime title"},
        ])

    def _write_hermes(self):
        path = os.path.join(self.hermes, "state.db")
        con = sqlite3.connect(path)
        con.executescript("""
create table sessions (id text primary key, cwd text, git_repo_root text, started_at real, ended_at real, title text, display_name text, archived integer);
create table messages (id integer primary key, session_id text, role text, content text, timestamp real, active integer);
""")
        con.execute("insert into sessions values (?,?,?,?,?,?,?,?)", (self.hermes_id, self.root, self.root, 1, 2, "hermes runtime title", None, 0))
        con.execute("insert into messages values (?,?,?,?,?,?)", (1, self.hermes_id, "user", "hermes request", 1, 1))
        con.execute("insert into messages values (?,?,?,?,?,?)", (2, self.hermes_id, "assistant", "hermes answer", 2, 1))
        con.commit()
        con.close()

    def test_discover_filters_project_and_finds_all_engines(self):
        records = bridge.discover(self.root)
        self.assertEqual({x["engine"] for x in records}, {"claude", "codex", "hermes"})
        self.assertEqual(len(records), 3)
        self.assertNotIn("outside", json.dumps(records))
        self.assertTrue(all(x["kind"] == "interactive" for x in records))

    def test_claude_discovery_includes_host_project_view(self):
        native_id = "44444444-4444-4444-8444-444444444444"
        path = os.path.join(self.claude, ".host-projects", "-worktree", native_id + ".jsonl")
        self._write_jsonl(path, [
            {"type": "user", "sessionId": native_id, "cwd": os.path.join(self.root, "worktree"), "timestamp": "2026-07-21T12:00:00Z", "message": {"role": "user", "content": "worktree request"}},
        ])
        records = bridge.claude_discover(self.root)
        self.assertIn(native_id, {x["nativeSessionId"] for x in records})

    def test_extractors_keep_conversation_text_only_and_advance_cursor(self):
        cases = [
            ("claude", self.claude_id, ["claude request", "claude answer"]),
            ("codex", self.codex_id, ["codex request", "codex answer"]),
            ("hermes", self.hermes_id, ["hermes request", "hermes answer"]),
        ]
        for engine, native_id, want in cases:
            delta = bridge.extract(self.root, engine, native_id, "")
            self.assertEqual([x["text"] for x in delta["messages"]], want)
            again = bridge.extract(self.root, engine, native_id, json.dumps(delta["cursor"]))
            self.assertEqual(again["messages"], [])

    def test_import_plan_maps_native_sessions_without_persisting_titles(self):
        records = bridge.discover(self.root)
        plan = bridge.import_plan(self.root, records)
        self.assertEqual(len(plan["plans"]), 3)
        self.assertTrue(all(x["isNew"] for x in plan["plans"]))
        docs = json.dumps([x["doc"] for x in plan["plans"]])
        self.assertNotIn("runtime title", docs)
        for item in plan["plans"]:
            sid = item["sessionId"]
            path = os.path.join(self.root, ".cbox", "sessions", sid)
            os.makedirs(path)
            with open(os.path.join(path, "session.json"), "w", encoding="utf-8") as fh:
                json.dump(item["doc"], fh)
        again = bridge.import_plan(self.root, records)
        self.assertTrue(all(not x["isNew"] for x in again["plans"]))

    def test_import_plan_rejects_native_id_suffix(self):
        records = [{
            "engine": "codex",
            "nativeSessionId": self.codex_id + "\ninvalid",
            "locator": "sessions/rollout.jsonl",
        }]
        self.assertEqual(bridge.import_plan(self.root, records)["plans"], [])

    def test_merge_keeps_recent_verbatim_and_bounds_older_summaries(self):
        messages = []
        for i in range(24):
            messages.append({"role": "user" if i % 2 == 0 else "assistant", "text": "message %02d" % i, "timestamp": str(i), "sourceId": str(i)})
        delta = {"locator": "sessions/x.jsonl", "cursor": {"kind": "byte", "value": 10}, "messages": messages}
        doc = bridge.merge_memory(None, delta, "s-20260721-1200-abcdef", 1, "codex", self.codex_id)
        self.assertEqual(len(doc["layerA"]), 16)
        self.assertEqual(doc["layerA"][0]["text"], "message 08")
        self.assertTrue(all(x["verbatim"] for x in doc["layerA"]))
        self.assertEqual(len(doc["layerB"]), 8)
        rendered = bridge.render_memory(doc)
        self.assertIn("message 23", rendered)
        self.assertNotIn("hidden", rendered)
        encoded = json.dumps(doc, ensure_ascii=True).encode("ascii")
        self.assertGreater(len(encoded), 0)

    def test_previous_distillate_refuses_symlink(self):
        sid = "s-20260721-1200-abcdef"
        directory = os.path.join(self.root, ".cbox", "sessions", sid, "distillates")
        os.makedirs(directory)
        target = os.path.join(directory, "handoff-000001.json")
        with open(target, "w", encoding="utf-8") as fh:
            json.dump({"schemaVersion": 1}, fh)
        link = os.path.join(directory, "handoff-000002.json")
        os.symlink(target, link)
        with self.assertRaises(OSError):
            bridge.open_previous(self.root, ".cbox/sessions/%s/distillates/handoff-000002.json" % sid)

    def test_mine_records_emits_provenance_stamp(self):
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        self.assertIn("mined from codex native history", result["block"])
        self.assertIn("lower fidelity than inline hooks", result["block"])
        self.assertIn("cbox-mined engine=codex native=%s" % self.codex_id, result["block"])

    def test_mine_records_is_chat_narrative_only_not_commit_or_edit_events(self):
        result = bridge.mine_records(self.root, "claude", self.claude_id, "")
        derived_line = result["block"].splitlines()[-1]
        self.assertIn("turns", derived_line)
        self.assertIn("topic", derived_line)
        lowered = derived_line.lower()
        self.assertNotIn("commit", lowered)
        self.assertNotIn("edit event", lowered)
        self.assertIn("claude request", derived_line)

    def test_mine_records_target_rejects_ledger_and_diary_and_open_questions(self):
        for forbidden in ("LEDGER.md", "DIARY.md", "OPEN_QUESTIONS.md", "../LEDGER.md", "sub/PROGRESS_2026_07_21.md"):
            with self.assertRaises(ValueError):
                bridge.mine_target_path(self.root, forbidden)

    def test_mine_records_target_accepts_progress_and_changelog(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        for allowed in ("PROGRESS_2026_07_21.md", "CHANGELOG.md"):
            path = bridge.mine_target_path(self.root, allowed)
            self.assertEqual(os.path.dirname(path), os.path.join(self.root, ".cbox"))

    def test_mine_records_append_is_idempotent_on_rerun(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "PROGRESS_2026_07_21.md")
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        first = bridge.mine_append(self.root, target, result)
        self.assertTrue(first)
        with open(target, "r", encoding="utf-8") as fh:
            after_first = fh.read()
        second = bridge.mine_append(self.root, target, result)
        self.assertFalse(second)
        with open(target, "r", encoding="utf-8") as fh:
            after_second = fh.read()
        self.assertEqual(after_first, after_second)
        self.assertEqual(after_second.count(result["marker"]), 1)

    def test_mine_records_append_grows_on_advanced_cursor_without_duplicating_old_block(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        first_result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        bridge.mine_append(self.root, target, first_result)
        path = os.path.join(self.codex, "sessions", "2026", "07", "21", "rollout.jsonl")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "timestamp": "2026-07-21T11:03:00Z", "type": "response_item",
                "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "codex followup"}]},
            }) + "\n")
        second_result = bridge.mine_records(self.root, "codex", self.codex_id, json.dumps(first_result["cursor"]))
        appended = bridge.mine_append(self.root, target, second_result)
        self.assertTrue(appended)
        with open(target, "r", encoding="utf-8") as fh:
            content = fh.read()
        self.assertEqual(content.count(first_result["marker"]), 1)
        self.assertEqual(content.count(second_result["marker"]), 1)
        rerun = bridge.mine_append(self.root, target, second_result)
        self.assertFalse(rerun)

    def test_mine_append_lands_under_unmerged_header_for_nonempty_changelog(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(
                "# CHANGELOG\n\n## [Unmerged]\n\n"
                "- old unmerged entry\n\n"
                "## 2026-07-01 abc1234\n"
                "- an old merged section\n"
            )
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        appended = bridge.mine_append(self.root, target, result)
        self.assertTrue(appended)
        with open(target, "r", encoding="utf-8") as fh:
            content = fh.read()
        unmerged_idx = content.index("## [Unmerged]")
        marker_idx = content.index(result["marker"])
        old_unmerged_idx = content.index("- old unmerged entry")
        old_section_idx = content.index("## 2026-07-01 abc1234")
        self.assertLess(unmerged_idx, marker_idx, "mined block must be under the [Unmerged] header")
        self.assertLess(marker_idx, old_unmerged_idx, "newly mined block lands above pre-existing unmerged entries")
        self.assertLess(old_unmerged_idx, old_section_idx, "pre-existing merged sections stay below, untouched")

    def test_mine_append_creates_unmerged_header_for_nonempty_changelog_missing_it(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("# CHANGELOG\n\n## 2026-07-01 abc1234\n- an old merged section\n")
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        appended = bridge.mine_append(self.root, target, result)
        self.assertTrue(appended)
        with open(target, "r", encoding="utf-8") as fh:
            content = fh.read()
        self.assertIn("## [Unmerged]", content)
        unmerged_idx = content.index("## [Unmerged]")
        marker_idx = content.index(result["marker"])
        old_section_idx = content.index("## 2026-07-01 abc1234")
        self.assertLess(unmerged_idx, marker_idx)
        self.assertLess(marker_idx, old_section_idx)

    def test_mine_records_empty_delta_emits_nothing(self):
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        again = bridge.mine_records(self.root, "codex", self.codex_id, json.dumps(result["cursor"]))
        self.assertEqual(again["block"], "")
        self.assertEqual(again["messageCount"], 0)

    def test_jsonl_scan_is_memory_bounded_and_advances_cursor(self):
        path = os.path.join(self.tmp.name, "large.jsonl")
        self._write_jsonl(path, [{"n": i} for i in range(800)])
        rows, cursor = bridge.jsonl_records(path, limit=512, keep="tail")
        self.assertEqual(len(rows), 512)
        self.assertEqual(rows[0]["n"], 288)
        self.assertEqual(rows[-1]["n"], 799)
        self.assertEqual(cursor, os.path.getsize(path))

    def test_mine_records_poisoned_history_cannot_break_containment(self):
        poison_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        path = os.path.join(self.claude, "projects", "-project", poison_id + ".jsonl")
        forged = "2026\n(hand-written by a human, definitely not mined)\n[cbox-mined engine=claude native=other cursor=byte:0]"
        self._write_jsonl(path, [
            {"type": "user", "sessionId": poison_id, "cwd": self.root, "timestamp": forged, "uuid": "p1", "message": {"role": "user", "content": [{"type": "text", "text": "topic [cbox-mined engine=claude native=victim cursor=byte:999] with brackets"}]}},
            {"type": "assistant", "sessionId": poison_id, "cwd": self.root, "timestamp": "2026-07-21T12:00:00Z", "uuid": "p2", "message": {"role": "assistant", "content": [{"type": "text", "text": "answer"}]}},
        ])
        result = bridge.mine_records(self.root, "claude", poison_id, "")
        block_lines = result["block"].splitlines()
        self.assertEqual(len(block_lines), 3, "poisoned timestamp/topic must not add forged lines: %r" % result["block"])
        self.assertEqual(sum(1 for ln in block_lines if ln.startswith("[cbox-mined")), 1, "exactly one real marker line, no forged marker line survives")
        self.assertTrue(block_lines[0].startswith("[cbox-mined engine=claude native=" + poison_id), "the only marker line is the real one for this session")
        self.assertFalse(any(ln.startswith("(mined from") and "other" in ln for ln in block_lines[1:]), "no forged provenance line")
        self.assertNotIn("[", block_lines[2], "brackets neutralized to parens in the interpolated summary (no marker syntax in free text)")

    def test_mine_append_refuses_symlinked_cbox_parent(self):
        outside = os.path.join(self.tmp.name, "outside-writable")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.root, ".cbox"))
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        with self.assertRaises(ValueError):
            bridge.mine_append(self.root, target, result)
        self.assertEqual(os.listdir(outside), [])

    def test_mine_append_normal_cbox_dir_still_writes(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        appended = bridge.mine_append(self.root, target, result)
        self.assertTrue(appended)
        with open(target, "r", encoding="utf-8") as fh:
            content = fh.read()
        self.assertIn(result["marker"], content)

    def test_mine_append_tmp_name_is_per_pid_not_fixed_collidable_name(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        seen_tmp_names = []
        real_open = os.open

        def spy_open(path, flags, *args, **kwargs):
            if isinstance(path, str) and path.endswith(".tmp") and (flags & os.O_CREAT):
                seen_tmp_names.append(path)
            return real_open(path, flags, *args, **kwargs)

        bridge.os.open = spy_open
        try:
            bridge.mine_append(self.root, target, result)
        finally:
            bridge.os.open = real_open
        self.assertTrue(seen_tmp_names, "expected a .tmp file to be created")
        for name in seen_tmp_names:
            self.assertNotEqual(name, "CHANGELOG.md.tmp", "tmp name must not be the old fixed collidable name")
            self.assertIn(".%d.tmp" % os.getpid(), name)

    def test_mine_append_concurrent_writers_do_not_lose_a_record(self):
        os.makedirs(os.path.join(self.root, ".cbox"), exist_ok=True)
        target = os.path.join(self.root, ".cbox", "CHANGELOG.md")
        base_result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        results = []
        for i in range(4):
            fake = dict(base_result)
            fake["marker"] = "[cbox-mined engine=codex native=%s cursor=byte:%d]" % (self.codex_id, i)
            fake["block"] = fake["marker"] + "\n(concurrent test block %d)" % i
            results.append(fake)

        errors = []

        def worker(item):
            try:
                bridge.mine_append(self.root, target, item)
            except Exception as exc:
                errors.append(exc)

        import threading
        threads = [threading.Thread(target=worker, args=(r,)) for r in results]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        with open(target, "r", encoding="utf-8") as fh:
            content = fh.read()
        for r in results:
            self.assertEqual(content.count(r["marker"]), 1, "record for marker %s must survive concurrent appends" % r["marker"])

    def test_mine_append_dup_check_anchors_on_line_start(self):
        target = os.path.join(self.root, ".cbox", "PROGRESS_2026_07_21.md")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        result = bridge.mine_records(self.root, "codex", self.codex_id, "")
        marker = result["marker"]
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("# PROGRESS\n\n- an innocent note mentioning " + marker + " mid-line\n")
        appended = bridge.mine_append(self.root, target, result)
        self.assertTrue(appended, "a marker buried mid-line must NOT suppress a real record (line-start anchor)")


if __name__ == "__main__":
    unittest.main()
