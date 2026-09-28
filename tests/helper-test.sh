#!/usr/bin/env bash
# Exercises omadroidctrl-helper against stubbed adb, scrcpy, avahi-browse,
# qrencode and hyprctl. Real jq is required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/omadroidctrl-helper"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export XDG_STATE_HOME="$sandbox/state"
export ANDROID_USER_HOME="$sandbox/android"
export STUB_LOG="$sandbox/calls"
: >"$STUB_LOG"
mkdir -p "$ANDROID_USER_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() { jq -e "$1" <<<"$2" >/dev/null 2>&1 || fail "$3: $2"; }
assert_logged() { grep -q -- "$1" "$STUB_LOG" || fail "$2 (expected '$1' in calls: $(tr '\n' '|' <"$STUB_LOG"))"; }
assert_not_logged() { grep -q -- "$1" "$STUB_LOG" && fail "$2" || true; }

# ------------------------------------------------------------------ stubs

cat >"$sandbox/adb" <<'STUB'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >>"$STUB_LOG"
case $1 in
  devices)
    printf 'List of devices attached\n'
    [[ ${ADB_DEVICES:-} == none ]] && exit 0
    printf '192.168.1.20:41123     device product:frankel model:Pixel_9_Pro device:frankel transport_id:3\n'
    [[ ${ADB_DEVICES:-} == two ]] && printf 'ZY22ABCD               unauthorized usb:1-2 transport_id:4\n'
    exit 0 ;;
  pair)
    [[ ${ADB_PAIR_FAIL:-} == true ]] && { echo "Failed: Wrong password or connection was dropped."; exit 1; }
    echo "Successfully paired to $2 [guid=adb-XXXX]"; exit 0 ;;
  connect)
    [[ ${ADB_CONNECT_FAIL:-} == true ]] && { echo "failed to connect to '$2'"; exit 0; }
    echo "connected to $2"; exit 0 ;;
  disconnect) echo "disconnected"; exit 0 ;;
  -s) shift 2; [[ $1 == tcpip ]] && { echo "restarting in TCP mode port: $2"; exit 0; }; exit 0 ;;
esac
exit 0
STUB

cat >"$sandbox/avahi-browse" <<'STUB'
#!/usr/bin/env bash
printf 'avahi-browse %s\n' "$*" >>"$STUB_LOG"
type=${@: -1}
count=$(grep -c "avahi-browse.*$type" "$STUB_LOG")
if [[ $type == _adb-tls-pairing._tcp ]]; then
  # Advertise the pairing service only after the second poll, and under the name the helper asked for.
  if (( count >= 2 )) && [[ -n ${STUB_PAIR_NAME:-} ]]; then
    printf '=;wlan0;IPv6;%s;_adb-tls-pairing._tcp;local;Pixel.local;fe80::1;37001;\n' "$STUB_PAIR_NAME"
    printf '=;wlan0;IPv4;%s;_adb-tls-pairing._tcp;local;Pixel.local;192.168.1.20;37001;\n' "$STUB_PAIR_NAME"
  fi
elif [[ $type == _adb-tls-connect._tcp ]]; then
  if [[ ${AVAHI_NO_CONNECT:-} != true ]]; then
    printf '=;wlan0;IPv4;adb-ZY22ABCD-abc123;_adb-tls-connect._tcp;local;Pixel.local;192.168.1.20;41123;\n'
  fi
fi
exit 0
STUB

cat >"$sandbox/qrencode" <<'STUB'
#!/usr/bin/env bash
printf 'qrencode %s\n' "$*" >>"$STUB_LOG"
out=""
while [[ $# -gt 0 ]]; do case $1 in -o) out=$2; shift 2 ;; *) payload=$1; shift ;; esac; done
printf 'PNG' >"$out"
# Expose the requested service name so the avahi stub can advertise it.
printf '%s' "$payload" | sed -n 's/^WIFI:T:ADB;S:\([^;]*\);P:\([0-9]*\);;$/\1/p' >"$XDG_STATE_HOME/pair-name"
STUB

cat >"$sandbox/scrcpy" <<'STUB'
#!/usr/bin/env bash
printf 'scrcpy %s\n' "$*" >>"$STUB_LOG"
[[ ${SCRCPY_FAIL:-} == true ]] && { echo "ERROR: Could not find any ADB device" >&2; exit 1; }
sleep 30
STUB

cat >"$sandbox/hyprctl" <<'STUB'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$(tr '\n' ' ' <<<"$*")" >>"$STUB_LOG"
case $1 in
  --help) [[ ${HYPR_LEGACY:-} == true ]] || printf '    repl [code]         → Enter interactive Lua REPL mode\n'; printf '    dispatch <dispatcher> [args]\n' ;;
  repl) printf 'floating=true pinned=true\n' ;;
  monitors) printf '[{"id":0,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1.25,"reserved":[0,24,0,0],"focused":false},{"id":1,"name":"DP-3","x":2752,"y":0,"width":2560,"height":1080,"scale":1.25,"reserved":[0,24,0,0],"focused":true}]\n' ;;
  clients)
    if [[ ${HYPR_WINDOW:-} != none ]]; then
      printf '[{"address":"0xabc","title":"omadroidctrl","initialTitle":"omadroidctrl","class":"scrcpy","floating":%s,"pinned":%s,"size":[420,933],"monitor":0}]\n' "${HYPR_FLOATING:-false}" "${HYPR_PINNED:-false}"
    else printf '[]\n'; fi ;;
esac
exit 0
STUB
cat >"$sandbox/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUB_LOG"
[[ ${AVAHI_DAEMON:-} == active ]]
STUB

cat >"$sandbox/omarchy-launch-floating-terminal-with-presentation" <<'STUB'
#!/usr/bin/env bash
printf 'launch %s\n' "$*" >>"$STUB_LOG"
STUB
chmod +x "$sandbox"/{adb,avahi-browse,qrencode,scrcpy,hyprctl,systemctl,omarchy-launch-floating-terminal-with-presentation}
export PATH="$sandbox:$PATH"

# ----------------------------------------------------------------- status

out=$("$HELPER" status --tailnet-host pixel --tailnet-port 5555)
assert_jq '.schemaVersion == 1 and .deps.adb and .deps.scrcpy and .deps.avahi and .deps.qrencode and .deps.hyprctl' "$out" "status reports every dependency"
assert_jq '.devices | length == 1 and .[0].serial == "192.168.1.20:41123" and .[0].model == "Pixel 9 Pro" and .[0].wireless == true' "$out" "status parses adb devices -l"
assert_jq '.active.serial == "192.168.1.20:41123"' "$out" "status picks the ready wireless device as active"
assert_jq '.lan.connect | length == 0' "$out" "browse skips mDNS when the avahi daemon is not running"
assert_jq '.mirror.running == false' "$out" "status reports no mirror"
assert_jq '.hostKey == false' "$out" "status reports no adb host key yet"
assert_jq '.tailnet.host == "pixel" and .tailnet.port == 5555' "$out" "status echoes the tailnet target"
assert_jq '.missing == [] and .deps.avahiDaemon == false' "$out" "status reports missing packages and the avahi daemon"
[[ -f "$XDG_STATE_HOME/omadroidctrl/helper.log" ]] || fail "helper does not write its log file"
grep -q "run: status --tailnet-host pixel" "$XDG_STATE_HOME/omadroidctrl/helper.log" || fail "helper log does not record the command"
grep -q 'avahi _adb-tls-connect._tcp:' "$XDG_STATE_HOME/omadroidctrl/helper.log" && \
  fail "browse must not query mDNS when the avahi daemon is stopped"

# When the avahi daemon is running, browse() actually queries mDNS and returns
# the `_adb-tls-connect._tcp` records the stub advertises.
out=$(AVAHI_DAEMON=active "$HELPER" status)
assert_jq '.lan.connect | length == 1 and .[0].host == "192.168.1.20" and .[0].port == 41123' "$out" "status lists LAN connect services when avahi-daemon is running"
grep -q "avahi _adb-tls-connect._tcp: 1 resolved" "$XDG_STATE_HOME/omadroidctrl/helper.log" || fail "helper log does not record mDNS results when daemon is running"
out=$("$HELPER" log 5)
assert_jq '(.path | endswith("/omadroidctrl/helper.log")) and (.lines | length) <= 5 and (.lines | length) > 0' "$out" "log subcommand returns the tail as JSON"

printf 'key' >"$ANDROID_USER_HOME/adbkey"
out=$(ADB_DEVICES=two "$HELPER" status)
assert_jq '.hostKey == true and (.devices | length == 2) and .active.serial == "192.168.1.20:41123"' "$out" "unauthorized USB devices never become active"
out=$(ADB_DEVICES=none "$HELPER" status)
assert_jq '.active == null and (.devices | length == 0)' "$out" "no devices means no active device"

# ------------------------------------------------------------------- pair

# The avahi stub reads the generated service name lazily from the file the
# qrencode stub writes, so it can advertise exactly what the helper asked for.
# Full flow: make the avahi stub advertise whatever name the next run generates by reading the name file lazily.
cat >"$sandbox/avahi-browse" <<'STUB'
#!/usr/bin/env bash
printf 'avahi-browse %s\n' "$*" >>"$STUB_LOG"
type=${@: -1}
if [[ ${AVAHI_QUIET:-} == true ]]; then exit 0; fi
if [[ $type == _adb-tls-pairing._tcp ]]; then
  name=$(cat "$XDG_STATE_HOME/pair-name" 2>/dev/null || true)
  [[ -n ${AVAHI_PAIR_NAME:-} ]] && name=$AVAHI_PAIR_NAME
  count=$(grep -c "avahi-browse.*_adb-tls-pairing" "$STUB_LOG")
  if (( count >= 2 )) && [[ -n $name ]]; then
    printf '=;wlan0;IPv6;%s;_adb-tls-pairing._tcp;local;Pixel.local;fe80::1;37001;\n' "$name"
    printf '=;wlan0;IPv4;%s;_adb-tls-pairing._tcp;local;Pixel.local;192.168.1.20;37001;\n' "$name"
  fi
elif [[ $type == _adb-tls-connect._tcp ]]; then
  [[ ${AVAHI_NO_CONNECT:-} == true ]] || printf '=;wlan0;IPv4;adb-ZY22ABCD-abc123;_adb-tls-connect._tcp;local;Pixel.local;192.168.1.20;41123;\n'
fi
exit 0
STUB
quiet=$(AVAHI_DAEMON=active AVAHI_QUIET=true "$HELPER" pair --timeout 2)
first=$(head -1 <<<"$quiet")
assert_jq '.event == "qr" and (.qrPath | endswith("/omadroidctrl/pair.png")) and (.name | startswith("omadroidctrl-")) and (.code | test("^[0-9]{6}$")) and .timeout == 2' "$first" "pair emits a qr event with path, name and six-digit code"
assert_logged "qrencode -s 8 -m 2 -t PNG -o" "pair renders the QR with qrencode"
assert_jq '.event == "timeout"' "$(tail -1 <<<"$quiet")" "pair times out when nothing scans the code"
[[ ! -f "$XDG_STATE_HOME/omadroidctrl/pair.png" ]] || fail "pair timeout should remove the QR image"

: >"$STUB_LOG"
events=$(AVAHI_DAEMON=active "$HELPER" pair --timeout 10)
assert_jq 'map(.event) == ["qr","pairing","paired","connected"]' "$(jq -sc '.' <<<"$events")" "pair streams qr, pairing, paired, connected"
assert_jq '.[1].host == "192.168.1.20" and .[1].port == 37001' "$(jq -sc '.' <<<"$events")" "pair uses the IPv4 pairing service, not the IPv6 one"
assert_jq '.[3].serial == "192.168.1.20:41123"' "$(jq -sc '.' <<<"$events")" "pair connects to the phone's connect service afterwards"
code=$(jq -r 'select(.event == "qr") | .code' <<<"$events")
assert_logged "adb pair 192.168.1.20:37001 $code" "pair passes host, port and the pairing code to adb"
assert_logged "adb connect 192.168.1.20:41123" "pair runs adb connect after pairing"
grep -q "pair: using pairing service 192.168.1.20 37001 omadroidctrl-" "$XDG_STATE_HOME/omadroidctrl/helper.log" || fail "helper log does not record the chosen pairing service"

: >"$STUB_LOG"
events=$(AVAHI_DAEMON=active AVAHI_PAIR_NAME="Pixel pairing" "$HELPER" pair --timeout 10)
assert_jq 'map(.event) == ["qr","pairing","paired","connected"]' "$(jq -sc '.' <<<"$events")" "a pairing service under a different name is still used"

: >"$STUB_LOG"
events=$(AVAHI_DAEMON=active ADB_PAIR_FAIL=true "$HELPER" pair --timeout 10)
assert_jq 'map(.event) == ["qr","pairing","error"] and (.[2].message | test("adb pair failed"))' "$(jq -sc '.' <<<"$events")" "a rejected pairing code reports an error event"
assert_not_logged "adb connect" "a failed pairing must not attempt adb connect"

# ---------------------------------------------------------------- connect

: >"$STUB_LOG"
out=$(AVAHI_DAEMON=active "$HELPER" connect --timeout 5)
assert_jq '.event == "connected" and .serial == "192.168.1.20:41123"' "$out" "connect discovers the LAN service and connects"
out=$(AVAHI_DAEMON=active AVAHI_NO_CONNECT=true "$HELPER" connect --timeout 2)
assert_jq '.event == "timeout"' "$out" "connect times out without a LAN service"
: >"$STUB_LOG"
out=$("$HELPER" connect --target pixel)
assert_jq '.event == "connected" and .serial == "pixel:5555"' "$out" "connect --target defaults to port 5555"
assert_logged "adb connect pixel:5555" "connect --target calls adb connect directly"
assert_not_logged "avahi-browse" "connect --target never browses mDNS"
out=$(ADB_CONNECT_FAIL=true "$HELPER" connect --target 100.64.0.9:5555)
assert_jq '.event == "error" and (.message | test("failed"))' "$out" "a refused adb connect reports an error"

# ------------------------------------------------------ disconnect / tcpip

assert_jq '.ok == true' "$("$HELPER" disconnect)" "disconnect reports ok"
: >"$STUB_LOG"
out=$("$HELPER" tcpip --port 5555)
assert_jq '.ok == true and .port == 5555' "$out" "tcpip reports the port"
assert_logged "adb -s 192.168.1.20:41123 tcpip 5555" "tcpip targets the active device"
out=$(ADB_DEVICES=none "$HELPER" tcpip 2>/dev/null || true)
assert_jq '.ok == false' "$out" "tcpip fails cleanly without a device"

# ----------------------------------------------------------------- mirror

: >"$STUB_LOG"
out=$("$HELPER" mirror --mode docked --align right --width 420 --max-size 1080 --bit-rate 8 --stay-awake --no-audio --extra "--crop=1:2:3:4")
assert_jq '.ok == true and .mode == "docked" and .serial == "192.168.1.20:41123" and (.pid | type) == "number"' "$out" "mirror starts scrcpy docked"
assert_logged "scrcpy -s 192.168.1.20:41123 --window-title=omadroidctrl --max-size=1080 --video-bit-rate=8M --stay-awake --no-audio --window-borderless --always-on-top --window-width=420 --crop=1:2:3:4" "mirror builds the scrcpy command from its options"
assert_logged "hyprctl repl local w = hl.get_window('address:0xabc')" "docked mirror drives Hyprland through the Lua REPL"
assert_logged "hl.dsp.window.float({ window = w })" "docked mirror floats the window"
assert_logged "hl.dsp.window.pin({ window = w })" "docked mirror pins the window"
assert_logged "hl.dsp.window.resize({ x = 420, y = 933, exact = true, window = w })" "docked mirror keeps the phone aspect when resizing"
assert_logged "hl.dsp.window.move({ x = 2324, y = 32, exact = true, window = w })" "docked mirror parks the window under the bar on the window's monitor, not the focused one"
grep -q "dock: hyprctl -> floating=true pinned=true" "$XDG_STATE_HOME/omadroidctrl/helper.log" || fail "dock does not log Hyprland's reply"
status=$("$HELPER" status)
assert_jq '.mirror.running == true and .mirror.mode == "docked"' "$status" "status sees the running mirror"
again=$("$HELPER" mirror --mode docked)
assert_jq '.ok == true and .already == true' "$again" "a second mirror call is idempotent"

: >"$STUB_LOG"
out=$(HYPR_FLOATING=true HYPR_PINNED=true "$HELPER" undock)
assert_jq '.ok == true and .mode == "window"' "$out" "undock reports window mode"
assert_logged "if w.pinned then hl.dispatch(hl.dsp.window.pin({ window = w })) end" "undock unpins only when pinned"
assert_logged "if w.floating then hl.dispatch(hl.dsp.window.float({ window = w })) end" "undock tiles only when floating"
assert_jq '.mirror.mode == "window"' "$("$HELPER" status)" "status reflects the popped-out mode"
: >"$STUB_LOG"
out=$("$HELPER" dock --align center --width 600)
assert_jq '.ok == true and .mode == "docked"' "$out" "dock reports docked mode"
assert_logged "hl.dsp.window.move({ x = 1076, y = 32, exact = true, window = w })" "dock centers the window when asked"
: >"$STUB_LOG"
out=$(HYPR_LEGACY=true "$HELPER" dock --align right --width 420)
assert_jq '.ok == true' "$out" "dock works on Hyprland without the Lua REPL"
assert_logged "hyprctl --batch dispatch setfloating address:0xabc; dispatch pin address:0xabc" "legacy dock floats and pins with classic dispatchers"
assert_logged "hyprctl dispatch movewindowpixel exact 2324 32,address:0xabc" "legacy dock places the window with classic dispatchers"

assert_jq '.ok == true' "$("$HELPER" stop)" "stop reports ok"
assert_jq '.mirror.running == false' "$("$HELPER" status)" "status sees the stopped mirror"
out=$(HYPR_WINDOW=none "$HELPER" dock 2>/dev/null || true)
assert_jq '.ok == false' "$out" "dock without a window fails cleanly"

: >"$STUB_LOG"
out=$("$HELPER" mirror --mode window)
assert_jq '.ok == true and .mode == "window"' "$out" "window mode starts scrcpy"
assert_not_logged "window-borderless" "window mode does not pass docked flags"
assert_not_logged "hyprctl" "window mode leaves Hyprland alone"
"$HELPER" stop >/dev/null

out=$(SCRCPY_FAIL=true "$HELPER" mirror --mode window 2>/dev/null || true)
assert_jq '.ok == false and (.error | test("scrcpy exited"))' "$out" "a crashing scrcpy is reported with its last log line"

# --------------------------------------- mirror_pid PID-reuse hardening
#
# A security review flagged that mirror_pid() only checked `kill -0`, which is
# vulnerable to PID reuse: after our scrcpy exits the kernel can reassign the
# PID to an unrelated process, and a subsequent stop() would signal that
# unrelated process. The fix records the kernel-issued starttime (clock ticks
# since boot, /proc/<pid>/stat field 22 read via the robust `split on ")" `
# idiom) at launch and verifies it on every liveness check. cmd_stop uses
# `kill -- -$pgid` (process-group kill, kernel-enforced boundary) instead of
# pgrep -f pattern matching against scrcpy argv.
"$HELPER" mirror --mode window >/dev/null
recorded_pid=$(jq -r '.pid' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
recorded_pgid=$(jq -r '.pgid' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
recorded_starttime=$(jq -r '.starttime' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
[[ $recorded_pid =~ ^[0-9]+$ ]] || fail "mirror state must carry a numeric PID"
[[ $recorded_pgid =~ ^[0-9]+$ ]] || fail "mirror state must carry a numeric pgid"
[[ $recorded_starttime =~ ^[0-9]+$ ]] || fail "mirror state must carry starttime"
[[ $recorded_pgid == "$recorded_pid" ]] \
  || fail "pgid must equal pid because setsid made scrcpy the leader of its own process group"

# status reports the running mirror (PID matches).
assert_jq '.mirror.running and (.mirror.pid == '"$recorded_pid"')' "$("$HELPER" status)" \
  "status reports the mirror running with the recorded PID"

# The live /proc/<pid>/stat starttime must equal the recorded value. (We read
# it the same way the helper does — split on ")" — to validate the helper's
# reader, not awk's `$22` which is broken when (comm) contains special chars.)
live_starttime=$(awk -F')' 'NF >= 2 { split($2, a, " "); print a[20] }' "/proc/$recorded_pid/stat")
[[ -n $live_starttime && $live_starttime == "$recorded_starttime" ]] \
  || fail "live starttime ($live_starttime) must equal recorded starttime ($recorded_starttime) — pid_starttime helper broken"

# Simulate PID reuse: overwrite the recorded starttime with a bogus value
# and confirm mirror_pid() drops the state file instead of treating the
# stale PID as ours.
fake_starttime=999999999
jq --argjson s "$fake_starttime" '.starttime = $s' "$XDG_STATE_HOME/omadroidctrl/mirror.json" \
  >"$XDG_STATE_HOME/omadroidctrl/mirror.json.next" && mv "$XDG_STATE_HOME/omadroidctrl/mirror.json.next" "$XDG_STATE_HOME/omadroidctrl/mirror.json"
[[ ! -f $XDG_STATE_HOME/omadroidctrl/mirror.json ]] && fail "PID-reuse test setup failed"
out=$("$HELPER" status 2>&1)
[[ ! -f $XDG_STATE_HOME/omadroidctrl/mirror.json ]] \
  || fail "state file must be dropped when starttime does not match (PID reuse)"
assert_jq '.mirror.running == false' "$out" \
  "status reports mirror NOT running after starttime mismatch"

# Re-arm: launch again so the next test sees a fresh state.
"$HELPER" mirror --mode window >/dev/null
recorded_pid=$(jq -r '.pid' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
[[ $recorded_pid =~ ^[0-9]+$ ]] || fail "second mirror launch must record a fresh PID"

# stop() must cleanly tear down the mirror via process-group kill and clear
# the state file.
"$HELPER" stop >/dev/null
[[ ! -f $XDG_STATE_HOME/omadroidctrl/mirror.json ]] || fail "stop() must clear the state file"
assert_jq '.mirror.running == false' "$("$HELPER" status)" \
  "status reports mirror not running after stop"

# If mirror_pid rejects the recorded PID (e.g. starttime mismatch), cmd_stop
# must NOT signal the recorded PGID — PGID reuse is unlikely but defensive
# correctness still requires we refuse to signal a group whose owning
# process we cannot verify.
"$HELPER" mirror --mode window >/dev/null
real_pid=$(jq -r '.pid' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
real_pgid=$(jq -r '.pgid' "$XDG_STATE_HOME/omadroidctrl/mirror.json")
fake_starttime=999999999
jq --argjson s "$fake_starttime" '.starttime = $s' "$XDG_STATE_HOME/omadroidctrl/mirror.json" \
  >"$XDG_STATE_HOME/omadroidctrl/mirror.json.next" && mv "$XDG_STATE_HOME/omadroidctrl/mirror.json.next" "$XDG_STATE_HOME/omadroidctrl/mirror.json"
out=$("$HELPER" stop 2>&1)
# The state file is dropped (status already cleared it). stop() must NOT
# report any kill.
[[ ! -f $XDG_STATE_HOME/omadroidctrl/mirror.json ]] \
  || fail "stop() must clear the state file even after PID-reuse tampering"
assert_jq '.ok == true' "$out" \
  "stop() returns ok but does not signal the tampered recorded PID/PGID"
# The real scrcpy is still running (we never signalled it).
kill -0 "$real_pid" 2>/dev/null \
  || fail "stop() with tampered state must NOT have killed the real scrcpy pid=$real_pid"
kill -- -"$real_pgid" 2>/dev/null || true  # clean up the live scrcpy we left running
sleep 0.2

# ------------------------------------------------------------- missing deps

# A PATH holding only the coreutils the helper needs, so the real adb and
# friends on the developer's machine cannot leak into this check.
mkdir -p "$sandbox/minimal"
for tool in bash jq timeout awk sort cut tr head tail grep sed date sleep mkdir kill pkill cat rm mv printf setsid; do
  bin=$(command -v "$tool" 2>/dev/null) && ln -sf "$bin" "$sandbox/minimal/$tool"
done
out=$(PATH="$sandbox/minimal" "$HELPER" status 2>/dev/null || true)
assert_jq '.deps.adb == false and .deps.scrcpy == false and (.devices | length == 0)' "$out" "status degrades gracefully without adb or scrcpy"
out=$(PATH="$sandbox/minimal" "$HELPER" pair 2>/dev/null || true)
assert_jq '.ok == false and (.error | test("not installed"))' "$out" "pair fails cleanly when a tool is missing"


# ---------------------------------------------------------------- install

# Install never touches systemd — it only installs missing packages. A user
# who wants LAN discovery runs `omadroidctrl-helper enable-avahi` themselves
# (or clicks the "Open terminal to enable avahi-daemon" button in the panel).

out=$(AVAHI_DAEMON=active "$HELPER" install)
assert_jq '.ok and .launched == false' "$out" "install does nothing when everything is set up"

# install never adds `sudo systemctl enable --now avahi-daemon.service` to its
# steps array, regardless of daemon state. The plugin stays opt-in about
# avahi-daemon. We check both possible daemon states to be thorough.
for state in active inactive; do
  out=$(AVAHI_DAEMON=$state "$HELPER" install)
  assert_jq "(.steps // []) | index(\"sudo systemctl enable --now avahi-daemon.service\") | not" \
    "$out" "install (avahi-daemon $state) never enables avahi-daemon"
done

# enable-avahi is the user-facing opt-in: it opens a floating terminal pre-filled
# with `sudo systemctl enable --now avahi-daemon` so the user runs it themselves.
: >"$STUB_LOG"
out=$("$HELPER" enable-avahi)
assert_jq '.ok and .launched' "$out" "enable-avahi opens a floating terminal"
for _ in $(seq 20); do grep -q '^launch ' "$STUB_LOG" && break; sleep 0.1; done
assert_logged "launch sudo systemctl enable --now avahi-daemon" \
  "enable-avahi opens a terminal pre-filled with the systemd command"

# enable-avahi is the user-facing opt-in: it opens a floating terminal pre-filled
# with `sudo systemctl enable --now avahi-daemon` so the user runs it themselves.
: >"$STUB_LOG"
out=$("$HELPER" enable-avahi)
assert_jq '.ok and .launched' "$out" "enable-avahi opens a floating terminal"
for _ in $(seq 20); do grep -q '^launch ' "$STUB_LOG" && break; sleep 0.1; done
assert_logged "launch sudo systemctl enable --now avahi-daemon" \
  "enable-avahi opens a terminal pre-filled with the systemd command"

echo "helper tests passed"
