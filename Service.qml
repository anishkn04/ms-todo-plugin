import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything that must exist once, not once per screen. The shell mounts a
// `service` plugin exactly once and hands it to views through
// bar.shell.serviceFor(id); a bar widget exists per monitor, so the sync
// timer, the CLI queue, the reminder clock, and the focus countdown all
// live here.
//
// State model mirrors the ticktick plugin's, minus what To Do does not need:
//   - data.json is the cache the CLI writes and this reads back through a
//     bounded reader (`timeout 5 head -c`), never whole-file into the shell.
//     Optimistic UI (pending completions/deletions) clears when the write
//     lands, because the write is the authority on what is still open.
//   - Writes go through a single Process with a FIFO of argv vectors; Graph
//     mutations are cheap but serialising them avoids interleaved tokens
//     refreshes and keeps error reporting in one place. CLI output is capped
//     at the producer (head -c) before it can reach a collector.
//   - Reminders: the phone is notified by Microsoft's own app. This side
//     watches the cache with a minute clock and fires notify-send when a
//     task's reminder time arrives (minus the configured lead). A notified
//     map persisted to disk stops restarts from re-nagging old reminders.

Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null
  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback) {
    var v = parseInt(setting(name, fallback), 10)
    return isNaN(v) ? fallback : v
  }

  function boolSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value === true
  }

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string cli: pluginDir + "bin/omarchy-mstodo"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/mstodo"

  // ---- cache -------------------------------------------------------------

  property var cache: Model.parseCache("")
  property var sections: []

  readonly property bool signedIn: !cache.authRequired && (root.hasTokens || cache.syncedAt > 0)
  readonly property bool authRequired: cache.authRequired === true
  readonly property string account: cache.account
  readonly property string listName: cache.listName

  // Existence proof for the token file, so the very first seconds after a
  // shell restart (before the first sync lands) still read as signed-in.
  property bool hasTokens: false

  function reloadSections() {
    root.sections = Model.sectionize(root.cache.tasks, Date.now())
  }

  // ---- state files ---------------------------------------------------------
  //
  // Nothing under ~/.local/state is trusted to be small: data.json mirrors
  // remote Graph state, and every other file sits user-writable. Reads are
  // therefore capped at the producer instead of after accumulation — head
  // -c stops consuming at the limit, so the collector can never hold more
  // than that, and timeout keeps a swapped-in FIFO from stalling the
  // process. The FileView objects below are watchers and writers only;
  // preload:false means Quickshell never materializes a file into this
  // process. Model.js parse-time caps stay as the second line of defense.

  readonly property int dataReadLimit: 262144   // 256 KiB of task cache
  readonly property int authReadLimit: 16384    // token blobs are tiny
  readonly property int stateReadLimit: 4096    // notified/pomo maps

  function boundedRead(path, limit) {
    // Check file is a regular file (not symlink) and use trap to kill process group on timeout
    return ["sh", "-c",
      'trap "kill -TERM -$$" TERM INT EXIT; ' +
      '[ -f "$1" ] && [ ! -L "$1" ] && head -c "$1" -- "$2" || exit 1',
      "sh", String(limit), path]
  }

  FileView {
    id: dataWatch
    path: root.statePath + "/data.json"
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: root.readData()
  }

  // One read in flight; a change arriving mid-read queues exactly one
  // follow-up, so a burst of writes can never starve the latest one out.
  property bool dataReadQueued: false

  function readData() {
    if (dataReadProc.running) {
      root.dataReadQueued = true
      return
    }
    root.dataReadQueued = false
    dataReadProc.command = root.boundedRead(root.statePath + "/data.json", root.dataReadLimit)
    dataReadProc.running = true
  }

  function applyData(raw) {
    // A prefix cut off mid-document parses as garbage and lands on the
    // empty-cache path, same as any other unreadable file; the next sync
    // rewrite brings the UI back through this same reader.
    root.cache = Model.parseCache(raw)
    root.reloadSections()
    // The write that lands here is the authority on what is still open;
    // optimistic rows stop being needed the moment it arrives.
    root.pendingIds = ({})
    root.pendingDeletes = ({})
  }

  Process {
    id: dataReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyData(String(text || ""))
    }
    onExited: {
      if (root.dataReadQueued) root.readData()
    }
  }

  // Watchdog: bounded read should complete within 5s (timeout in shell wrapper).
  Timer {
    interval: 5000
    running: dataReadProc.running
    onTriggered: { dataReadProc.running = false }
  }

  FileView {
    id: authWatch
    path: root.statePath + "/auth.json"
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: root.readAuth()
  }

  property bool authReadQueued: false

  function readAuth() {
    if (authReadProc.running) {
      root.authReadQueued = true
      return
    }
    root.authReadQueued = false
    authReadProc.command = root.boundedRead(root.statePath + "/auth.json", root.authReadLimit)
    authReadProc.running = true
  }

  Process {
    id: authReadProc
    stdout: StdioCollector {
      waitForEnd: true
      // Empty text covers both "missing file" and "empty file": either way
      // there are no tokens to point at.
      onStreamFinished: root.hasTokens = String(text || "").trim() !== ""
    }
    onExited: {
      if (root.authReadQueued) root.readAuth()
    }
  }

  // Watchdog: bounded read should complete within 5s (timeout in shell wrapper).
  Timer {
    interval: 5000
    running: authReadProc.running
    onTriggered: { authReadProc.running = false }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      // Midnight flips which section a task belongs to.
      root.reloadSections()
      root.checkReminders()
      root.rollPomoDay()
    }
  }

  // "synced N ago" for the panel subtitle; empty until the first sync.
  readonly property string cacheAgeLabel: {
    if (root.cache.syncedAt <= 0) return ""
    var age = Math.max(0, Math.floor(Date.now() / 1000 - root.cache.syncedAt))
    if (age < 60) return "synced just now"
    if (age < 3600) return "synced " + Math.floor(age / 60) + "m ago"
    return "synced " + Math.floor(age / 3600) + "h ago"
  }

  // Derived counts for the bar. Overdue outranks everything else visually,
  // so it gets its own channel instead of being folded into the count.
  readonly property int overdueCount: Model.overdueCount(cache.tasks, Date.now())
  readonly property int dueTodayCount: Model.dueTodayCount(cache.tasks, Date.now())
  readonly property string nextTitle: Model.nextTitle(cache.tasks, Date.now())
  readonly property string nextBarLine: Model.nextBarLine(cache.tasks, Date.now())
  readonly property bool hasWork: overdueCount > 0 || dueTodayCount > 0 || nextTitle !== ""

  // ---- sync ---------------------------------------------------------------

  readonly property int refreshIntervalSec: {
    var s = setting("syncInterval", "5 minutes")
    if (s === "2 minutes") return 120
    if (s === "5 minutes") return 300
    if (s === "15 minutes") return 900
    if (s === "1 hour") return 3600
    return 0
  }
  readonly property bool autoSyncs: refreshIntervalSec > 0
  property string actionError: ""
  readonly property bool syncing: syncProc.running

  // CLI output is consumed only where a human reads it: an error line or a
  // sign-in status object, both short by design. The wrapper caps what can
  // reach a collector at the producer — head stops reading after capBytes
  // and SIGPIPE ends a runaway child — while pipefail preserves the CLI's
  // exit code. The "stderr" capture also forwards stdout (which is empty
  // for our sync/action paths) so it, too, is bounded.
  // Caps are hardcoded constants to avoid any interpolation into the shell command.
  readonly property int errCapBytes: 8192     // an error message, generously
  readonly property int jsonCapBytes: 16384   // login status objects

  function cappedCmd(args, capture) {
    var redirect = capture === "stdout"
      ? "2>/dev/null | head -c " + root.jsonCapBytes
      : "2>&1 | head -c " + root.errCapBytes
    return ["sh", "-c",
      'trap "kill -TERM -$$" TERM INT EXIT; set -o pipefail; "$0" "$@" ' + redirect,
      root.cli].concat(args)
  }

  function refresh(force) {
    if (!root.signedIn) return
    if (syncProc.running) return
    var args = force === false
      ? ["sync", "--max-age", String(Math.max(30, refreshIntervalSec - 15))]
      : ["sync"]
    syncProc.command = root.cappedCmd(args, "stderr")
    syncProc.running = true
  }

  Process {
    id: syncProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 140)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      // The CLI just rewrote data.json; reload through the bounded reader
      // rather than trusting the watcher, which never attached if the state
      // directory did not exist yet when this service started.
      root.readData()
    }
  }

  // Watchdog: kill sync if it hangs longer than 15s (covers FIFO stalls the
  // CLI might hit before its own timeout fires).
  Timer {
    interval: 15000
    running: syncProc.running
    onTriggered: { syncProc.running = false }
  }

  Timer {
    id: syncTimer
    interval: Math.max(60, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.autoSyncs
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // With background sync off the cache would still be stale after a shell
  // restart; one startup sync is not a poll, it is the bar having something
  // to show.
  Timer {
    interval: 1500
    running: !root.autoSyncs
    repeat: false
    onTriggered: root.refresh(false)
  }

  // ---- sign-in (device-code flow, driven from the panel) -------------------

  // The panel's Sign in button runs the CLI's machine steps: `login start`
  // prints the device code as JSON and persists the challenge, then a timer
  // polls `login poll` until Microsoft approves or the window expires. The
  // service owns processes and state; the panel owns everything visible.
  property bool signingIn: false
  property string loginCode: ""
  property string loginUri: ""
  property real loginExpiresAt: 0
  property int loginPollIntervalSec: 5
  property int loginSlowDowns: 0
  property string loginError: ""

  function signIn() {
    if (root.signingIn) return
    root.loginError = ""
    root.loginCode = ""
    root.loginUri = ""
    root.loginSlowDowns = 0
    loginStartProc.command = root.cappedCmd(["login", "start"], "stdout")
    loginStartProc.running = true
  }

  function stopSignIn() {
    root.signingIn = false
    root.loginCode = ""
    root.loginUri = ""
    root.loginExpiresAt = 0
  }

  function cancelSignIn() {
    var wasActive = root.signingIn || loginPollProc.running || loginStartProc.running
    root.stopSignIn()
    if (wasActive) runAction(["login", "cancel"])
  }

  function copySignInCode() {
    if (root.loginCode === "") return
    // wl-copy forks a background holder; Process only tracks the parent.
    // Pass code via stdin to avoid leaking device code in argv/process table.
    copyProc.command = ["sh", "-c", 'printf %s "$1" | wl-copy', "sh", root.loginCode]
    copyProc.running = true
  }

  Process {
    id: copyProc
    command: ["true"]
  }

  // Watchdog: wl-copy fork should complete quickly.
  Timer {
    interval: 2000
    running: copyProc.running
    onTriggered: { copyProc.running = false }
  }

  function pollSignIn() {
    if (!root.signingIn) return
    if (Date.now() >= root.loginExpiresAt) {
      root.loginError = "Sign-in window expired \u2014 try again"
      root.stopSignIn()
      return
    }
    if (loginPollProc.running) return
    loginPollProc.command = root.cappedCmd(["login", "poll"], "stdout")
    loginPollProc.running = true
  }

  Process {
    id: loginStartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = Model.parseJson(String(text || ""))
        if (!r || r.status !== "started") {
          root.loginError = r && r.message ? Model.elide(r.message, 120) : "Could not start sign-in"
          return
        }
        root.loginCode = String(r.user_code || "")
        root.loginUri = Model.safeLoginUri(r.verification_uri)
        root.loginExpiresAt = Date.now() + parseInt(r.expires_in || 900, 10) * 1000
        root.loginPollIntervalSec = Math.max(2, parseInt(r.interval || 5, 10))
        root.signingIn = true
        // The browser handoff is the whole point of the button; opening the
        // tab is one less manual step. The code stays copyable regardless.
        Qt.openUrlExternally(root.loginUri)
      }
    }
  }

  // Watchdog: device-code request should complete within 10s.
  Timer {
    interval: 10000
    running: loginStartProc.running
    onTriggered: { loginStartProc.running = false }
  }

  Process {
    id: loginPollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.signingIn) return   // cancelled while the poll was in flight
        var r = Model.parseJson(String(text || ""))
        var status = r ? String(r.status || "") : ""
        if (status === "success") {
          root.stopSignIn()
          root.actionError = ""
          root.refresh(true)
        } else if (status === "expired") {
          root.loginError = "Sign-in window expired \u2014 try again"
          root.stopSignIn()
        } else if (status === "declined") {
          root.loginError = "Sign-in was declined"
          root.stopSignIn()
        } else if (status === "slow_down") {
          root.loginSlowDowns++
        } else if (status === "error") {
          // Transient (offline, server hiccup): surface once, keep polling.
          root.loginError = Model.elide(String(r.message || "network error"), 120)
        }
      }
    }
    onExited: {
      // Approval writes auth.json; pick it up without waiting for the sync.
      root.readAuth()
    }
  }

  // Watchdog: token poll should complete within 10s.
  Timer {
    interval: 10000
    running: loginPollProc.running
    onTriggered: { loginPollProc.running = false }
  }

  Timer {
    id: loginPollTimer
    interval: Math.min(30, Math.max(2, root.loginPollIntervalSec + root.loginSlowDowns * 5)) * 1000
    repeat: true
    running: root.signingIn && !loginStartProc.running
    onTriggered: root.pollSignIn()
  }

  // ---- writes -------------------------------------------------------------

  property var actionQueue: []

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 140)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      // Every action rewrites data.json, and logout removes auth.json;
      // reload both through the readers rather than trusting the watchers.
      root.readData()
      root.readAuth()
      root.drainQueue()
    }
  }

  // Watchdog: mutation should complete within 10s.
  Timer {
    interval: 10000
    running: actionProc.running
    onTriggered: { actionProc.running = false }
  }

  function runAction(args) {
    if (actionProc.running) {
      actionQueue = actionQueue.concat([args])
      return
    }
    actionProc.command = root.cappedCmd(args, "stderr")
    actionProc.running = true
  }

  function drainQueue() {
    if (actionQueue.length === 0) return
    var queued = actionQueue.slice()
    var next = queued.shift()
    actionQueue = queued
    actionProc.command = root.cappedCmd(next, "stderr")
    actionProc.running = true
  }

  // ---- undo window --------------------------------------------------------

  property var pendingIds: ({})
  property var pendingDeletes: ({})

  readonly property int undoSeconds: Math.max(0, parseInt(setting("undoSeconds", 6), 10) || 0)

  // Held actions, oldest first; each carries its own deadline so completing
  // several rows in a row holds all of them.
  property var pendingActions: []
  property int undoTick: 0

  readonly property var pendingAction: pendingActions.length > 0 ? pendingActions[pendingActions.length - 1] : null
  readonly property int pendingCount: pendingActions.length
  readonly property int undoLeft: {
    if (!pendingAction) return 0
    void root.undoTick   // re-evaluate per ticker tick so the countdown moves
    return Math.max(0, Math.ceil((pendingAction.deadline - Date.now()) / 1000))
  }

  function scheduleAction(kind, title, args, key) {
    if (undoSeconds <= 0) {
      runAction(args)
      return
    }
    pendingActions = pendingActions.concat([{
      kind: kind,
      title: title,
      args: args,
      key: key,
      deadline: Date.now() + undoSeconds * 1000
    }])
  }

  function flushExpired() {
    var due = []
    var remaining = []
    var now = Date.now()
    for (var i = 0; i < pendingActions.length; i++) {
      if (pendingActions[i].deadline <= now) due.push(pendingActions[i])
      else remaining.push(pendingActions[i])
    }
    if (due.length > 0) {
      pendingActions = remaining
      for (var j = 0; j < due.length; j++) runAction(due[j].args)
    }
  }

  // Closing the panel commits everything still held rather than dropping it.
  function flushPending() {
    if (pendingActions.length === 0) return
    var held = pendingActions
    pendingActions = []
    for (var i = 0; i < held.length; i++) runAction(held[i].args)
  }

  function cancelPending() {
    if (pendingActions.length === 0) return
    pendingActions = pendingActions.slice(0, pendingActions.length - 1)
  }

  function clearKey(map, key) {
    var next = {}
    for (var k in map) if (k !== String(key)) next[k] = map[k]
    return next
  }

  function setKey(map, key) {
    var next = {}
    for (var k in map) next[k] = map[k]
    next[String(key)] = true
    return next
  }

  function completeTask(task) {
    if (!task || !task.id || pendingIds[task.id]) return
    pendingIds = setKey(pendingIds, task.id)
    scheduleAction("complete", task.title,
                   ["complete", String(task.id)], String(task.id))
  }

  function deleteTask(task) {
    if (!task || !task.id || pendingDeletes[task.id]) return
    pendingDeletes = setKey(pendingDeletes, task.id)
    scheduleAction("delete", task.title,
                   ["delete", String(task.id)], String(task.id))
  }

  function snoozeTask(task, whenArgs) {
    if (!task || !task.id) return
    runAction(["snooze", String(task.id)].concat(whenArgs))
  }

  function submitQuickAdd(line) {
    var text = String(line || "").trim()
    if (text === "") return false
    runAction(["add", text])
    return true
  }

  function submitEdit(taskId, line) {
    var text = String(line || "").trim()
    if (text === "") return false
    runAction(["update", String(taskId), text])
    return true
  }

  Timer {
    id: undoTicker
    interval: 250
    repeat: true
    running: root.pendingActions.length > 0
    onTriggered: {
      root.undoTick++
      root.flushExpired()
    }
  }

  // ---- desktop reminders --------------------------------------------------

  // Fired reminders persist as { "<taskId>": remindEpoch } — restarting the
  // shell must not re-notify last week's reminder.
  property var notifiedMap: ({})

  readonly property int notifyLeadMinutes: {
    var s = setting("notifyLeadMinutes", "At reminder time")
    if (s === "5 minutes before") return 5
    if (s === "15 minutes before") return 15
    return 0
  }

  // Omarchy's daemon clamps every non-critical toast to thirty seconds at
  // most, so "stays until dismissed" can only be expressed as critical
  // urgency. Critical notify-send also bypasses Do Not Disturb, which is
  // exactly right for a reminder and exactly why it stays a toggle.
  readonly property bool persistentNotifs: boolSetting("persistentReminders", true)

  // Writer only — hydration happens through the bounded reader below, so a
  // user-writable file of any size never enters the process whole. atomic
  // writes keep a torn file from being read back as garbage after a crash.
  FileView {
    id: notifiedFile
    path: root.statePath + "/notified.json"
    watchChanges: false
    preload: false
    atomicWrites: true
    printErrors: false
  }

  function readNotified() {
    if (notifiedReadProc.running) return
    notifiedReadProc.command = root.boundedRead(root.statePath + "/notified.json", root.stateReadLimit)
    notifiedReadProc.running = true
  }

  Process {
    id: notifiedReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.notifiedMap = Model.parseNotified(String(text || ""))
        root.checkReminders()
      }
    }
  }

  // Watchdog: bounded read should complete within 5s.
  Timer {
    interval: 5000
    running: notifiedReadProc.running
    onTriggered: { notifiedReadProc.running = false }
  }

  function markNotified(key) {
    var nowSec = Math.floor(Date.now() / 1000)
    var next = Model.pruneNotified(notifiedMap, nowSec)
    next[key] = nowSec
    notifiedMap = next
    notifiedFile.setText(JSON.stringify(next))
  }

  function checkReminders() {
    var lead = root.notifyLeadMinutes * 60
    var now = Date.now() / 1000
    var tasks = root.cache.tasks
    for (var i = 0; i < tasks.length; i++) {
      var t = tasks[i]
      if (t.completed || !(t.remind > 0)) continue
      var fireAt = t.remind - lead
      if (fireAt > now) continue
      var key = t.id + ":" + Math.floor(t.remind)
      if (root.notifiedMap[key]) continue
      // Skip reminders that were already stale before this session began:
      // booting the shell at 4pm should not dump ten 9am notifications.
      if (fireAt < root._sessionStart - 90) {
        root.markNotified(key)
        continue
      }
      root.markNotified(key)
      notifyProc.command = [
        "notify-send", "-a", "To Do",
        "-u", (root.persistentNotifs || overdueCount > 0 ? "critical" : "normal"),
        Model.elide(t.title, 80),
        (t.recurType !== "" ? "\u21bb recurring \u00b7 " : "") + "due " + Model.dueLabel(Model.effectiveDue(t), Date.now())
      ]
      notifyProc.running = true
      break   // one per tick keeps the queue calm; the clock re-fires in 60s
    }
  }

  property real _sessionStart: Date.now() / 1000

  Process {
    id: notifyProc
    command: ["notify-send", "-a", "To Do"]
  }

  // ---- focus timer --------------------------------------------------------

  readonly property var pomoPrefs: ({
    focusMinutes: Math.min(180, intSetting("focusMinutes", 25)),
    shortBreakMinutes: Math.min(60, intSetting("shortBreakMinutes", 5)),
    longBreakMinutes: Math.min(120, intSetting("longBreakMinutes", 15)),
    longBreakInterval: Math.max(1, Math.min(12, intSetting("longBreakInterval", 4)))
  })
  readonly property bool pomoAutoChain: boolSetting("autoChain", true)
  readonly property bool pomoNotifies: boolSetting("pomoNotifications", true)

  property string pomoPhase: "idle"
  property real pomoEndMs: 0
  property real pomoPausedLeft: 0
  property int pomoTick: 0

  readonly property bool pomoRunning: pomoPhase !== "idle" && pomoEndMs > 0
  readonly property bool pomoPaused: pomoPhase !== "idle" && pomoEndMs === 0
  readonly property bool pomoActive: pomoRunning || pomoPaused
  readonly property int pomoSecondsLeft: pomoPaused
    ? Math.round(pomoPausedLeft)
    : (pomoRunning ? Math.max(0, Math.round((pomoEndMs - Date.now() + root.pomoTick * 0) / 1000)) : 0)
  readonly property string pomoClock: pomoPhase === "idle" ? "" : Model.formatClock(pomoSecondsLeft)

  function startPomo(phase) {
    pomoPhase = phase
    pomoEndMs = Date.now() + Model.pomoPhaseSeconds(phase, root.pomoPrefs) * 1000
    pomoPausedLeft = 0
  }

  function pausePomo() {
    if (!root.pomoRunning) return
    pomoPausedLeft = Math.max(0, (pomoEndMs - Date.now()) / 1000)
    pomoEndMs = 0
  }

  function resumePomo() {
    if (!root.pomoPaused) return
    pomoEndMs = Date.now() + pomoPausedLeft * 1000
    pomoPausedLeft = 0
  }

  function stopPomo() {
    // A stopped block is deliberately not logged — only finished focus
    // blocks count toward the day's stats.
    pomoPhase = "idle"
    pomoEndMs = 0
    pomoPausedLeft = 0
  }

  function togglePomo() {
    if (root.pomoRunning) pausePomo()
    else if (root.pomoPaused) resumePomo()
    else startPomo("focus")
  }

  function notifyPomo(title, body) {
    if (!root.pomoNotifies) return
    // Owns its process so a toast never collides with a task reminder
    // racing through notifyProc.
    pomoNotifyProc.command = ["notify-send", "-a", "To Do",
                              "-u", root.persistentNotifs ? "critical" : "normal",
                              Model.elide(title, 80), body]
    pomoNotifyProc.running = true
  }

  function pomoFinished() {
    if (pomoPhase === "focus") {
      var minutes = Model.pomoPhaseSeconds("focus", root.pomoPrefs) / 60
      logPomoBlock(minutes)
      var nextPhase = Model.pomoPhaseAfter(root.pomoState.blocks, root.pomoPrefs.longBreakInterval)
      notifyPomo("Focus block done",
                 root.pomoAutoChain ? "Starting " + Model.pomoPhaseLabel(nextPhase).toLowerCase() + "."
                                    : "Start your " + (nextPhase === "longBreak" ? "long" : "short") + " break when ready.")
      if (root.pomoAutoChain) startPomo(nextPhase)
      else stopPomo()
    } else {
      notifyPomo("Break over", "Back to focus.")
      if (root.pomoAutoChain) startPomo("focus")
      else stopPomo()
    }
  }

  Timer {
    id: pomoTicker
    interval: 500
    repeat: true
    running: root.pomoRunning
    onTriggered: {
      root.pomoTick++
      if (root.pomoSecondsLeft <= 0) root.pomoFinished()
    }
  }

  Process {
    id: pomoNotifyProc
    command: ["notify-send", "-a", "To Do"]
  }

  // ---- daily focus stats --------------------------------------------------

  // { dateKey: "YYYY-MM-DD", blocks: n, minutes: m } — To Do has nowhere to
  // store pomodoros, so finished blocks are counted locally and reset daily.
  property var pomoState: ({ dateKey: "", blocks: 0, minutes: 0 })

  function rollPomoDay() {
    var key = Model.pomoDateKey(Date.now())
    if (String(pomoState.dateKey || "") !== key)
      pomoState = { dateKey: key, blocks: 0, minutes: 0 }
  }

  function logPomoBlock(minutes) {
    rollPomoDay()
    var next = {
      dateKey: String(pomoState.dateKey || Model.pomoDateKey(Date.now())),
      blocks: Number(pomoState.blocks || 0) + 1,
      minutes: Math.round(Number(pomoState.minutes || 0) + minutes)
    }
    pomoState = next
    pomoFile.setText(JSON.stringify(next))
  }

  // Writer only, like notifiedFile; the bounded reader below hydrates it.
  FileView {
    id: pomoFile
    path: root.statePath + "/pomo.json"
    watchChanges: false
    preload: false
    atomicWrites: true
    printErrors: false
  }

  function readPomo() {
    if (pomoReadProc.running) return
    pomoReadProc.command = root.boundedRead(root.statePath + "/pomo.json", root.stateReadLimit)
    pomoReadProc.running = true
  }

  Process {
    id: pomoReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pomoState = Model.parsePomoState(String(text || ""))
        root.rollPomoDay()
      }
    }
  }

  // Watchdog: bounded read should complete within 5s.
  Timer {
    interval: 5000
    running: pomoReadProc.running
    onTriggered: { pomoReadProc.running = false }
  }

  Component.onCompleted: {
    // Seed the state dir so first-run writes and the readers have somewhere
    // to land; the readers re-check once seeding exits. Sync happens via
    // the startup timer above. The plugin only ever touches its own mstodo
    // tree.
    seedProc.command = ["bash", "-c",
      "d=\"$HOME/.local/state/omarchy/mstodo\"; mkdir -p \"$d\"; " +
      "f=\"$d/notified.json\"; [[ -f \"$f\" ]] || printf '{}' > \"$f\"; " +
      "f=\"$d/pomo.json\"; [[ -f \"$f\" ]] || printf '{ \"dateKey\": \"\", \"blocks\": 0, \"minutes\": 0 }' > \"$f\""]
    seedProc.running = true
  }

  Process {
    id: seedProc
    onExited: {
      // Initial hydration through the same bounded readers; from here on
      // the CLI-exit hooks and the file watchers keep everything current.
      root.readData()
      root.readAuth()
      root.readNotified()
      root.readPomo()
    }
  }

  // Watchdog: seeding should complete within 5s.
  Timer {
    interval: 5000
    running: seedProc.running
    onTriggered: { seedProc.running = false }
  }
}
