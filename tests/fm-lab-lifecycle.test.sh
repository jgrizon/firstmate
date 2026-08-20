#!/usr/bin/env bash
# Behavior tests for Firstmate lab (repo-less) tasks.
#
# Lab tasks (kind=lab) use an isolated plain directory at data/<id>/lab/ rather
# than a git worktree. They deliver a report at data/<id>/report.md and retire
# the working directory to data/.labs-retired/<id>/ on teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-lab-lifecycle)

make_lab_env() {  # <name> -> sets up home, state, data, config, fakebin
  local name=$1 home fakebin fakedir
  home="$TMP_ROOT/$name/home"
  fakebin="$TMP_ROOT/$name/bin"
  fakedir="$TMP_ROOT/$name/fake"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin" "$fakedir"

  printf 'claude' > "$fakedir/command"
  printf 'claude' > "$fakedir/becomes"
  : > "$fakedir/windows"
  : > "$fakedir/cwd"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D="$FM_FAKE_DIR"
case "${1:-}" in
  new-window)
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) printf '%s\n' "$2" >> "$D/windows"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -s "$D/cwd" ]; then
            cat "$D/cwd"; printf '\n'; exit 0
          fi
          pwd
          exit 0
          ;;
      esac
    done
    printf '1\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window|kill-pane|set-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"

  # Fake treehouse: records calls to treehouse.log
  cat > "$fakebin/treehouse" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$home/treehouse.log"
exit 0
SH
  chmod +x "$fakebin/treehouse"

  printf '%s|%s|%s' "$home" "$fakebin" "$fakedir"
}

run_spawn() {
  local home=$1 fakebin=$2 fakedir=$3
  shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_DIR="$fakedir" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_control() {
  local home=$1 fakebin=$2 fakedir=$3
  shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_DIR="$fakedir" \
    FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$CONTROL" "$@" 2>&1
}

run_teardown() {
  local home=$1 fakebin=$2 fakedir=$3
  shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_DIR="$fakedir" \
    FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

test_lab_flag_refusal_combinations() {
  local rec home fakebin fakedir out status
  rec=$(make_lab_env flag-refusals)
  IFS='|' read -r home fakebin fakedir <<EOF
$rec
EOF

  # 1. Positional argument with repo
  mkdir -p "$home/data/lab-pos"
  printf 'brief\n' > "$home/data/lab-pos/brief.md"
  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-pos projects/some-repo --lab)
  status=$?
  expect_code 1 "$status" "lab with repo positional must exit 1"
  assert_contains "$out" "--lab takes the task id only; a repo-less task has no project positional" \
    "refusal did not explain project positional rejection"

  # 2. Mutually exclusive flags
  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-scout --lab --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "lab with --scout should fail"

  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-sm --lab --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "lab with --secondmate should fail"

  # 3. Delivery flags
  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-mode --lab --mode direct-PR)
  status=$?
  expect_code 1 "$status" "lab with --mode must exit 1"
  assert_contains "$out" "--mode applies only to ship spawns" "lab with --mode did not refuse with proper message"

  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-yolo --lab --yolo on)
  status=$?
  expect_code 1 "$status" "lab with --yolo must exit 1"
  assert_contains "$out" "--yolo applies only to ship spawns" "lab with --yolo did not refuse with proper message"

  # 4. Backend orca
  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-orca --lab --backend orca)
  status=$?
  expect_code 1 "$status" "lab with --backend orca must exit 1"
  assert_contains "$out" "backend=orca does not support --lab spawns" "lab with backend=orca did not refuse properly"

  # 5. Batch pair
  out=$(run_spawn "$home" "$fakebin" "$fakedir" lab-batch-1=proj1 lab-batch-2=proj2 --lab)
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch with --lab should exit non-zero"
  assert_contains "$out" "batch dispatch does not support --lab" "batch dispatch with --lab did not refuse properly"

  pass "fm-spawn --lab: invalid flag and positional combinations are strictly refused"
}

test_lab_spawn_and_lifecycle() {
  local rec home fakebin fakedir out status id meta lab_dir retired_dir brief
  rec=$(make_lab_env lab-e2e)
  IFS='|' read -r home fakebin fakedir <<EOF
$rec
EOF

  id="lab-task-1"
  lab_dir="$home/data/$id/lab"

  # 1. Scaffold lab brief
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" "$id" --lab >/dev/null 2>&1 \
    || fail "fm-brief.sh --lab failed"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not created"

  # 2. Spawn lab task
  printf '%s\n' "$lab_dir" > "$fakedir/cwd"
  out=$(run_spawn "$home" "$fakebin" "$fakedir" "$id" --lab)
  status=$?
  expect_code 0 "$status" "fm-spawn.sh --lab failed: $out"

  # Verify no treehouse lease was acquired
  assert_absent "$home/treehouse.log" "treehouse was invoked during lab spawn"

  # Verify metadata
  meta="$home/state/$id.meta"
  assert_present "$meta" "task metadata was not created"
  assert_grep "kind=lab" "$meta" "metadata kind is not lab"
  assert_grep "worktree=$lab_dir" "$meta" "metadata worktree is not $lab_dir"
  assert_grep "project=$lab_dir" "$meta" "metadata project is not $lab_dir"
  assert_no_grep "mode=" "$meta" "metadata must not contain mode"
  assert_no_grep "yolo=" "$meta" "metadata must not contain yolo"

  # Verify lab directory exists and is NOT a git repo
  assert_present "$lab_dir" "lab working directory was not created"
  assert_absent "$lab_dir/.git" "lab working directory must not be a git repo"

  # Write test work in lab
  printf 'lab test content\n' > "$lab_dir/experiment.txt"

  # 3. Test relaunch of lab task
  out=$(run_control "$home" "$fakebin" "$fakedir" "$id" relaunch --note "relaunching lab experiment")
  status=$?
  expect_code 0 "$status" "fm-control relaunch failed for lab task: $out"
  assert_grep "relaunching lab experiment" "$brief" "relaunch progress note was not appended to brief"

  # 4. Test promotion refusal
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 1 "$status" "promotion of lab task must exit 1"
  assert_contains "$out" "task $id is a lab task; a repo-less task has no repository to ship into" \
    "promotion did not refuse lab task properly"

  # 5. Test teardown refusal without report
  out=$(run_teardown "$home" "$fakebin" "$fakedir" "$id")
  status=$?
  expect_code 1 "$status" "teardown without report must exit 1"
  assert_contains "$out" "REFUSED: lab task $id has no report at" "teardown refusal did not name missing report"
  assert_present "$lab_dir/experiment.txt" "lab files were deleted on refused teardown"

  # 6. Write report, complete decision hold gate, and tear down
  printf '# Lab Task 1 Report\nAll tests passed cleanly.\n' > "$home/data/$id/report.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$DECISION_HOLD" complete "$id" --none >/dev/null 2>&1 \
    || fail "fm-decision-hold complete failed"

  out=$(run_teardown "$home" "$fakebin" "$fakedir" "$id")
  status=$?
  expect_code 0 "$status" "teardown with report failed: $out"
  assert_contains "$out" "teardown: retired lab $id to $home/data/.labs-retired/$id" \
    "teardown did not announce retirement destination"

  # Verify worktree is moved to .labs-retired and NOT deleted
  assert_absent "$lab_dir" "original lab working directory was not moved"
  retired_dir="$home/data/.labs-retired/$id"
  assert_present "$retired_dir" "retired lab directory was not created"
  assert_present "$retired_dir/experiment.txt" "experiment file was lost during retirement"
  assert_grep "lab test content" "$retired_dir/experiment.txt" "experiment file content was altered"

  # Verify report survives teardown
  assert_present "$home/data/$id/report.md" "report.md was deleted by teardown"

  # Verify task metadata is retired
  assert_absent "$meta" "task metadata was not cleaned up by teardown"

  pass "lab lifecycle: spawn, brief, relaunch, promote-refusal, report-gate, and retirement verification complete"
}

test_lab_flag_refusal_combinations
test_lab_spawn_and_lifecycle
echo "# all fm-lab-lifecycle tests passed"
