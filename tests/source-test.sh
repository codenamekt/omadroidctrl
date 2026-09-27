#!/usr/bin/env bash
# Source-level contracts between Panel.qml, Service.qml and the helper.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -qF -- "$2" "$ROOT/$1" || fail "$1: $3"; }

contains Panel.qml 'moduleName: "io.github.codenamekt.omadroidctrl"' "panel module name must match the manifest id"
contains Panel.qml 'ipcTarget: "io.github.codenamekt.omadroidctrl"' "ipc target must match the manifest id"
contains Panel.qml 'manageIpc: false' "panel must own its IpcHandler to expose mirror/pair/connect"
for fn in 'function mirror()' 'function stop()' 'function toggleMirror()' 'function pair()' 'function connect()' 'function disconnect()' 'function status()'; do
  contains Panel.qml "$fn" "IPC handler is missing $fn"
done
contains Panel.qml 'BarIconButton {' "bar icon must use the shared BarIconButton"
contains Panel.qml 'KeyboardPanel {' "popup must use the shared KeyboardPanel"
contains Panel.qml 'PanelKeyCatcher {' "popup must be keyboard navigable"
contains Panel.qml 'bar.foreground' "colors must come from the bar theme, not hard-coded values"
contains Panel.qml 'source: phone.pairQrPath !== "" ? "file://" + phone.pairQrPath : ""' "QR image must render the helper's PNG"
contains Panel.qml 'onEditingFinished: root.persistSettings({ tailnetHost: text.trim() })' "tailnet host must persist through updateEntryInline"
contains Panel.qml 'if (buttonCode === Qt.MiddleButton) phone.toggleMirror()' "middle click must toggle the mirror"
contains Panel.qml 'else if (buttonCode === Qt.RightButton) { root.open(); root.showSettings(true) }' "right click must open settings"
! grep -q "toggleDock\|docked" "$ROOT/Panel.qml" "$ROOT/Service.qml" || fail "docking must stay out of the v1 UI"
! grep -qE '"#[0-9a-fA-F]{6}"' "$ROOT/Panel.qml" || fail "Panel.qml hard-codes a color"

contains Service.qml 'Qt.resolvedUrl("omadroidctrl-helper")' "service must resolve the bundled helper"
for sub in '"status"' '"pair"' '"connect"' '"disconnect"' '"tcpip"' '"mirror"' '"stop"'; do
  contains Service.qml "$sub" "service never calls helper subcommand $sub"
done
contains Service.qml 'stdout: SplitParser { onRead: function(line) { root.handlePairEvent(line) } }' "pair events must stream line by line"
contains Service.qml 'if (boolSetting("autoMirror", true)) startMirror()' "connect must honour the autoMirror setting"
contains Service.qml 'pairProcess.signal(15)' "cancelling a pair must stop the helper"
contains Service.qml '"install"' "service never calls helper subcommand \"install\""
contains Panel.qml 'onClicked: phone.installDeps()' "setup section must offer to install what is missing"

# Every setting the manifest declares is read by the service or panel.
for key in $(jq -r '.barWidget.schema[].key' "$ROOT/manifest.json"); do
  grep -qF "\"$key\"" "$ROOT/Service.qml" "$ROOT/Panel.qml" || fail "setting $key is declared but never read"
done
echo "source tests passed"
