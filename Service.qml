import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// State and process orchestration for omadroidctrl. Every action runs the
// bundled helper and parses its JSON; nothing here shells out directly.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  // status
  property bool refreshing: false
  property bool statusLoaded: false
  property var deps: ({adb: false, scrcpy: false, avahi: false, qrencode: false, hyprctl: false})
  property var devices: []
  property var active: null
  property var lanConnect: []
  property bool lanPairing: false
  property bool hostKey: false
  property var mirror: ({running: false})

  // pairing flow
  property bool pairing: false
  property string pairPhase: ""      // qr | pairing | paired | connected | timeout | error
  property string pairQrPath: ""
  property string pairName: ""
  property string pairCode: ""
  property string pairMessage: ""

  // one-shot actions
  property bool busy: connectProcess.running || actionProcess.running || mirrorProcess.running
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool connected: active !== null && active !== undefined
  readonly property bool mirroring: mirror && mirror.running === true
  readonly property string mirrorMode: mirroring && mirror.mode ? String(mirror.mode) : ""
  readonly property bool docked: mirrorMode === "docked"
  readonly property bool lanAvailable: Array.isArray(lanConnect) && lanConnect.length > 0
  readonly property string tailnetHost: String(setting("tailnetHost", "")).trim()
  readonly property int tailnetPort: intSetting("tailnetPort", 5555, 1024, 65535)
  readonly property bool ready: deps.adb && deps.scrcpy
  readonly property string logPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omadroidctrl/helper.log"
  readonly property string deviceLabel: {
    if (!connected) return "No phone connected"
    var model = String(active.model || "").trim()
    return model !== "" ? model : String(active.serial || "Android")
  }
  readonly property string stateText: {
    if (!statusLoaded) return "Checking…"
    if (!deps.adb) return "adb not installed"
    if (!deps.scrcpy) return "scrcpy not installed"
    if (pairing) {
      if (pairPhase === "qr") return "Scan the code with your phone"
      if (pairPhase === "pairing") return "Pairing…"
      if (pairPhase === "paired") return "Paired, connecting…"
      return "Pairing…"
    }
    if (mirroring) return docked ? "Mirroring · docked" : "Mirroring · window"
    if (connected) return "Connected · " + String(active.serial || "")
    if (lanAvailable) return "Phone found on Wi-Fi"
    if (!hostKey) return "Not paired yet"
    return "No phone found on Wi-Fi"
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    return v === true || v === "true"
  }
  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }
  function helperPath() {
    return decodeURIComponent(Qt.resolvedUrl("omadroidctrl-helper").toString().replace(/^file:\/\//, ""))
  }
  function parseJson(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }
  // Goes to the shell's journal: journalctl --user -f | grep omadroidctrl
  function logLine(message) {
    console.log("omadroidctrl: " + message)
  }
  function run(process, argv, label) {
    logLine(label + ": " + argv.slice(1).join(" "))
    process.command = argv
    process.running = true
  }

  // ------------------------------------------------------------- status

  function refresh() {
    if (statusProcess.running) return
    refreshing = true
    var argv = [helperPath(), "status", "--tailnet-port", String(tailnetPort)]
    if (tailnetHost !== "") argv.push("--tailnet-host", tailnetHost)
    run(statusProcess, argv, "status")
  }

  function applyStatus(data) {
    if (!data || typeof data !== "object") return
    deps = data.deps || deps
    devices = Array.isArray(data.devices) ? data.devices : []
    active = data.active || null
    lanConnect = data.lan && Array.isArray(data.lan.connect) ? data.lan.connect : []
    lanPairing = !!(data.lan && Array.isArray(data.lan.pairing) && data.lan.pairing.length > 0)
    hostKey = data.hostKey === true
    mirror = data.mirror && typeof data.mirror === "object" ? data.mirror : {running: false}
    statusLoaded = true
  }

  // --------------------------------------------------------------- pair

  function pair() {
    if (pairProcess.running) return
    lastError = ""
    pairing = true
    pairPhase = ""
    pairQrPath = ""
    pairMessage = ""
    run(pairProcess, [helperPath(), "pair", "--timeout", String(intSetting("pairTimeoutSec", 120, 30, 600))], "pair")
  }

  function cancelPair() {
    logLine("pair: cancelled")
    if (pairProcess.running) pairProcess.signal(15)
    pairing = false
    pairPhase = ""
    pairQrPath = ""
  }

  function handlePairEvent(line) {
    var ev = parseJson(line)
    if (!ev || !ev.event) { logLine("pair: unparsed line " + line); return }
    logLine("pair event: " + line)
    pairPhase = String(ev.event)
    if (ev.event === "qr") {
      pairQrPath = String(ev.qrPath || "")
      pairName = String(ev.name || "")
      pairCode = String(ev.code || "")
    } else if (ev.event === "connected") {
      pairMessage = "Connected to " + String(ev.serial || "")
      actionStatus = pairMessage
      pairing = false
      refresh()
      if (boolSetting("autoMirror", true)) startMirror()
    } else if (ev.event === "paired") {
      pairMessage = "Paired with " + String(ev.host || "")
    } else if (ev.event === "timeout" || ev.event === "error") {
      pairMessage = String(ev.message || ev.event)
      lastError = pairMessage
      pairing = false
    }
  }

  // ------------------------------------------------------------ connect

  function connectLan() {
    runConnect([helperPath(), "connect", "--timeout", String(intSetting("lanTimeoutSec", 15, 2, 60))], "Looking for the phone on this network…")
  }

  function connectTailnet() {
    if (tailnetHost === "") { lastError = "Set a tailnet host in settings first"; return }
    runConnect([helperPath(), "connect", "--target", tailnetHost + ":" + tailnetPort], "Connecting over the tailnet…")
  }

  function runConnect(argv, status) {
    if (connectProcess.running) return
    lastError = ""
    actionStatus = status
    run(connectProcess, argv, "connect")
  }

  function handleConnectEvent(line) {
    var ev = parseJson(line)
    if (!ev || !ev.event) { logLine("connect: unparsed line " + line); return }
    logLine("connect event: " + line)
    if (ev.event === "connected") {
      actionStatus = "Connected to " + String(ev.serial || "")
      refresh()
      if (boolSetting("autoMirror", true)) startMirror()
    } else if (ev.event === "timeout" || ev.event === "error") {
      lastError = String(ev.message || ev.event)
      actionStatus = ""
    }
  }

  function disconnect() {
    runAction([helperPath(), "disconnect"], "Disconnected")
  }

  function enableTcpip() {
    runAction([helperPath(), "tcpip", "--port", String(tailnetPort)], "Phone now listens on port " + tailnetPort + " until it reboots")
  }

  function runAction(argv, doneStatus) {
    if (actionProcess.running) return
    lastError = ""
    actionProcess.doneStatus = doneStatus
    run(actionProcess, argv, "action")
  }

  // ------------------------------------------------------------- mirror

  function mirrorArgs() {
    var mode = String(setting("mirrorMode", "Window")).toLowerCase() === "docked" ? "docked" : "window"
    var argv = [helperPath(), "mirror", "--mode", mode,
      "--align", String(setting("dockAlign", "Right")).toLowerCase(),
      "--width", String(intSetting("dockWidth", 420, 200, 1200)),
      "--max-size", String(intSetting("maxSize", 1080, 0, 2160)),
      "--bit-rate", String(intSetting("bitRateMbps", 8, 0, 40))]
    if (boolSetting("turnScreenOff", false)) argv.push("--turn-screen-off")
    if (boolSetting("stayAwake", true)) argv.push("--stay-awake")
    if (boolSetting("showTouches", false)) argv.push("--show-touches")
    if (!boolSetting("audio", true)) argv.push("--no-audio")
    var extra = String(setting("extraArgs", "")).trim()
    if (extra !== "") argv.push("--extra", extra)
    if (active && active.serial) argv.push("--serial", String(active.serial))
    return argv
  }

  function startMirror() {
    if (mirrorProcess.running) return
    lastError = ""
    actionStatus = "Starting mirror…"
    run(mirrorProcess, mirrorArgs(), "mirror")
  }

  function stopMirror() {
    // Optimistic: the Dock button must not stay enabled between stop and the next status.
    mirror = {running: false}
    runAction([helperPath(), "stop"], "Mirror stopped")
  }

  function toggleMirror() {
    if (mirroring) stopMirror(); else startMirror()
  }

  function dock() {
    runAction([helperPath(), "dock", "--align", String(setting("dockAlign", "Right")).toLowerCase(), "--width", String(intSetting("dockWidth", 420, 200, 1200))], "Docked under the bar")
  }

  function undock() {
    runAction([helperPath(), "undock"], "Popped out into its own window")
  }

  function toggleDock() {
    if (!mirroring) {
      // Nothing to move yet: start the mirror straight into docked mode.
      if (mirrorProcess.running || !connected) return
      lastError = ""
      actionStatus = "Starting docked mirror…"
      var argv = mirrorArgs()
      argv[argv.indexOf("--mode") + 1] = "docked"
      run(mirrorProcess, argv, "mirror")
      return
    }
    if (docked) undock(); else dock()
  }

  // ---------------------------------------------------------- processes

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) root.logLine("status exited " + exitCode + ": " + String(statusStderr.text || "").trim().slice(0, 300))
      var data = root.parseJson(String(statusStdout.text || ""))
      if (exitCode === 0 && data) root.applyStatus(data)
      else {
        root.statusLoaded = true
        var err = String(statusStderr.text || "").trim()
        if (data && data.error) err = String(data.error)
        if (err !== "") root.lastError = err
      }
    }
  }

  Process {
    id: pairProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.handlePairEvent(line) } }
    stderr: SplitParser { onRead: function(line) { root.logLine("pair stderr: " + line) } }
    onExited: function(exitCode) {
      root.logLine("pair exited " + exitCode)
      if (root.pairing) {
        root.pairing = false
        if (exitCode !== 0 && root.lastError === "") root.lastError = "Pairing helper exited with code " + exitCode
      }
      root.refresh()
    }
  }

  Process {
    id: connectProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.handleConnectEvent(line) } }
    stderr: SplitParser { onRead: function(line) { root.logLine("connect stderr: " + line) } }
    onExited: function(exitCode) {
      root.logLine("connect exited " + exitCode)
      if (exitCode !== 0 && root.lastError === "") root.lastError = "Connect failed"
      root.refresh()
    }
  }

  Process {
    id: actionProcess
    property string doneStatus: ""
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.logLine("action exited " + exitCode + ": " + String(actionStdout.text || "").trim().slice(0, 300))
      var data = root.parseJson(String(actionStdout.text || ""))
      if (exitCode === 0 && data && data.ok !== false) root.actionStatus = actionProcess.doneStatus
      else root.lastError = data && data.error ? String(data.error) : "Action failed"
      root.refresh()
    }
  }

  Process {
    id: mirrorProcess
    running: false
    command: []
    stdout: StdioCollector { id: mirrorStdout; waitForEnd: true }
    stderr: StdioCollector { id: mirrorStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.logLine("mirror exited " + exitCode + ": " + String(mirrorStdout.text || "").trim().slice(0, 300) + " " + String(mirrorStderr.text || "").trim().slice(0, 300))
      var data = root.parseJson(String(mirrorStdout.text || ""))
      if (exitCode === 0 && data && data.ok) root.actionStatus = data.mode === "docked" ? "Mirroring under the bar" : "Mirroring in its own window"
      else root.lastError = data && data.error ? String(data.error) : "Could not start scrcpy"
      root.refresh()
    }
  }

  Timer {
    interval: (root.panelOpen ? 5 : root.intSetting("refreshIntervalSec", 30, 5, 600)) * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    // Clear transient status lines so the hero returns to the live state.
    id: statusClear
    interval: 6000
    running: root.actionStatus !== ""
    onTriggered: root.actionStatus = ""
  }

  Component.onCompleted: refresh()
}
