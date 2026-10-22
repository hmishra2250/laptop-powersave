#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154  # hooks are single-quoted on purpose; globals are read by the sourced script
# Unit tests for bin/powersave's workloads config, save state and restore prompt.
#
# Runs entirely in a temporary HOME with docker, systemctl, sudo, pgrep, pkill and
# sleep replaced by stubs, so nothing on the machine is stopped, started or
# changed. Usage: tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Any real command these stubs shadow leaves a trace here; the run fails if it does.
LEAK=$TMP/leak
mkdir -p "$TMP/bin"
for c in docker systemctl sudo pgrep pkill notify-send prime-select modprobe; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 99\n' "$c" "$LEAK" > "$TMP/bin/$c"
  chmod +x "$TMP/bin/$c"
done
export PATH=$TMP/bin:$PATH
export HOME=$TMP/home; mkdir -p "$HOME"
export POWERSAVE_WORKLOADS=$TMP/workloads
export LOG=$TMP/log HOOKLOG=$TMP/hooklog

# shellcheck source=../bin/powersave
. "$ROOT/bin/powersave"
[[ $STATE == "$TMP"/* ]] || { echo "STATE is not under the test dir: $STATE"; exit 1; }

# --- stubs ------------------------------------------------------------------
# docker: running containers in $TMP/running, `docker info` fails when $TMP/docker_down exists,
# `docker start` fails for names listed in $TMP/start_fails.
docker() {
  case $1 in
    ps)    cat "$TMP/running" 2>/dev/null ;;
    info)  [[ ! -e $TMP/docker_down ]] ;;
    stop)  shift; echo "docker stop $*" >> "$LOG"
           local c; for c in "$@"; do grep -vxF "$c" "$TMP/running" > "$TMP/r"; mv "$TMP/r" "$TMP/running"; done ;;
    start) shift; echo "docker start $*" >> "$LOG"
           grep -qxF "$1" "$TMP/start_fails" 2>/dev/null && return 1
           echo "$1" >> "$TMP/running" ;;
  esac
}
# systemctl [--user] is-active|start|stop UNIT; active units are files in $TMP/active
systemctl() {
  local scope=sys; [[ $1 == --user ]] && { scope=user; shift; }
  case $1 in
    is-active) [[ -e $TMP/active/$scope.$2 ]] && echo active || echo inactive ;;
    start) echo "$scope start $2" >> "$LOG"; touch "$TMP/active/$scope.$2" ;;
    stop)  echo "$scope stop $2" >> "$LOG"; rm -f "$TMP/active/$scope.$2" ;;
  esac
}
sudo() { [[ $1 == systemctl ]] && { systemctl "${@:2}"; return; }; echo "sudo $*" >> "$LOG"; }
pgrep() { return 1; }
pkill() { return 0; }
sleep() { :; }
interactive() { [[ ${INTERACTIVE:-1} == 1 ]]; }

# --- harness ----------------------------------------------------------------
PASS=0 FAIL=0
fresh() {  # reset state, stubs and config for one test
  rm -rf "$STATE" "$TMP/active" "$TMP/running" "$TMP/docker_down" "$TMP/start_fails" "$LOG" "$HOOKLOG" "$POWERSAVE_WORKLOADS"
  mkdir -p "$STATE" "$TMP/active"; : > "$TMP/running"; : > "$LOG"
}
expect() { "$@" || { echo "    expected: $*"; exit 1; }; }
has()    { grep -qF -- "$2" "$1" || { echo "    expected '$2' in $1:"; sed 's/^/      /' "$1"; exit 1; }; }
hasnt()  { ! grep -qF -- "$2" "$1" 2>/dev/null || { echo "    did not expect '$2' in $1"; exit 1; }; }
lines()  { [[ $(grep -c . "$1" 2>/dev/null) == "$2" ]] || { echo "    expected $2 lines in $1, got:"; cat "$1" 2>/dev/null; exit 1; }; }
t() {  # t NAME FUNCTION: run one test in a subshell
  local out=$TMP/out
  if ( fresh; "$2" ) > "$out" 2>&1; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); echo "FAIL $1"; sed 's/^/    /' "$out"; fi
}
config() { cat > "$POWERSAVE_WORKLOADS"; }
answer() { printf '%s\n' "$@" > "$TMP/answers"; export POWERSAVE_TTY=$TMP/answers; TTY=$TMP/answers; }
running() { printf '%s\n' "$@" >> "$TMP/running"; }
active() { local u; for u in "$@"; do touch "$TMP/active/$u"; done; }

SAMPLE='# sample
container  cctv-edge-app-1      ask   backfill   # Frigate, CCTV recorder
container  cctv-edge-go2rtc-1   ask              # go2rtc, camera stream relay
container  zoe-mailpit          auto             # Zoe dev mail catcher
container  supabase_*_zoe-auto  ask              # Zoe local Supabase stack
container  keepme               auto  keep       # always on
user-unit  cctv-edge-backfill.service  auto
user-unit  idle-keeper.service         never
user-unit  talkies.service             auto  headless
system-unit docker.service auto
system-unit bluetooth.service ask   # Bluetooth
app slack never
ask_timeout 5
ask_default yes
unattended skip
backfill_max_age_h 24
unlisted_container ask'

# --- config parsing -----------------------------------------------------------
test_parse() {
  config <<< "$SAMPLE"
  load_workloads > "$TMP/o"
  lines "$TMP/o" 0
  expect [ "$WL_SOURCE" = "$POWERSAVE_WORKLOADS" ]
  expect [ "${#WL[@]}" = 11 ]
  expect [ "$(workload_rule container cctv-edge-app-1)" = "cctv-edge-app-1|ask|backfill|Frigate, CCTV recorder" ]
  expect [ "$(workload_rule container supabase_db_zoe-auto)" = "supabase_*_zoe-auto|ask||Zoe local Supabase stack" ]
  expect [ "$(workload_rule container random)" = "random|ask||" ]          # unlisted_container ask
  expect [ "$(workload_rule user-unit talkies.service)" = "talkies.service|auto|headless|" ]
  expect [ "$(workload_rule app slack)" = "slack|never||" ]
  expect [ "$(trim "$USER_UNITS")" = "cctv-edge-backfill.service idle-keeper.service" ]
  expect [ "$(trim "$HEADLESS_USER_UNITS")" = "talkies.service" ]
  expect [ "$(trim "$SYS_UNITS")" = "docker.service bluetooth.service" ]
  expect [ "$(trim "$APPS")" = "slack" ]
  expect [ "${SET[ask_timeout]}" = 5 ]
}

test_invalid_lines() {
  config <<'EOF'
frobnicate foo bar           # unknown kind
user-unit  web-*.service auto   # glob on a unit
container  a   sometimes     # bad policy
container  b   auto  keep,shiny
container
ask_timeout soon
ask_default maybe
unattended restart
container  c   auto  keep  extra
EOF
  load_workloads > "$TMP/o"
  has "$TMP/o" "ignored unknown line: frobnicate foo bar"
  has "$TMP/o" "globs work only for containers"
  has "$TMP/o" "'sometimes' is not auto|ask|never for a - treating it as ask"
  has "$TMP/o" "ignored unknown flag 'shiny' on b"
  has "$TMP/o" "ignored line without a name"
  has "$TMP/o" "'soon' is not valid for ask_timeout - keeping 30"
  has "$TMP/o" "'maybe' is not valid for ask_default - keeping yes"
  has "$TMP/o" "ignored extra words after c: extra"
  expect [ "$(workload_rule container a)" = "a|ask||bad policy" ]
  expect [ "$(workload_rule container b)" = "b|auto|keep|" ]
  expect [ "$(workload_rule user-unit web-1.service)" = "web-1.service|auto||" ]
  expect [ "${SET[unattended]}" = restart ]
}

test_no_config_fallback() {
  USER_UNITS="u1.service" HEADLESS_USER_UNITS="h1.service" SYS_UNITS="docker.service" APPS="slack"
  load_workloads > "$TMP/o"
  expect [ "$WL_SOURCE" = "built-in defaults" ]
  expect [ "${SET[unlisted_container]}" = auto ]
  expect [ "$(workload_rule container zoe-mailpit)" = "zoe-mailpit|auto||" ]
  expect [ "$(workload_rule container cctv-edge-app-1)" = "cctv-edge-app-*|auto|backfill|Frigate, CCTV recorder" ]
  expect [ "$(workload_rule container old_frigate_1)" = "*frigate*|auto|backfill|Frigate, CCTV recorder" ]
  expect [ "$(workload_rule user-unit h1.service)" = "h1.service|auto|headless|" ]
  expect [ "$(workload_rule app slack)" = "slack|never||" ]
  expect [ "$USER_UNITS" = u1.service ]
}

# --- save -------------------------------------------------------------------
test_save_flags() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  running cctv-edge-app-1 keepme zoe-mailpit
  active user.cctv-edge-backfill.service user.talkies.service sys.docker.service
  stop_workloads > "$TMP/o"
  has "$TMP/o" "kept running (keep): keepme"
  has "$TMP/o" "coverage gap starts"
  expect [ -f "$STATE/outage_start" ]
  expect [ -f "$STATE/stopped_at" ]
  expect [ "$(cat "$TMP/running")" = keepme ]
  expect [ "$(sort "$STATE/containers" | tr '\n' ' ')" = "cctv-edge-app-1 zoe-mailpit " ]
  expect [ "$(cat "$STATE/user_units")" = cctv-edge-backfill.service ]    # talkies is headless-only
  expect [ -e "$TMP/active/user.talkies.service" ]
  expect [ "$(cat "$STATE/sys_units")" = docker.service ]
}

test_save_no_recorder_no_gap() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  running zoe-mailpit
  stop_workloads > "$TMP/o"
  expect [ ! -f "$STATE/outage_start" ]
  hasnt "$TMP/o" "coverage gap"
}

test_save_appends_and_dedupes() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  printf 'old-one\nzoe-mailpit\n' > "$STATE/containers"
  echo idle-keeper.service > "$STATE/user_units"
  running zoe-mailpit cctv-edge-go2rtc-1
  active user.cctv-edge-backfill.service
  stop_workloads >/dev/null
  expect [ "$(sort "$STATE/containers" | tr '\n' ' ')" = "cctv-edge-go2rtc-1 old-one zoe-mailpit " ]
  expect [ "$(sort "$STATE/user_units" | tr '\n' ' ')" = "cctv-edge-backfill.service idle-keeper.service " ]
}

test_dry_run_changes_nothing() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  running cctv-edge-app-1 keepme supabase_db_zoe-auto
  active user.idle-keeper.service user.talkies.service sys.bluetooth.service
  local before; before=$(ls -A "$STATE")
  preview_workloads > "$TMP/o"
  has "$TMP/o" "containers: cctv-edge-app-1 supabase_db_zoe-auto"
  has "$TMP/o" "a backfill recorder is among them"
  has "$TMP/o" "user units: idle-keeper.service"
  has "$TMP/o" "headless tier only: talkies.service"
  has "$TMP/o" "system units: bluetooth.service"
  has "$TMP/o" "kept running (keep): keepme"
  expect [ "$(ls -A "$STATE")" = "$before" ]
  lines "$LOG" 0
}

# --- restore ----------------------------------------------------------------
seed_restore() {  # state as left by a save of the SAMPLE machine
  config <<< "$SAMPLE"; load_workloads >/dev/null
  printf '%s\n' docker.service bluetooth.service > "$STATE/sys_units"
  printf '%s\n' cctv-edge-backfill.service idle-keeper.service > "$STATE/user_units"
  printf '%s\n' cctv-edge-app-1 cctv-edge-go2rtc-1 zoe-mailpit supabase_db_zoe-auto supabase_kong_zoe-auto supabase_auth_zoe-auto stray > "$STATE/containers"
}

test_restore_classify_and_yes() {
  seed_restore
  restore_workloads yes > "$TMP/o"
  has "$TMP/o" "left stopped (never): idle-keeper.service"
  has "$TMP/o" "1) bluetooth.service      Bluetooth"
  has "$TMP/o" "2) cctv-edge-app-1        Frigate, CCTV recorder"
  has "$TMP/o" "4) supabase_*_zoe-auto    Zoe local Supabase stack (3 containers)"
  has "$TMP/o" "5) stray                  (no label)"
  expect [ ! -e "$STATE/sys_units" ] && expect [ ! -e "$STATE/user_units" ] && expect [ ! -e "$STATE/containers" ]
  # system units before user units before containers
  expect [ "$(grep -n 'sys start docker.service' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'user start' "$LOG" | head -1 | cut -d: -f1)" ]
  expect [ "$(grep -n 'user start' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'docker start' "$LOG" | head -1 | cut -d: -f1)" ]
  hasnt "$LOG" "idle-keeper"
}

test_restore_no_keeps_ask_items() {
  seed_restore
  restore_workloads no > "$TMP/o"
  has "$TMP/o" "--no: leaving them stopped"
  has "$TMP/o" "still stopped: supabase_*_zoe-auto"
  has "$LOG" "docker start zoe-mailpit"
  has "$LOG" "sys start docker.service"
  hasnt "$LOG" "docker start cctv-edge-app-1"
  expect [ "$(cat "$STATE/sys_units")" = bluetooth.service ]
  expect [ "$(sort "$STATE/containers" | tr '\n' ' ')" = "cctv-edge-app-1 cctv-edge-go2rtc-1 stray supabase_auth_zoe-auto supabase_db_zoe-auto supabase_kong_zoe-auto " ]
  expect [ ! -e "$STATE/user_units" ]
  status_stopped > "$TMP/s"
  has "$TMP/s" "still stopped (restore offers them again)"
  has "$TMP/s" "containers: cctv-edge-app-1"
  # the next restore offers the same items again
  : > "$LOG"; answer "2"
  restore_workloads ask > "$TMP/o2"
  has "$TMP/o2" "2) cctv-edge-app-1"
  has "$LOG" "docker start cctv-edge-app-1"
  lines "$LOG" 1
}

pick_test() {  # pick_test EXPECTED-LOG-LINES ANSWER...
  local want=$1; shift
  seed_restore; answer "$@"
  : > "$STATE/containers"; printf '%s\n' cctv-edge-app-1 cctv-edge-go2rtc-1 > "$STATE/containers"
  rm -f "$STATE/sys_units" "$STATE/user_units"
  restore_workloads ask > "$TMP/o"
  lines "$LOG" "$want"
}
test_prompt_enter()  { pick_test 2 ""; has "$TMP/o" "(Enter = yes, 5 s)"; }
test_prompt_y()      { pick_test 2 "y"; }
test_prompt_n()      { pick_test 0 "n"; expect [ "$(grep -c . "$STATE/containers")" = 2 ]; }
test_prompt_numbers() {
  seed_restore; answer "1 3"; restore_workloads ask > "$TMP/o"
  has "$LOG" "sys start bluetooth.service"
  has "$LOG" "docker start cctv-edge-go2rtc-1"
  hasnt "$LOG" "docker start cctv-edge-app-1"
  has "$TMP/o" "still stopped: cctv-edge-app-1"
  expect [ "$(sort "$STATE/containers" | tr '\n' ' ')" = "cctv-edge-app-1 stray supabase_auth_zoe-auto supabase_db_zoe-auto supabase_kong_zoe-auto " ]
}
test_prompt_bad_then_good() {
  pick_test 1 "9" "2"
  has "$TMP/o" "'9' is not valid: answer y, n, or numbers from 1 to 2"
  has "$LOG" "docker start cctv-edge-go2rtc-1"
}
test_prompt_bad_twice() { pick_test 0 "9" "0"; has "$TMP/o" "is still not valid - restarting none"; }
test_prompt_timeout() {
  seed_restore; rm -f "$STATE/sys_units" "$STATE/user_units"
  printf '%s\n' cctv-edge-app-1 > "$STATE/containers"
  SET[ask_timeout]=1
  mkfifo "$TMP/fifo"; command sleep 4 > "$TMP/fifo" & local w=$!
  TTY=$TMP/fifo; restore_workloads ask > "$TMP/o"
  kill "$w" 2>/dev/null
  has "$TMP/o" "no answer - using the default (yes)"
  has "$LOG" "docker start cctv-edge-app-1"
}
test_prompt_default_no() {
  seed_restore; SET[ask_default]=no; answer ""
  printf '%s\n' cctv-edge-app-1 > "$STATE/containers"; rm -f "$STATE/sys_units" "$STATE/user_units"
  restore_workloads ask > "$TMP/o"
  has "$TMP/o" "[N]one"
  lines "$LOG" 0
  expect [ "$(cat "$STATE/containers")" = cctv-edge-app-1 ]
}
test_unattended_skip() {
  seed_restore; INTERACTIVE=0; restore_workloads ask > "$TMP/o"
  has "$TMP/o" "no terminal: leaving them stopped (unattended skip)"
  hasnt "$LOG" "docker start cctv-edge-app-1"
  has "$LOG" "docker start zoe-mailpit"
}
test_unattended_restart() {
  seed_restore; INTERACTIVE=0; SET[unattended]=restart; restore_workloads ask > "$TMP/o"
  has "$TMP/o" "unattended restart"
  has "$LOG" "docker start cctv-edge-app-1"
  expect [ ! -e "$STATE/containers" ]
}
test_docker_down_keeps_containers() {
  seed_restore; touch "$TMP/docker_down"; restore_workloads yes > "$TMP/o"
  has "$TMP/o" "docker is not up - containers stay recorded"
  expect [ "$(grep -c . "$STATE/containers")" = 7 ]
  hasnt "$LOG" "docker start"
}
test_failed_start_kept() {
  seed_restore; echo zoe-mailpit > "$TMP/start_fails"; restore_workloads no > "$TMP/o"
  has "$TMP/o" "failed to start (kept for the next restore): zoe-mailpit"
  has "$STATE/containers" "zoe-mailpit"
}

# --- coverage gap and hook ------------------------------------------------------
gap() {  # gap HOURS-AGO [recorder-running]
  config <<< "$SAMPLE"; load_workloads >/dev/null
  date -Iseconds -d "-$1 hours" > "$STATE/outage_start"
  date -Iseconds -d "-$1 hours" > "$STATE/stopped_at"
  [[ ${2:-} == up ]] && running cctv-edge-app-1
  POST_RESTORE_HOOK='echo "$POWERSAVE_STOPPED_AT" > "$HOOKLOG"'
}
test_gap_fresh_runs_hook() {
  gap 2 up; local start; start=$(cat "$STATE/outage_start")
  run_post_restore_hook > "$TMP/o"
  expect [ "$(cat "$HOOKLOG")" = "$start" ]
  expect [ ! -e "$STATE/outage_start" ] && expect [ ! -e "$STATE/stopped_at" ]
}
test_gap_waits_for_recorder() {
  gap 2; run_post_restore_hook > "$TMP/o"
  has "$TMP/o" "no recorder (backfill flag) is running"
  expect [ -f "$STATE/outage_start" ] && expect [ ! -e "$HOOKLOG" ]
}
test_gap_stale_declined() {
  gap 30 up; answer "n"; run_post_restore_hook > "$TMP/o"
  has "$TMP/o" "h ago). Backfill all of it? [y/N]"
  has "$TMP/o" "declined: nothing was queued"
  expect [ ! -e "$STATE/outage_start" ] && expect [ ! -e "$HOOKLOG" ]
  expect ls "$STATE"/outage_start.skipped-* "$STATE"/stopped_at.skipped-*
}
test_gap_stale_enter_is_no() {
  gap 30 up; answer ""; run_post_restore_hook > "$TMP/o"
  expect [ ! -e "$HOOKLOG" ]; has "$TMP/o" "declined"
}
test_gap_stale_approved() {
  gap 30 up; answer "y"; run_post_restore_hook > "$TMP/o"
  expect [ -s "$HOOKLOG" ] && expect [ ! -e "$STATE/outage_start" ]
}
test_gap_stale_unattended() {
  gap 30 up; INTERACTIVE=0; local before; before=$(cat "$STATE/outage_start")
  run_post_restore_hook > "$TMP/o"
  has "$TMP/o" "left as it is (no terminal to ask)"
  expect [ "$(cat "$STATE/outage_start")" = "$before" ] && expect [ ! -e "$HOOKLOG" ]
}
test_gap_stale_then_fresh_stop() {  # an old gap marker next to a new stop marker
  gap 30 up; date -Iseconds -d "-1 hours" > "$STATE/stopped_at"; answer "n"
  run_post_restore_hook > "$TMP/o"
  expect [ -s "$HOOKLOG" ]
  expect [ "$(cat "$HOOKLOG")" != "$(cat "$STATE"/outage_start.skipped-*)" ]
}
test_gap_without_hook() {
  gap 2 up; POST_RESTORE_HOOK=
  run_post_restore_hook > "$TMP/o"
  has "$TMP/o" "no POST_RESTORE_HOOK set: nothing was queued"
  expect ls "$STATE"/outage_start.skipped-*
  expect [ ! -e "$STATE/stopped_at" ]
}
test_hook_without_gap() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  date -Iseconds > "$STATE/stopped_at"; POST_RESTORE_HOOK='echo "$POWERSAVE_STOPPED_AT" > "$HOOKLOG"'
  run_post_restore_hook > "$TMP/o"
  expect [ -s "$HOOKLOG" ] && expect [ ! -e "$STATE/stopped_at" ]
}
test_hook_failure_keeps_markers() {
  gap 2 up; POST_RESTORE_HOOK='exit 3'
  run_post_restore_hook > "$TMP/o"
  has "$TMP/o" "hook failed"
  expect [ -f "$STATE/outage_start" ]
}

test_status_lists_stopped() {
  config <<< "$SAMPLE"; load_workloads >/dev/null
  echo cctv-edge-app-1 > "$STATE/containers"; echo bluetooth.service > "$STATE/sys_units"
  date -Iseconds -d '-5 hours' > "$STATE/outage_start"
  status_stopped > "$TMP/o"
  has "$TMP/o" "system units: bluetooth.service"
  has "$TMP/o" "containers: cctv-edge-app-1"
  has "$TMP/o" "(5 h ago)"
}

for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do t "${f#test_}" "$f"; done
if [[ -s $LEAK ]]; then echo "FAIL a real command was called:"; cat "$LEAK"; FAIL=$((FAIL + 1)); fi
echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
