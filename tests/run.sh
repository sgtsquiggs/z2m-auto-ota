#!/usr/bin/env bash
# End-to-end tests: run z2m-auto-ota against tests/fake-z2m over a real broker.
#
# Usage: tests/run.sh
#
# Starts a throwaway mosquitto broker if `mosquitto` is installed. To use an
# existing broker instead, set TEST_MQTT_HOST (and TEST_MQTT_PORT). Tests use
# a unique base topic per run and clean up their retained messages, so they
# do not interfere with a real Zigbee2MQTT on the same broker.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/bin/z2m-auto-ota
work=$(mktemp -d)
own_broker=false
fake_pid=
failed=0

# Called from the EXIT trap. Older ShellCheck reports that as SC2317, newer as SC2329.
# shellcheck disable=SC2317,SC2329
cleanup() {
    if [[ -n $fake_pid ]]; then kill "$fake_pid" 2>/dev/null || true; fi
    if [[ -e $work/broker.pid ]]; then kill "$(cat "$work/broker.pid")" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

start_broker() {
    mosquitto -c "$work/mosquitto.conf" >>"$work/mosquitto.log" 2>&1 &
    echo $! >"$work/broker.pid"
    sleep 1
}

if [[ -n ${TEST_MQTT_HOST:-} ]]; then
    host=$TEST_MQTT_HOST
    port=${TEST_MQTT_PORT:-1883}
else
    command -v mosquitto >/dev/null || { echo "install mosquitto or set TEST_MQTT_HOST" >&2; exit 1; }
    host=127.0.0.1
    port=$((20000 + RANDOM % 20000))
    printf 'listener %s 127.0.0.1\nallow_anonymous true\n' "$port" >"$work/mosquitto.conf"
    own_broker=true
    start_broker
fi

# Connection options for the mosquitto_* tools used by fake-z2m and below.
mkdir -p "$work/xdg"
printf -- '-h %s\n-p %s\n' "$host" "$port" | tee "$work/xdg/mosquitto_pub" >"$work/xdg/mosquitto_sub"

# scenario <name> <expected-exit> <expected-requests> [script args...]
#
# Before calling, write the fake device state to $state and any extra config
# lines to $state/extra.conf.
scenario() {
    local name=$1 want_exit=$2 want_requests=$3
    shift 3
    local base="z2m-auto-ota-test/$$/$name" got_exit=0

    XDG_CONFIG_HOME=$work/xdg "$root/tests/fake-z2m" "$base" "$state" &
    fake_pid=$!
    sleep 1 # let fake-z2m publish and subscribe

    {
        echo "Z2M_MQTT_HOST=$host"
        echo "Z2M_MQTT_PORT=$port"
        echo "Z2M_BASE_TOPIC=$base"
        echo "OTA_ACTIVITY_LISTEN=2"
        cat "$state/extra.conf" 2>/dev/null || true
    } >"$state/test.conf"
    "$script" --config "$state/test.conf" "$@" >"$state/out.log" 2>&1 || got_exit=$?

    kill "$fake_pid" 2>/dev/null || true
    wait "$fake_pid" 2>/dev/null || true
    fake_pid=
    XDG_CONFIG_HOME=$work/xdg mosquitto_pub -r -n -t "$base/bridge/state"
    XDG_CONFIG_HOME=$work/xdg mosquitto_pub -r -n -t "$base/bridge/devices"

    local got_requests problems=()
    got_requests=$(cat "$state/requests" 2>/dev/null || true)
    [[ $got_exit == "$want_exit" ]] || problems+=("exit status $got_exit, expected $want_exit")
    [[ $got_requests == "$want_requests" ]] ||
        problems+=("requests differ:"$'\n'"$(diff <(echo "$want_requests") <(echo "$got_requests") || true)")
    local pattern
    for pattern in "${EXPECT_LOG[@]}"; do
        grep -qF -- "$pattern" "$state/out.log" || problems+=("log is missing: $pattern")
    done

    if ((${#problems[@]})); then
        echo "FAIL $name"
        printf '  %s\n' "${problems[@]}"
        echo "  --- script output ---"
        sed 's/^/  /' "$state/out.log"
        failed=1
    else
        echo "ok   $name"
    fi
}

new_state() {
    state=$work/$1
    mkdir -p "$state/pending" "$state/fail" "$state/hang" "$state/busy" "$state/sparse"
    EXPECT_LOG=()
}

# --- A full run: multi-step update, a failure, an exclusion, and an update
# that never finishes, which must end the run before the next device.
new_state full-run
echo 2 >"$state/pending/0x00000000000000a2"
echo 1 >"$state/pending/0x00000000000000a3"
touch "$state/fail/0x00000000000000a3"
echo 1 >"$state/pending/0x00000000000000a4"
touch "$state/hang/0x00000000000000a4"
echo 1 >"$state/pending/0x00000000000000a5"
printf 'OTA_EXCLUDE=Excluded Bulb\nOTA_UPDATE_TIMEOUT=3\n' >"$state/extra.conf"
EXPECT_LOG=(
    "Up To Date Bulb: up to date"
    "Two Step Bulb: updated 1.98.0 (file version 998) -> 1.99.0 (file version 999)"
    "Two Step Bulb: updated 1.99.0 (file version 999) -> 1.100.0 (file version 1000)"
    "Failing Bulb: update failed: Update of 0x00000000000000a3 failed (Timeout)"
    "Hanging Bulb: update did not finish within 3s"
    "finished: 2 update(s) installed, 2 failure(s)"
)
scenario full-run 1 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2
device/ota_update/update 0x00000000000000a2
device/ota_update/check 0x00000000000000a2
device/ota_update/update 0x00000000000000a2
device/ota_update/check 0x00000000000000a2
device/ota_update/check 0x00000000000000a3
device/ota_update/update 0x00000000000000a3
device/ota_update/check 0x00000000000000a4
device/ota_update/update 0x00000000000000a4"

# --- Dry run: checks every eligible device, installs nothing.
new_state dry-run
echo 1 >"$state/pending/0x00000000000000a2"
echo 1 >"$state/pending/0x00000000000000a5"
EXPECT_LOG=(
    "Two Step Bulb: update available (dry run, not installing)"
    "After Hang Bulb: update available (dry run, not installing)"
)
scenario dry-run 0 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2
device/ota_update/check 0x00000000000000a3
device/ota_update/check 0x00000000000000a4
device/ota_update/check 0x00000000000000a5
device/ota_update/check 0x00000000000000b2" --dry-run

# --- OTA_MAX_STEPS caps updates per device; battery devices opt in;
# exclusions match names or addresses and ignore surrounding spaces.
new_state max-steps
EXPECT_LOG=("Failing Bulb: excluded, skipping" "Excluded Bulb: excluded, skipping")
echo 3 >"$state/pending/0x00000000000000a2"
printf 'OTA_MAX_STEPS=1\nOTA_INCLUDE_BATTERY=true\nOTA_EXCLUDE=0x00000000000000a3, 0x00000000000000a4,0x00000000000000a5 ,Excluded Bulb\n' >"$state/extra.conf"
scenario max-steps 0 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2
device/ota_update/update 0x00000000000000a2
device/ota_update/check 0x00000000000000b1"

# --- An update already running (e.g. started from the Z2M UI) ends the run,
# so no second update starts alongside it.
new_state already-updating
touch "$state/busy/0x00000000000000a2"
echo 1 >"$state/pending/0x00000000000000a3"
EXPECT_LOG=("Two Step Bulb: an update is already in progress; ending this run")
scenario already-updating 0 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2"

# --- Update replies with missing version fields are still logged sensibly.
new_state sparse-reply
echo 1 >"$state/pending/0x00000000000000a2"
touch "$state/sparse/0x00000000000000a2"
EXPECT_LOG=("Two Step Bulb: updated 1.101.5 -> unknown version")
scenario sparse-reply 0 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2
device/ota_update/update 0x00000000000000a2
device/ota_update/check 0x00000000000000a2
device/ota_update/check 0x00000000000000a3
device/ota_update/check 0x00000000000000a4
device/ota_update/check 0x00000000000000a5
device/ota_update/check 0x00000000000000b2"

# --- A zero-length window starts nothing.
new_state zero-window
echo 1 >"$state/pending/0x00000000000000a2"
echo 'OTA_WINDOW=0' >"$state/extra.conf"
EXPECT_LOG=("update window (0s) has ended")
scenario zero-window 0 ""

# --- The window is checked again just before an update: one that ends during
# the check or the listen starts nothing.
new_state window-ends-before-update
echo 1 >"$state/pending/0x00000000000000a1"
printf 'OTA_WINDOW=2\nOTA_ACTIVITY_LISTEN=4\n' >"$state/extra.conf"
EXPECT_LOG=("update window (2s) has ended")
scenario window-ends-before-update 0 "device/ota_update/check 0x00000000000000a1"

# --- An update started elsewhere, on a device later in the list, is noticed
# from its progress reports before anything else starts.
new_state busy-elsewhere
echo 1 >"$state/pending/0x00000000000000a2"
touch "$state/busy/0x00000000000000a5"
EXPECT_LOG=("an update is already running on After Hang Bulb; ending this run")
scenario busy-elsewhere 0 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2"

# --- A broker restart while waiting for an update ends the run promptly
# instead of waiting out OTA_UPDATE_TIMEOUT. Needs a broker of our own.
if [[ $own_broker == true ]]; then
    new_state broker-restart
    echo 1 >"$state/pending/0x00000000000000a4"
    touch "$state/hang/0x00000000000000a4"
    echo 'OTA_UPDATE_TIMEOUT=30' >"$state/extra.conf"
    EXPECT_LOG=("Hanging Bulb: lost contact with the MQTT broker" "finished: 0 update(s) installed, 1 failure(s)")
    (
        for _ in $(seq 100); do
            if grep -qxF "device/ota_update/update 0x00000000000000a4" "$state/requests" 2>/dev/null; then
                sleep 1
                kill "$(cat "$work/broker.pid")"
                sleep 1
                start_broker
                exit
            fi
            sleep 0.2
        done
    ) &
    scenario broker-restart 1 "device/ota_update/check 0x00000000000000a1
device/ota_update/check 0x00000000000000a2
device/ota_update/check 0x00000000000000a3
device/ota_update/check 0x00000000000000a4
device/ota_update/update 0x00000000000000a4"
    wait
else
    echo "skip broker-restart (needs a broker started by this script)"
fi

# --- Bad config is rejected before connecting.
new_state bad-config
printf 'OTA_MAX_STEPS=3  # an inline comment is part of the value\n' >"$state/extra.conf"
EXPECT_LOG=("OTA_MAX_STEPS must be a whole number, got '3  # an inline comment is part of the value'")
scenario bad-config 2 ""

exit "$failed"
