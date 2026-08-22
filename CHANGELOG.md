# Changelog

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
