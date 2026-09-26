#!/usr/bin/env bash
#
# A small, numbered pool of iOS simulators that parallel sessions on this
# machine share instead of each creating their own.
#
# Every session that ran tests alongside another used to `simctl create` a
# device of its own — `OH-695`, `iPhone 18 Pro (698)`, … — because two runs
# cannot share a simulator (see AGENTS.md). Nothing ever deleted them, so the
# machine collected one per issue. The pool replaces that with devices named
# `OpenHikes Pool 1`, `OpenHikes Pool 2`, … and a claim per device:
#
#   udid="$(Scripts/sim-pool.sh acquire)"   # a free device, erased and booted
#   xcodebuild test … -destination "platform=iOS Simulator,id=$udid"
#   Scripts/sim-pool.sh release             # shut it down, give it back
#
# `acquire` hands out the lowest-numbered free device, and creates one only
# when every existing one is held — never more than OPENHIKES_SIM_POOL_MAX
# (default 5), so the pool cannot grow into the hundred devices it replaces.
# Calling it again from the same owner returns the same device and renews the
# claim, which is why it is safe to run before every test command.
#
# ## Who holds a device, and when that stops being true
#
# A claim records an owner and, when there is one, the PID that has to stay
# alive for it to hold. Inside a Claude Code session the owner is the session
# id and the PID is Claude Code's own (CLAUDE_CODE_SESSION_ID, CLAUDE_PID), so a
# session that ends frees its device without having to say so. Not this
# script's `$PPID`: that is the one-shot shell the session ran the command in,
# gone the moment it returns. Outside a session the owner is the checkout's
# top-level path and there is no PID unless `--owner-pid` names one. A claim is
# stale — and the device free for the next caller — when any of these holds:
#
#   * its PID is gone, or is now a different process that reused the number
#     (the claim keeps the PID's start time and compares it);
#   * it has not been renewed for OPENHIKES_SIM_POOL_TTL_MINUTES (default 180)
#     *and* no running process names the device's UDID.
#
# A device is never handed out while a process names its UDID or
# Scripts/run-ui-tests.sh holds its device lock, claimed or not: that is a run
# already on it, and erasing under it is the failure this exists to prevent.
#
# ## Erasing
#
# A device changing hands is erased first, because what the last owner left —
# an installed build, a granted permission, a simulated location still playing
# — is exactly what makes a test pass or fail for a reason that is not the
# code. Its own owner coming back keeps its data. `--keep-data` skips the erase.
#
# Exit status:
#   0  success (acquire prints the UDID on stdout, and nothing else)
#   1  failure: no free device and the pool is at its cap, or simctl failed
#   2  usage error

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/simulator.sh
source "$script_directory/lib/simulator.sh"

pool_prefix="OpenHikes Pool"
pool_max="${OPENHIKES_SIM_POOL_MAX:-5}"
ttl_minutes="${OPENHIKES_SIM_POOL_TTL_MINUTES:-180}"
device_type="${OPENHIKES_SIM_POOL_DEVICE_TYPE:-iPhone 18 Pro}"
claim_root="${OPENHIKES_SIM_POOL_DIR:-${HOME:-/tmp}/Library/Caches/OpenHikes/sim-pool}"
# Scripts/run-ui-tests.sh's own claims, read so the pool never hands out a
# device one of its runs is on. The same default and override it uses.
ui_test_lock_root="${OPENHIKES_UI_TEST_LOCK_DIR:-${HOME:-/tmp}/Library/Caches/OpenHikes/ui-test-locks}"

usage() {
    cat <<'EOF'
Usage: Scripts/sim-pool.sh <command> [options]

Commands:
  acquire              Claim a free pool simulator, erase it if it changed
                       hands, boot it, and print its UDID
  release              Shut down and give back the device this owner holds
  status               List the pool's devices and who holds each
  adopt <name|udid>    Rename an idle iOS simulator into the pool
  prune                Delete free pool devices beyond the lowest --keep

Options:
  --owner <id>         Who the claim is for (default: the Claude Code session
                       id, else the checkout's top-level path)
  --owner-pid <pid>    A process whose exit ends the claim (default: Claude
                       Code's own PID inside a session, else none)
  --keep-data          acquire: do not erase a device that changed hands
  --keep <n>           prune: how many free devices to keep (default 2)
  -h, --help           Show this help

Environment:
  OPENHIKES_SIM_POOL_MAX           Most devices the pool creates (default 5)
  OPENHIKES_SIM_POOL_TTL_MINUTES   Idle minutes before a claim lapses (180)
  OPENHIKES_SIM_POOL_DEVICE_TYPE   Device type created (iPhone 18 Pro)
  OPENHIKES_SIM_POOL_DIR           Where claims are recorded
EOF
}

command_name=""
owner=""
owner_pid=""
keep_data=false
keep_free=2
adopt_target=""

require_value() {
    if [[ -z "${2:-}" ]]; then
        echo "$1 needs a value." >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --owner) require_value "$1" "${2:-}"; owner="$2"; shift 2 ;;
        --owner-pid)
            require_value "$1" "${2:-}"
            if ! [[ "$2" =~ ^[0-9]+$ ]] || ! kill -0 "$2" 2>/dev/null; then
                echo "--owner-pid takes the PID of a running process, not '$2'." >&2
                exit 2
            fi
            owner_pid="$2"; shift 2 ;;
        --keep-data) keep_data=true; shift ;;
        --keep)
            require_value "$1" "${2:-}"
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "--keep takes a whole number, not '$2'." >&2
                exit 2
            fi
            keep_free="$2"; shift 2 ;;
        acquire|release|status|prune)
            if [[ -n "$command_name" ]]; then echo "One command at a time." >&2; exit 2; fi
            command_name="$1"; shift ;;
        adopt)
            if [[ -n "$command_name" ]]; then echo "One command at a time." >&2; exit 2; fi
            require_value "$1" "${2:-}"
            command_name="adopt"; adopt_target="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$command_name" ]]; then
    usage >&2
    exit 2
fi
if ! [[ "$pool_max" =~ ^[1-9][0-9]*$ && "$ttl_minutes" =~ ^[0-9]+$ ]]; then
    echo "OPENHIKES_SIM_POOL_MAX must be at least 1 and OPENHIKES_SIM_POOL_TTL_MINUTES a whole number." >&2
    exit 2
fi

if [[ -z "$owner" ]]; then
    if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
        owner="$CLAUDE_CODE_SESSION_ID"
        if [[ -z "$owner_pid" ]]; then owner_pid="${CLAUDE_PID:-}"; fi
    else
        owner="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
fi

mkdir -p "$claim_root"

# MARK: The pool's devices

# `udid<TAB>state<TAB>number`, one per pool device, lowest number first.
pool_devices() {
    simulator_devices \
        | awk -F'\t' -v prefix="$pool_prefix" '
            index($3, prefix " ") == 1 {
                number = substr($3, length(prefix) + 2)
                if (number ~ /^[0-9]+$/) print $1 "\t" $2 "\t" number
            }' \
        | sort -t "$(printf '\t')" -k3,3n
}

# The lowest number no pool device is using, so a pruned gap is refilled
# before the pool grows past it.
next_free_number() {
    local numbers="$1" candidate=1
    while printf '%s\n' "$numbers" | grep -qx "$candidate"; do
        candidate=$((candidate + 1))
    done
    printf '%s\n' "$candidate"
}

# MARK: Claims

claim_file() { printf '%s/%s.claim\n' "$claim_root" "$1"; }

claim_field() {
    local file="$1" key="$2"
    sed -n "s/^$key=//p" "$file" 2>/dev/null | head -n 1
}

# When a process started, as `ps` prints it; empty for one that is gone.
process_started() {
    [[ -n "$1" ]] || return 0
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

write_claim() {
    local udid="$1"
    printf 'owner=%s\npid=%s\nstarted=%s\nclaimed=%s\n' \
        "$owner" "$owner_pid" "$(process_started "$owner_pid")" "$(date +%s)" \
        > "$(claim_file "$udid")"
}

# Whether the claim's PID is still the process that made it.
claim_pid_alive() {
    local file="$1" pid
    pid="$(claim_field "$file" pid)"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 1
    local started
    started="$(claim_field "$file" started)"
    [[ -z "$started" || "$(process_started "$pid")" == "$started" ]]
}

# Whether a running process other than this script names the UDID — an
# `xcodebuild -destination id=…`, a `simctl` call, a UI-test clone's parent.
#
# Not `pgrep -f`: every subshell of this script carries its command line, so
# `adopt <udid>` would find itself. The UDID reaches `awk` through the
# environment for the same reason — as an argument, `awk` would match itself.
process_names() {
    ps -Axo command= 2>/dev/null \
        | POOL_UDID="$1" awk 'index($0, ENVIRON["POOL_UDID"]) && !/sim-pool\.sh/ { found = 1 } END { exit !found }'
}

# Whether Scripts/run-ui-tests.sh holds the device through a live process.
ui_test_run_holds() {
    local pid
    pid="$(cat "$ui_test_lock_root/$1.lock/pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Minutes since the claim was written or renewed.
claim_age_minutes() {
    local modified
    modified="$(stat -f %m "$1" 2>/dev/null || echo 0)"
    echo $(( ($(date +%s) - modified) / 60 ))
}

# Prints `mine`, `held`, `busy` or `free` for a device. `busy` is a device in
# use with no live claim — a run that never asked the pool — and is as
# untouchable as a held one.
device_standing() {
    local udid="$1" file
    file="$(claim_file "$udid")"
    if [[ -f "$file" ]]; then
        local holder
        holder="$(claim_field "$file" owner)"
        if [[ "$holder" == "$owner" ]]; then
            echo mine
            return
        fi
        local alive=true
        if ! claim_pid_alive "$file"; then
            alive=false
        elif (( $(claim_age_minutes "$file") >= ttl_minutes )) && ! process_names "$udid"; then
            alive=false
        fi
        if [[ "$alive" == true ]]; then
            echo held
            return
        fi
    fi
    if process_names "$udid" || ui_test_run_holds "$udid"; then
        echo busy
    else
        echo free
    fi
}

# MARK: The critical section

# One `acquire` at a time across every session, so two started together cannot
# both read a device as free and both take it. `mkdir` because it is one atomic
# step; the PID inside lets a lock left by a killed run be taken over rather
# than wedge the pool.
pool_lock="$claim_root/.lock"

take_pool_lock() {
    local waited=0
    until mkdir "$pool_lock" 2>/dev/null; do
        local holder
        holder="$(cat "$pool_lock/pid" 2>/dev/null || true)"
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$pool_lock"
            continue
        fi
        # Polling the lock itself — the thing being waited on — rather than
        # sleeping a guess. A holder only ever creates one device inside it.
        if (( waited >= 1200 )); then
            echo "Timed out waiting for the pool lock held by pid ${holder:-unknown}." >&2
            exit 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" > "$pool_lock/pid"
    trap 'rm -rf "$pool_lock"' EXIT
}

release_pool_lock() {
    rm -rf "$pool_lock"
    trap - EXIT
}

# MARK: Commands

acquire() {
    take_pool_lock
    local devices chosen="" chosen_state="" changed_hands=false
    devices="$(pool_devices)"

    # Your own device first, so a second call is a renewal and not a second
    # device; then the lowest-numbered free one.
    local udid state number standing
    while IFS=$'\t' read -r udid state number; do
        [[ -n "$udid" ]] || continue
        if [[ "$(device_standing "$udid")" == mine ]]; then
            chosen="$udid"; chosen_state="$state"
            break
        fi
    done <<< "$devices"
    if [[ -z "$chosen" ]]; then
        while IFS=$'\t' read -r udid state number; do
            [[ -n "$udid" ]] || continue
            standing="$(device_standing "$udid")"
            if [[ "$standing" == free ]]; then
                chosen="$udid"; chosen_state="$state"; changed_hands=true
                break
            fi
        done <<< "$devices"
    fi

    if [[ -z "$chosen" ]]; then
        local count
        count="$(printf '%s\n' "$devices" | grep -c . || true)"
        if (( count >= pool_max )); then
            release_pool_lock
            echo "Every pool simulator is in use and the pool is at its cap of $pool_max." >&2
            status >&2
            echo "Release one (Scripts/sim-pool.sh release from its owner), wait for a run" >&2
            echo "to finish, or raise OPENHIKES_SIM_POOL_MAX." >&2
            exit 1
        fi
        local name
        name="$pool_prefix $(next_free_number "$(printf '%s\n' "$devices" | cut -f3)")"
        echo "Creating $name ($device_type)." >&2
        if ! chosen="$(xcrun simctl create "$name" "$device_type")" || [[ -z "$chosen" ]]; then
            release_pool_lock
            echo "simctl could not create '$name' as a '$device_type'." >&2
            exit 1
        fi
        chosen_state="Shutdown"
    fi

    write_claim "$chosen"
    release_pool_lock

    if [[ "$changed_hands" == true && "$keep_data" == false ]]; then
        echo "Erasing $chosen for its new owner." >&2
        if [[ "$chosen_state" != "Shutdown" ]]; then
            xcrun simctl shutdown "$chosen" >/dev/null 2>&1 || true
        fi
        xcrun simctl erase "$chosen" >&2
    fi
    # `-b` boots it if it is not up and returns once it is usable, which is the
    # boot AGENTS.md makes part of every test command. Its once-a-second
    # progress is only worth reading when the boot failed.
    local boot_log
    if ! boot_log="$(xcrun simctl bootstatus "$chosen" -b 2>&1)"; then
        printf '%s\n' "$boot_log" >&2
        echo "$chosen did not boot." >&2
        exit 1
    fi
    printf '%s\n' "$chosen"
}

release() {
    local devices released=0 udid state number
    devices="$(pool_devices)"
    while IFS=$'\t' read -r udid state number; do
        [[ -n "$udid" ]] || continue
        local file
        file="$(claim_file "$udid")"
        [[ -f "$file" && "$(claim_field "$file" owner)" == "$owner" ]] || continue
        rm -f "$file"
        if [[ "$state" != "Shutdown" ]]; then
            xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        fi
        echo "Released $pool_prefix $number ($udid)." >&2
        released=$((released + 1))
    done <<< "$devices"
    if (( released == 0 )); then
        echo "$owner holds no pool simulator." >&2
    fi
}

status() {
    local devices udid state number
    devices="$(pool_devices)"
    if [[ -z "$devices" ]]; then
        echo "The pool is empty; the first acquire creates $pool_prefix 1."
        return
    fi
    while IFS=$'\t' read -r udid state number; do
        [[ -n "$udid" ]] || continue
        local standing file detail=""
        standing="$(device_standing "$udid")"
        file="$(claim_file "$udid")"
        if [[ -f "$file" && ( "$standing" == held || "$standing" == mine ) ]]; then
            detail="  $(claim_field "$file" owner), renewed $(claim_age_minutes "$file")m ago"
        fi
        printf '%s %s  %s  %-8s %s%s\n' "$pool_prefix" "$number" "$udid" "$state" "$standing" "$detail"
    done <<< "$devices"
}

adopt() {
    take_pool_lock
    local udid state
    udid="$(resolve_simulator_udid "$adopt_target")" || { release_pool_lock; exit 1; }
    state="$(simulator_devices | awk -F'\t' -v udid="$udid" '$1 == udid { print $2 }')"
    if [[ "$state" != "Shutdown" ]] || process_names "$udid" || ui_test_run_holds "$udid"; then
        release_pool_lock
        echo "$adopt_target is $state or in use; only an idle, shut-down simulator is adopted." >&2
        exit 1
    fi
    local devices name
    devices="$(pool_devices)"
    if printf '%s\n' "$devices" | cut -f1 | grep -qx "$udid"; then
        release_pool_lock
        echo "$adopt_target is already in the pool." >&2
        return
    fi
    name="$pool_prefix $(next_free_number "$(printf '%s\n' "$devices" | cut -f3)")"
    xcrun simctl rename "$udid" "$name"
    # Its contents belong to whoever made it, so it joins as a device that
    # changes hands on its first acquire and is erased then.
    rm -f "$(claim_file "$udid")"
    release_pool_lock
    echo "Adopted $adopt_target as $name." >&2
}

prune() {
    take_pool_lock
    local devices kept=0 udid state number
    devices="$(pool_devices)"
    while IFS=$'\t' read -r udid state number; do
        [[ -n "$udid" ]] || continue
        [[ "$(device_standing "$udid")" == free ]] || continue
        if (( kept < keep_free )); then
            kept=$((kept + 1))
            continue
        fi
        if [[ "$state" != "Shutdown" ]]; then
            xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        fi
        xcrun simctl delete "$udid"
        rm -f "$(claim_file "$udid")"
        echo "Deleted $pool_prefix $number ($udid)." >&2
    done <<< "$devices"
    release_pool_lock
}

"$command_name"
