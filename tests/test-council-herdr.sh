#!/usr/bin/env bash
# Behavioural tests for scripts/council-herdr.sh against a fake herdr on PATH.
# Drives the shipped helper; the fake only records pane split/run/close.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$(cd "$HERE/.." && pwd)"
HELPER="$SOURCE/scripts/council-herdr.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/council-herdr-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

[[ -x "$HELPER" || -f "$HELPER" ]] || { echo "missing helper: $HELPER" >&2; exit 1; }

cat >"$T/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STATE="${COUNCIL_HERDR_FAKE_STATE:?}"
mkdir -p "$STATE"
log() { printf '%s\n' "$*" >>"$STATE/herdr.log"; }

case "${1:-} ${2:-}" in
  'pane list')
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p0"}]}}'
    ;;
  'pane split')
    log "split $*"
    if [[ "${FAIL_SPLIT:-}" == "1" ]]; then
      exit 1
    fi
    n="$(cat "$STATE/panes" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s\n' "$n" >"$STATE/panes"
    if [[ "${FAIL_SPLIT_AFTER:-}" == "$n" ]]; then
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"w1:p%s"}}}\n' "$n"
    ;;
  'pane run')
    pane="${3:-}"
    shift 3 || true
    log "run ${pane} $*"
    printf '%s\n' "PANE_SCROLLBACK" >>"$STATE/pane-output"
    if [[ "${FAIL_RUN:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "${HANG:-}" == "1" || "${HOLD:-}" == "1" ]]; then
      exit 0
    fi
    # Disown so the worker survives this fake CLI exiting (real herdr keeps the pane shell).
    bash -c "$*" >>"$STATE/pane-output" 2>&1 &
    disown $! 2>/dev/null || true
    ;;
  'pane close')
    log "close ${3:-}"
    ;;
  'pane wait-output'|'pane read')
    log "forbidden $*"
    exit 2
    ;;
  *)
    log "unknown $*"
    exit 2
    ;;
esac
FAKE
chmod +x "$T/bin/herdr"

for cli in codex gemini ollama; do
  cat >"$T/bin/$cli" <<'FAKECLI'
#!/usr/bin/env bash
state="${COUNCIL_HERDR_FAKE_STATE:?}"
name="$(basename "$0")"
n="$(cat "$state/${name}.calls" 2>/dev/null || echo 0)"
printf '%s\n' "$((n + 1))" >"$state/${name}.calls"
printf '%s-ok\n' "$name"
exit 0
FAKECLI
  chmod +x "$T/bin/$cli"
done

export PATH="$T/bin:$PATH"
export COUNCIL_HERDR_POLL="${COUNCIL_HERDR_POLL:-0.05}"
export COUNCIL_HERDR_GRACE="${COUNCIL_HERDR_GRACE:-1}"

PASS=0
FAIL=0
chk() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name: got '$got' want '$want'"
    FAIL=$((FAIL + 1))
  fi
}

reset() {
  rm -rf "$T/state"
  mkdir -p "$T/state"
  export COUNCIL_HERDR_FAKE_STATE="$T/state"
  unset FAIL_SPLIT FAIL_SPLIT_AFTER FAIL_RUN HANG HOLD
}

worker_argv_from_wrapper() {
  awk '/^# worker-argv-begin$/{p=1;next} /^# worker-argv-end$/{p=0} p' "$1" | sed 's/^# //;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

count_pat() {
  local pat="$1" file="$2"
  if [[ -f "$file" ]]; then
    grep -c -- "$pat" "$file" || true
  else
    echo 0
  fi
}
split_count() { count_pat '^split ' "$T/state/herdr.log"; }
run_count() { count_pat '^run ' "$T/state/herdr.log"; }
close_list() { awk '$1=="close"{print $2}' "$T/state/herdr.log" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
close_count() { awk '$1=="close"{n++} END{print n+0}' "$T/state/herdr.log" 2>/dev/null || echo 0; }
forbidden() { count_pat '^forbidden ' "$T/state/herdr.log"; }

# --- no panes when HERDR_ENV is unset ---
reset
BEGIN=$(env -u HERDR_ENV "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
chk "no-env herdr_active" "$(printf '%s' "$BEGIN" | jq -r .herdr_active)" "false"
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' 'local-answer' >/dev/null
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
OUT=$("$HELPER" ingest "$RUN" --seat watts --round 1)
chk "no-env ingest from file" "$OUT" "local-answer"
chk "no-env no splits" "$(split_count)" "0"
chk "no-env run dir mode 0700" "$(stat -f '%Lp' "$RUN")" "700"

# --- --herdr forces activation without HERDR_ENV ---
reset
BEGIN=$(env -u HERDR_ENV "$HELPER" begin --herdr)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
chk "force --herdr herdr_active" "$(printf '%s' "$BEGIN" | jq -r .herdr_active)" "true"
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' 'forced-herdr' >/dev/null
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
chk "force --herdr created a pane" "$(split_count)" "1"
"$HELPER" close-success "$RUN" >/dev/null

# --- --no-herdr disables pane creation ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin --no-herdr)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
chk "no-herdr herdr_active" "$(printf '%s' "$BEGIN" | jq -r .herdr_active)" "false"
"$HELPER" start "$RUN" --seat feynman --round 1 --timeout 5 -- printf '%s\n' 'no-herdr-answer' >/dev/null
"$HELPER" wait "$RUN" --seat feynman --round 1 >/dev/null
chk "no-herdr no splits" "$(split_count)" "0"
chk "no-herdr ingest" "$("$HELPER" ingest "$RUN" --seat feynman --round 1)" "no-herdr-answer"

# --- --dry-route creates no panes and start refuses ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin --dry-route)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
chk "dry-route herdr_active" "$(printf '%s' "$BEGIN" | jq -r .herdr_active)" "false"
chk "dry-route flag" "$(printf '%s' "$BEGIN" | jq -r .dry_route)" "true"
set +e
DRY_ERR=$("$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' x 2>&1)
DRY_RC=$?
set -e
chk "dry-route start refused" "$DRY_RC" "1"
chk "dry-route error names dry-route" "$(grep -c 'dry-route' <<<"$DRY_ERR")" "1"
chk "dry-route no splits" "$(split_count)" "0"

# --- Herdr mode: owned panes, JSON ids, --no-focus, file ingest, close on success ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
chk "herdr_active" "$(printf '%s' "$BEGIN" | jq -r .herdr_active)" "true"
chk "preexisting recorded" "$(printf '%s' "$BEGIN" | jq -r '.preexisting_panes | join(",")')" "w1:p0"
JOB=$("$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' 'file-answer')
chk "uses returned pane id" "$(printf '%s' "$JOB" | jq -r .pane_id)" "w1:p1"
chk "split uses --no-focus" "$(count_pat --no-focus "$T/state/herdr.log")" "1"
chk "split uses --current" "$(count_pat --current "$T/state/herdr.log")" "1"
chk "split uses --cwd" "$(count_pat --cwd "$T/state/herdr.log")" "1"
chk "first split direction right" "$(grep -c -- '--direction right' "$T/state/herdr.log")" "1"
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
OUT=$("$HELPER" ingest "$RUN" --seat watts --round 1)
chk "ingest is result file not scrollback" "$OUT" "file-answer"
chk "scrollback was not the answer" "$(grep -c PANE_SCROLLBACK <<<"$OUT" || true)" "0"
chk "no wait-output/read completion" "$(forbidden)" "0"
"$HELPER" close-success "$RUN" >/dev/null
chk "success closes owned pane" "$(close_list)" "w1:p1"
chk "preexisting never closed" "$(grep -c 'close w1:p0' "$T/state/herdr.log" || true)" "0"

# --- worker transport/model argv unchanged vs non-Herdr ---
reset
LOCAL_BEGIN=$(env -u HERDR_ENV "$HELPER" begin)
LOCAL_RUN=$(printf '%s' "$LOCAL_BEGIN" | jq -r .run_dir)
"$HELPER" start "$LOCAL_RUN" --seat ada --round 1 --timeout 5 -- \
  codex exec -c model=gpt-5.4 -c auto_approve=true 'PROMPT-TEXT' >/dev/null
"$HELPER" wait "$LOCAL_RUN" --seat ada --round 1 >/dev/null || true
LOCAL_WRAP=$(worker_argv_from_wrapper "$LOCAL_RUN/wrappers/run_ada__1.zsh")

reset
HERD_BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
HERD_RUN=$(printf '%s' "$HERD_BEGIN" | jq -r .run_dir)
"$HELPER" start "$HERD_RUN" --seat ada --round 1 --timeout 5 -- \
  codex exec -c model=gpt-5.4 -c auto_approve=true 'PROMPT-TEXT' >/dev/null
"$HELPER" wait "$HERD_RUN" --seat ada --round 1 >/dev/null || true
HERD_WRAP=$(worker_argv_from_wrapper "$HERD_RUN/wrappers/run_ada__1.zsh")
chk "argv identical herdr vs local" "$HERD_WRAP" "$LOCAL_WRAP"
chk "codex exec preserved" "$(grep -c 'codex exec' <<<"$HERD_WRAP")" "1"
chk "model flag preserved" "$(grep -c 'model=gpt-5.4' <<<"$HERD_WRAP")" "1"
chk "codex invoked once" "$(cat "$T/state/codex.calls" 2>/dev/null || echo 0)" "1"
LIVE_CODEX=$(grep -c '^[[:space:]]*codex exec' "$HERD_RUN/wrappers/run_ada__1.zsh" || true)
chk "wrapper has one live codex exec" "$LIVE_CODEX" "1"

reset
GEM_BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
GEM_RUN=$(printf '%s' "$GEM_BEGIN" | jq -r .run_dir)
"$HELPER" start "$GEM_RUN" --seat feynman --round 1 --timeout 5 -- \
  gemini -m gemini-2.5-pro -p 'PROMPT-TEXT' >/dev/null
"$HELPER" wait "$GEM_RUN" --seat feynman --round 1 >/dev/null || true
GEM_WRAP=$(worker_argv_from_wrapper "$GEM_RUN/wrappers/run_feynman__1.zsh")
chk "gemini argv preserved" "$(grep -c 'gemini -m gemini-2.5-pro' <<<"$GEM_WRAP")" "1"

reset
OLL_BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
OLL_RUN=$(printf '%s' "$OLL_BEGIN" | jq -r .run_dir)
"$HELPER" start "$OLL_RUN" --seat watts --round 1 --timeout 5 -- \
  ollama run llama3.2 'PROMPT-TEXT' >/dev/null
"$HELPER" wait "$OLL_RUN" --seat watts --round 1 >/dev/null || true
OLL_WRAP=$(worker_argv_from_wrapper "$OLL_RUN/wrappers/run_watts__1.zsh")
chk "ollama argv preserved" "$(grep -c 'ollama run llama3.2' <<<"$OLL_WRAP")" "1"

# --- atomic sentinel records real pipeline exit (pipefail, not tee) ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- \
  sh -c 'printf "%s\n" body; exit 7' >/dev/null
WAIT=$("$HELPER" wait "$RUN" --seat watts --round 1)
chk "pipefail sentinel exit 7" "$(printf '%s' "$WAIT" | jq -r .exit_code)" "7"
chk "nonzero is failed leg" "$(printf '%s' "$WAIT" | jq -r .status)" "failed"
SENTINEL="$(printf '%s' "$WAIT" | jq -r .sentinel)"
chk "sentinel has exit_code" "$(grep -c '^exit_code=7$' "$SENTINEL")" "1"
chk "sentinel has seat" "$(grep -c '^seat=watts$' "$SENTINEL")" "1"
chk "sentinel has round" "$(grep -c '^round=1$' "$SENTINEL")" "1"
"$HELPER" close-success "$RUN" >/dev/null
chk "failed pane preserved" "$(close_count)" "0"

# --- empty result is a failed leg even when exit is 0 ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- true >/dev/null
WAIT=$("$HELPER" wait "$RUN" --seat watts --round 1)
chk "empty result is failed" "$(printf '%s' "$WAIT" | jq -r .status)" "failed"
chk "empty result exit 0 still failed" "$(printf '%s' "$WAIT" | jq -r .exit_code)" "0"
"$HELPER" close-success "$RUN" >/dev/null
chk "empty-result pane preserved" "$(close_count)" "0"

# --- --keep-panes preserves successful panes ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin --keep-panes)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' ok >/dev/null
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
"$HELPER" ingest "$RUN" --seat watts --round 1 >/dev/null
"$HELPER" close-success "$RUN" >/dev/null
chk "keep-panes closes none" "$(close_count)" "0"

# --- timeout / missing sentinel is a failed leg, pane preserved ---
reset
export HANG=1
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 1 -- printf '%s\n' never >/dev/null
WAIT=$("$HELPER" wait "$RUN" --seat watts --round 1)
chk "missing sentinel is timeout" "$(printf '%s' "$WAIT" | jq -r .status)" "timeout"
chk "timeout reason" "$(printf '%s' "$WAIT" | jq -r .reason)" "missing_sentinel"
set +e
"$HELPER" ingest "$RUN" --seat watts --round 1 >/dev/null 2>&1
INGEST_RC=$?
set -e
chk "missing sentinel is not ingest success" "$INGEST_RC" "1"
"$HELPER" close-success "$RUN" >/dev/null
chk "timed-out pane preserved" "$(close_count)" "0"
chk "timeout artifacts kept" "$([[ -d "$RUN" && -f "$RUN/wrappers/run_watts__1.zsh" ]] && echo yes || echo no)" "yes"
unset HANG

# --- setup failure falls back and closes only empty panes from that attempt ---
reset
export FAIL_RUN=1
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
JOB=$("$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' 'fallback-answer')
chk "setup failure falls back local" "$(printf '%s' "$JOB" | jq -r .mode)" "local"
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
chk "setup fallback result" "$("$HELPER" ingest "$RUN" --seat watts --round 1)" "fallback-answer"
chk "setup failure closed empty owned pane" "$(close_list)" "w1:p1"
chk "setup failure did not close preexisting" "$(grep -c 'close w1:p0' "$T/state/herdr.log" || true)" "0"
unset FAIL_RUN

# --- native seats create zero worker panes in the same run ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat socrates --round 1 --timeout 5 --native >/dev/null
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' native-mix >/dev/null
"$HELPER" wait-all "$RUN" >/dev/null
chk "native+external splits" "$(split_count)" "1"
chk "native status" "$(jq -r .status "$RUN/jobs/socrates__1.json")" "native"
chk "native has no pane" "$(jq -r '.pane_id // "null"' "$RUN/jobs/socrates__1.json")" "null"

# --- more than four external seats use a bounded pane pool ---
# HOLD: pane run records the job but does not write a sentinel, so four seats
# stay concurrently running and the helper must wave later seats through reuse.
reset
export HOLD=1
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
complete_hold_job() {
  local seat="$1"
  local body="$2"
  local key="${seat}__1"
  local sent="$RUN/sentinels/${key}"
  printf '%s\n' "$body" >"$RUN/results/${key}.txt"
  printf 'exit_code=0\nresult=%s\nseat=%s\nround=1\n' "$RUN/results/${key}.txt" "$seat" >"${sent}.tmp"
  mv "${sent}.tmp" "$sent"
}
for i in 1 2 3 4; do
  "$HELPER" start "$RUN" --seat "s$i" --round 1 --timeout 20 -- printf '%s\n' "ok$i" >/dev/null
done
SPLITS=$(split_count)
UNIQUE=$(awk '$1=="run"{print $2}' "$T/state/herdr.log" | sort -u | wc -l | tr -d ' ')
chk "pool four concurrent splits" "$SPLITS" "4"
chk "pool four unique panes" "$UNIQUE" "4"
DIRS=$(awk '/^split /{for(i=1;i<=NF;i++) if($i=="--direction") print $(i+1)}' "$T/state/herdr.log" | paste -sd, -)
chk "pool splits alternate right/down" "$DIRS" "right,down,right,down"
complete_hold_job s1 ok1
complete_hold_job s2 ok2
"$HELPER" start "$RUN" --seat s5 --round 1 --timeout 20 -- printf '%s\n' ok5 >/dev/null
"$HELPER" start "$RUN" --seat s6 --round 1 --timeout 20 -- printf '%s\n' ok6 >/dev/null
chk "pool still four splits after wave" "$(split_count)" "4"
chk "pool six runs" "$(run_count)" "6"
UNIQUE2=$(awk '$1=="run"{print $2}' "$T/state/herdr.log" | sort -u | wc -l | tr -d ' ')
chk "pool unique panes still <=4" "$UNIQUE2" "4"
complete_hold_job s3 ok3
complete_hold_job s4 ok4
complete_hold_job s5 ok5
complete_hold_job s6 ok6
"$HELPER" wait-all "$RUN" >/dev/null
for i in 1 2 3 4 5 6; do
  chk "pool ingest s$i" "$("$HELPER" ingest "$RUN" --seat "s$i" --round 1)" "ok$i"
done
"$HELPER" close-success "$RUN" >/dev/null
chk "pool did not close preexisting" "$(grep -c 'close w1:p0' "$T/state/herdr.log" || true)" "0"
unset HOLD

# --- after workers started, a full failed pool does not open a 5th pane or local-run ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
for i in 1 2 3 4; do
  "$HELPER" start "$RUN" --seat "f$i" --round 1 --timeout 8 -- sh -c 'printf x; exit 1' >/dev/null
done
"$HELPER" wait-all "$RUN" >/dev/null
JOB5=$("$HELPER" start "$RUN" --seat f5 --round 1 --timeout 8 -- printf '%s\n' should-not-run)
chk "failed pool does not split a 5th pane" "$(split_count)" "4"
chk "failed pool fifth seat fails" "$(printf '%s' "$JOB5" | jq -r .status)" "failed"
chk "failed pool fifth reason" "$(printf '%s' "$JOB5" | jq -r .reason)" "no_pane"
chk "failed pool fifth is not local" "$(printf '%s' "$JOB5" | jq -r .mode)" "herdr"

# --- split JSON parse / split fail before workers: no leaked empty panes ---
reset
export FAIL_SPLIT=1
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
JOB=$("$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' 'split-fail-answer')
chk "split fail falls back local" "$(printf '%s' "$JOB" | jq -r .mode)" "local"
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
chk "split fail ingest" "$("$HELPER" ingest "$RUN" --seat watts --round 1)" "split-fail-answer"
chk "split fail ran no pane command" "$(run_count)" "0"
chk "split fail did not close preexisting" "$(grep -c 'close w1:p0' "$T/state/herdr.log" || true)" "0"
unset FAIL_SPLIT

# --- wrapper uses set -o pipefail ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' ok >/dev/null
chk "wrapper pipefail" "$(grep -c 'set -o pipefail' "$RUN/wrappers/run_watts__1.zsh")" "1"
chk "pane run sources wrapper" "$(grep -c "source " "$T/state/herdr.log")" "1"

# --- leftover sentinel is unlinked; same-seat restart is not a false failure ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' first-answer >/dev/null
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
chk "first ingest" "$("$HELPER" ingest "$RUN" --seat watts --round 1)" "first-answer"
[[ -f "$RUN/sentinels/watts__1" ]] || { echo "missing first sentinel"; FAIL=$((FAIL + 1)); }
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' second-answer >/dev/null
WAIT=$("$HELPER" wait "$RUN" --seat watts --round 1)
chk "restart not failed leftover" "$(printf '%s' "$WAIT" | jq -r .status)" "success"
chk "restart ingest is new result" "$("$HELPER" ingest "$RUN" --seat watts --round 1)" "second-answer"

# --- restate and round 1 are distinct job keys ---
reset
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
"$HELPER" start "$RUN" --seat watts --round restate --timeout 5 -- printf '%s\n' restate-ok >/dev/null
"$HELPER" start "$RUN" --seat watts --round 1 --timeout 5 -- printf '%s\n' round1-ok >/dev/null
"$HELPER" wait "$RUN" --seat watts --round restate >/dev/null
"$HELPER" wait "$RUN" --seat watts --round 1 >/dev/null
chk "restate ingest" "$("$HELPER" ingest "$RUN" --seat watts --round restate)" "restate-ok"
chk "round1 ingest distinct" "$("$HELPER" ingest "$RUN" --seat watts --round 1)" "round1-ok"

# --- concurrent start() serializes allocation: ≤4 splits, complete owned_panes ---
reset
export HOLD=1
BEGIN=$(HERDR_ENV=1 "$HELPER" begin)
RUN=$(printf '%s' "$BEGIN" | jq -r .run_dir)
complete_hold_job() {
  local seat="$1"
  local body="$2"
  local key="${seat}__1"
  local sent="$RUN/sentinels/${key}"
  printf '%s\n' "$body" >"$RUN/results/${key}.txt"
  printf 'exit_code=0\nresult=%s\nseat=%s\nround=1\n' "$RUN/results/${key}.txt" "$seat" >"${sent}.tmp"
  mv "${sent}.tmp" "$sent"
}
for i in 1 2 3 4 5 6; do
  "$HELPER" start "$RUN" --seat "c$i" --round 1 --timeout 30 -- printf '%s\n' "ok$i" >/dev/null &
done
pane_ready_n() {
  local f n=0
  shopt -s nullglob
  for f in "$RUN"/jobs/*.json; do
    [[ "$(jq -r '.status + " " + (.pane_id // "null")' "$f")" == running\ w1:* ]] && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}
for _ in $(seq 100); do
  [[ "$(pane_ready_n)" -ge 4 && "$(split_count)" -ge 4 ]] && break
  sleep 0.05
done
chk "concurrent splits cap at 4 before wave" "$(split_count)" "4"
READY=$(jq -r 'select(.status=="running" and .pane_id != null) | .seat' "$RUN"/jobs/*.json)
READY1=$(printf '%s\n' "$READY" | sed -n '1p')
READY2=$(printf '%s\n' "$READY" | sed -n '2p')
complete_hold_job "$READY1" "ok${READY1#c}"
complete_hold_job "$READY2" "ok${READY2#c}"
for _ in $(seq 100); do
  [[ "$(run_count)" -ge 6 ]] && break
  sleep 0.05
done
wait || true
chk "concurrent still four splits" "$(split_count)" "4"
chk "concurrent six runs" "$(run_count)" "6"
OWNED_N=$(jq -r '.owned_panes | length' "$RUN/manifest.json")
chk "concurrent owned_panes length 4" "$OWNED_N" "4"
OWNED_IDS=$(jq -r '.owned_panes | join(",")' "$RUN/manifest.json")
MISSING=0
while IFS= read -r pane; do
  [[ -z "$pane" ]] && continue
  printf '%s' "$OWNED_IDS" | grep -Fq "$pane" || MISSING=$((MISSING + 1))
done < <(awk '$1=="run"{print $2}' "$T/state/herdr.log" | sort -u)
chk "concurrent no untracked run panes" "$MISSING" "0"
DIRS=$(awk '/^split /{for(i=1;i<=NF;i++) if($i=="--direction") print $(i+1)}' "$T/state/herdr.log" | paste -sd, -)
chk "concurrent splits alternate right/down" "$DIRS" "right,down,right,down"
for i in 1 2 3 4 5 6; do
  complete_hold_job "c$i" "ok$i"
done
"$HELPER" wait-all "$RUN" >/dev/null
for i in 1 2 3 4 5 6; do
  chk "concurrent ingest c$i" "$("$HELPER" ingest "$RUN" --seat "c$i" --round 1)" "ok$i"
done
"$HELPER" close-success "$RUN" >/dev/null
chk "concurrent close only owned" "$(close_count)" "4"
chk "concurrent preexisting not closed" "$(grep -c 'close w1:p0' "$T/state/herdr.log" || true)" "0"
unset HOLD

if [[ $FAIL -eq 0 ]]; then
  echo "PASS council-herdr: $PASS checks"
  exit 0
fi
echo "FAIL council-herdr: $FAIL of $((PASS + FAIL)) checks failed"
exit 1
