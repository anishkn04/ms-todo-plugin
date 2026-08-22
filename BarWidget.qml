import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for MS To Do. The service owns the cache and the timers; this
// reads already-shaped state off it so the line stays live whether or not
// the panel has ever been opened.
//
// Left click opens the panel; right click walks three views: the next
// commitment, how much is left today, or the icon alone. The chosen view
// persists in this widget's shell.json entry, so it survives restarts.
BarWidget {
  id: root
  moduleName: "anishkn.mstodo"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("anishkn.mstodo")
    : null

  readonly property bool signedIn: service ? service.signedIn : false
  readonly property int overdueCount: service ? service.overdueCount : 0
  readonly property int dueTodayCount: service ? service.dueTodayCount : 0

  // The shell injects settings into bar widgets, not services; without this
  // push the service never sees sync interval, undo window, reminder lead,
  // or the focus lengths.
  onServiceChanged: pushSettings()
  onSettingsChanged: {
    pushSettings()
    injectPanel()
  }
  function pushSettings() {
    if (root.service && "settings" in root.service) root.service.settings = root.settings
  }

  // A live countdown outranks everything: while a block runs, the remaining
  // time is the only thing on the bar worth the space.
  readonly property string pomoClock: service ? service.pomoClock : ""
  readonly property bool pomoRunning: service ? service.pomoRunning === true : false
  readonly property bool pomoPaused: service ? service.pomoPaused === true : false
  readonly property bool pomoActive: pomoRunning || pomoPaused

  // The bar IS the next commitment: "11:30 Work / Program #1". No icon, no
  // bare count. When today is clear, a dimmed word beats an empty slot.
  readonly property string nextLine: {
    var line = Model.plain(service ? String(service.nextBarLine) : "")
    if (root.vertical) return Model.elide(line, 12)
    return Model.elide(line, 34)
  }
  readonly property bool hasLine: nextLine !== ""

  // ---- display views ------------------------------------------------------
  // Right click walks the ring; a live focus countdown outranks whichever
  // view is active. The choice persists in this widget's shell.json entry
  // ("displayMode") — same persistence as omarchy.clock's format ring and
  // screen-time's iconOnly.
  // nf-md-format_list_checks (U+F0316) as its UTF-16 surrogate pair — QML
  // string \u escapes take exactly four hex digits, so five-digit codepoints
  // cannot be written as one escape.
  readonly property string glyph: "\uDB80\uDF16"

  readonly property var modeRing: ["next", "count", "icon"]
  readonly property string displayMode: {
    var m = String(setting("displayMode", "next"))
    return root.modeRing.indexOf(m) >= 0 ? m : "next"
  }

  function cycleMode() {
    var next = root.modeRing[(root.modeRing.indexOf(root.displayMode) + 1) % root.modeRing.length]
    if (next === root.displayMode) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.displayMode = next
    // Applied locally first so the bar changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Icon-only is a signed-in shape only — before sign-in the slot must keep
  // saying "setup", and a running focus block owns the text in every view.
  readonly property bool iconOnly: root.signedIn && !root.pomoActive && displayMode === "icon"

  // What's left today: everything overdue plus everything due by midnight.
  // The count view prefixes the plugin glyph — a bare number next to
  // workspace indicators reads as "workspace 3", not as tasks.
  readonly property int remainingCount: overdueCount + dueTodayCount

  readonly property string displayText: !signedIn
    ? "setup"
    : (pomoActive ? pomoClock
      : iconOnly ? ""
      : displayMode === "count" ? root.glyph + " " + remainingCount
      : (hasLine ? nextLine : "clear"))
  readonly property var verticalLines: [root.iconOnly ? root.glyph : displayText]

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function focusedInstance() {
    if (root.bar && typeof root.bar.findPanelWidget === "function") {
      var item = root.bar.findPanelWidget(root.moduleName)
      if (item) return item
    }
    return root
  }

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "anishkn.mstodo"

    function sync(): void { if (root.service) root.service.refresh(true) }
    function open(): void { root.focusedInstance().open() }
    function close(): void { root.focusedInstance().close() }
    function show(): void { root.focusedInstance().open() }
    function hide(): void { root.focusedInstance().close() }
    function toggle(): void { root.focusedInstance().togglePanel() }
    function focus(): void { if (root.service) root.service.togglePomo() }
    function focusStop(): void { if (root.service) root.service.stopPomo() }
    function cycleMode(): void { root.cycleMode() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // In icon mode the Text still holds the glyph so its advance width
    // keeps the slot sized; labelVisible only stops the double render.
    text: root.vertical ? "" : (root.iconOnly ? root.glyph : root.displayText)
    labelVisible: !root.vertical && !root.iconOnly
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1

    // Late work is the one state worth spending the bar's urgent color on —
    // unless a focus block is running, in which case the timer owns it.
    active: root.pomoActive ? root.pomoRunning : (root.signedIn && root.overdueCount > 0)
    dimmed: !root.signedIn

    tooltipText: {
      if (!root.signedIn) return "MS To Do \u2014 click to set up"
      if (root.pomoActive) {
        var phase = service ? String(service.pomoPhase) : "focus"
        var word = phase === "shortBreak" ? "short break"
                 : phase === "longBreak" ? "long break" : "focus"
        return word.charAt(0).toUpperCase() + word.slice(1) + (root.pomoPaused ? " paused" : " running")
      }
      if (root.overdueCount > 0)
        return root.overdueCount + " overdue \u00b7 " + root.dueTodayCount + " today \u00b7 click to open"
      if (root.dueTodayCount > 0)
        return root.dueTodayCount + " due today \u00b7 click to open"
      return "MS To Do \u2014 all clear"
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleMode()
      else root.togglePanel()
    }

    // Icon-only view: the hidden label still sizes the slot off its advance
    // width; the glyph itself is painted through an OpticalGlyph so its ink
    // is centred. Overdue work keeps recoloring it through the button's
    // active state.
    OpticalGlyph {
      id: iconGlyph
      visible: !root.vertical && root.iconOnly
      anchors.fill: parent
      text: root.glyph
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
