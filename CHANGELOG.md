# Changelog

## 0.3.0 — 2026-08-23

Bounded state IO and persistent notifications.

- Nothing on disk is materialized into the shell whole anymore. `data.json`
  (remote-derived), `auth.json`, `notified.json`, and `pomo.json`
  (user-writable) are read through bounded readers — `timeout 5 head -c`,
  256 KiB for the task cache, 4–16 KiB for the small files — so an
  oversized or hostile state file can no longer exhaust the long-lived
  shell before parsing. The FileView objects remain only as change
  watchers and writers (`atomicWrites` on).
- CLI output is capped at the producer: sync/action stderr and login
  stdout pass through `head -c` inside a `pipefail` wrapper (SIGPIPE ends
  runaway children), and the login processes' previously buffered stderr
  is discarded instead of collected without limit.
- Parse-time caps back the readers: at most 1000 tasks with ≤200-character
  titles/accounts reach the model, notified-map entries older than 14 days
  are pruned on every write, and focus stats parse to a fixed shape.
- New *Persistent notifications* toggle (default on): task reminders and
  focus toasts use critical urgency, which Omarchy's daemon holds until
  dismissed and across shell restarts. Critical urgency bypasses Do Not
  Disturb, hence it being a setting rather than an assumption.
- Test suite fixes: `build_task_payload` accepts an injectable clock and
  every payload test now freezes time, so the suite no longer breaks at
  midnight; Model.js gained a node test module.

## 0.2.0 — 2026-08-22

Bar display modes and hardening.

- Right-click the bar slot to cycle views: next commitment → remaining
  count (overdue + due today, prefixed with the task glyph so it never
  reads as a workspace number) → icon only. The choice persists in
  `shell.json` per widget; `omarchy-mstodo cycle-mode` works from scripts.
  A running focus countdown still outranks every view, and the setup hint
  never hides.
- Panel rows keep their spacing between the repeat glyph and its label
  (`↻ daily`, not `↻daily`).
- A refused token refresh (revoked grant, password change, tenant policy)
  now flips the cache to signed-out instead of surfacing as a generic API
  error while the UI kept claiming a live session.
- Task sync follows Graph's `@odata.nextLink` so lists beyond one page
  sync completely; continuation links are accepted only from the same
  Graph v1.0 endpoint. Overall fetch stays capped at 250 tasks.
- Malformed JSON bodies surface as network errors instead of tracebacks;
  list/task ids are percent-encoded into request paths; device-code login
  URLs are allowlisted to Microsoft sign-in hosts in both the CLI and the
  panel before a browser is opened; due-date timestamps with unknown time
  zone strings are pinned to UTC instead of drifting with local time; the
  plugin state directory is created `0700`.

## 0.1.1 — 2026-08-22

Security hardening.

- Microsoft-sourced strings (task titles, list name, account, Graph/OAuth
  errors) render as plain text: QML text controls pin `Text.PlainText`, and
  strings crossing into shell-owned widgets are stripped of markup so remote
  content can no longer be interpreted as rich text or fetch referenced
  resources.
- Graph and OAuth response bodies are read under a 4 MiB cap (64 KiB for
  error payloads) instead of unbounded reads.
- Removed the startup move of a pre-existing `~/.local/state/omarchy/tasks`
  directory into the plugin's state tree; the plugin only ever touches its
  own `~/.local/state/omarchy/mstodo`.

## 0.1.0 — 2026-08-22

First release.

- Microsoft To Do tasks in the Omarchy bar: next-task line, overdue/today
  counts, focus-timer takeover.
- Quick-add grammar: `@date HH:MM repeat … !priority`, live preview,
  edit-by-grammar (double-click a row).
- Panel sign-in: device-code flow driven by a button — code display with
  copy/open-link/cancel, automatic browser handoff, polling handled for you.
  (`omarchy-mstodo login` still works from a terminal.)
- Desktop reminders via `notify-send` with configurable lead time; phone
  notifications stay with Microsoft's own To Do app.
- Pomodoro: configurable focus/break lengths, auto-chaining, daily local
  stats.
- Undo window for completions and deletions; serialized write queue.
