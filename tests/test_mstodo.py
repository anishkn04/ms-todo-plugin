#!/usr/bin/env python3
"""Tests for the omarchy-mstodo CLI: grammar parsing and Graph payload mapping.

Run:  python3 tests/test_mstodo.py
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
NOW = datetime(2026, 8, 22, 12, 0)  # noon of that Saturday, frozen
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
        body = cli.build_task_payload(p, NOW)
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
        body = cli.build_task_payload(p, NOW)
        rng = body["recurrence"]["range"]
        self.assertEqual(rng["type"], "endDate")
        self.assertEqual(rng["startDate"], date(2026, 8, 28).isoformat())
        self.assertEqual(rng["endDate"], date(2026, 9, 9).isoformat())
        self.assertEqual(body["recurrence"]["pattern"]["type"], "daily")

    def test_without_until_range_stays_noend(self):
        body = cli.build_task_payload(cli.parse_quick_add("t repeat daily", TODAY), NOW)
        self.assertEqual(body["recurrence"]["range"]["type"], "noEnd")

    def test_label_appends_until(self):
        p = cli.parse_quick_add("x repeat weekdays until 26.8", TODAY)
        self.assertEqual(cli.recur_label(p), f"weekdays until {date(2026, 8, 26).strftime('%d %b')}")


class PayloadMapping(unittest.TestCase):
    def test_due_without_time_is_end_of_day_and_no_reminder(self):
        p = cli.parse_quick_add("pay rent @tomorrow", TODAY)
        body = cli.build_task_payload(p, NOW)
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
        body = cli.build_task_payload(p, NOW)
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
            body = cli.build_task_payload(p, NOW)
            self.assertEqual(body["recurrence"]["pattern"]["type"], ptype)
            self.assertEqual(body["recurrence"]["pattern"]["interval"], interval)
            self.assertEqual(body["recurrence"]["range"]["type"], "noEnd")

    def test_recurrence_without_date_synthesizes_due(self):
        # Graph requires dueDateTime on any recurring task; the CLI anchors
        # it today/tomorrow and uses it as the range startDate.
        body = cli.build_task_payload(cli.parse_quick_add("study @7:00 repeat daily", TODAY), NOW)
        self.assertIn("dueDateTime", body)
        self.assertTrue(body.get("isReminderOn"))
        self.assertIn("startDate", body["recurrence"]["range"])
        start = date.fromisoformat(body["recurrence"]["range"]["startDate"])
        self.assertIn((start - TODAY).days, (0, 1))

    def test_recurring_dateless_task_carries_range_start(self):
        for line in ("bins repeat weekly",
                     "x repeat after completion",
                     "y repeat every 2 days"):
            body = cli.build_task_payload(cli.parse_quick_add(line, TODAY), NOW)
            self.assertIn("dueDateTime", body)
            self.assertIn("startDate", body["recurrence"]["range"])

    def test_weekdays_carries_days_of_week(self):
        p = cli.parse_quick_add("standup repeat weekdays", TODAY)
        body = cli.build_task_payload(p, NOW)
        pattern = body["recurrence"]["pattern"]
        self.assertEqual(pattern["type"], "weekly")
        self.assertEqual(pattern["daysOfWeek"],
                         ["monday", "tuesday", "wednesday", "thursday", "friday"])

    def test_every_n_maps_units(self):
        p3d = cli.build_task_payload(cli.parse_quick_add("x repeat every 3 days", TODAY), NOW)
        self.assertEqual((p3d["recurrence"]["pattern"]["type"],
                          p3d["recurrence"]["pattern"]["interval"]), ("daily", 3))
        p2w = cli.build_task_payload(cli.parse_quick_add("x repeat every 2 weeks", TODAY), NOW)
        self.assertEqual((p2w["recurrence"]["pattern"]["type"],
                          p2w["recurrence"]["pattern"]["interval"]), ("weekly", 2))
        p6m = cli.build_task_payload(cli.parse_quick_add("x repeat every 6 months", TODAY), NOW)
        self.assertEqual((p6m["recurrence"]["pattern"]["type"],
                          p6m["recurrence"]["pattern"]["interval"]),
                         ("absoluteMonthly", 6))

    def test_importance(self):
        body = cli.build_task_payload(cli.parse_quick_add("urgent thing !high", TODAY), NOW)
        self.assertEqual(body["importance"], "high")

    def test_plain_title_payload_minimal(self):
        body = cli.build_task_payload(cli.parse_quick_add("only a title", TODAY), NOW)
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


class AuthRefreshMapping(unittest.TestCase):
    """A refused token refresh is a sign-in state, not a generic API error."""

    def setUp(self):
        cli.set_authority("common")
        self._orig_request = cli.oauth_token_request
        self._orig_save = cli.save_json_atomic

    def tearDown(self):
        cli.oauth_token_request = self._orig_request
        cli.save_json_atomic = self._orig_save

    def _expired_tokens(self):
        return {"refresh_token": "rt", "access_token": "at", "expires_at": 0}

    def test_invalid_grant_maps_to_auth_required(self):
        for err in ("invalid_grant", "interaction_required",
                    "consent_required", "unauthorized_client"):
            with self.subTest(err=err):
                cli.oauth_token_request = lambda fields, e=err: (
                    (_ for _ in ()).throw(cli.ApiError(f"{e}: token expired")))
                with self.assertRaises(cli.AuthRequired):
                    cli.access_token(self._expired_tokens())

    def test_transient_api_error_stays_api_error(self):
        cli.oauth_token_request = lambda fields: (
            (_ for _ in ()).throw(cli.ApiError("temporarily_unavailable")))
        with self.assertRaises(cli.ApiError) as ctx:
            cli.access_token(self._expired_tokens())
        self.assertNotIsInstance(ctx.exception, cli.AuthRequired)

    def test_successful_refresh_saves_and_returns(self):
        saved = {}
        cli.save_json_atomic = lambda path, data: saved.update(path=path)
        cli.oauth_token_request = lambda fields: {
            "access_token": "fresh", "refresh_token": "rt2", "expires_in": 3600}
        token = cli.access_token(self._expired_tokens())
        self.assertEqual(token, "fresh")
        self.assertIn("auth.json", str(saved.get("path")))


class TaskPagination(unittest.TestCase):
    """fetch_all_tasks walks @odata.nextLink but never off Graph v1.0."""

    def setUp(self):
        self.calls = []
        self._orig_graph = cli.graph_request

    def tearDown(self):
        cli.graph_request = self._orig_graph

    def _serve(self, pages):
        """pages: dict mapping the request path (with query) to a payload."""
        def fake(method, path, body=None, params=None):
            self.calls.append(path)
            if path in pages:
                page = pages[path]
                if isinstance(page, Exception):
                    raise page
                return page
            raise AssertionError(f"unexpected request {path}")

        cli.graph_request = fake

    def test_follows_next_link(self):
        base = "/me/todo/lists/L1/tasks?$top=250"
        second = "/me/todo/lists/L1/tasks?$top=250&$skiptoken=abc"
        self._serve({
            base: {"value": [{"id": "a"}],
                   "@odata.nextLink": f"https://graph.microsoft.com/v1.0{second}"},
            second: {"value": [{"id": "b"}]},
        })
        tasks = cli.fetch_all_tasks("L1")
        self.assertEqual([t["id"] for t in tasks], ["a", "b"])
        self.assertEqual(len(self.calls), 2)

    def test_rejects_offsite_next_link(self):
        base = "/me/todo/lists/L1/tasks?$top=250"
        self._serve({
            base: {"value": [{"id": "a"}],
                   "@odata.nextLink": "https://evil.example/steal?all=1"},
        })
        tasks = cli.fetch_all_tasks("L1")
        self.assertEqual([t["id"] for t in tasks], ["a"])
        self.assertEqual(len(self.calls), 1)

    def test_rejects_non_https_or_wrong_path_next_link(self):
        base = "/me/todo/lists/L1/tasks?$top=250"
        for link in ("http://graph.microsoft.com/v1.0/x",
                     "https://graph.microsoft.com/beta/x"):
            with self.subTest(link=link):
                self._serve({base: {"value": [], "@odata.nextLink": link}})
                self.assertEqual(cli.fetch_all_tasks("L1"), [])
                self.assertEqual(len(self.calls), 1)
                self.calls.clear()

    def test_caps_at_max_tasks_fetch(self):
        base = "/me/todo/lists/L1/tasks?$top=250"
        page = [{"id": i} for i in range(300)]
        self._serve({base: {"value": page}})
        tasks = cli.fetch_all_tasks("L1")
        self.assertEqual(len(tasks), cli.MAX_TASKS_FETCH)

    def test_encodes_list_id_in_first_url(self):
        seen = []
        cli.graph_request = lambda method, path, body=None, params=None: (
            seen.append(path)) or {"value": []}
        cli.fetch_all_tasks("../../me/lists")
        prefix = "/me/todo/lists/"
        self.assertTrue(seen[0].startswith(prefix))
        # The id rides as ONE path segment — no raw separators inside it.
        segment = seen[0][len(prefix):].split("/tasks", 1)[0]
        self.assertNotIn("/", segment)
        self.assertIn("%2F", segment)


class MalformedResponses(unittest.TestCase):
    """Garbage bodies surface as NetworkError, not tracebacks."""

    class FakeCtx:
        def __init__(self, payload):
            self.resp = FakeResponse(payload)

        def __enter__(self):
            return self.resp

        def __exit__(self, *exc):
            return False

    def tearDown(self):
        if hasattr(self, "_orig_urlopen"):
            cli.urllib.request.urlopen = self._orig_urlopen
        if hasattr(self, "_orig_load_tokens"):
            cli.load_tokens = self._orig_load_tokens

    def _serve_body(self, payload):
        self._orig_urlopen = cli.urllib.request.urlopen
        cli.urllib.request.urlopen = lambda req, timeout=None: type(self).FakeCtx(payload)
        # A live token so access_token() short-circuits and the request
        # actually reaches urlopen.
        self._orig_load_tokens = cli.load_tokens
        cli.load_tokens = lambda: {
            "access_token": "x", "refresh_token": "rt", "expires_at": time.time() + 9999}

    def test_http_form_bad_json_is_network_error(self):
        self._serve_body(b"\xff\xfe not json at all")
        with self.assertRaises(cli.NetworkError):
            cli.http_form("https://login.microsoftonline.com/token", {})

    def test_graph_request_bad_json_is_network_error(self):
        self._serve_body(b"<html>gateway error</html>")
        with self.assertRaises(cli.NetworkError):
            cli.graph_request("GET", "/me")

    def test_graph_request_binary_junk_is_network_error(self):
        self._serve_body(bytes(range(256)))
        with self.assertRaises(cli.NetworkError):
            cli.graph_request("GET", "/me")


class LoginUriAllowlist(unittest.TestCase):
    """The device-code URL is allowlisted to Microsoft sign-in hosts."""

    def test_accepts_microsoft_hosts(self):
        for uri in ("https://microsoft.com/devicelogin",
                    "https://www.microsoft.com/link",
                    "https://login.microsoftonline.com/common/oauth2/deviceauth"):
            with self.subTest(uri=uri):
                self.assertEqual(cli._login_uri({"verification_uri": uri}), uri)

    def test_accepts_live_host(self):
        uri = "https://login.live.com/oauth20_desktop.srf"
        self.assertEqual(cli._login_uri({"verification_uri": uri}), uri)

    def test_rejects_everything_else(self):
        for uri in ("http://microsoft.com/link",
                    "https://evil.example/microsoft.com",
                    "javascript:alert(1)",
                    "",
                    None,
                    "file:///etc/passwd"):
            with self.subTest(uri=uri):
                self.assertEqual(
                    cli._login_uri({"verification_uri": uri}),
                    "https://microsoft.com/link")

    def test_missing_field_falls_back(self):
        self.assertEqual(cli._login_uri({}), "https://microsoft.com/link")


class MapTaskTimezones(unittest.TestCase):
    """Uninterpreted zone strings are pinned to UTC, not local time."""

    def test_unknown_tz_pinned_to_utc(self):
        # 12:00 with an exotic zone must read as 12:00 UTC regardless of the
        # machine's own timezone.
        task = cli.map_task({
            "dueDateTime": {"dateTime": "2026-08-22T12:00:00.0",
                            "timeZone": "Florianopolis Standard Time"},
        })
        dt = datetime.fromtimestamp(task["due"], tz=timezone.utc)
        self.assertEqual((dt.hour, dt.minute), (12, 0))

    def test_utc_explicit_unchanged(self):
        task = cli.map_task({
            "dueDateTime": {"dateTime": "2026-08-22T12:00:00.0", "timeZone": "UTC"},
        })
        dt = datetime.fromtimestamp(task["due"], tz=timezone.utc)
        self.assertEqual(dt.hour, 12)


class SecurityHardening(unittest.TestCase):
    """Tests for the security hardening: bounded reads, atomic writes, caps."""

    def setUp(self):
        self.tmpdir = Path("/tmp/omarchy_test").resolve()
        self.tmpdir.mkdir(exist_ok=True)
        # Patch STATE_DIR for isolation
        self._orig_state_dir = cli.STATE_DIR
        cli.STATE_DIR = str(self.tmpdir)
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.CONFIG_PATH = os.path.join(cli.STATE_DIR, "config.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")

    def tearDown(self):
        cli.STATE_DIR = self._orig_state_dir
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.CONFIG_PATH = os.path.join(cli.STATE_DIR, "config.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")
        # Clean up temp dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_read_file_bounded_normal(self):
        path = self.tmpdir / "normal.json"
        path.write_text('{"foo": "bar"}')
        result = cli._read_file_bounded(str(path), 1024)
        self.assertEqual(result, '{"foo": "bar"}')

    def test_read_file_bounded_size_limit(self):
        path = self.tmpdir / "large.json"
        large_content = "x" * 2000
        path.write_text(large_content)
        with self.assertRaises(cli.FileReadLimitExceeded):
            cli._read_file_bounded(str(path), 1024)

    def test_read_file_bounded_fifo_timeout(self):
        # Create a FIFO and ensure read times out (we don't write to it)
        fifo_path = self.tmpdir / "test_fifo"
        os.mkfifo(fifo_path)
        try:
            with self.assertRaises(cli.FileReadTimeout):
                cli._read_file_bounded(str(fifo_path), 1024)
        finally:
            os.unlink(fifo_path)

    def test_load_json_oversized_returns_fallback(self):
        path = self.tmpdir / "cache.json"
        path.write_text("x" * 500000)  # 500KB, exceeds MAX_CACHE_BYTES (256KB)
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=cli.MAX_CACHE_BYTES)
        self.assertEqual(result, {"fallback": True})

    def test_load_json_fifo_returns_fallback(self):
        fifo_path = self.tmpdir / "fifo.json"
        os.mkfifo(fifo_path)
        try:
            result = cli.load_json(str(fifo_path), {"fallback": True}, max_bytes=1024)
            self.assertEqual(result, {"fallback": True})
        finally:
            os.unlink(fifo_path)

    def test_load_json_valid_parses(self):
        path = self.tmpdir / "valid.json"
        path.write_text('{"key": "value"}')
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=1024)
        self.assertEqual(result, {"key": "value"})

    def test_save_json_atomic_perms_0600(self):
        path = self.tmpdir / "atomic.json"
        cli.save_json_atomic(str(path), {"key": "value"})
        stat = os.stat(path)
        # Check file is 0600 (owner read/write only)
        self.assertEqual(stat.st_mode & 0o777, 0o600)

    def test_save_json_atomic_atomic_replace(self):
        path = self.tmpdir / "atomic.json"
        cli.save_json_atomic(str(path), {"v": 1})
        # Simulate concurrent write by writing directly then atomic should win
        cli.save_json_atomic(str(path), {"v": 2})
        with open(path) as f:
            data = json.load(f)
        self.assertEqual(data["v"], 2)

    def test_save_json_atomic_dir_perms_0700(self):
        path = self.tmpdir / "subdir" / "nested.json"
        cli.save_json_atomic(str(path), {"key": "value"})
        dir_stat = os.stat(os.path.dirname(path))
        self.assertEqual(dir_stat.st_mode & 0o777, 0o700)


def test_save_json_atomic_dir_perms_0700(self):
        path = self.tmpdir / "subdir" / "nested.json"
        cli.save_json_atomic(str(path), {"key": "value"})
        dir_stat = os.stat(os.path.dirname(path))
        self.assertEqual(dir_stat.st_mode & 0o777, 0o700)


class SecurityHardening(unittest.TestCase):
    """Security hardening tests for symlink protection, FIFO handling, and atomic writes."""

    def setUp(self):
        self.tmpdir = Path("/tmp/omarchy_test").resolve()
        self.tmpdir.mkdir(exist_ok=True)
        # Patch STATE_DIR for isolation
        self._orig_state_dir = cli.STATE_DIR
        cli.STATE_DIR = str(self.tmpdir)
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.CONFIG_PATH = os.path.join(cli.STATE_DIR, "config.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")

    def tearDown(self):
        cli.STATE_DIR = self._orig_state_dir
        cli.AUTH_PATH = os.path.join(cli.STATE_DIR, "auth.json")
        cli.CACHE_PATH = os.path.join(cli.STATE_DIR, "data.json")
        cli.CONFIG_PATH = os.path.join(cli.STATE_DIR, "config.json")
        cli.LOGIN_PATH = os.path.join(cli.STATE_DIR, "login.json")
        # Clean up temp dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_read_file_bounded_rejects_symlink(self):
        # Create symlink to /etc/passwd, verify read fails with FileReadLimitExceeded
        path = self.tmpdir / "link.json"
        path.symlink_to("/etc/passwd")
        with self.assertRaises(cli.FileReadLimitExceeded):
            cli._read_file_bounded(str(path), 1024)

    def test_read_file_bounded_rejects_fifo(self):
        # Create FIFO and ensure read times out
        fifo_path = self.tmpdir / "test_fifo"
        os.mkfifo(fifo_path)
        try:
            with self.assertRaises(cli.FileReadTimeout):
                cli._read_file_bounded(str(fifo_path), 1024)
        finally:
            os.unlink(fifo_path)

    def test_load_json_rejects_symlink(self):
        # Create symlink for cache file, verify fallback used
        path = self.tmpdir / "cache.json"
        path.symlink_to("/etc/passwd")
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=cli.MAX_CACHE_BYTES)
        self.assertEqual(result, {"fallback": True})

    def test_load_json_rejects_symlink_manifest(self):
        # Symlink manifest.json, verify fallback
        path = self.tmpdir / "manifest.json"
        path.symlink_to("/etc/passwd")
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=cli.MAX_MANIFEST_BYTES)
        self.assertEqual(result, {"fallback": True})

    def test_load_json_rejects_symlink_shell_json(self):
        # Symlink shell.json, verify fallback
        path = self.tmpdir / "shell.json"
        path.symlink_to("/etc/passwd")
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=cli.MAX_SHELL_JSON_BYTES)
        self.assertEqual(result, {"fallback": True})

    def test_save_json_atomic_rejects_symlink_temp(self):
        # Create symlink as temp file target, verify write fails with ELOOP or EEXIST
        path = self.tmpdir / "atomic.json"
        # Create a symlink where the temp file would be created
        tmp_path = Path(str(path) + ".tmp")
        tmp_path.symlink_to("/etc/passwd")
        with self.assertRaises(OSError) as cm:
            cli.save_json_atomic(str(path), {"key": "value"})
        # Should fail with ELOOP (symlink detected) or EEXIST (file exists)
        self.assertIn(cm.exception.errno, (17, 40))

    def test_load_json_rejects_symlink(self):
        # Create symlink for any state file, verify fallback used
        path = self.tmpdir / "config.json"
        path.symlink_to("/etc/passwd")
        result = cli.load_json(str(path), {"fallback": True}, max_bytes=cli.MAX_CONFIG_BYTES)
        self.assertEqual(result, {"fallback": True})


if __name__ == "__main__":
    print(json.dumps({"suite": "omarchy-mstodo", "bin": str(BIN), "exists": BIN.exists()}))
    unittest.main(verbosity=2)
