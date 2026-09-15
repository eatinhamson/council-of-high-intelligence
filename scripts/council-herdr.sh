#!/usr/bin/env bash
# council-herdr.sh — Herdr visibility/lifecycle for Council external CLI seats.
# shellcheck disable=SC2016  # jq programs use $vars that must not expand in bash
#
# Herdr is orchestration only. Worker transport stays the caller-supplied argv
# (codex exec / gemini / ollama). Native seats create no panes. Completion is
# an atomic file sentinel; terminal scrollback and Herdr idle/done are diagnostic.
set -euo pipefail

MAX_PANES=4
POLL="${COUNCIL_HERDR_POLL:-0.2}"
GRACE="${COUNCIL_HERDR_GRACE:-5}"

usage() {
  cat <<'EOF'
Usage: council-herdr.sh <command> [args]

Commands:
  begin [--keep-panes] [--no-herdr] [--herdr] [--dry-route]
  start <run_dir> --seat NAME --round N --timeout SECONDS [--native] [--prompt-file PATH] -- CMD...
  wait <run_dir> --seat NAME --round N
  wait-all <run_dir>
  ingest <run_dir> --seat NAME --round N
  close-success <run_dir>
  abort-setup <run_dir>
  status <run_dir>
EOF
  exit "${1:-0}"
}

die() { echo "council-herdr: $*" >&2; exit 1; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

now_epoch() { date +%s; }

job_key() {
  printf '%s__%s' "$1" "$2"
}

validate_ident() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid identifier: $1"
}

quote_argv() {
  local out="" a
  for a in "$@"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

manifest_path() { printf '%s/manifest.json' "$1"; }
job_path() { printf '%s/jobs/%s.json' "$1" "$(job_key "$2" "$3")"; }

read_manifest() {
  jq -c '.' "$(manifest_path "$1")"
}

write_manifest() {
  local run_dir="$1" json="$2" tmp
  tmp="$(mktemp "${run_dir}/manifest.json.tmp.XXXXXX")"
  printf '%s\n' "$json" | jq -c '.' >"$tmp"
  mv "$tmp" "$(manifest_path "$run_dir")"
}

# Serialize pane allocation and manifest RMW across parallel `start` processes.
# mkdir lock is the portable exclusive lock (no `flock` on this host); nested
# acquires in the same process bump a depth counter instead of deadlocking.
acquire_run_lock() {
  local run_dir="$1"
  local lock="$run_dir/.alloc.lock"
  if [[ "${COUNCIL_HERDR_LOCK_OWNER:-}" == "$$" && "${COUNCIL_HERDR_LOCK_DIR:-}" == "$run_dir" ]]; then
    COUNCIL_HERDR_LOCK_DEPTH=$((COUNCIL_HERDR_LOCK_DEPTH + 1))
    return 0
  fi
  while ! mkdir "$lock" 2>/dev/null; do
    local pid=""
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    sleep "$POLL"
  done
  printf '%s\n' "$$" >"$lock/pid"
  COUNCIL_HERDR_LOCK_OWNER="$$"
  COUNCIL_HERDR_LOCK_DIR="$run_dir"
  COUNCIL_HERDR_LOCK_DEPTH=1
}

release_run_lock() {
  local run_dir="$1"
  local lock="$run_dir/.alloc.lock"
  if [[ "${COUNCIL_HERDR_LOCK_OWNER:-}" != "$$" || "${COUNCIL_HERDR_LOCK_DIR:-}" != "$run_dir" ]]; then
    return 0
  fi
  COUNCIL_HERDR_LOCK_DEPTH=$((COUNCIL_HERDR_LOCK_DEPTH - 1))
  if [[ "$COUNCIL_HERDR_LOCK_DEPTH" -gt 0 ]]; then
    return 0
  fi
  unset COUNCIL_HERDR_LOCK_OWNER COUNCIL_HERDR_LOCK_DIR COUNCIL_HERDR_LOCK_DEPTH
  rm -rf "$lock"
}

update_manifest() {
  local run_dir="$1"
  shift
  acquire_run_lock "$run_dir"
  local json rc=0
  json="$(jq -c "$@" "$(manifest_path "$run_dir")")" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    write_manifest "$run_dir" "$json" || rc=$?
  fi
  release_run_lock "$run_dir"
  return "$rc"
}

write_job() {
  local run_dir="$1" seat="$2" round="$3" json="$4" path tmp
  path="$(job_path "$run_dir" "$seat" "$round")"
  tmp="${path}.tmp"
  printf '%s\n' "$json" | jq -c '.' >"$tmp"
  mv "$tmp" "$path"
}

read_job() {
  local path
  path="$(job_path "$1" "$2" "$3")"
  [[ -f "$path" ]] || die "no job for seat=$2 round=$3"
  jq -c '.' "$path"
}

update_job() {
  local run_dir="$1" seat="$2" round="$3"
  shift 3
  local json
  json="$(jq -c "$@" "$(job_path "$run_dir" "$seat" "$round")")"
  write_job "$run_dir" "$seat" "$round" "$json"
}

herdr_deps_ok() {
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

should_activate() {
  local no_herdr="$1" force_herdr="$2" dry_route="$3"
  [[ "$dry_route" == "1" ]] && return 1
  [[ "$no_herdr" == "1" ]] && return 1
  herdr_deps_ok || return 1
  if [[ "$force_herdr" == "1" ]]; then
    return 0
  fi
  [[ "${HERDR_ENV:-}" == "1" ]]
}

snapshot_preexisting() {
  local json=""
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    json="$(herdr pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null || true)"
  else
    json="$(herdr pane list 2>/dev/null || true)"
  fi
  if [[ -z "$json" ]]; then
    printf '[]'
    return 0
  fi
  printf '%s' "$json" | jq -c '[.result.panes[]?.pane_id // empty]' 2>/dev/null || printf '[]'
}

cmd_begin() {
  need_jq
  local keep_panes=0 no_herdr=0 force_herdr=0 dry_route=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-panes) keep_panes=1; shift ;;
      --no-herdr) no_herdr=1; shift ;;
      --herdr) force_herdr=1; shift ;;
      --dry-route) dry_route=1; shift ;;
      -h|--help) usage 0 ;;
      *) die "begin: unknown option: $1" ;;
    esac
  done

  local herdr_active=false
  if should_activate "$no_herdr" "$force_herdr" "$dry_route"; then
    herdr_active=true
  fi

  umask 077
  local run_dir
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/council-herdr.XXXXXX")"
  chmod 0700 "$run_dir"
  mkdir -p "$run_dir"/{prompts,wrappers,results,sentinels,status,jobs,diag}

  local preexisting='[]'
  if [[ "$herdr_active" == "true" ]]; then
    preexisting="$(snapshot_preexisting)"
  fi

  local keep_json=false dry_json=false
  [[ "$keep_panes" -eq 1 ]] && keep_json=true
  [[ "$dry_route" -eq 1 ]] && dry_json=true

  jq -nc \
    --arg run_dir "$run_dir" \
    --argjson herdr_active "$herdr_active" \
    --argjson keep_panes "$keep_json" \
    --argjson dry_route "$dry_json" \
    --argjson max_panes "$MAX_PANES" \
    --arg next_direction "right" \
    --argjson owned_panes '[]' \
    --argjson preexisting_panes "$preexisting" \
    --argjson workers_started false \
    --argjson fallback_local false \
    --arg cwd "$PWD" \
    '{
      run_dir: $run_dir,
      herdr_active: $herdr_active,
      keep_panes: $keep_panes,
      dry_route: $dry_route,
      max_panes: $max_panes,
      next_direction: $next_direction,
      owned_panes: $owned_panes,
      preexisting_panes: $preexisting_panes,
      workers_started: $workers_started,
      fallback_local: $fallback_local,
      cwd: $cwd
    }' >"$(manifest_path "$run_dir")"

  jq -c '.' "$(manifest_path "$run_dir")"
}

write_wrapper() {
  local wrapper="$1" result="$2" sentinel="$3" seat="$4" round="$5" prompt_file="$6"
  shift 6
  local cmd quoted_prompt
  cmd="$(quote_argv "$@")"
  if [[ -n "$prompt_file" ]]; then
    quoted_prompt="$(printf '%q' "$prompt_file")"
    cmd+=" \"\$(cat -- ${quoted_prompt})\""
  fi
  local q_result q_sentinel q_seat q_round q_tmp
  q_result="$(printf '%q' "$result")"
  q_sentinel="$(printf '%q' "$sentinel")"
  q_seat="$(printf '%q' "$seat")"
  q_round="$(printf '%q' "$round")"
  q_tmp="$(printf '%q' "${sentinel}.tmp")"
  local commented
  commented="$(printf '%s\n' "$cmd" | sed 's/^/# /')"
  cat >"$wrapper" <<EOF
set -o pipefail
# worker-argv-begin
${commented}
# worker-argv-end
{
  ${cmd}
} | tee ${q_result}
rc=\$?
printf 'exit_code=%s\nresult=%s\nseat=%s\nround=%s\n' "\$rc" ${q_result} ${q_seat} ${q_round} > ${q_tmp} \\
  && mv ${q_tmp} ${q_sentinel}
EOF
  chmod 0700 "$wrapper"
}

parse_sentinel() {
  local sentinel="$1"
  local exit_code="" result="" seat="" round=""
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      exit_code) exit_code="$value" ;;
      result) result="$value" ;;
      seat) seat="$value" ;;
      round) round="$value" ;;
    esac
  done <"$sentinel"
  [[ -n "$exit_code" && -n "$result" && -n "$seat" && -n "$round" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$exit_code" "$result" "$seat" "$round"
}

classify_result() {
  local exit_code="$1" result="$2"
  if [[ "$exit_code" != "0" ]]; then
    printf 'failed'
    return 0
  fi
  if [[ ! -f "$result" || ! -r "$result" || ! -s "$result" ]]; then
    printf 'failed'
    return 0
  fi
  printf 'success'
}

harvest_job_if_done() {
  local run_dir="$1" seat="$2" round="$3"
  local job sentinel parsed exit_code result status deadline now
  job="$(read_job "$run_dir" "$seat" "$round")"
  status="$(printf '%s' "$job" | jq -r '.status')"
  [[ "$status" == "running" ]] || return 0
  sentinel="$(printf '%s' "$job" | jq -r '.sentinel')"
  deadline="$(printf '%s' "$job" | jq -r '.deadline_epoch')"
  now="$(now_epoch)"
  if [[ -f "$sentinel" ]]; then
    parsed="$(parse_sentinel "$sentinel")" || {
      update_job "$run_dir" "$seat" "$round" '.status="failed" | .exit_code=1 | .reason="malformed_sentinel"'
      return 0
    }
    exit_code="$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')"
    result="$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=1
    status="$(classify_result "$exit_code" "$result")"
    update_job "$run_dir" "$seat" "$round" \
      --arg status "$status" --arg result "$result" --argjson exit_code "$exit_code" \
      '.status=$status | .result=$result | .exit_code=$exit_code | .reason=(if $status=="success" then "ok" else "worker_or_result" end)'
    return 0
  fi
  if [[ "$now" -ge "$deadline" ]]; then
    update_job "$run_dir" "$seat" "$round" '.status="timeout" | .reason="missing_sentinel"'
    kill_local_job "$run_dir" "$seat" "$round"
  fi
}

kill_local_job() {
  local run_dir="$1" seat="$2" round="$3"
  local job mode pid_file pid
  job="$(read_job "$run_dir" "$seat" "$round")"
  mode="$(printf '%s' "$job" | jq -r '.mode')"
  [[ "$mode" == "local" ]] || return 0
  pid_file="$(printf '%s' "$job" | jq -r '.pid_file // empty')"
  [[ -n "$pid_file" && -f "$pid_file" ]] || return 0
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
}

iter_jobs() {
  local run_dir="$1" f
  shopt -s nullglob
  for f in "$run_dir"/jobs/*.json; do
    jq -r '"\(.seat)\t\(.round)"' "$f"
  done
  shopt -u nullglob
}

harvest_completed() {
  local run_dir="$1" seat round
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    harvest_job_if_done "$run_dir" "$seat" "$round"
  done < <(iter_jobs "$run_dir")
}

running_count() {
  local run_dir="$1" n=0 seat round status
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    if [[ "$status" == "running" ]]; then
      n=$((n + 1))
    fi
  done < <(iter_jobs "$run_dir")
  printf '%s' "$n"
}

pane_in_use() {
  local run_dir="$1" pane="$2" seat round status job_pane
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    job_pane="$(jq -r '.pane_id // empty' "$(job_path "$run_dir" "$seat" "$round")")"
    if [[ "$status" == "running" && "$job_pane" == "$pane" ]]; then
      return 0
    fi
  done < <(iter_jobs "$run_dir")
  return 1
}

pane_is_failed() {
  local run_dir="$1" pane="$2" seat round status job_pane
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    job_pane="$(jq -r '.pane_id // empty' "$(job_path "$run_dir" "$seat" "$round")")"
    if [[ "$job_pane" == "$pane" && ( "$status" == "failed" || "$status" == "timeout" ) ]]; then
      return 0
    fi
  done < <(iter_jobs "$run_dir")
  return 1
}

find_reusable_pane() {
  local run_dir="$1" pane
  while IFS= read -r pane; do
    [[ -z "$pane" ]] && continue
    if pane_in_use "$run_dir" "$pane"; then
      continue
    fi
    if pane_is_failed "$run_dir" "$pane"; then
      continue
    fi
    printf '%s' "$pane"
    return 0
  done < <(jq -r '.owned_panes[]?' "$(manifest_path "$run_dir")")
  return 1
}

owned_count() {
  jq -r '.owned_panes | length' "$(manifest_path "$1")"
}

split_pane() {
  local run_dir="$1"
  local direction cwd response pane_id next
  direction="$(jq -r '.next_direction' "$(manifest_path "$run_dir")")"
  cwd="$(jq -r '.cwd' "$(manifest_path "$run_dir")")"
  if ! response="$(herdr pane split --current --direction "$direction" --cwd "$cwd" --no-focus)"; then
    return 1
  fi
  pane_id="$(printf '%s' "$response" | jq -er '.result.pane.pane_id' 2>/dev/null || true)"
  if [[ -z "$pane_id" ]]; then
    close_untracked_new_panes "$run_dir"
    return 1
  fi
  if [[ "$direction" == "right" ]]; then
    next="down"
  else
    next="right"
  fi
  update_manifest "$run_dir" \
    --arg pane_id "$pane_id" --arg next "$next" \
    '.owned_panes += [$pane_id] | .next_direction=$next'
  printf '%s' "$pane_id"
}

close_untracked_new_panes() {
  local run_dir="$1" pane
  local current preexisting owned
  current="$(snapshot_preexisting)"
  preexisting="$(jq -c '.preexisting_panes' "$(manifest_path "$run_dir")")"
  owned="$(jq -c '.owned_panes' "$(manifest_path "$run_dir")")"
  while IFS= read -r pane; do
    [[ -z "$pane" ]] && continue
    if printf '%s' "$preexisting" | jq -e --arg p "$pane" 'index($p) != null' >/dev/null; then
      continue
    fi
    if printf '%s' "$owned" | jq -e --arg p "$pane" 'index($p) != null' >/dev/null; then
      continue
    fi
    herdr pane close "$pane" >/dev/null 2>&1 || true
  done < <(printf '%s' "$current" | jq -r '.[]?')
}

close_owned_empty() {
  local run_dir="$1" pane preexisting
  preexisting="$(jq -r '.preexisting_panes[]?' "$(manifest_path "$run_dir")")"
  while IFS= read -r pane; do
    [[ -z "$pane" ]] && continue
    if printf '%s\n' "$preexisting" | grep -Fxq "$pane"; then
      continue
    fi
    herdr pane close "$pane" >/dev/null 2>&1 || true
  done < <(jq -r '.owned_panes[]?' "$(manifest_path "$run_dir")")
  update_manifest "$run_dir" '.owned_panes=[] | .herdr_active=false | .fallback_local=true'
}

cmd_abort_setup() {
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "abort-setup requires run_dir"
  close_owned_empty "$run_dir"
  jq -c '.' "$(manifest_path "$run_dir")"
}

wait_for_pool_slot() {
  local run_dir="$1" max
  max="$(jq -r '.max_panes' "$(manifest_path "$run_dir")")"
  harvest_completed "$run_dir"
  while [[ "$(running_count "$run_dir")" -ge "$max" ]]; do
    sleep "$POLL"
    harvest_completed "$run_dir"
  done
}

allocate_pane() {
  local run_dir="$1" pane max owned
  acquire_run_lock "$run_dir"
  wait_for_pool_slot "$run_dir"
  if pane="$(find_reusable_pane "$run_dir")"; then
    release_run_lock "$run_dir"
    printf '%s' "$pane"
    return 0
  fi
  owned="$(owned_count "$run_dir")"
  max="$(jq -r '.max_panes' "$(manifest_path "$run_dir")")"
  if [[ "$owned" -ge "$max" ]]; then
    release_run_lock "$run_dir"
    return 1
  fi
  pane="$(split_pane "$run_dir")" || {
    release_run_lock "$run_dir"
    return 1
  }
  release_run_lock "$run_dir"
  printf '%s' "$pane"
}

run_wrapper_local_bg() {
  local wrapper="$1" pid_file="$2" log_file="$3"
  # Child bash so a sourced wrapper cannot exit the helper.
  # Redirect stdio: tee still writes the result file; helper stdout stays JSON-only.
  bash -c 'source "$1"' _ "$wrapper" >"$log_file" 2>&1 &
  printf '%s\n' "$!" >"$pid_file"
}

pane_run_wrapper() {
  local pane="$1" wrapper="$2"
  local cmd
  cmd="source $(printf '%q' "$wrapper")"
  herdr pane run "$pane" "$cmd" >/dev/null
}

mark_workers_started() {
  update_manifest "$1" '.workers_started=true'
}

cmd_start() {
  need_jq
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "start requires run_dir"
  shift
  local seat="" round="" timeout="" native=0 prompt_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seat) seat="${2:-}"; shift 2 ;;
      --round) round="${2:-}"; shift 2 ;;
      --timeout) timeout="${2:-}"; shift 2 ;;
      --native) native=1; shift ;;
      --prompt-file) prompt_file="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) die "start: unknown option: $1" ;;
    esac
  done
  [[ -n "$seat" && -n "$round" ]] || die "start requires --seat and --round"
  validate_ident "$seat"
  validate_ident "$round"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "start: timeout must be a positive integer"
  if [[ "$native" -eq 0 && $# -eq 0 ]]; then
    die "start: external seats require a command after --"
  fi
  if [[ -n "$prompt_file" && ! -f "$prompt_file" ]]; then
    die "start: prompt file not found: $prompt_file"
  fi

  local mf dry herdr_active
  mf="$(read_manifest "$run_dir")"
  dry="$(printf '%s' "$mf" | jq -r '.dry_route')"
  herdr_active="$(printf '%s' "$mf" | jq -r '.herdr_active')"

  if [[ "$dry" == "true" ]]; then
    die "start: --dry-route is non-executing; no seats or panes"
  fi

  local key result sentinel wrapper status_file deadline
  key="$(job_key "$seat" "$round")"
  result="$run_dir/results/${key}.txt"
  sentinel="$run_dir/sentinels/${key}"
  wrapper="$run_dir/wrappers/run_${key}.zsh"
  status_file="$run_dir/status/${key}"
  deadline=$(( $(now_epoch) + timeout + GRACE ))
  # A later start for the same seat/round (or a coordinator that reused --round)
  # must not harvest a leftover sentinel against a freshly truncated result.
  rm -f "$sentinel" "${sentinel}.tmp"
  : >"$result"

  local argv_json='[]' pid_file
  pid_file="$run_dir/status/${key}.pid"
  if [[ $# -gt 0 ]]; then
    argv_json="$(jq -nc --args '$ARGS.positional' -- "$@")"
  fi

  write_job "$run_dir" "$seat" "$round" "$(jq -nc \
    --arg seat "$seat" --arg round "$round" --argjson native "$native" \
    --argjson timeout "$timeout" --arg result "$result" --arg sentinel "$sentinel" \
    --arg wrapper "$wrapper" --arg status_file "$status_file" \
    --arg pid_file "$pid_file" \
    --argjson deadline_epoch "$deadline" --argjson argv "$argv_json" \
    --arg prompt_file "$prompt_file" \
    '{
      seat: $seat, round: $round, native: ($native==1), timeout: $timeout,
      status: "pending", pane_id: null, result: $result, sentinel: $sentinel,
      wrapper: $wrapper, status_file: $status_file, pid_file: $pid_file,
      deadline_epoch: $deadline_epoch, argv: $argv, prompt_file: $prompt_file,
      exit_code: null, mode: "pending", reason: ""
    }')"

  if [[ "$native" -eq 1 ]]; then
    update_job "$run_dir" "$seat" "$round" '.status="native" | .mode="native"'
    jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
    return 0
  fi

  write_wrapper "$wrapper" "$result" "$sentinel" "$seat" "$round" "$prompt_file" "$@"

  local mode="local"
  if [[ "$herdr_active" == "true" ]]; then
    local pane started
    acquire_run_lock "$run_dir"
    if pane="$(allocate_pane "$run_dir")"; then
      if pane_run_wrapper "$pane" "$wrapper"; then
        mark_workers_started "$run_dir"
        mode="herdr"
        update_job "$run_dir" "$seat" "$round" \
          --arg pane "$pane" --arg mode "$mode" \
          '.status="running" | .pane_id=$pane | .mode=$mode'
        release_run_lock "$run_dir"
        jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
        return 0
      fi
      # pane run failed. If no worker has started yet, treat as setup failure.
      started="$(jq -r '.workers_started' "$(manifest_path "$run_dir")")"
      if [[ "$started" != "true" ]]; then
        close_owned_empty "$run_dir"
        herdr_active=false
        release_run_lock "$run_dir"
      else
        update_job "$run_dir" "$seat" "$round" \
          --arg pane "$pane" \
          '.status="failed" | .mode="herdr" | .pane_id=$pane | .reason="pane_run"'
        release_run_lock "$run_dir"
        jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
        return 0
      fi
    else
      started="$(jq -r '.workers_started' "$(manifest_path "$run_dir")")"
      if [[ "$started" != "true" ]]; then
        close_owned_empty "$run_dir"
        herdr_active=false
        release_run_lock "$run_dir"
      else
        # Pool is full of preserved failed panes; do not open a 5th pane
        # and do not silently switch this seat to local after workers started.
        update_job "$run_dir" "$seat" "$round" \
          '.status="failed" | .mode="herdr" | .reason="no_pane"'
        release_run_lock "$run_dir"
        jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
        return 0
      fi
    fi
  fi

  # Local path (default, --no-herdr, missing deps, or Herdr setup fallback).
  mode="local"
  update_job "$run_dir" "$seat" "$round" --arg mode "$mode" '.status="running" | .mode=$mode | .pane_id=null'
  run_wrapper_local_bg "$wrapper" "$pid_file" "$run_dir/diag/${key}.local.log"
  jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
}

wait_one() {
  local run_dir="$1" seat="$2" round="$3"
  local job status deadline now
  job="$(read_job "$run_dir" "$seat" "$round")"
  status="$(printf '%s' "$job" | jq -r '.status')"
  if [[ "$status" == "native" ]]; then
    printf '%s' "$job"
    return 0
  fi
  deadline="$(printf '%s' "$job" | jq -r '.deadline_epoch')"
  while true; do
    harvest_job_if_done "$run_dir" "$seat" "$round"
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    case "$status" in
      success|failed|timeout|native) break ;;
    esac
    now="$(now_epoch)"
    if [[ "$now" -ge "$deadline" ]]; then
      update_job "$run_dir" "$seat" "$round" '.status="timeout" | .reason="missing_sentinel"'
      kill_local_job "$run_dir" "$seat" "$round"
      break
    fi
    sleep "$POLL"
  done
  jq -c '.' "$(job_path "$run_dir" "$seat" "$round")"
}

cmd_wait() {
  need_jq
  local run_dir="${1:-}"; shift || true
  local seat="" round=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seat) seat="${2:-}"; shift 2 ;;
      --round) round="${2:-}"; shift 2 ;;
      *) die "wait: unknown option: $1" ;;
    esac
  done
  [[ -n "$run_dir" && -n "$seat" && -n "$round" ]] || die "wait requires run_dir --seat --round"
  wait_one "$run_dir" "$seat" "$round"
}

cmd_wait_all() {
  need_jq
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "wait-all requires run_dir"
  local seat round status
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    if [[ "$status" == "running" || "$status" == "pending" ]]; then
      wait_one "$run_dir" "$seat" "$round" >/dev/null
    fi
  done < <(iter_jobs "$run_dir")
  local out='[]' f
  shopt -s nullglob
  for f in "$run_dir"/jobs/*.json; do
    out="$(jq -c --slurpfile j "$f" '. + $j' <<<"$out")"
  done
  shopt -u nullglob
  printf '%s\n' "$out"
}

cmd_ingest() {
  need_jq
  local run_dir="${1:-}"; shift || true
  local seat="" round=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seat) seat="${2:-}"; shift 2 ;;
      --round) round="${2:-}"; shift 2 ;;
      *) die "ingest: unknown option: $1" ;;
    esac
  done
  [[ -n "$run_dir" && -n "$seat" && -n "$round" ]] || die "ingest requires run_dir --seat --round"
  local job status result
  job="$(wait_one "$run_dir" "$seat" "$round")"
  status="$(printf '%s' "$job" | jq -r '.status')"
  result="$(printf '%s' "$job" | jq -r '.result')"
  if [[ "$status" != "success" ]]; then
    echo "council-herdr: ingest failed for ${seat}/${round} status=${status}" >&2
    exit 1
  fi
  # Coordinator reads the result file, never pane scrollback.
  cat -- "$result"
}

pane_has_only_success() {
  local run_dir="$1" pane="$2" seat round status job_pane any=0
  while IFS=$'\t' read -r seat round; do
    [[ -z "$seat" ]] && continue
    job_pane="$(jq -r '.pane_id // empty' "$(job_path "$run_dir" "$seat" "$round")")"
    [[ "$job_pane" == "$pane" ]] || continue
    any=1
    status="$(jq -r '.status' "$(job_path "$run_dir" "$seat" "$round")")"
    case "$status" in
      success) ;;
      running|pending) return 1 ;;
      *) return 1 ;;
    esac
  done < <(iter_jobs "$run_dir")
  [[ "$any" -eq 1 ]]
}

cmd_close_success() {
  need_jq
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "close-success requires run_dir"
  acquire_run_lock "$run_dir"
  local keep pane preexisting
  keep="$(jq -r '.keep_panes' "$(manifest_path "$run_dir")")"
  if [[ "$keep" == "true" ]]; then
    jq -c '.' "$(manifest_path "$run_dir")"
    release_run_lock "$run_dir"
    return 0
  fi
  preexisting="$(jq -r '.preexisting_panes[]?' "$(manifest_path "$run_dir")")"
  local remaining='[]'
  while IFS= read -r pane; do
    [[ -z "$pane" ]] && continue
    if printf '%s\n' "$preexisting" | grep -Fxq "$pane"; then
      remaining="$(printf '%s' "$remaining" | jq -c --arg p "$pane" '. + [$p]')"
      continue
    fi
    if pane_has_only_success "$run_dir" "$pane"; then
      herdr pane close "$pane" >/dev/null 2>&1 || true
    else
      remaining="$(printf '%s' "$remaining" | jq -c --arg p "$pane" '. + [$p]')"
    fi
  done < <(jq -r '.owned_panes[]?' "$(manifest_path "$run_dir")")
  update_manifest "$run_dir" --argjson remaining "$remaining" '.owned_panes=$remaining'
  jq -c '.' "$(manifest_path "$run_dir")"
  release_run_lock "$run_dir"
}

cmd_status() {
  need_jq
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "status requires run_dir"
  jq -nc --slurpfile m "$(manifest_path "$run_dir")" --slurpfile jobs "$run_dir"/jobs/*.json \
    '{manifest: $m[0], jobs: $jobs}' 2>/dev/null \
    || jq -nc --slurpfile m "$(manifest_path "$run_dir")" '{manifest: $m[0], jobs: []}'
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || usage 2
  shift || true
  case "$cmd" in
    begin) cmd_begin "$@" ;;
    start) cmd_start "$@" ;;
    wait) cmd_wait "$@" ;;
    wait-all) cmd_wait_all "$@" ;;
    ingest) cmd_ingest "$@" ;;
    close-success) cmd_close_success "$@" ;;
    abort-setup) cmd_abort_setup "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|help) usage 0 ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
