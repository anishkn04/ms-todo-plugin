#!/usr/bin/env python3
"""Tests for the omarchy-mstodo CLI: grammar parsing and Graph payload mapping.

Run:  python3 tests/test_tasks.py
"""

import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import time
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "omarchy-mstodo"

# Extensionless scripts need an explicit source loader.
loader = importlib.machinery.SourceFileLoader("omarchy_tasks_cli", str(BIN))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)

TODAY = date(2026, 8, 22)          # a Saturday
MONDAY = date(2026, 8, 24)


def iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M")


class QuickAddParsing(unittest.TestCase):
    def test_full_grammar(self):
        p = cli.parse_quick_add("Pay electricity @tomorrow 18:30 repeat daily !high", TODAY)
        self.assertEqual(p["title"], "Pay electricity")
        self.assertEqual(p["due_date"], TODAY + timedelta(days=1))
        self.assertEqual(p["time"], (18, 30))
        self.assertEqual(p["recur"], "daily")
        self.assertEqual(p["priority"], "high")

    def test_plain_title(self):
        p = cli.parse_quick_add("just remember the milk", TODAY)
        self.assertEqual(p["title"], "just remember the milk")
        self.assertIsNone(p["due_date"])
        self.assertIsNone(p["time"])
        self.assertIsNone(p["recur"])
        self.assertIsNone(p["priority"])

    def test_weekday_token_resolves_forward(self):
        p = cli.parse_quick_add("standup @mon", TODAY)
        self.assertEqual(p["due_date"], MONDAY)

    def test_weekday_today_counts_as_today(self):
        p = cli.parse_quick_add("gym @sat", TODAY)
        self.assertEqual(p["due_date"], TODAY)

    def test_dd_rolls_to_next_month_when_past(self):
        p = cli.parse_quick_add("rent @1", TODAY)
        self.assertEqual(p["due_date"], date(2026, 9, 1))

    def test_dd_stays_this_month_when_future(self):
        p = cli.parse_quick_add("review @31", TODAY)
        self.assertEqual(p["due_date"], date(2026, 8, 31))

    def test_ddmm_explicit(self):
        p = cli.parse_quick_add("taxes @03.10", TODAY)
        self.assertEqual(p["due_date"], date(2026, 10, 3))

    def test_invalid_dates_stay_in_title(self):
        p = cli.parse_quick_add("call about @99 thing", TODAY)
        self.assertEqual(p["title"], "call about @99 thing")
        self.assertIsNone(p["due_date"])

    def test_time_only_sets_no_date(self):
        p = cli.parse_quick_add("stretch 07:15", TODAY)
        self.assertIsNone(p["due_date"])
        self.assertEqual(p["time"], (7, 15))
        self.assertEqual(p["title"], "stretch")

    def test_at_prefixed_time_token(self):
        p = cli.parse_quick_add("study @7:00 repeat daily", TODAY)
        self.assertEqual(p["title"], "study")
        self.assertEqual(p["time"], (7, 0))
        self.assertEqual(p["recur"], "daily")

    def test_every_n_days(self):
        p = cli.parse_quick_add("water plants repeat every 3 days", TODAY)
        self.assertEqual(p["recur"], "every-day")
        self.assertEqual(p["every_n"], 3)
        self.assertEqual(cli.recur_label(p), "every 3 days")

    def test_every_one_week_singular_label(self):
        p = cli.parse_quick_add("clean desk repeat every 1 week", TODAY)
        self.assertEqual(cli.recur_label(p), "every 1 week")

    def test_after_completion_maps_to_regenerating(self):
        p = cli.parse_quick_add("change sheets repeat after-completion", TODAY)
        self.assertEqual(p["recur"], "after")
        body = cli.build_task_payload(p)
        self.assertEqual(body["recurrence"]["pattern"]["type"], "regenerating")
        self.assertEqual(body["recurrence"]["range"]["startDate"], TODAY.isoformat())

    def test_unknown_repeat_keyword_stays_literal(self):
        p = cli.parse_quick_add("repeat sometimes sometimes", TODAY)
        # "repeat sometimes" is not a known pair; both words stay in the title.
        self.assertEqual(p["title"], "repeat sometimes sometimes")
        self.assertIsNone(p["recur"])

    def test_priority_variants(self):
        for token, expected in (("!low", "low"), ("!normal", "normal"), ("!high", "high")):
            p = cli.parse_quick_add(f"task {token}", TODAY)
            self.assertEqual(p["priority"], expected)
            self.assertEqual(p["title"], "task")

    def test_unknown_bang_stays_in_title(self):
        p = cli.parse_quick_add("fix !urgent", TODAY)
        self.assertEqual(p["title"], "fix !urgent")
        self.assertIsNone(p["priority"])


class UntilSuffix(unittest.TestCase):
    def test_until_after_keyword_parses_date(self):
        p = cli.parse_quick_add("study @today 07:15 repeat daily until 26.8", TODAY)
        self.assertEqual(p["title"], "study")
        self.assertEqual(p["recur"], "daily")
        self.assertEqual(p["recur_until"], date(2026, 8, 26))

    def test_until_after_every_n(self):
        p = cli.parse_quick_add("sprint repeat every 2 days until 25.9", TODAY)
        self.assertEqual(p["recur"], "every-day")
        self.assertEqual(p["every_n"], 2)
        self.assertEqual(p["recur_until"], date(2026, 9, 25))
        self.assertIn("until", cli.recur_label(p))

    def test_unparseable_until_stays_in_title(self):
        p = cli.parse_quick_add("wait repeat daily until someday", TODAY)
        self.assertIsNone(p["recur_until"])
        self.assertIn("until", p["title"])

    def test_until_without_repeat_stays_in_title(self):
        p = cli.parse_quick_add("read until bedtime", TODAY)
        self.assertIsNone(p["recur"])
        self.assertIsNone(p["recur_until"])
        self.assertEqual(p["title"], "read until bedtime")

    def test_payload_end_date_range(self):
        p = cli.parse_quick_add("study @28.8 07:15 repeat daily until 9.9", TODAY)
        body = cli.build_task_payload(p)
        rng = body["recurrence"]["range"]
        self.assertEqual(rng["type"], "endDate")
        self.assertEqual(rng["startDate"], date(2026, 8, 28).isoformat())
        self.assertEqual(rng["endDate"], date(2026, 9, 9).isoformat())
        self.assertEqual(body["recurrence"]["pattern"]["type"], "daily")

    def test_without_until_range_stays_noend(self):
        body = cli.build_task_payload(cli.parse_quick_add("t repeat daily", TODAY))
        self.assertEqual(body["recurrence"]["range"]["type"], "noEnd")

    def test_label_appends_until(self):
        p = cli.parse_quick_add("x repeat weekdays until 26.8", TODAY)
        self.assertEqual(cli.recur_label(p), f"weekdays until {date(2026, 8, 26).strftime('%d %b')}")


class PayloadMapping(unittest.TestCase):
    def test_due_without_time_is_end_of_day_and_no_reminder(self):
        p = cli.parse_quick_add("pay rent @tomorrow", TODAY)
        body = cli.build_task_payload(p)
        expected = cli.local_epoch(TODAY + timedelta(days=1), (23, 59))
        self.assertEqual(
            body["dueDateTime"],
            {"dateTime": datetime.fromtimestamp(expected, tz=timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%S.000"), "timeZone": "UTC"},
        )
        self.assertNotIn("reminderDateTime", body)
        self.assertNotIn("isReminderOn", body)

    def test_time_sets_reminder(self):
        p = cli.parse_quick_add("demo @mon 09:30", TODAY)
        body = cli.build_task_payload(p)
        expected = cli.local_epoch(MONDAY, (9, 30))
        self.assertIn("reminderDateTime", body)
        self.assertTrue(body["isReminderOn"])
        self.assertEqual(
            body["reminderDateTime"]["dateTime"],
            datetime.fromtimestamp(expected, tz=timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%S.000"),
        )

    def test_recurrence_patterns(self):
        cases = {
            "daily": ("daily", 1),
            "weekly": ("weekly", 1),
            "monthly": ("absoluteMonthly", 1),
            "yearly": ("absoluteYearly", 1),
        }
        for keyword, (ptype, interval) in cases.items():
            p = cli.parse_quick_add(f"t repeat {keyword}", TODAY)
            body = cli.build_task_payload(p)
            self.assertEqual(body["recurrence"]["pattern"]["type"], ptype)
            self.assertEqual(body["recurrence"]["pattern"]["interval"], interval)
            self.assertEqual(body["recurrence"]["range"]["type"], "noEnd")

    def test_recurrence_without_date_synthesizes_due(self):
        # Graph requires dueDateTime on any recurring task; the CLI anchors
        # it today/tomorrow and uses it as the range startDate.
        body = cli.build_task_payload(cli.parse_quick_add("study @7:00 repeat daily", TODAY))
        self.assertIn("dueDateTime", body)
        self.assertTrue(body.get("isReminderOn"))
        self.assertIn("startDate", body["recurrence"]["range"])
        start = date.fromisoformat(body["recurrence"]["range"]["startDate"])
        self.assertIn((start - date.today()).days, (0, 1))

    def test_recurring_dateless_task_carries_range_start(self):
        for line in ("bins repeat weekly",
                     "x repeat after completion",
                     "y repeat every 2 days"):
            body = cli.build_task_payload(cli.parse_quick_add(line, TODAY))
            self.assertIn("dueDateTime", body)
            self.assertIn("startDate", body["recurrence"]["range"])

    def test_weekdays_carries_days_of_week(self):
        p = cli.parse_quick_add("standup repeat weekdays", TODAY)
        body = cli.build_task_payload(p)
        pattern = body["recurrence"]["pattern"]
        self.assertEqual(pattern["type"], "weekly")
        self.assertEqual(pattern["daysOfWeek"],
                         ["monday", "tuesday", "wednesday", "thursday", "friday"])

    def test_every_n_maps_units(self):
        p3d = cli.build_task_payload(cli.parse_quick_add("x repeat every 3 days", TODAY))
        self.assertEqual((p3d["recurrence"]["pattern"]["type"],
                          p3d["recurrence"]["pattern"]["interval"]), ("daily", 3))
        p2w = cli.build_task_payload(cli.parse_quick_add("x repeat every 2 weeks", TODAY))
        self.assertEqual((p2w["recurrence"]["pattern"]["type"],
                          p2w["recurrence"]["pattern"]["interval"]), ("weekly", 2))
        p6m = cli.build_task_payload(cli.parse_quick_add("x repeat every 6 months", TODAY))
        self.assertEqual((p6m["recurrence"]["pattern"]["type"],
                          p6m["recurrence"]["pattern"]["interval"]),
                         ("absoluteMonthly", 6))

    def test_importance(self):
        body = cli.build_task_payload(cli.parse_quick_add("urgent thing !high", TODAY))
        self.assertEqual(body["importance"], "high")

    def test_plain_title_payload_minimal(self):
        body = cli.build_task_payload(cli.parse_quick_add("only a title", TODAY))
        self.assertEqual(body, {"title": "only a title"})

    def test_recur_labels(self):
        self.assertEqual(cli.recur_label(cli.parse_quick_add("x repeat weekdays", TODAY)), "weekdays")
        self.assertEqual(cli.recur_label(cli.parse_quick_add("x repeat yearly", TODAY)), "yearly")
        self.assertEqual(cli.recur_label(cli.parse_quick_add("x repeat after", TODAY)),
                         "after completion")


class TokenLogic(unittest.TestCase):
    def setUp(self):
        self.old_state = cli.STATE_DIR
        cli.STATE_DIR = "/tmp/opencode/tasks-test-state"
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")
        os.makedirs(cli.STATE_DIR, exist_ok=True)

    def tearDown(self):
        import shutil
        shutil.rmtree(cli.STATE_DIR, ignore_errors=True)

    def test_cache_roundtrip_atomic(self):
        cli.write_cache(syncedAt=123.0, tasks=[{"id": "a"}])
        cli.write_cache(listName="Tasks")
        cache = cli.load_json(cli.CACHE_PATH, {})
        self.assertEqual(cache["syncedAt"], 123.0)
        self.assertEqual(cache["listName"], "Tasks")
        self.assertTrue(os.path.exists(cli.AUTH_PATH) is False)

    def test_access_token_requires_refresh_field(self):
        with self.assertRaises(cli.AuthRequired):
            cli.access_token({})

    def test_client_id_precedence(self):
        self.assertEqual(cli.client_id({"client_id": "from-file"}), "from-file")
        old = os.environ.get("OMARCHY_MSTODO_CLIENT_ID")
        os.environ["OMARCHY_MSTODO_CLIENT_ID"] = "from-env"
        try:
            self.assertEqual(cli.client_id({"client_id": "from-file"}), "from-env")
            self.assertEqual(cli.client_id({}), "from-env")
        finally:
            if old is None:
                del os.environ["OMARCHY_MSTODO_CLIENT_ID"]
            else:
                os.environ["OMARCHY_MSTODO_CLIENT_ID"] = old

    def test_map_task_shape(self):
        raw = {
            "id": "abc",
            "title": "Hello",
            "status": "completed",
            "importance": "high",
            "isReminderOn": True,
            "dueDateTime": {"dateTime": "2026-08-23T13:29:00.000", "timeZone": "UTC"},
            "reminderDateTime": {"dateTime": "2026-08-23T12:00:00.000", "timeZone": "UTC"},
            "completedDateTime": {"dateTime": "2026-08-22T10:00:00.000", "timeZone": "UTC"},
            "lastModifiedDateTime": "2026-08-22T09:00:00.0000000Z",
            "recurrence": {"pattern": {"type": "daily", "interval": 2,
                                       "daysOfWeek": ["monday", "friday"]}},
        }
        task = cli.map_task(raw)
        self.assertEqual(task["id"], "abc")
        expected_remind = datetime(2026, 8, 23, 12, 0,
                                   tzinfo=timezone.utc).timestamp()
        self.assertEqual(task["remind"], expected_remind)
        self.assertGreater(task["due"], task["remind"])


class FakeResponse:
    """Minimal stand-in for an urlopen() context result."""

    def __init__(self, payload: bytes):
        self.payload = payload

    def read(self, n=-1) -> bytes:
        if n < 0:
            out, self.payload = self.payload, b""
            return out
        out, self.payload = self.payload[:n], self.payload[n:]
        return out


class BodyLimits(unittest.TestCase):
    """Responses are read under a hard cap, never unbounded."""

    def test_read_body_limited_within(self):
        self.assertEqual(cli.read_body_limited(FakeResponse(b'{"a": 1}'), 100), '{"a": 1}')

    def test_read_body_limited_exact(self):
        body = b"x" * 100
        self.assertEqual(cli.read_body_limited(FakeResponse(body), 100), body.decode())

    def test_read_body_limited_rejects_oversize(self):
        with self.assertRaises(cli.ApiError):
            cli.read_body_limited(FakeResponse(b"x" * 101), 100)

    def test_error_bytes_cap_constant(self):
        self.assertEqual(cli.MAX_ERROR_BYTES, 64 * 1024)
        self.assertEqual(cli.MAX_RESPONSE_BYTES, 4 * 1024 * 1024)


class DeviceFlow(unittest.TestCase):
    """login start / login poll as separate machine steps, no network."""

    def setUp(self):
        self.old_state = cli.STATE_DIR
        cli.STATE_DIR = "/tmp/opencode/tasks-test-state-login"
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")
        os.makedirs(cli.STATE_DIR, exist_ok=True)
        self._sync_orig = cli.cmd_sync
        cli.cmd_sync = lambda args: 0
        # _poll_once mutates the module-global tenant authority; reset it.
        cli.set_authority("common")

    def tearDown(self):
        import shutil
        shutil.rmtree(cli.STATE_DIR, ignore_errors=True)
        cli.STATE_DIR = self.old_state
        cli.cmd_sync = self._sync_orig
        cli.set_authority("common")
        if hasattr(self, "_http_orig"):
            cli.http_form = self._http_orig

    def _patch_http(self, script):
        """script: list of return values or exceptions for successive calls."""
        calls = []

        def fake(url, fields):
            calls.append((url, dict(fields)))
            result = script.pop(0)
            if isinstance(result, Exception):
                raise result
            return result

        self._http_orig = cli.http_form
        cli.http_form = fake
        return calls

    def _challenge(self):
        return {
            "device_code": "DEV123",
            "user_code": "ABCD-1234",
            "verification_uri": "https://microsoft.com/link",
            "interval": 5,
            "expires_in": 900,
        }

    def test_start_persists_and_prints_challenge(self):
        import io, contextlib
        calls = self._patch_http([self._challenge()])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.cmd_login_start(argparse.Namespace(step="start"))
        self.assertEqual(code, 0)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["status"], "started")
        self.assertEqual(payload["user_code"], "ABCD-1234")
        pending = json.load(open(cli.LOGIN_PATH))
        self.assertEqual(pending["device_code"], "DEV123")
        self.assertEqual(pending["authority"], "common")
        self.assertEqual(calls[0][0], cli.AUTH_BASE + "/devicecode")

    def test_poll_none_without_pending(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(json.loads(out.getvalue())["status"], "none")

    def test_poll_success_saves_tokens_and_clears_pending(self):
        import io, contextlib
        cli.save_json_atomic(cli.LOGIN_PATH, {
            "device_code": "DEV123", "client_id": "cid", "authority": "consumers",
            "interval": 5, "expires_at": time.time() + 600,
        })
        self._patch_http([{"access_token": "at", "refresh_token": "rt", "expires_in": 3600}])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["status"], "success")
        tokens = json.load(open(cli.AUTH_PATH))
        self.assertEqual(tokens["refresh_token"], "rt")
        self.assertEqual(tokens["client_id"], "cid")
        self.assertEqual(tokens["authority"], "consumers")
        self.assertFalse(os.path.exists(cli.LOGIN_PATH))

    def test_poll_pending_keeps_challenge(self):
        import io, contextlib
        cli.save_json_atomic(cli.LOGIN_PATH, {
            "device_code": "DEV123", "client_id": "cid", "authority": "common",
            "interval": 5, "expires_at": time.time() + 600,
        })
        self._patch_http([cli.ApiError("authorization_pending: keep waiting")])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(json.loads(out.getvalue())["status"], "pending")
        self.assertTrue(os.path.exists(cli.LOGIN_PATH))

    def test_poll_slow_down_keeps_challenge(self):
        import io, contextlib
        cli.save_json_atomic(cli.LOGIN_PATH, {
            "device_code": "DEV123", "client_id": "cid", "authority": "common",
            "interval": 5, "expires_at": time.time() + 600,
        })
        self._patch_http([cli.ApiError("slow_down: too fast")])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(json.loads(out.getvalue())["status"], "slow_down")
        self.assertTrue(os.path.exists(cli.LOGIN_PATH))

    def test_poll_declined_clears_challenge(self):
        import io, contextlib
        cli.save_json_atomic(cli.LOGIN_PATH, {
            "device_code": "DEV123", "client_id": "cid", "authority": "common",
            "interval": 5, "expires_at": time.time() + 600,
        })
        self._patch_http([cli.ApiError("authorization_declined: user said no")])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(json.loads(out.getvalue())["status"], "declined")
        self.assertFalse(os.path.exists(cli.LOGIN_PATH))

    def test_poll_expired_by_clock(self):
        import io, contextlib
        cli.save_json_atomic(cli.LOGIN_PATH, {
            "device_code": "DEV123", "client_id": "cid", "authority": "common",
            "interval": 5, "expires_at": time.time() - 10,
        })
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.cmd_login_poll(argparse.Namespace(step="poll"))
        self.assertEqual(json.loads(out.getvalue())["status"], "expired")
        self.assertFalse(os.path.exists(cli.LOGIN_PATH))

    def test_interactive_login_loops_until_success(self):
        import io, contextlib
        from unittest import mock
        script = [
            self._challenge(),
            cli.ApiError("authorization_pending: x"),
            cli.ApiError("slow_down: x"),
            {"access_token": "at", "refresh_token": "rt", "expires_in": 3600},
        ]
        calls = self._patch_http(script)
        with mock.patch("time.sleep"):
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = cli.cmd_login(argparse.Namespace())
        self.assertEqual(code, 0)
        statuses = [c[0].endswith("/token") for c in calls]
        self.assertEqual(statuses.count(True), 3)   # two failures + one success
        tokens = json.load(open(cli.AUTH_PATH))
        self.assertEqual(tokens["access_token"], "at")


class Listing(unittest.TestCase):
    def make(self, **kw):
        base = {"id": "id1234567=", "title": "T", "due": 0, "remind": 0,
                "isReminderOn": False, "importance": "normal",
                "completed": False, "recurType": "", "recurInterval": 1,
                "recurDays": ""}
        base.update(kw)
        return base

    def test_eff_epoch_prefers_reminder_same_day(self):
        due = time.mktime(time.strptime("2026-08-22", "%Y-%m-%d"))
        remind = due + 3600
        t = self.make(due=due, remind=remind, isReminderOn=True)
        self.assertEqual(cli.eff_epoch(t), remind)
        # different day -> keep due
        t["remind"] = remind + 86400 * 3
        self.assertEqual(cli.eff_epoch(t), due)
        # reminder off -> keep due
        t2 = self.make(due=due, remind=remind, isReminderOn=False)
        self.assertEqual(cli.eff_epoch(t2), due)

    def test_short_id_strips_padding(self):
        self.assertEqual(cli.short_id("ABCdefGHIJKL="), "fGHIJKL")

    def test_resolve_task_id_suffix(self):
        cache = {"tasks": [{"id": "AAAAxxxx111="}, {"id": "BBBByyyy222="}]}
        self.assertEqual(cli.resolve_task_id("AAAAxxxx111=", cache), "AAAAxxxx111=")
        self.assertEqual(cli.resolve_task_id("y222", cache), "BBBByyyy222=")
        with self.assertRaises(cli.SystemExitWith):
            cli.resolve_task_id("zzzz", cache)

    def test_resolve_ambiguous_suffix(self):
        cache = {"tasks": [{"id": "QQQaaa111="}, {"id": "WWWaaa111="}]}
        with self.assertRaises(cli.SystemExitWith):
            cli.resolve_task_id("a111", cache)

    def test_select_groups_buckets_by_local_day(self):
        now = time.time()
        lt = time.localtime(now)
        midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
        tasks = [
            self.make(id="over1=", title="past", due=midnight - 100),
            self.make(id="tod1=", title="now", due=midnight + 3600),
            self.make(id="lat1=", title="future", due=midnight + 86400 * 5),
            self.make(id="nod1=", title="undated"),
            self.make(id="done1=", title="finished", completed=True),
        ]
        groups = dict(cli.select_groups(tasks, include_done=True))
        self.assertEqual([t["title"] for t in groups["Overdue"]], ["past"])
        self.assertEqual([t["title"] for t in groups["Today"]], ["now"])
        self.assertEqual([t["title"] for t in groups["Later"]], ["future", "undated"])
        self.assertEqual([t["title"] for t in groups["Done"]], ["finished"])

    def test_format_line_marks_high_and_badge(self):
        line = cli.format_task_line(self.make(
            id="suffix123=", title="Exam", importance="high",
            recurType="daily"))
        self.assertTrue(line.startswith("! "))
        self.assertIn("Exam", line)
        self.assertIn("\u21bb daily", line)
        self.assertIn("ffix123", line)

    def test_map_task_tolerates_missing_fields(self):
        task = cli.map_task({"id": "x"})
        self.assertEqual(task["due"], 0)
        self.assertFalse(task["completed"])
        self.assertEqual(task["recurType"], "")


if __name__ == "__main__":
    print(json.dumps({"suite": "omarchy-mstodo", "bin": str(BIN), "exists": BIN.exists()}))
    unittest.main(verbosity=2)
