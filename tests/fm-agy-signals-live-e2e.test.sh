#!/usr/bin/env bash
# Opt-in live check of the Antigravity CLI (agy) guarded global hook.
#
# The guard is harness-dependent: its verdict comes from the payload agy itself
# emits, so a stub can only confirm the assumption already written into the stub.
# This runs the REAL binary against the REAL installed global hook - once from a
# workspace holding a registered Firstmate pointer, once from a workspace
# holding none - and asserts the turn-end marker and the semantic busy record
# move only for the registered one. That pair is the whole safety claim for
# sharing one hook entry with the captain's own agy sessions.
#
# The hook itself must live in agy's real config directory: agy resolves that
# root from $HOME alone and honours no override, and moving $HOME would take its
# credentials with it. So this installs into the shared config through the same
# idempotent installer fm-spawn uses, and afterwards removes ONLY what it added -
# its own registry token always, its own tmux server always, and the shared hook
# only when this run is what created it. Everything else (state, workspaces,
# marker) is scratch.
#
# The last case drives the INTERACTIVE `-i` launch the adapter actually ships,
# in a real pane on a dedicated tmux socket. Headless `-p` and interactive `-i`
# are separately verified behaviours on agy, so a guard built only from `-p`
# would sit still through a release that changed Stop/fullyIdle or
# workspacePaths for the one mode a crewmate ever runs in.
set -u

if [ "${FM_AGY_SIGNALS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE_E2E=1 to run the live agy signal check"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGY_BIN=$(command -v agy) || fail "agy not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not found"
REAL_TMUX=$(command -v tmux) || fail "tmux is required to drive agy's interactive launch mode"
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
AGY_VERSION=$("$AGY_BIN" --version 2>&1 | head -1)
CONFIG_DIR="$HOME/.gemini/config"
[ -d "$CONFIG_DIR" ] || fail "agy config directory is absent at $CONFIG_DIR"
LAB=$(fm_test_tmproot fm-agy-signals)
STATE="$LAB/state"
mkdir -p "$STATE" "$LAB/registered" "$LAB/outsider"

HOOK_PREEXISTING=no
if [ -f "$CONFIG_DIR/hooks.json" ] \
   && jq -e 'has("firstmate-turn-end")' "$CONFIG_DIR/hooks.json" >/dev/null 2>&1; then
  HOOK_PREEXISTING=yes
fi
TOKEN=

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$TOKEN" ] || rm -f "$CONFIG_DIR/fm-agy-turn-end.d/$TOKEN"
  if [ "$HOOK_PREEXISTING" = no ]; then
    "$ROOT/bin/fm-agy-config.sh" remove "$LAB/absent-skills" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_live EXIT

run_agy() {  # <workspace> [--add-dir]
  local workspace=$1
  shift
  ( cd "$workspace" && "$AGY_BIN" -p 'Reply with exactly: LIVE-OK' \
      --dangerously-skip-permissions "$@" \
      >"$LAB/agy.out" 2>"$LAB/agy.err" )
}

# The interactive launch, in a real pane. This is fm-spawn's own command shape,
# and the folder-trust dialog it hits on a fresh path is cleared the same way
# fm-spawn clears it: an Enter only once the dialog's own text is on screen.
# bin/fm-spawn.sh owns that handling; this repeats the prompt text because the
# pane here is driven directly rather than through a spawn.
run_agy_interactive() {  # <workspace>
  local workspace=$1 pane
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$workspace" \
    || fail "could not start the isolated tmux server ($AGY_VERSION)"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$workspace" -- \
    "$AGY_BIN" --dangerously-skip-permissions --add-dir "$workspace" \
    -i 'Reply with exactly: LIVE-OK' \
    || fail "could not launch agy interactively ($AGY_VERSION)"
  for _ in $(seq 1 60); do
    pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -120 2>/dev/null || true)
    case "$pane" in
      *'Do you trust the contents of this project'*)
        "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
        break
        ;;
    esac
    sleep 0.5
  done
}

"$ROOT/bin/fm-agy-config.sh" install "$LAB/absent-skills" \
  || fail "agy global wiring install failed"

BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) \
  || fail "could not arm a busy generation"
TOKEN=$(basename "$(mktemp "$CONFIG_DIR/fm-agy-turn-end.d/fm.XXXXXXXXXXXX")")
printf '%s\n%s\n%s\n%s\n%s\n' "$STATE/live.turn-ended" "$ROOT/bin/fm-busy-event.sh" \
  "$STATE" live "$BUSY_GEN" > "$CONFIG_DIR/fm-agy-turn-end.d/$TOKEN"
printf 'token=%s\n' "$TOKEN" > "$LAB/registered/.fm-agy-turnend"

# 1. An agy session in a workspace Firstmate never registered.
run_agy "$LAB/outsider" --add-dir "$LAB/outsider" \
  || fail "agy refused to run in the unregistered workspace: $(head -3 "$LAB/agy.err")"
[ ! -e "$STATE/live.turn-ended" ] \
  || fail "an unregistered agy session fired a Firstmate turn-end marker ($AGY_VERSION)"
grep -q 'source=agy-hook' "$STATE/live.busy-state" \
  && fail "an unregistered agy session wrote a Firstmate busy event ($AGY_VERSION)"
pass "the agy global hook is inert for a session Firstmate did not register ($AGY_VERSION)"

# 2. The same hook, same binary, in the registered workspace.
run_agy "$LAB/registered" --add-dir "$LAB/registered" \
  || fail "agy refused to run in the registered workspace: $(head -3 "$LAB/agy.err")"
[ -e "$STATE/live.turn-ended" ] \
  || fail "a registered agy session did not fire its turn-end marker ($AGY_VERSION)"
grep -q 'state=idle source=agy-hook' "$STATE/live.busy-state" \
  || fail "a registered agy session did not record a semantic idle event ($AGY_VERSION)"
pass "the agy global hook fires the turn-end marker and idle event for a registered task ($AGY_VERSION)"

# 3. agy still reports an EMPTY workspacePaths without --add-dir, which is the
# reason fm-spawn passes it; without that binding the guard can never match, so
# a release that starts populating it would make the flag redundant and this
# case is what would say so.
rm -f "$STATE/live.turn-ended"
run_agy "$LAB/registered" \
  || fail "agy refused to run without --add-dir: $(head -3 "$LAB/agy.err")"
[ ! -e "$STATE/live.turn-ended" ] \
  || fail "agy populated workspacePaths without --add-dir; fm-spawn's binding may be redundant now ($AGY_VERSION)"
pass "agy still reports no workspace without --add-dir, so fm-spawn's binding is still required ($AGY_VERSION)"

# 4. The same guarded hook under the launch mode the adapter actually ships.
# `-i` keeps the session interactive, which is a different code path in agy than
# `-p`, and CORRECTION 2 in this adapter's brief exists because an earlier probe
# concluded the hook was headless-only. A pane is the only way to exercise it.
run_agy_interactive "$LAB/registered"
for _ in $(seq 1 240); do
  [ -e "$STATE/live.turn-ended" ] && break
  sleep 0.5
done
[ -e "$STATE/live.turn-ended" ] \
  || fail "an interactive agy session did not fire its turn-end marker ($AGY_VERSION)"
grep -q 'state=idle source=agy-hook' "$STATE/live.busy-state" \
  || fail "an interactive agy session did not record a semantic idle event ($AGY_VERSION)"
pass "the agy global hook fires for the interactive -i launch fm-spawn actually uses ($AGY_VERSION)"
