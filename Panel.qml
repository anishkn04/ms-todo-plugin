import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popout panel for MS To Do. One input, one syntax — editing renders the
// row back into the same grammar you would have typed to create it.
//
// Layout is four zones, top to bottom: header (title + sync/help), quick-add,
// the open list (Overdue / Today), and the focus timer. Everything
// else is transient: an undo window or an error takes one status line above
// the input, keyboard shortcuts live behind the ? button.
Panel {
  id: root
  moduleName: "anishkn.mstodo"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("anishkn.mstodo")
    : null

  // The service has no settings source of its own; every panel carries the
  // same inline entry, so whichever loads first hands them over.
  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  function pushSettings() {
    if (svc && "settings" in svc) svc.settings = root.settings
  }

  readonly property bool signedIn: svc ? svc.signedIn : false
  readonly property bool authRequired: svc ? svc.authRequired : false
  readonly property string account: svc ? svc.account : ""
  readonly property string listName: svc ? svc.listName : ""
  readonly property bool syncing: svc ? svc.syncing === true : false
  readonly property string actionError: svc ? svc.actionError : ""
  readonly property string cacheAgeLabel: svc ? svc.cacheAgeLabel : ""

  // ---- sign-in (state lives in the service) -------------------------------

  readonly property bool signingIn: svc ? svc.signingIn === true : false
  readonly property string loginCode: svc ? String(svc.loginCode || "") : ""
  readonly property string loginUri: svc ? String(svc.loginUri || "") : ""
  readonly property real loginExpiresAt: svc ? Number(svc.loginExpiresAt) || 0 : 0
  readonly property string loginError: svc ? String(svc.loginError || "") : ""

  property bool codeCopied: false
  property int signInTick: 0

  Timer {
    interval: 1000
    repeat: true
    running: root.signingIn
    onTriggered: {
      root.signInTick++
      if (root.codeCopied) root.codeCopied = false
    }
  }

  function signIn() { if (svc) svc.signIn() }
  function cancelSignIn() { if (svc) svc.cancelSignIn() }
  function copySignInCode() {
    if (!svc || root.loginCode === "") return
    svc.copySignInCode()
    root.codeCopied = true
  }
  function openLoginLink() {
    if (root.loginUri !== "") Qt.openUrlExternally(root.loginUri)
  }
  readonly property string loginExpiresLabel: {
    void root.signInTick   // re-evaluate each second while the timer runs
    var left = Math.floor((root.loginExpiresAt - Date.now()) / 60000)
    if (!root.signingIn || left <= 0) return ""
    return "expires in " + left + " min"
  }

  readonly property int maxPerSection: Math.max(3, parseInt(setting("maxTasksPerSection", 8), 10) || 8)

  readonly property var pendingIds: svc ? svc.pendingIds : ({})
  readonly property var pendingDeletes: svc ? svc.pendingDeletes : ({})
  readonly property var pendingAction: svc ? svc.pendingAction : null
  readonly property int pendingCount: svc ? svc.pendingCount : 0
  readonly property int undoLeft: svc ? svc.undoLeft : 0

  // ---- focus timer (state lives in the service; one clock per shell) -----

  readonly property var pomoPrefs: svc ? svc.pomoPrefs : ({})
  readonly property string pomoPhase: svc ? String(svc.pomoPhase) : "idle"
  readonly property bool pomoRunning: svc ? svc.pomoRunning === true : false
  readonly property bool pomoPaused: svc ? svc.pomoPaused === true : false
  readonly property bool pomoActive: pomoRunning || pomoPaused
  readonly property string pomoClock: svc ? String(svc.pomoClock) : ""

  function togglePomo() { if (svc) svc.togglePomo() }
  function stopPomo() { if (svc) svc.stopPomo() }

  // ---- flat render + navigation model ------------------------------------
  //
  // Sections flatten into header rows and task rows so one Repeater draws
  // everything and the keyboard cursor has a single index space that skips
  // headers automatically.

  readonly property var rawSections: svc ? svc.sections : []

  readonly property var flatRows: {
    var rows = []
    for (var s = 0; s < root.rawSections.length; s++) {
      var section = root.rawSections[s]
      var shown = section.tasks.slice(0, root.maxPerSection)
      rows.push({ kind: "header", label: section.label, count: section.tasks.length })
      for (var i = 0; i < shown.length; i++) {
        rows.push({ kind: "task", task: shown[i], section: section.key })
      }
      if (section.tasks.length > shown.length) {
        rows.push({ kind: "more", label: (section.tasks.length - shown.length) + " more" })
      }
    }
    return rows
  }

  readonly property var taskIndexes: {
    var idx = []
    for (var i = 0; i < flatRows.length; i++)
      if (flatRows[i].kind === "task") idx.push(i)
    return idx
  }

  property bool cursorActive: false
  property int cursor: -1   // index into taskIndexes

  function moveCursor(delta) {
    cursorActive = true
    var count = taskIndexes.length
    if (count === 0) { cursor = -1; return }
    if (cursor < 0) cursor = delta > 0 ? 0 : count - 1
    else cursor = Math.max(0, Math.min(count - 1, cursor + delta))
    ensureVisible()
  }

  function cursorToFirst() {
    cursorActive = true
    cursor = taskIndexes.length > 0 ? 0 : -1
    ensureVisible()
  }

  function cursorToLast() {
    cursorActive = true
    cursor = taskIndexes.length - 1
    ensureVisible()
  }

  function ensureVisible() {
    if (cursor < 0 || cursor >= taskIndexes.length) return
    var y = rowY(taskIndexes[cursor])
    if (y < 0) return
    var h = rowHeight(taskIndexes[cursor])
    if (y < scroll.contentY) scroll.contentY = y
    else if (y + h > scroll.contentY + scroll.height)
      scroll.contentY = Math.min(scroll.contentHeight - scroll.height, y + h - scroll.height)
  }

  // Row geometry mirror: delegate heights are fixed constants, so the
  // Flickable can be scrolled without measuring live items.
  readonly property int rowStride: Style.space(30)
  readonly property int headerStride: Style.space(26)
  function rowY(flatIndex) {
    var y = 0
    for (var i = 0; i < flatIndex && i < flatRows.length; i++) {
      y += flatRows[i].kind === "header" ? headerStride : rowStride
    }
    return y
  }
  function rowHeight(flatIndex) {
    if (flatIndex < 0 || flatIndex >= flatRows.length) return rowStride
    return flatRows[flatIndex].kind === "header" ? headerStride : rowStride
  }

  function currentTask() {
    if (cursor < 0 || cursor >= taskIndexes.length) return null
    var row = flatRows[taskIndexes[cursor]]
    return row && row.kind === "task" ? row.task : null
  }

  function activateCursor() {
    var task = currentTask()
    if (!task) return
    if (svc) svc.completeTask(task)
  }

  function deleteCursor() {
    var task = currentTask()
    if (!task) return
    if (svc) svc.deleteTask(task)
  }

  function snoozeCursor(args) {
    var task = currentTask()
    if (!task) return
    if (svc) svc.snoozeTask(task, args)
  }

  property string editingTaskId: ""

  function beginEdit() {
    var task = currentTask()
    if (!task || !task.id) return
    editingTaskId = String(task.id)
    quickAdd.text = Model.editLineFor(task)
    quickAdd.forceActiveFocus()
    quickAdd.selectAll()
  }

  function cancelEdit() {
    editingTaskId = ""
    quickAdd.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitQuickAdd() {
    var text = String(quickAdd.text || "").trim()
    if (text === "") return
    if (!root.signedIn) return
    if (editingTaskId !== "") {
      var id = editingTaskId
      editingTaskId = ""
      quickAdd.text = ""
      if (svc) svc.submitEdit(id, text)
      return
    }
    quickAdd.text = ""
    if (svc) svc.submitQuickAdd(text)
  }

  // Due date + recurrence condensed into the one label a row gets to keep:
  // "18:30 ↻ daily". Priority is not a label — it paints the title instead.
  function metaLine(task) {
    var bits = []
    if (task.due > 0) bits.push(Model.dueLabel(Model.effectiveDue(task), Date.now()))
    var recur = Model.recurBadge(task)
    if (recur !== "") bits.push(recur)
    return bits.join(" ")
  }

  property bool helpVisible: false

  // ---- lifecycle ----------------------------------------------------------

  function open() {
    root.controller.show()
    if (svc) svc.refresh(true)
  }

  function close() {
    // Closing is not a cancel: anything still held is sent, so a click
    // followed by a close does what the click said it would.
    if (svc) svc.flushPending()
    cursor = -1
    cursorActive = false
    editingTaskId = ""
    helpVisible = false
    quickAdd.text = ""
    quickAdd.focus = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- surface ------------------------------------------------------------

  readonly property color fg: Color.popups.text
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight, Style.space(580))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: quickAdd.activeFocus
      onCloseRequested: {
        if (root.helpVisible) root.helpVisible = false
        else if (root.pendingAction && root.svc) root.svc.cancelPending()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
      }
      // Enter emits BOTH returnRequested and activateRequested; binding both
      // acted twice per press, so listen to activate (Space emits only that).
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "?") root.helpVisible = !root.helpVisible
        else if (text === "r" && root.svc) root.svc.refresh(true)
        else if (text === "a") quickAdd.forceActiveFocus()
        else if (text === "e") root.beginEdit()
        else if (text === "u" && root.svc) root.svc.cancelPending()
        else if (text === "d") root.deleteCursor()
        else if (text === "s") root.snoozeCursor(["tomorrow", "09:00"])
        else if (text === "h") root.snoozeCursor(["@+1h"])
        else if (text === "g") root.cursorToFirst()
        else if (text === "G") root.cursorToLast()
        else if (text === "p") root.togglePomo()
        else if (text === "x") root.stopPomo()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentCol
          width: scroll.width
          spacing: Style.space(10)

          // ---- header -------------------------------------------------
          Item {
            width: parent.width
            height: Math.max(headerTitle.implicitHeight, Math.max(syncButton.height, helpButton.height))

            Column {
              id: headerTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.listName !== "" ? "To Do \u00b7 " + root.listName : "To Do"
                color: root.fg
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: {
                  var bits = []
                  if (root.syncing) bits.push("syncing\u2026")
                  else if (root.cacheAgeLabel !== "") bits.push(root.cacheAgeLabel)
                  else if (root.account !== "") bits.push(root.account)
                  return bits.join(" \u00b7 ")
                }
                textFormat: Text.PlainText
                visible: !root.signedIn || text !== ""
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              id: helpButton
              anchors.right: syncButton.left
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "?"
              tooltipText: "Keyboard shortcuts  (?)"
              fontFamily: root.contentFontFamily
              foreground: root.helpVisible ? Color.accent : root.muted
              onClicked: root.helpVisible = !root.helpVisible
            }

            PanelActionButton {
              id: syncButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u21bb"
              tooltipText: root.syncing ? "Syncing\u2026" : "Sync now  (r)"
              foreground: root.syncing ? Color.accent : root.fg
              onClicked: if (root.svc) root.svc.refresh(true)
            }
          }

          // ---- status: error first; the undo window yields ---------------
          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.actionError !== ""
            text: root.actionError
            color: root.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }

          Rectangle {
            width: parent.width
            implicitHeight: undoText.implicitHeight + Style.space(12)
            visible: root.actionError === "" && root.pendingCount > 0 && root.pendingAction !== null
            radius: Style.space(4)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)

            Text {
              id: undoText
              textFormat: Text.PlainText
              anchors.centerIn: parent
              color: root.muted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              text: {
                if (!root.pendingAction) return ""
                var verb = root.pendingAction.kind === "delete" ? "deleting" : "completing"
                return "\u2713 " + verb + " \u201c" + Model.elide(root.pendingAction.title, 30)
                  + "\u201d \u00b7 u keeps it \u00b7 " + root.undoLeft + "s"
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.svc) root.svc.cancelPending()
            }
          }

          // ---- quick-add ------------------------------------------------
          TextField {
            id: quickAdd
            width: parent.width
            foreground: root.fg
            accent: root.accent
            placeholderText: !root.signedIn
              ? "sign in to add tasks"
              : (root.editingTaskId !== "" ? "editing \u2014 enter saves, esc cancels" : "add a task\u2026")
            enabled: root.signedIn
            font.pixelSize: Style.font.bodySmall
            onAccepted: root.submitQuickAdd()
            onActiveFocusChanged: if (!activeFocus && root.editingTaskId !== "") root.cancelEdit()
            Keys.onEscapePressed: {
              if (text === "") {
                root.close()
              } else if (root.editingTaskId !== "") {
                root.cancelEdit()
              } else {
                text = ""
                keyCatcher.forceActiveFocus()
              }
            }
          }

          // Live grammar preview: only while typing, never as standing chrome.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.signedIn && quickAdd.activeFocus
              && Model.previewFor(quickAdd.text, Date.now()) !== ""
            text: root.signedIn ? Model.previewFor(quickAdd.text, Date.now()) : ""
            color: root.accent
            opacity: 0.85
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ---- setup card -----------------------------------------------
          Column {
            width: parent.width
            visible: !root.signedIn
            spacing: Style.space(8)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.authRequired
                ? "Session expired \u2014 sign in again"
                : "Connect your Microsoft account"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            // Idle: one obvious action instead of terminal instructions.
            Button {
              width: parent.width
              visible: !root.signingIn && root.loginCode === ""
              text: root.authRequired ? "Sign in again" : "Sign in with Microsoft"
              bordered: true
              foreground: root.fg
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.signIn()
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: root.loginError !== ""
              text: root.loginError
              color: root.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }

            // Active: the device code, with the handoff one click away.
            Column {
              width: parent.width
              visible: root.signingIn || (root.loginCode !== "")
              spacing: Style.space(6)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Enter this code at microsoft.com/link:"
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: root.loginCode
                color: root.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                font.letterSpacing: 3
              }

              Item {
                width: parent.width
                height: copyCodeButton.height

                Button {
                  id: copyCodeButton
                  anchors.left: parent.left
                  visible: root.loginUri !== ""
                  text: "Copy code" + (root.codeCopied ? " \u2713" : "")
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  onClicked: root.copySignInCode()
                }

                Button {
                  anchors.left: copyCodeButton.right
                  anchors.leftMargin: Style.space(6)
                  visible: root.loginUri !== ""
                  text: "Open link"
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  onClicked: root.openLoginLink()
                }

                Button {
                  anchors.right: parent.right
                  text: "Cancel"
                  bordered: true
                  foreground: root.muted
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  onClicked: root.cancelSignIn()
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: root.loginExpiresLabel !== ""
                text: root.loginExpiresLabel + " \u00b7 waiting for approval\u2026"
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- empty state ----------------------------------------------
          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.signedIn && root.flatRows.length === 0
            text: "Nothing open.\nType above \u2014 @tomorrow 09:00 repeat daily works."
            color: root.muted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            padding: Style.space(4)
          }

          // ---- rows -------------------------------------------------------
          Repeater {
            model: root.flatRows

            Item {
              id: rowRoot
              required property var modelData
              required property int index

              readonly property bool isHeader: modelData.kind === "header"
              readonly property bool isMore: modelData.kind === "more"
              readonly property bool isTask: modelData.kind === "task"
              readonly property var task: isTask ? modelData.task : null

              readonly property bool isCursor: {
                if (!isTask || !root.cursorActive) return false
                return root.taskIndexes[root.cursor] === index
              }
              readonly property bool isEditing: isTask && root.editingTaskId === String(task.id)
              readonly property bool isHeld: isTask && !!
                (root.pendingIds[String(task.id)] || root.pendingDeletes[String(task.id)])

              readonly property bool overdue: isTask && task.due > 0
                && task.due * 1000 < startOfTodayMs()
              readonly property color titleColor: {
                if (overdue) return root.urgent
                if (task && task.importance === "high") return root.accent
                return root.fg
              }

              function startOfTodayMs() {
                var d = new Date()
                d.setHours(0, 0, 0, 0)
                return d.getTime()
              }

              width: parent.width
              height: isHeader ? root.headerStride : root.rowStride

              Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                visible: rowRoot.isCursor || rowRoot.isEditing || taskHover.containsMouse
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b,
                               rowRoot.isEditing ? 0.14 : ((rowRoot.isCursor || taskHover.containsMouse) ? 0.08 : 0))
              }

              // Click selects, double-click opens the edit field. Declared
              // beneath the circle so the circle keeps its own clicks.
              MouseArea {
                anchors.fill: parent
                enabled: rowRoot.isTask
                onClicked: {
                  root.cursorActive = true
                  root.syncCursorToRow(rowRoot.index)
                }
                onDoubleClicked: {
                  root.cursorActive = true
                  root.syncCursorToRow(rowRoot.index)
                  root.beginEdit()
                }
              }

              // Row-wide hover highlights and keeps the keyboard cursor in
              // sync. Accepts no buttons and sits beneath the circle's own
              // hover area, so completion belongs to the circle alone.
              MouseArea {
                id: taskHover
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                hoverEnabled: true
                enabled: rowRoot.isTask
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = false
                  root.syncCursorToRow(rowRoot.index)
                }
              }

              // Header / more rows
              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: rowRoot.isHeader
                text: (rowRoot.modelData.label + "  " + rowRoot.modelData.count).toUpperCase()
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.1
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: rowRoot.isMore
                text: "\u00b7\u00b7\u00b7 " + rowRoot.modelData.label
                color: root.muted
                opacity: 0.7
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              // Task row
              Row {
                anchors.fill: parent
                visible: rowRoot.isTask
                spacing: Style.space(9)

                // The circle is the only thing that completes a task. Small
                // and deliberate, because there is an undo window but still.
                Rectangle {
                  id: checkCircle
                  width: Style.space(15)
                  height: Style.space(15)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: rowRoot.isHeld
                    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)
                    : "transparent"
                  border.color: rowRoot.overdue ? root.urgent
                    : (circleClick.containsMouse ? root.fg : root.muted)
                  border.width: 1

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: rowRoot.isHeld
                    text: "\u2713"
                    color: root.fg
                    opacity: 0.75
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  MouseArea {
                    id: circleClick
                    anchors.fill: parent
                    anchors.margins: -Style.space(3)
                    hoverEnabled: true
                    enabled: rowRoot.isTask
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursorActive = true
                      root.syncCursorToRow(rowRoot.index)
                      root.activateCursor()
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                    - checkCircle.width - metaText.implicitWidth - parent.spacing * 2
                  text: rowRoot.isTask ? Model.elide(rowRoot.task.title, 70) : ""
                  color: rowRoot.titleColor
                  opacity: !rowRoot.isTask || rowRoot.isHeld ? 0.55
                    : (rowRoot.task.importance === "low" ? 0.65 : 1.0)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: rowRoot.isTask && rowRoot.task.importance === "high"
                  elide: Text.ElideRight
                }

                Text {
                  id: metaText
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowRoot.isTask ? root.metaLine(rowRoot.task) : ""
                  color: rowRoot.overdue ? root.urgent : root.muted
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- focus timer ------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: focusTitle.implicitHeight

              PanelSectionHeader {
                id: focusTitle
                anchors.left: parent.left
                text: "FOCUS"
                foreground: root.fg
                fontFamily: root.contentFontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.baseline: focusTitle.baseline
                text: Model.pomoStatsLabel(root.svc ? root.svc.pomoState : null).toUpperCase()
                visible: text !== ""
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.1
              }
            }

            Item {
              width: parent.width
              height: Style.space(32)

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pomoPhase === "idle"
                    ? Model.formatClock(Model.pomoPhaseSeconds("focus", root.pomoPrefs))
                    : root.pomoClock
                  color: root.pomoRunning ? root.fg : root.muted
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: root.pomoRunning
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pomoPhase === "idle"
                    ? "ready"
                    : (root.pomoPaused ? "paused" : Model.pomoPhaseLabel(root.pomoPhase).toLowerCase())
                  color: root.muted
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: root.pomoRunning ? "\u23f8" : "\u25b6"
                  tooltipText: root.pomoRunning
                    ? "Pause  (p)"
                    : (root.pomoPaused ? "Resume  (p)" : "Start focus  (p)")
                  foreground: root.fg
                  onClicked: root.togglePomo()
                }

                PanelActionButton {
                  visible: root.pomoActive
                  iconText: "\u23f9"
                  tooltipText: "Discard this block  (x)"
                  foreground: root.muted
                  hoverColor: root.urgent
                  onClicked: root.stopPomo()
                }
              }
            }
          }

          // ---- help overlay ---------------------------------------------
          // Reachable two ways on purpose: `?` for the keyboard, the header
          // button for the mouse. This is the only shortcut reference — there
          // is no footer repeating it underneath everything.
          Column {
            width: parent.width
            visible: root.helpVisible
            spacing: Style.space(3)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Repeater {
              model: [
                ["a", "focus add box"],
                ["e", "edit selected"],
                ["space / enter", "complete"],
                ["s", "snooze to tomorrow 9:00"],
                ["h", "push 1 hour"],
                ["d / del", "remove"],
                ["u", "undo last"],
                ["p", "start / pause focus"],
                ["x", "discard focus block"],
                ["g / G", "first / last row"],
                ["tab", "next panel"],
                ["?", "close this help"]
              ]

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  width: Style.space(64)
                  horizontalAlignment: Text.AlignRight
                  text: modelData[0]
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData[1]
                  color: root.muted
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  function syncCursorToRow(flatIndex) {
    for (var i = 0; i < root.taskIndexes.length; i++) {
      if (root.taskIndexes[i] === flatIndex) { root.cursor = i; return }
    }
  }
}
