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
// Static IP prompt
//   Enter                   apply ("dhcp" switches back to DHCP)
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
  // Selection follows the device rather than the row index, so refreshes never move it.
  property string selectedDevice: ""
  // Devices with an action in flight; each adapter runs independently.
  property var busyDevices: ({})

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

  function refresh() {
    listProc.running = false
    listProc.running = true
  }

  function select(delta) {
    if (rows.length === 0) return
    root.selectedDevice = rows[Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))].device
  }

  // Runs `ip-config <action> <device> [args...]`. A second action on the same
  // adapter waits for the first; other adapters are unaffected.
  function run(action, device, extra) {
    if (!device || root.busyDevices[device]) return
    root.setBusy(device, true)
    actionComponent.createObject(root, {
      device: device,
      command: [root.backend, action, device].concat(extra || [])
    })
  }

  function setBusy(device, busy) {
    var next = ({})
    for (var k in root.busyDevices) if (k !== device) next[k] = true
    if (busy) next[device] = true
    root.busyDevices = next
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
                 method: p[4] || "", address: p[5] || "", state: p[6] || "" })
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
    if (root.busyDevices[row.device]) return row.device + " · Working…"
    var status = ""
    if (!row.enabled) status = "Off"
    else if (row.state === "unavailable") status = "No cable"
    else if (row.state.indexOf("connecting") === 0) status = "Connecting…"
    else if (!row.address) status = "Not connected"
    // Static adapters always show their configured IP, even when down.
    var ip = row.address && (row.method === "manual" || !status) ? row.address : ""
    return [row.device, ip, status].filter(function(s) { return s }).join(" · ")
  }

  // --- Processes ---

  Process {
    id: listProc
    command: [root.backend, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
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
      onExited: {
        root.setBusy(device, false)
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

            Keys.onPressed: function(event) {
              // A held Left walks through the text and stops at the start; only a
              // fresh press at the start leaves.
              var leaveLeft = event.key === Qt.Key_Left && !event.isAutoRepeat
                && cursorPosition === 0 && selectedText === ""
              if (event.key === Qt.Key_Escape || leaveLeft) {
                root.showList()
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

          Text {
            textFormat: Text.PlainText
            text: "·  or 'dhcp'"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
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
                selected: row.modelData.method !== "manual"
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
                selected: row.modelData.method === "manual"
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
