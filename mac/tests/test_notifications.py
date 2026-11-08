"""Notification/control unit tests. The Windows PTY witness is tests/notifications.ps1."""
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if os.name == "nt":
    # These tests never open a Unix socket or acquire a Unix file lock.
    sys.modules.setdefault("fcntl", types.SimpleNamespace())
import lane
import lanehost
import lanes_common as lc


class Notifications(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        with patch.object(lc, "sock_path", return_value="unused"):
            self.host = lanehost.Host(dict(name="parent", dir=str(self.path), **{
                "argv-json": "[]", "meta-json": json.dumps({"inbox": str(self.path / "inbox.jsonl")})}))
        self.event = dict(lane="child", state="finished", why="exit-0", label="done\x1b\nhello")
        (self.path / "inbox.jsonl").write_text(json.dumps(self.event) + "\n", encoding="utf-8")

    def test_busy_question_permission_are_not_answered(self):
        with patch.object(self.host, "write_paste") as send:
            for state, why in (("running", "input"), ("needs-input", "permission"), ("needs-input", "question"), ("needs-input", "prompt")):
                self.host.state, self.host.why = state, why
                self.host.poll_inbox()
            send.assert_not_called()
            self.assertEqual(self.host.inbox_read, 0)

    def test_complete_is_submitted_once_with_controls_removed(self):
        self.host.state, self.host.why = "needs-input", "turn-complete"
        with patch.object(self.host, "write_paste") as send:
            self.host.poll_inbox()
            self.host.poll_inbox()
            send.assert_called_once()
            msg = send.call_args.args[0]
            self.assertIn(b"child finished (exit-0)", msg)
            self.assertNotIn(b"\x1b", msg)
            self.assertTrue(msg.endswith(b"\r"))

    def test_failed_submission_is_not_consumed(self):
        self.host.state, self.host.why = "needs-input", "turn-complete"
        with patch.object(self.host, "write_paste", side_effect=OSError("closed")):
            with self.assertRaises(OSError):
                self.host.poll_inbox()
        self.assertEqual(self.host.inbox_read, 0)

    def test_partial_row_waits(self):
        self.host.state, self.host.why = "needs-input", "turn-complete"
        (self.path / "inbox.jsonl").write_text('{"lane":', encoding="utf-8")
        with patch.object(self.host, "write_paste") as send:
            self.host.poll_inbox()
            send.assert_not_called()

    def test_restart_recovers_delivery_cursor(self):
        (self.path / "inbox.jsonl.cursor").write_text("123", encoding="utf-8")
        with patch.object(lc, "sock_path", return_value="unused"):
            host = lanehost.Host(dict(name="parent", dir=str(self.path), **{
                "argv-json": "[]", "meta-json": json.dumps({"inbox": str(self.path / "inbox.jsonl")})}))
        self.assertEqual(host.inbox_read, 123)

    def test_send_parser_and_consumers(self):
        for args, text in ((["p", "Run", "--example", "value"], ["Run", "--example", "value"]),
                           (["p", "--", "--force"], ["--force"])):
            self.assertEqual(lane.parse(args, ["name"], {"force"}, message=True)["_rest"], text)
        with patch.dict(os.environ, {"LANES_HEAD": "head", "LANES_LANE": "sibling"}):
            self.assertEqual(lane.current_consumer(), "sibling")

    def test_stale_cursor_prompt_does_not_answer_dialog(self):
        self.host.kind = "cursor"
        for text in ("Old answer\nAdd a follow-up\n" + "dialog\n" * 8 + "Do you want to run this command?\nEnter to confirm\n",
                     "Add a follow-up\nAllow this command\n", "Add a follow-up  ctrl+c to stop\n"):
            self.host.tail = bytearray(text.encode())
            self.host.state, self.host.why = "needs-input", "prompt"
            with patch.object(self.host, "write_paste") as send:
                self.host.poll_inbox()
                send.assert_not_called()

    def test_raw_enter_clears_old_completion(self):
        self.host.state, self.host.why = "needs-input", "turn-complete"
        self.host.idle_at_prompt = True
        self.host.hook_turn_done = True
        with patch.object(self.host, "audit_input"), patch.object(lanehost.os, "write"):
            self.host.write_input(b"\r")
        self.assertFalse(self.host.idle_at_prompt)
        self.assertFalse(self.host.hook_turn_done)
        self.host.pending_input = False  # the subsequent output-loop transition
        self.host.last_output = time.monotonic() - 10
        self.host._tick()
        with patch.object(self.host, "write_paste") as send:
            self.host.poll_inbox()
            send.assert_not_called()

    def test_raw_draft_defers_even_at_idle_prompt(self):
        self.host.state, self.host.why = "needs-input", "turn-complete"
        with patch.object(self.host, "audit_input"), patch.object(lanehost.os, "write"):
            self.host.write_input(b"unfinished draft")
        self.host.pending_input = False
        with patch.object(self.host, "write_paste") as send:
            self.host.poll_inbox()
            send.assert_not_called()

    def test_first_consumer_read_retains_completed_event(self):
        head = self.path / "heads" / "head"
        head.mkdir(parents=True)
        (head / "events.jsonl").write_text(json.dumps(dict(self.event, ts=lc.now_iso(), head="head")) + "\n", encoding="utf-8")
        with patch.dict(os.environ, {"LANES_HOME": str(self.path), "LANES_HEADS_ROOT": str(self.path / "heads"),
                                    "LANES_HEAD": "head", "LANES_LANE": "helper"}), patch.object(lane, "get_lanes", return_value=[]):
            rows = lane.get_events(drain=True, as_object=True)
        self.assertEqual(len(rows), 1)


if __name__ == "__main__":
    unittest.main()
