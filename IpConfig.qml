import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// IP config: toggle network adapters and switch them between DHCP and a
// static IP, in the Omarchy menu style. All NetworkManager work happens in
// the bundled `ip-config` script; this file is only the UI.
//
// List view
//   Enter / Space / click   turn the adapter off or on
//   Right / Static button   set a static IP
//   Left / DHCP button      switch to DHCP
//   Up / Down, j / k        move between adapters
//   Esc                     close
//
// Static IP prompt (digits, ".", "/" and spaces only)
//   Enter                   apply
//   Left / Right, h / l     move the cursor
//   Esc, or Left at start   back to the list
Item {
  id: root

  property var shell: null
  property var manifest: null

  // The payload may point at another backend (the demo recorder uses a mock).
  readonly property string bundledBackend: decodeURIComponent(Qt.resolvedUrl("ip-config").toString().replace(/^file:\/\//, ""))
  property string backend: bundledBackend

  property bool opened: false
  property string step: "list"          // "list" | "input"

  // Adapter rows from `ip-config list`, in a fixed order.
  property var rows: []
  property string lastListText: ""
  property bool refreshQueued: false
  // Reads are numbered so a finished action waits for a read started after it.
  property int readSeq: 0
  property int runningReadSeq: 0
  // Selection follows the device rather than the row index, so refreshes never move it.
  property string selectedDevice: ""
  // Actions in flight, by device: { method, status }. The row shows
  // the requested mode straight away instead of waiting on nmcli (a DHCP
  // lease can take a while). Each adapter runs independently.
  property var pending: ({})
  // Progress steps per device: { text, shownAt, queue }. Steps come from the
  // action's own stages and from `ip-config watch` (DHCP packets, including
  // connections NetworkManager starts itself). DHCP steps are often only
  // milliseconds apart, so each is held on screen for at least stepHold ms.
  property var steps: ({})
  readonly property int stepHold: 600
  // How long the last step lingers once nothing more is coming.
  readonly property int stepLinger: 2500
  // Ticks while open: advances steps and the lease countdown.
  property double now: Date.now()

  // Static IP prompt state.
  property string editDevice: ""
  property string inputText: ""
  property int cursorPosition: 0
  property bool caretOn: true
  readonly property var hintFields: ["IP address/mask", "Gateway", "DNS", "DNS"]
  readonly property int activeField: {
    var before = inputText.slice(0, cursorPosition)
    var words = before.split(/\s+/).filter(function(w) { return w }).length
    if (words === 0) return 0
    return Math.min(hintFields.length - 1, /\s$/.test(before) ? words : words - 1)
  }

  readonly property int selectedIndex: {
    for (var i = 0; i < rows.length; i++) if (rows[i].device === selectedDevice) return i
    return 0
  }
  readonly property var selectedRow: rows.length > 0 ? rows[selectedIndex] : null

  // Theme, shared with the Omarchy menu.
  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
  readonly property int cornerRadius: Style.cornerRadius

  // Layout, matching the Omarchy menu's metrics.
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int hintHeight: Math.round(Style.font.bodySmall * 1.6)
  property int rowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  readonly property int listHeight: rows.length * rowHeight + Math.max(0, rows.length - 1) * rowSpacing
  property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(contentMargin * 2 + headerHeight + contentSpacing
    + (step === "input" ? hintHeight : listHeight), panel.height - Style.gapsOut * 2)

  // --- Shell plugin interface ---

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    root.backend = payload.backend || root.bundledBackend

    root.opened = true
    root.showList()
    root.lastListText = ""
    root.refresh()
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ip-config")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --- Actions ---

  // Never kill a read in flight (a cut-off read returns a partial list);
  // queue another one to start when it's done instead.
  function refresh() {
    if (listProc.running) root.refreshQueued = true
    else root.startRead()
  }

  function startRead() {
    root.readSeq++
    root.runningReadSeq = root.readSeq
    listProc.running = true
  }

  function select(delta) {
    if (rows.length === 0) return
    root.selectedDevice = rows[Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))].device
  }

  // Runs `ip-config <action> <device> [args...]`. A second action on the same
  // adapter waits for the first; other adapters are unaffected.
  function run(action, device, extra) {
    if (!device || root.pending[device]) return
    if (action === "toggle" && !root.canToggle(device)) return
    var expected = root.expectedState(action, extra)
    root.setPending(device, expected)
    // The opening message is a step like any other, so it gets its time too.
    root.setSteps(device, { text: "", shownAt: 0, queue: [] })
    root.pushStep(device, expected.status)
    actionComponent.createObject(root, {
      device: device,
      command: [root.backend, action, device].concat(extra || [])
    })
  }

  // What the row should show while an action runs.
  function expectedState(action, extra) {
    var words = String((extra || [])[0] || "").trim().split(/\s+/)
    if (action === "static" && words[0].toLowerCase() === "dhcp") action = "dhcp"
    if (action === "dhcp") return { method: "auto", status: "Waiting for DHCP…" }
    if (action === "static") return { method: "manual", status: "Applying…" }
    return { status: "Working…" }
  }

  function setPending(device, state) {
    var next = ({})
    for (var k in root.pending) if (k !== device) next[k] = root.pending[k]
    if (state) next[device] = state
    root.pending = next
  }

  // Queues a progress step. An empty step ends the sequence: once the steps
  // before it have had their time, the row goes back to normal.
  function pushStep(device, text) {
    var cur = root.steps[device] || { text: "", shownAt: 0, queue: [] }
    var queue = cur.queue.slice()
    // A step arriving after the end marker (the action exited before the
    // watcher's last lines came in) continues the sequence instead.
    if (text && queue.length && !queue[queue.length - 1]) queue.pop()
    var last = queue.length ? queue[queue.length - 1] : cur.text
    if (text === last) return
    queue.push(text)
    root.setSteps(device, { text: cur.text, shownAt: cur.shownAt, queue: queue })
    root.advanceSteps()
  }

  // Shows the next queued step for each device whose current one has had its time.
  function advanceSteps() {
    var t = Date.now()
    var next = ({})
    var changed = false
    for (var dev in root.steps) {
      var st = root.steps[dev]
      var due = !st.text || t - st.shownAt >= root.stepHold
      // Hold the last step until the action's result is on screen, so the row
      // never drops back to the opening message or the old address.
      var ending = st.queue.length === 1 && !st.queue[0]
      if (due && st.queue.length && !(ending && root.pending[dev])) {
        var queue = st.queue.slice()
        var text = queue.shift()
        changed = true
        if (!text && !queue.length) continue
        st = { text: text, shownAt: t, queue: queue }
      } else if (!st.queue.length && st.text && t - st.shownAt >= root.stepLinger
                 && !root.pending[dev] && !root.isConnecting(dev)) {
        changed = true
        continue
      }
      next[dev] = st
    }
    if (changed) root.steps = next
  }

  function setSteps(device, st) {
    var next = ({})
    for (var k in root.steps) if (k !== device) next[k] = root.steps[k]
    next[device] = st
    root.steps = next
  }

  // Unplugged Ethernet has nothing to disconnect, so off/on doesn't apply.
  function canToggle(device) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].device === device) return !(rows[i].type === "ethernet" && rows[i].state === "unavailable")
    return false
  }

  function isConnecting(device) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].device === device) return rows[i].state.indexOf("connecting") === 0
    return false
  }

  // Remaining lease time: whole days, else whole hours ("3d", "11h", "<1h").
  // "exp." when the lease has run out but the address is still held.
  function leaseLeft(expiry) {
    if (!expiry) return ""
    var secs = Math.floor(expiry - root.now / 1000)
    if (secs <= 0) return "exp."
    if (secs >= 86400) return Math.floor(secs / 86400) + "d"
    return secs >= 3600 ? Math.floor(secs / 3600) + "h" : "<1h"
  }

  function markFinished(device) {
    var p = root.pending[device]
    if (!p) return
    var state = ({})
    for (var k in p) state[k] = p[k]
    // Only a read started after this point reflects the action.
    state.clearAfterRead = root.readSeq + 1
    root.setPending(device, state)
  }

  // Drops finished actions that the read numbered `seq` already reflects.
  function clearFinished(seq) {
    var next = ({})
    for (var k in root.pending) {
      var p = root.pending[k]
      if (!p.clearAfterRead || seq < p.clearAfterRead) next[k] = p
    }
    root.pending = next
  }

  function methodFor(row) {
    var p = root.pending[row.device]
    return p && p.method ? p.method : row.method
  }

  function editStatic(device) {
    if (!device) return
    root.selectedDevice = device
    root.editDevice = device
    root.inputText = ""
    root.step = "input"
    prefillProc.command = [root.backend, "prefill", device]
    prefillProc.running = true
  }

  function showList() {
    root.step = "list"
    root.inputText = ""
    keyCatcher.forceActiveFocus()
  }

  // --- Row presentation ---

  function parseRows(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      var p = lines[i].split("\t")
      out.push({ device: p[0], type: p[1], enabled: p[2] === "1", connection: p[3] || "",
                 method: p[4] || "", address: p[5] || "", state: p[6] || "",
                 expiry: parseInt(p[7], 10) || 0 })
    }
    // nmcli orders devices by state; sort so toggling never reshuffles the list.
    var typeRank = { wifi: 0, ethernet: 1 }
    out.sort(function(a, b) {
      return (typeRank[a.type] - typeRank[b.type]) || a.device.localeCompare(b.device)
    })
    return out
  }

  function iconFor(row) {
    if (row.type === "wifi") return row.enabled ? "󰤨" : "󰤮"
    return row.enabled ? "󰈀" : "󰈂"
  }

  // Subtitle: the adapter name, then its IP and/or state.
  function detailFor(row) {
    var p = root.pending[row.device]
    var st = root.steps[row.device]
    // Progress replaces the address while it runs.
    if (st && st.text) return row.device + " · " + st.text
    if (p && !st) return row.device + " · " + p.status
    var status = ""
    if (!row.enabled) status = "Off"
    else if (row.state === "unavailable") status = "No cable"
    else if (row.state.indexOf("connecting") === 0) status = "Connecting…"
    else if (!row.address) status = "Not connected"
    // Static adapters always show their configured IP, even when down.
    var ip = row.address && (row.method === "manual" || !status) ? row.address : ""
    var lease = !status && row.method === "auto" ? root.leaseLeft(row.expiry) : ""
    return [row.device, ip, lease, status].filter(function(s) { return s }).join(" · ")
  }

  // Load the adapters once up front so even the first open shows rows at once.
  Component.onCompleted: root.refresh()

  // --- Processes ---

  // DHCP progress for every adapter while the menu is open.
  Process {
    id: watchProc
    command: [root.backend, "watch"]
    running: root.opened
    stdout: SplitParser {
      onRead: function(line) {
        var parts = line.split("\t")
        if (parts[0] === "event" && parts.length === 3) root.pushStep(parts[1], parts[2])
      }
    }
  }

  Timer {
    interval: 100
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: {
      root.now = Date.now()
      root.advanceSteps()
    }
  }

  Process {
    id: listProc
    command: [root.backend, "list"]
    onExited: if (root.refreshQueued) {
      root.refreshQueued = false
      root.startRead()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.clearFinished(root.runningReadSeq)
        // Rebuilding identical rows would recreate the delegates under the pointer.
        if (text === root.lastListText) return
        root.lastListText = text
        root.rows = root.parseRows(text)
        if (!root.selectedDevice && root.rows.length > 0) root.selectedDevice = root.rows[0].device
      }
    }
  }

  // Current static settings, or the ones saved when the adapter last went to DHCP.
  Process {
    id: prefillProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = text.trim()
        if (root.step !== "input" || root.inputText || !line) return
        root.inputText = line
        ipInput.cursorPosition = line.length
      }
    }
  }

  Component {
    id: actionComponent
    Process {
      property string device: ""
      running: true
      // The backend streams "status<TAB>text" lines while the connection comes up.
      stdout: SplitParser {
        onRead: function(line) {
          var parts = line.split("\t")
          if (parts[0] === "status" && parts[1]) root.pushStep(device, parts[1])
        }
      }
      onExited: {
        // Keep showing the pending state until a list read taken after the
        // action lands; clearing it now would flash the old state first.
        root.markFinished(device)
        root.pushStep(device, "")
        root.refresh()
        destroy()
      }
    }
  }

  // nmcli returns before links settle; keep the list current while it's open.
  Timer {
    interval: 1500
    repeat: true
    running: root.opened && root.step === "list"
    onTriggered: if (!listProc.running) root.refresh()
  }

  // --- UI ---

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ip-config"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // List-view keys. The static IP prompt handles its own keys.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.step === "input") {
            ipInput.forceActiveFocus()
            return
          }
          var device = root.selectedRow ? root.selectedRow.device : ""
          switch (event.key) {
          case Qt.Key_Escape: root.dismiss(); break
          case Qt.Key_Up: case Qt.Key_K: root.select(-1); break
          case Qt.Key_Down: case Qt.Key_J: root.select(1); break
          case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: root.run("toggle", device); break
          case Qt.Key_Right: case Qt.Key_L: root.editStatic(device); break
          case Qt.Key_Left: case Qt.Key_H: root.run("dhcp", device); break
          default: return
          }
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header: the title in list view, the text field in the static IP prompt.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.step === "list" || !root.inputText
            text: root.step === "input" ? ("Static IP for " + root.editDevice + "…") : "IP config…"
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          TextInput {
            id: ipInput
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.step === "input"
            clip: true
            text: root.inputText
            color: root.foreground
            selectionColor: Util.alpha(root.foreground, 0.3)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            cursorVisible: activeFocus
            // Qt only positions a custom cursor horizontally, so it needs an explicit height.
            cursorDelegate: Rectangle {
              width: 2
              height: ipInput.cursorRectangle.height
              color: root.foreground
              visible: ipInput.activeFocus && root.caretOn
            }

            onVisibleChanged: if (visible) forceActiveFocus()
            onTextEdited: root.inputText = text
            onCursorPositionChanged: {
              root.cursorPosition = cursorPosition
              root.caretOn = true
              caretBlink.restart()
            }

            // Solid while typing, blinking once idle.
            Timer {
              id: caretBlink
              interval: 530
              repeat: true
              running: ipInput.activeFocus
              onTriggered: root.caretOn = !root.caretOn
            }

            // Only what an address line needs: digits, dots, "/" and spaces.
            validator: RegularExpressionValidator { regularExpression: /[0-9.\/ ]*/ }

            Keys.onPressed: function(event) {
              // h and l move like Left and Right, as in the list.
              var left = event.key === Qt.Key_Left || (event.key === Qt.Key_H && event.modifiers === Qt.NoModifier)
              var right = event.key === Qt.Key_L && event.modifiers === Qt.NoModifier
              // A held Left walks through the text and stops at the start; only a
              // fresh press at the start leaves.
              if (event.key === Qt.Key_Escape
                  || (left && !event.isAutoRepeat && cursorPosition === 0 && selectedText === "")) {
                root.showList()
                event.accepted = true
              } else if (left && event.key === Qt.Key_H) {
                cursorPosition = Math.max(0, cursorPosition - 1)
                event.accepted = true
              } else if (right) {
                cursorPosition = Math.min(text.length, cursorPosition + 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                var input = text.trim()
                var device = root.editDevice
                root.showList()
                if (input) root.run("static", device, [input])
                event.accepted = true
              }
            }
          }
        }

        // Static IP prompt hint; the field under the cursor is highlighted.
        Row {
          visible: root.step === "input"
          height: root.hintHeight
          spacing: Style.space(14)

          Repeater {
            model: root.hintFields
            delegate: Text {
              required property int index
              required property string modelData
              textFormat: Text.PlainText
              text: modelData
              color: root.foreground
              opacity: index === root.activeField ? 0.9 : 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

        }

        // Adapter list.
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.step === "list"

          Repeater {
            model: root.rows

            delegate: BorderSurface {
              id: row
              required property var modelData

              readonly property bool hasCursor: modelData.device === root.selectedDevice
              readonly property color textColor: hasCursor ? root.selectedText : root.foreground

              width: parent.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"
              borderSpec: hasCursor ? root.selectedBorderSpec : Border.none()

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                // Only real pointer motion moves the selection; a row appearing
                // under a still pointer must not steal it from the keyboard.
                onPositionChanged: root.selectedDevice = row.modelData.device
                onClicked: {
                  root.selectedDevice = row.modelData.device
                  root.run("toggle", row.modelData.device)
                }
              }

              Button {
                id: dhcpButton
                text: "DHCP"
                selected: root.methodFor(row.modelData) !== "manual"
                foreground: row.textColor
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.leftMargin: Border.left(root.selectedBorderSpec) + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                onClicked: {
                  root.selectedDevice = row.modelData.device
                  root.run("dhcp", row.modelData.device)
                }
              }

              Button {
                id: staticButton
                text: "Static"
                selected: root.methodFor(row.modelData) === "manual"
                foreground: row.textColor
                fontFamily: root.fontFamily
                anchors.right: parent.right
                anchors.rightMargin: Border.right(root.selectedBorderSpec) + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.editStatic(row.modelData.device)
              }

              Text {
                id: iconText
                textFormat: Text.PlainText
                text: root.iconFor(row.modelData)
                color: row.textColor
                opacity: row.modelData.enabled ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                anchors.left: dhcpButton.right
                anchors.leftMargin: Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Column {
                id: contentColumn
                anchors.left: iconText.right
                anchors.leftMargin: Style.space(6)
                anchors.right: staticButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  id: labelText
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.modelData.connection || row.modelData.device
                  color: row.textColor
                  opacity: row.modelData.enabled ? 1 : 0.58
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.detailFor(row.modelData)
                  color: root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }
  }
}
