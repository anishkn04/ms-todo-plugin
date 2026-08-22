import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for MS To Do. The service owns the cache and the timers; this
// reads already-shaped state off it so the line stays live whether or not
// the panel has ever been opened.
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
    var line = service ? String(service.nextBarLine) : ""
    if (root.vertical) return Model.elide(line, 12)
    return Model.elide(line, 34)
  }
  readonly property bool hasLine: nextLine !== ""

  readonly property string displayText: !signedIn
    ? "setup"
    : (pomoActive ? pomoClock : (hasLine ? nextLine : "clear"))
  readonly property var verticalLines: [displayText]

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
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
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
      root.togglePanel()
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
