import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// omadroidctrl: a phone in the bar. Click for the panel, middle-click to start
// or stop the mirror, right-click to dock it under the bar or pop it out.
Panel {
  id: root
  moduleName: "codenamekt.omadroidctrl"
  ipcTarget: "codenamekt.omadroidctrl"
  manageIpc: false

  property bool settingsOpen: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: phone.connected || phone.mirroring ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool showBadge: phone.mirroring || phone.pairing
  readonly property string phoneGlyph: "󰄜"

  readonly property var mirrorModeOptions: [
    { value: "Docked", label: "Docked under the bar" },
    { value: "Window", label: "Own window" }
  ]
  readonly property var dockAlignOptions: [
    { value: "Right", label: "Right edge" },
    { value: "Center", label: "Centered" },
    { value: "Left", label: "Left edge" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Pairing keeps running while the panel is closed: the bar badge shows it,
  // and the phone may take a while to be scanned.
  onOpenedChanged: {
    phone.panelOpen = opened
    if (opened) {
      settingsOpen = false
      panelFlick.contentY = 0
      phone.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function showSettings(open) {
    settingsOpen = open === true
    panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: phone
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function mirror(): string { phone.startMirror(); return "ok" }
    function stop(): string { phone.stopMirror(); return "ok" }
    function toggleMirror(): string { phone.toggleMirror(); return "ok" }
    function toggleWindow(): string { phone.toggleDock(); return "ok" }
    function pair(): string { root.open(); phone.pair(); return "ok" }
    function connect(): string { phone.connectLan(); return "ok" }
    function connectTailnet(): string { phone.connectTailnet(); return "ok" }
    function disconnect(): string { phone.disconnect(); return "ok" }
    function status(): string { return phone.stateText }
  }

  // ------------------------------------------------------------ bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          id: glyph
          anchors.centerIn: parent
          text: root.phoneGlyph
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
        }
        Rectangle {
          visible: root.showBadge
          width: Style.space(5)
          height: width
          radius: width / 2
          color: phone.pairing ? root.urgent : Color.accent
          anchors.right: glyph.right
          anchors.top: glyph.top
          anchors.rightMargin: -Style.space(2)
          anchors.topMargin: -Style.space(1)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) phone.toggleMirror()
      else if (buttonCode === Qt.RightButton) phone.toggleDock()
      else root.toggle()
    }
  }

  // --------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(root.settingsOpen ? settingsColumn.implicitHeight : column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: extraArgsField.activeFocus || tailnetHostField.activeFocus
      onCloseRequested: {
        if (root.settingsOpen) root.showSettings(false)
        else if (phone.pairing && phone.pairPhase === "qr") phone.cancelPair()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.settingsOpen) return
        var k = String(t).toLowerCase()
        if (k === "m") phone.toggleMirror()
        else if (k === "w") phone.toggleDock()
        else if (k === "p") { if (phone.pairing) phone.cancelPair(); else phone.pair() }
        else if (k === "c") phone.connectLan()
        else if (k === "t") phone.connectTailnet()
        else if (k === "d") phone.disconnect()
        else if (k === "r") phone.refresh()
        else if (k === "s") root.showSettings(true)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: root.settingsOpen ? settingsColumn.implicitHeight : column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // ------------------------------------------------------ main page
        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)
          visible: !root.settingsOpen

          PanelHero {
            width: parent.width
            title: phone.deviceLabel
            meta: phone.actionStatus !== "" ? phone.actionStatus : phone.stateText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: phone.connected || phone.mirroring ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.phoneGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰒓"
                tooltipText: "omadroidctrl settings  s"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showSettings(true)
              }
            }
          }

          // Errors sit right under the hero so they are never missed.
          Text {
            width: parent.width
            visible: phone.lastError !== ""
            text: phone.lastError + "  (details: " + phone.logPath + ")"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ----------------------------------------------- primary actions
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: phone.ready && !phone.pairing

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: phone.mirroring ? "Stop mirror" : "Mirror"
              iconText: phone.mirroring ? "󰄛" : "󰐊"
              tooltipText: (phone.mirroring ? "Stop scrcpy" : "Start scrcpy") + "  m"
              enabled: phone.mirroring || phone.connected
              selected: phone.mirroring
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.toggleMirror()
            }
            Button {
              width: (parent.width - Style.space(8)) / 2
              text: phone.docked ? "Pop out" : "Dock"
              iconText: phone.docked ? "󰖯" : "󰁍"
              tooltipText: (phone.docked ? "Move the mirror into its own window" : "Park the mirror under the bar") + "  w"
              enabled: phone.mirroring
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.toggleDock()
            }
          }

          // ------------------------------------------------- missing deps
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: phone.statusLoaded && !phone.ready

            PanelSectionHeader { width: parent.width; text: "Setup"; foreground: root.foreground; fontFamily: root.fontFamily }
            Text {
              width: parent.width
              text: "Install what is missing, then reopen this panel:" +
                    (phone.deps.adb ? "" : "\n  omarchy pkg add android-tools") +
                    (phone.deps.scrcpy ? "" : "\n  omarchy pkg add scrcpy") +
                    (phone.deps.avahi ? "" : "\n  omarchy pkg add avahi   (LAN discovery)") +
                    (phone.deps.qrencode ? "" : "\n  omarchy pkg add qrencode   (QR pairing)")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ------------------------------------------------------ pairing
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: phone.pairing

            PanelSectionHeader { width: parent.width; text: "Pair with QR"; foreground: root.foreground; fontFamily: root.fontFamily }

            Rectangle {
              width: Style.space(220)
              height: width
              anchors.horizontalCenter: parent.horizontalCenter
              radius: Style.cornerRadius
              color: "white"
              visible: phone.pairQrPath !== ""
              Image {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                source: phone.pairQrPath !== "" ? "file://" + phone.pairQrPath : ""
                fillMode: Image.PreserveAspectFit
                smooth: false
                cache: false
              }
            }

            Text {
              width: parent.width
              text: phone.pairPhase === "qr"
                ? "On the phone: Settings → Developer options → Wireless debugging → Pair device with QR code. Both devices must be on the same Wi-Fi. You can close this panel; the code stays valid until it expires."
                : phone.pairMessage
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Cancel"
              iconText: "󰅖"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.cancelPair()
            }
          }

          // --------------------------------------------------- connection
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: phone.ready && !phone.pairing

            PanelSectionHeader { width: parent.width; text: "Connection"; foreground: root.foreground; fontFamily: root.fontFamily }

            Button {
              width: parent.width
              leftAlign: true
              text: "Pair a phone with a QR code"
              iconText: "󰐲"
              tooltipText: "Show a QR code for the phone's wireless debugging pairing  p"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.pair()
            }
            Button {
              width: parent.width
              leftAlign: true
              text: phone.lanAvailable ? "Connect over Wi-Fi · phone found" : "Connect over Wi-Fi"
              iconText: "󰖩"
              tooltipText: "Find the phone with mDNS and adb connect  c"
              enabled: !phone.busy
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.connectLan()
            }
            Button {
              width: parent.width
              leftAlign: true
              text: phone.tailnetHost !== "" ? "Connect via tailnet · " + phone.tailnetHost : "Connect via tailnet · no host set"
              iconText: "󰦝"
              tooltipText: "adb connect to the tailnet host and port  t"
              enabled: !phone.busy && phone.tailnetHost !== ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.connectTailnet()
            }
            Button {
              width: parent.width
              leftAlign: true
              visible: phone.connected
              text: "Enable tailnet mode · port " + phone.tailnetPort
              iconText: "󰒍"
              tooltipText: "Make the phone listen on a fixed port until it reboots, so it is reachable over Tailscale"
              enabled: !phone.busy
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.enableTcpip()
            }
            Button {
              width: parent.width
              leftAlign: true
              visible: phone.connected
              text: "Disconnect"
              iconText: "󰌙"
              tooltipText: "adb disconnect  d"
              enabled: !phone.busy
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: phone.disconnect()
            }
          }

          // ------------------------------------------------------ devices
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: phone.devices.length > 1

            PanelSectionHeader { width: parent.width; text: "Devices"; foreground: root.foreground; fontFamily: root.fontFamily }
            Repeater {
              model: phone.devices
              Text {
                required property var modelData
                width: parent.width
                text: (modelData.model ? modelData.model + "  " : "") + modelData.serial + "  ·  " + modelData.state
                color: modelData.state === "device" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }
            }
          }

          Text {
            width: parent.width
            text: "m mirror · w dock/pop out · p pair · c Wi-Fi · t tailnet · d disconnect · s settings"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // -------------------------------------------------- settings page
        Column {
          id: settingsColumn
          width: panelFlick.width
          spacing: Style.space(10)
          visible: root.settingsOpen

          Row {
            width: parent.width
            spacing: Style.space(8)
            PanelActionButton {
              iconText: "󰁍"
              tooltipText: "Back  Esc"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showSettings(false)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "omadroidctrl settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          PanelSectionHeader { width: parent.width; text: "Mirror"; foreground: root.foreground; fontFamily: root.fontFamily }
          Dropdown {
            width: parent.width
            label: "Mirror opens as"
            options: root.mirrorModeOptions
            value: String(phone.setting("mirrorMode", "Window"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { root.persistSettings({ mirrorMode: value }) }
          }
          Dropdown {
            width: parent.width
            label: "Docked position"
            options: root.dockAlignOptions
            value: String(phone.setting("dockAlign", "Right"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { root.persistSettings({ dockAlign: value }) }
          }
          NumberField {
            width: parent.width
            label: "Docked width (px)"
            value: phone.intSetting("dockWidth", 420, 200, 1200)
            from: 200; to: 1200; stepSize: 20
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ dockWidth: v }) }
          }
          NumberField {
            width: parent.width
            label: "Max video size (px, 0 = native)"
            value: phone.intSetting("maxSize", 1080, 0, 2160)
            from: 0; to: 2160; stepSize: 120
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ maxSize: v }) }
          }
          NumberField {
            width: parent.width
            label: "Video bit rate (Mbps, 0 = default)"
            value: phone.intSetting("bitRateMbps", 8, 0, 40)
            from: 0; to: 40; stepSize: 1
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ bitRateMbps: v }) }
          }
          Toggle {
            width: parent.width
            label: "Turn the phone screen off"
            description: "Keeps mirroring while the phone's own display is dark."
            checked: phone.boolSetting("turnScreenOff", false)
            foreground: root.foreground; accent: Color.accent; fontFamily: root.fontFamily
            onClicked: root.persistSettings({ turnScreenOff: !phone.boolSetting("turnScreenOff", false) })
          }
          Toggle {
            width: parent.width
            label: "Keep the phone awake"
            checked: phone.boolSetting("stayAwake", true)
            foreground: root.foreground; accent: Color.accent; fontFamily: root.fontFamily
            onClicked: root.persistSettings({ stayAwake: !phone.boolSetting("stayAwake", true) })
          }
          Toggle {
            width: parent.width
            label: "Show touches"
            checked: phone.boolSetting("showTouches", false)
            foreground: root.foreground; accent: Color.accent; fontFamily: root.fontFamily
            onClicked: root.persistSettings({ showTouches: !phone.boolSetting("showTouches", false) })
          }
          Toggle {
            width: parent.width
            label: "Forward audio"
            checked: phone.boolSetting("audio", true)
            foreground: root.foreground; accent: Color.accent; fontFamily: root.fontFamily
            onClicked: root.persistSettings({ audio: !phone.boolSetting("audio", true) })
          }
          Toggle {
            width: parent.width
            label: "Start mirroring right after connecting"
            checked: phone.boolSetting("autoMirror", true)
            foreground: root.foreground; accent: Color.accent; fontFamily: root.fontFamily
            onClicked: root.persistSettings({ autoMirror: !phone.boolSetting("autoMirror", true) })
          }
          Text {
            width: parent.width
            text: "Extra scrcpy arguments"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          TextField {
            id: extraArgsField
            width: parent.width
            foreground: root.foreground
            placeholderText: "--crop=1080:1920:0:0 --no-control"
            text: String(phone.setting("extraArgs", ""))
            onEditingFinished: root.persistSettings({ extraArgs: text.trim() })
            Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
          }

          PanelSectionHeader { width: parent.width; text: "Tailnet"; foreground: root.foreground; fontFamily: root.fontFamily }
          Text {
            width: parent.width
            text: "Tailnet host (MagicDNS name or 100.x address)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          TextField {
            id: tailnetHostField
            width: parent.width
            foreground: root.foreground
            placeholderText: "pixel-9-pro"
            text: String(phone.setting("tailnetHost", ""))
            onEditingFinished: root.persistSettings({ tailnetHost: text.trim() })
            Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
          }
          NumberField {
            width: parent.width
            label: "Tailnet adb port"
            value: phone.intSetting("tailnetPort", 5555, 1024, 65535)
            from: 1024; to: 65535; stepSize: 1
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ tailnetPort: v }) }
          }

          PanelSectionHeader { width: parent.width; text: "Logs"; foreground: root.foreground; fontFamily: root.fontFamily }
          Text {
            width: parent.width
            text: "Helper log: " + phone.logPath + "\nShell log: journalctl --user -f | grep omadroidctrl"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }

          PanelSectionHeader { width: parent.width; text: "Timing"; foreground: root.foreground; fontFamily: root.fontFamily }
          NumberField {
            width: parent.width
            label: "Refresh interval (s)"
            value: phone.intSetting("refreshIntervalSec", 30, 5, 600)
            from: 5; to: 600; stepSize: 5
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ refreshIntervalSec: v }) }
          }
          NumberField {
            width: parent.width
            label: "Wi-Fi discovery timeout (s)"
            value: phone.intSetting("lanTimeoutSec", 15, 2, 60)
            from: 2; to: 60; stepSize: 1
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ lanTimeoutSec: v }) }
          }
          NumberField {
            width: parent.width
            label: "QR pairing timeout (s)"
            value: phone.intSetting("pairTimeoutSec", 120, 30, 600)
            from: 30; to: 600; stepSize: 30
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(v) { root.persistSettings({ pairTimeoutSec: v }) }
          }
        }
      }
    }
  }
}
