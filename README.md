# MS To Do for Omarchy

Microsoft To Do tasks in your bar: quick-add with times and recurrence,
keyboard-driven review, desktop reminders so nothing slips, and a focus
timer (pomodoro) with local daily stats. Your phone keeps using Microsoft's
own To Do app — its notifications are excellent and free, and this widget
mirrors the same list on the desktop.

> [!NOTE]
> This project is fully AI generated.

## Install

```sh
omarchy plugin add https://github.com/anishkn04/ms-todo-plugin.git --enable
```

A dimmed `setup` slot appears on the bar. Click it to sign in.

## Dependencies

- `libnotify` (`notify-send`) — desktop reminders and focus-timer toasts.
- `wl-clipboard` (`wl-copy`) — the sign-in card's copy-code button.

Both ship with Omarchy. The CLI itself is stdlib-only Python — nothing to
pip install.

## Sign in

Click the bar slot and hit **Sign in with Microsoft**. The panel shows a
device code, opens `microsoft.com/link` in your browser, and polls until
you approve. Copy/open/cancel are one click each; the session survives
restarts via a refresh token. If it ever expires (~90 days of not using the
shell), the panel offers **Sign in again**.

Prefer a terminal? The CLI drives the same flow:

```sh
~/.config/omarchy/plugins/anishkn.mstodo/bin/omarchy-mstodo login
```

(Add `alias mstodo=...` to your shell if you'll use it often.)

Tokens live in `~/.local/state/omarchy/mstodo/auth.json` with `0600`
permissions; the task cache sits next to it. The plugin ships its own
registered public client id (a client id identifies the app — it is not a
secret). If your account type rejects it, register a free app of your own
(5 minutes) and set `OMARCHY_MSTODO_CLIENT_ID=<id>` for the first login —
the id is then stored with your tokens:

1. portal.azure.com → **App registrations** → New registration
2. Supported account types: **personal Microsoft accounts only**
3. Redirect URI: leave empty; then **Authentication** → *Allow public client
   flows* → **Yes**
4. Copy the Application (client) ID

## Choosing a list

By default your default Tasks list is used. Point at any list by display
name:

```jsonc
// ~/.config/omarchy/shell.json
"plugins": [ { "id": "anishkn.mstodo", "listName": "Errands" } ]
```

Sync cadence, undo window, reminder lead time, rows per section, and all
focus-timer lengths are editable from Omarchy's plugin settings UI.

## Quick-add grammar

Type into the panel's input; a live preview shows what will be created.

```
Pay electricity @tomorrow 18:30 repeat daily !high
└─ title       └─ date     └─ time └─ recurrence    └─ priority
```

| Part | Values | Result |
|---|---|---|
| date | `@today @tomorrow @mon..@sun @DD @DD.MM` | due date (weekday resolves forward, DD rolls to next month) |
| time | `HH:MM` | due time **and** reminder |
| repeat | `daily weekdays weekly monthly yearly every N days/weeks/months/years after-completion` | recurring task; completing it spawns the next occurrence server-side |
| until | `until DD.MM` (right after `repeat …`) | bounds the recurrence — no instances after that date |
| priority | `!low !normal !high` | importance |

No tokens = plain task with no date. Parse errors never block submission —
anything unrecognized stays in the title.

## Panel

Four zones, top to bottom: header (sync + help buttons), quick-add, the open
list grouped into **Overdue / Today**, and the **FOCUS** timer. Later work
stays out of the way — it lives in any To Do app or `omarchy-mstodo list`.

- Click a row to select it; double-click to edit it in the input (same
  grammar); click the circle to complete.
- Completions and deletions are held for an undo window before hitting the
  API.
- Shortcuts are listed behind the `?` button — there is no footer repeating
  them.

## Focus timer

A local pomodoro in the FOCUS block: press play to start a focus block;
when it ends you get a toast and (optionally) the break starts on its own —
short break, or a long one every N blocks. Finished focus blocks count into
daily stats (`~/.local/state/omarchy/mstodo/pomo.json`), reset at midnight;
discarded blocks don't count. While a timer runs, the bar slot shows the
countdown instead of the next task.

All lengths are plugin settings (bar settings UI or `shell.json`):
focus 25m, short break 5m, long break 15m, long break every 4 blocks by
default, plus **auto-start next phase** and **notifications** toggles.

## Keyboard

| Key | Action |
|---|---|
| `a` | focus add box |
| `e` | edit selected (double-click works too) |
| `space` / `enter` | complete |
| `s` | snooze to tomorrow 09:00 |
| `h` | push one hour |
| `d` / delete | remove |
| `u` | cancel last held action |
| `p` | start / pause / resume focus |
| `x` | discard the current focus block |
| `g` / `G` | first / last row |
| `r` | force sync |
| `tab` | switch to next bar panel |
| `esc` | close (backs out of help/undo first) |

## IPC

```sh
omarchy-shell anishkn.mstodo sync        # also: open close toggle show hide
omarchy-shell anishkn.mstodo focus       # start/pause/resume the timer
omarchy-shell anishkn.mstodo focusStop   # discard the current block
```

## Terminal

```sh
omarchy-mstodo list                # grouped: Overdue / Today / Later (full view)
omarchy-mstodo list today          # scopes: overdue|today|upcoming|all|done
omarchy-mstodo list -a             # include completed
omarchy-mstodo list --json         # machine-readable
omarchy-mstodo complete IaQAAAA    # short id suffix from `list` (unique)
omarchy-mstodo add "pay rent @tomorrow 09:00 !high"
```

MS To Do stores due dates date-only (the server truncates the time), so the
wall-clock time lives on the reminder; both the panel and `list` display the
reminder's time whenever it falls on the due date.

## Reminders

- **Phone**: MS To Do app notifications (reliable, free).
- **Desktop**: the service's minute clock watches the cache and fires a
  `notify-send` toast when a task's reminder time arrives — even with the
  panel closed. A lead time of 5/15 minutes is configurable. Reminders that
  were already stale before the session started never re-nag after a reboot;
  each fired reminder is recorded once in `notified.json`.

## Sync model

- Opening the panel always syncs; background ticks use `--max-age` so two
  monitors don't double-fetch.
- All writes go through one CLI process, serialized by the service's action
  queue.
- Graph rate limits (429) and network failures surface as a red line in the
  panel footer, never as crashes.

## Remove

```sh
omarchy plugin remove anishkn.mstodo
```

Tokens and cached data live outside the repo in
`~/.local/state/omarchy/mstodo/`; delete that directory as well if you want
a fully clean exit (it also logs you out of this device).

## Development

The CLI is stdlib-only Python (no pip installs). Layout:

```
~/.config/omarchy/plugins/anishkn.mstodo/
├── manifest.json      plugin metadata + settings schema
├── BarWidget.qml      bar slot: the next task line, or the countdown while one runs
├── Panel.qml          popout: quick-add, Overdue/Today list, sign-in card,
│                      undo window, help overlay (?), FOCUS timer block
├── Service.qml        mounted once: cache reader, sync timer, action queue,
│                      sign-in polling, reminder clock, focus countdown + stats
├── Model.js           cache shaping, quick-add preview + sectioning helpers
├── bin/omarchy-mstodo Python CLI — OAuth device flow + Microsoft Graph
└── tests/             unit tests for the grammar, payloads, and auth steps
```

```sh
python3 tests/test_mstodo.py
omarchy plugin validate ~/.config/omarchy/plugins/anishkn.mstodo
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml Service.qml
```

Saved changes under `~/.config/omarchy/plugins/` hot-reload; force discovery
with `omarchy-shell shell rescanPlugins`.

## Credits

With thanks to [omarchy-ticktick](https://github.com/SotoAugusto/omarchy-ticktick)
by [@SotoAugusto](https://github.com/SotoAugusto) — this plugin started as a
study of its architecture: the Python CLI behind the shell (long-lived
credentials in a 0600 file, serialized writes, cache-on-disk for QML) and
the service state model are adapted from there, with the Microsoft Graph
side built on top. If MS To Do isn't your thing, go check out TickTick.

## License

[MIT](LICENSE)
