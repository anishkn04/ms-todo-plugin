// Shared logic for the MS To Do plugin: cache shaping, a JS mirror of the
// CLI's quick-add grammar (for the input's live preview — the CLI stays the
// authority and re-parses on submit), sectioning for the panel, and the
// label helpers the bar reads.
//
// Epoch seconds everywhere: the CLI converts Graph's ISO strings once, so
// QML only ever does `new Date(sec * 1000)`.

var WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

var REPEAT_KEYWORDS = {
  "daily": { key: "daily", label: "daily" },
  "weekdays": { key: "weekdays", label: "weekdays" },
  "workdays": { key: "weekdays", label: "weekdays" },
  "weekly": { key: "weekly", label: "weekly" },
  "monthly": { key: "monthly", label: "monthly" },
  "yearly": { key: "yearly", label: "yearly" },
  "annually": { key: "yearly", label: "yearly" },
  "after-completion": { key: "after", label: "after completion" },
  "aftercompletion": { key: "after", label: "after completion" },
  "after": { key: "after", label: "after completion" }
}

var PRIORITIES = { "low": "low", "normal": "normal", "high": "high" }
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function pad2(n) { return n < 10 ? "0" + n : String(n) }

function startOfDay(ms) {
  var d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function elide(text, max) {
  var s = String(text || "")
  return s.length > max ? s.slice(0, Math.max(0, max - 1)) + "\u2026" : s
}

// Shell-owned widgets (WidgetButton labels, tooltips, OpticalGlyph) render
// Text in Qt's default AutoText mode, which interprets markup-looking
// input. Microsoft-sourced strings are stripped of markup-significant
// characters before crossing that boundary.
function plain(text) {
  return String(text || "").replace(/[<>&]/g, "")
}

// Mirror of the CLI's _login_uri allowlist: https on a Microsoft sign-in
// host, else the known-good default. The CLI already filters before it
// prints; this keeps a tampered cache or a future caller from handing the
// browser something else.
var LOGIN_URI_RE = /^https:\/\/(www\.)?microsoft\.com(\/|$)|^https:\/\/login\.(microsoftonline|live)\.com(\/|$)/

function safeLoginUri(uri) {
  var s = String(uri || "")
  return LOGIN_URI_RE.test(s) ? s : "https://microsoft.com/link"
}

// ---- cache ---------------------------------------------------------------

function parseJson(text) {
  try { return JSON.parse(String(text || "")) } catch (e) { return null }
}

function parseCache(text) {
  var raw = parseJson(text) || {}
  return {
    syncedAt: typeof raw.syncedAt === "number" ? raw.syncedAt : 0,
    authRequired: raw.authRequired === true,
    account: String(raw.account || ""),
    listId: String(raw.listId || ""),
    listName: String(raw.listName || ""),
    tasks: Array.isArray(raw.tasks) ? raw.tasks : []
  }
}

// ---- quick-add preview ---------------------------------------------------
//
// Mirrors bin/omarchy-mstodo parse_quick_add. The preview only needs the
// human-facing labels; unknown tokens stay in the title exactly like the
// CLI, so what you see is what gets created.

function parseQuickAdd(line, nowMs) {
  var now = new Date(nowMs || Date.now())
  var titleParts = []
  var dateLabel = ""
  var timeLabel = ""
  var recurLabel = ""
  var priority = ""

  var tokens = String(line || "").split(/\s+/).filter(function(t) { return t !== "" })
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    var lowered = token.toLowerCase()

    // @date tokens
    if (token.charAt(0) === "@" && token.length > 1) {
      var word = lowered.slice(1)
      if (word === "today") { dateLabel = "today"; continue }
      if (word === "tomorrow") { dateLabel = "tomorrow"; continue }
      var wd = WEEKDAYS.indexOf(word)
      if (wd >= 0) {
        var delta = (wd - now.getDay() + 7) % 7
        dateLabel = delta === 0 ? "today" : (delta === 1 ? "tomorrow" : word)
        continue
      }
      if (/^\d{1,2}$/.test(word)) {
        var day = parseInt(word, 10)
        if (day >= 1 && day <= 31) {
          var target = new Date(now.getFullYear(), now.getMonth(), day)
          if (target < new Date(startOfDay(nowMs || Date.now())))
            target = new Date(now.getFullYear(), now.getMonth() + 1, 1)
          dateLabel = MONTHS[target.getMonth()] + " " + target.getDate()
          continue
        }
      }
      var dm = /^(\d{1,2})\.(\d{1,2})$/.exec(word)
      if (dm) {
        var dd = parseInt(dm[1], 10), mm = parseInt(dm[2], 10) - 1
        if (mm >= 0 && mm <= 11 && dd >= 1 && dd <= 31) {
          var cand = new Date(now.getFullYear(), mm, dd)
          if (cand < new Date(startOfDay(nowMs || Date.now())))
            cand = new Date(now.getFullYear() + 1, mm, dd)
          dateLabel = MONTHS[cand.getMonth()] + " " + cand.getDate()
          continue
        }
      }
      // "@7:00" — a time wearing the @ prefix
      if (/^([01]?\d|2[0-3]):[0-5]\d$/.test(word)) {
        timeLabel = word
        continue
      }
      titleParts.push(token)
      continue
    }

    // bare HH:MM
    if (/^([01]?\d|2[0-3]):[0-5]\d$/.test(token)) {
      timeLabel = token
      continue
    }

    if (lowered === "repeat" && i + 1 < tokens.length) {
      var next = tokens[i + 1].toLowerCase()
      if (next === "every" && i + 3 < tokens.length && /^\d+$/.test(tokens[i + 2])) {
        var n = parseInt(tokens[i + 2], 10)
        var unit = tokens[i + 3].toLowerCase().replace(/s$/, "")
        if (["day", "week", "month", "year"].indexOf(unit) >= 0) {
          recurLabel = "every " + n + " " + unit + (n === 1 ? "" : "s")
          i += 3
          continue
        }
      }
      var mapped = REPEAT_KEYWORDS[next]
      if (mapped) { recurLabel = mapped.label; i += 1; continue }
    }

    if (lowered.charAt(0) === "!" && PRIORITIES[lowered.slice(1)]) {
      priority = PRIORITIES[lowered.slice(1)]
      continue
    }

    titleParts.push(token)
  }

  return {
    title: titleParts.join(" "),
    dateLabel: dateLabel,
    timeLabel: timeLabel,
    recurLabel: recurLabel,
    priority: priority
  }
}

function previewFor(line, nowMs) {
  var p = parseQuickAdd(line, nowMs)
  if (p.title === "" && p.dateLabel === "" && p.recurLabel === "") return ""
  var parts = []
  // Graph anchors a recurrence on the due date; with no date typed, the
  // CLI starts it today (or tomorrow once the stated time has passed).
  // The preview mirrors that so what you see is what will be created.
  if (!p.dateLabel && p.recurLabel) {
    var t = p.timeLabel ? p.timeLabel.split(":") : null
    var now = new Date(nowMs || Date.now())
    var starts = "today"
    if (t) {
      var hh = parseInt(t[0], 10), mm = parseInt(t[1], 10)
      if (now.getHours() * 60 + now.getMinutes() >= hh * 60 + mm) starts = "tomorrow"
    } else if (now.getHours() >= 23 && now.getMinutes() >= 59) {
      starts = "tomorrow"
    }
    parts.push("from " + starts)
  }
  if (p.dateLabel) parts.push(p.dateLabel)
  if (p.timeLabel) parts.push(p.timeLabel)
  if (p.recurLabel) parts.push("\u21bb " + p.recurLabel)
  if (p.priority) parts.push(p.priority)
  return p.title === "" ? parts.join(" \u00b7 ") : "\u2192 " + parts.join(" \u00b7 ")
}

// ---- task shaping ---------------------------------------------------------

// MS To Do stores due dates date-only: the server truncates any due time to
// midnight UTC, which reads as 05:45 in UTC+5:45. The true wall-clock time
// lives on the reminder. Use the reminder's instant whenever it falls on the
// due date itself — for sorting, labels, and the reverse grammar.
function effectiveDue(task) {
  var due = Number(task.due) || 0
  if (!task.isReminderOn || !(task.remind > 0)) return due
  var r = new Date(task.remind * 1000)
  var d = new Date(due * 1000)
  var sameDay = r.getFullYear() === d.getFullYear()
    && r.getMonth() === d.getMonth() && r.getDate() === d.getDate()
  return sameDay ? Number(task.remind) : due
}

function openTasks(tasks) {
  var out = []
  for (var i = 0; i < tasks.length; i++) {
    if (!tasks[i].completed && tasks[i].title) out.push(tasks[i])
  }
  out.sort(function(a, b) {
    var ea = effectiveDue(a), eb = effectiveDue(b)
    var da = ea > 0 ? ea : Infinity
    var db = eb > 0 ? eb : Infinity
    if (da !== db) return da - db
    if (a.importance === b.importance) return 0
    var rank = { high: 0, normal: 1, low: 2 }
    return rank[a.importance] - rank[b.importance]
  })
  return out
}

function sectionize(tasks, nowMs) {
  var todayStart = startOfDay(nowMs)
  var todayEnd = todayStart + 24 * 3600 * 1000
  var sections = [
    { key: "overdue", label: "Overdue", tasks: [] },
    { key: "today", label: "Today", tasks: [] }
  ]
  var byKey = {}
  for (var s = 0; s < sections.length; s++) byKey[sections[s].key] = sections[s]

  // Only today's work is shown; future and undated tasks stay reachable in
  // any To Do app or via `omarchy-mstodo list`, but the panel stays focused.
  var open = openTasks(tasks)
  for (var i = 0; i < open.length; i++) {
    var t = open[i]
    if (t.due > 0 && t.due * 1000 < todayStart) byKey.overdue.tasks.push(t)
    else if (t.due > 0 && t.due * 1000 < todayEnd) byKey.today.tasks.push(t)
  }

  var visible = []
  for (var k = 0; k < sections.length; k++) {
    if (sections[k].tasks.length > 0) visible.push(sections[k])
  }
  return visible
}

function overdueCount(tasks, nowMs) {
  var todayStart = startOfDay(nowMs)
  var count = 0
  for (var i = 0; i < tasks.length; i++) {
    var t = tasks[i]
    if (!t.completed && t.due > 0 && t.due * 1000 < todayStart) count++
  }
  return count
}

function dueTodayCount(tasks, nowMs) {
  var todayStart = startOfDay(nowMs)
  var todayEnd = todayStart + 24 * 3600 * 1000
  var count = 0
  for (var i = 0; i < tasks.length; i++) {
    var t = tasks[i]
    if (!t.completed && t.due > 0 && t.due * 1000 >= todayStart && t.due * 1000 < todayEnd) count++
  }
  return count
}

function nextTitle(tasks, nowMs) {
  var open = openTasks(tasks)
  var todayStart = startOfDay(nowMs)
  for (var i = 0; i < open.length; i++) {
    if (open[i].due <= 0 || open[i].due * 1000 <= todayStart + 48 * 3600 * 1000) return open[i].title
  }
  return open.length > 0 ? open[0].title : ""
}

// The bar's one line: the nearest open block as "HH:MM Title". Overdue work
// leads with "! " so it reads as urgent without any icon dependency.
function nextBarLine(tasks, nowMs) {
  var open = openTasks(tasks)
  var todayStart = startOfDay(nowMs)
  for (var i = 0; i < open.length; i++) {
    var t = open[i]
    if (t.due <= 0 || t.due * 1000 <= todayStart + 48 * 3600 * 1000) {
      var eff = effectiveDue(t)
      var overdue = t.due > 0 && t.due * 1000 < todayStart
      var when = ""
      if (eff > 0) {
        var d = new Date(eff * 1000)
        if (d.getHours() !== 0 || d.getMinutes() !== 0) when = timeLabel(eff) + " "
      }
      return (overdue ? "! " : "") + when + t.title
    }
  }
  return ""
}

// ---- display helpers ------------------------------------------------------

function timeLabel(epochSec) {
  if (!epochSec) return ""
  var d = new Date(epochSec * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function dueLabel(epochSec, nowMs) {
  if (!epochSec) return ""
  var d = new Date(epochSec * 1000)
  var now = new Date(nowMs || Date.now())
  var sameDay = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  var hasTime = d.getHours() !== 0 || d.getMinutes() !== 0
  if (sameDay) return hasTime ? timeLabel(epochSec) : "today"
  var day = WEEKDAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
  return hasTime ? day + " " + timeLabel(epochSec) : day
}

function recurBadge(task) {
  var type = String(task.recurType || "")
  var interval = Number(task.recurInterval) || 1
  if (type === "regenerating") return "\u21bb after"
  if (type === "") return ""
  var days = String(task.recurDays || "")
  if (days !== "") {
    var shorts = days.split(",").map(function(d) { return d.slice(0, 3) })
    if (shorts.join(",") === "mon,tue,wed,thu,fri") return "\u21bb weekdays"
    return "\u21bb " + shorts.join("")
  }
  var names = {
    daily: interval === 1 ? "\u21bb daily" : "\u21bb every " + interval + "d",
    weekly: interval === 1 ? "\u21bb weekly" : "\u21bb every " + interval + "w",
    absoluteMonthly: interval === 1 ? "\u21bb monthly" : "\u21bb every " + interval + "mo",
    absoluteYearly: interval === 1 ? "\u21bb yearly" : "\u21bb every " + interval + "y"
  }
  return names[type] || ("\u21bb " + type)
}

// The reverse grammar: an existing task rendered back into the line you
// would type to create it. One input, one syntax — editing is adding.
function editLineFor(task) {
  var parts = [task.title]
  if (task.due > 0) {
    var eff = effectiveDue(task)
    var d = new Date(eff * 1000)
    parts.push("@" + d.getDate() + "." + pad2(d.getMonth() + 1))
    if (d.getHours() !== 0 || d.getMinutes() !== 0) parts.push(timeLabel(eff))
  }
  var badge = recurBadge(task)
  if (badge !== "") {
    var words = badge.replace("\u21bb ", "").split(" ")
    if (words[0] === "after") parts.push("repeat after-completion")
    else if (words[0] === "every") parts.push("repeat every " + words.slice(1).join(" "))
    else parts.push("repeat " + words.join(""))
  }
  if (task.importance === "high") parts.push("!high")
  else if (task.importance === "low") parts.push("!low")
  return parts.join(" ")
}

// ---- pomodoro -------------------------------------------------------------

function formatClock(seconds) {
  var total = Math.max(0, Math.round(seconds))
  var mins = Math.floor(total / 60)
  var secs = total % 60
  if (mins >= 60) {
    var hours = Math.floor(mins / 60)
    return hours + ":" + pad2(mins % 60) + ":" + pad2(secs)
  }
  return pad2(mins) + ":" + pad2(secs)
}

// TickTick's cycle: focus, short break, focus, ... and a long break every
// `longBreakInterval` completed focus blocks.
function pomoPhaseAfter(completedFocusBlocks, longBreakInterval) {
  var every = Math.max(1, Number(longBreakInterval || 4))
  var done = Math.max(0, Number(completedFocusBlocks || 0))
  return (done > 0 && done % every === 0) ? "longBreak" : "shortBreak"
}

function pomoPhaseSeconds(phase, prefs) {
  var p = prefs || {}
  if (phase === "shortBreak") return Math.max(1, Number(p.shortBreakMinutes || 5)) * 60
  if (phase === "longBreak") return Math.max(1, Number(p.longBreakMinutes || 15)) * 60
  return Math.max(1, Number(p.focusMinutes || 25)) * 60
}

function pomoPhaseLabel(phase) {
  if (phase === "shortBreak") return "Short break"
  if (phase === "longBreak") return "Long break"
  return "Focus"
}

function pomoDateKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function pomoStatsLabel(stats) {
  var s = stats || {}
  var count = Number(s.blocks || 0)
  var minutes = Number(s.minutes || 0)
  if (count === 0 && minutes === 0) return ""
  var head = count + (count === 1 ? " block" : " blocks")
  return minutes > 0 ? head + " \u00b7 " + minutes + "m" : head
}
