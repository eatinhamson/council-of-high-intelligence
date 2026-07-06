#!/usr/bin/env bash
# Council of High Intelligence — read-only health check (local addition, not upstream).
# Verifies repo integrity and installed state without writing anything.
# Usage: ./scripts/health_check.sh   (exit 0 = healthy, 1 = failures found)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

FAILS=0
WARNS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }
warn() { echo "[WARN] $1"; WARNS=$((WARNS + 1)); }

echo "== Council health check: ${REPO_DIR} =="

# --- Repo integrity ---
for f in SKILL.md SKILL.codex.md install.sh CLAUDE.md \
         configs/auto-route-defaults.yaml configs/provider-model-slots.example.yaml; do
  [[ -f "$f" ]] && pass "$f present" || fail "$f missing"
done

[[ -x scripts/detect-providers.sh ]] \
  && pass "detect-providers.sh executable" \
  || fail "detect-providers.sh missing or not executable"

# --- Agent roster ---
agent_count=$(find agents -maxdepth 1 -name 'council-*.md' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$agent_count" -eq 18 ]]; then
  pass "18 council agent files present"
else
  fail "Expected 18 agent files, found ${agent_count}"
fi

frontmatter_ok=true
for agent_file in agents/council-*.md; do
  for field in "^model:" "^tools:" "provider_affinity" "polarity_pairs"; do
    grep -q "$field" "$agent_file" || { warn "$(basename "$agent_file"): missing '${field#^}'"; frontmatter_ok=false; }
  done
done
[[ "$frontmatter_ok" == true ]] && pass "All agents have model/tools/provider_affinity/polarity_pairs frontmatter"

# --- Provider detection (read-only probe) ---
if detect_json="$(bash scripts/detect-providers.sh 2>/dev/null)"; then
  count=$(echo "$detect_json" | sed -n 's/.*"provider_count":\([0-9]*\).*/\1/p')
  if [[ -n "$count" ]]; then
    pass "detect-providers.sh OK (${count} provider(s) available)"
    [[ "$count" -le 1 ]] && warn "Single provider only — multi-provider routing inactive (install codex/gemini/ollama for diversity)"
  else
    fail "detect-providers.sh output missing provider_count"
  fi
else
  fail "detect-providers.sh exited with error"
fi

# --- Git state ---
if git rev-parse --git-dir >/dev/null 2>&1; then
  head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  dirty_count=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  pass "git repo at ${head_sha}"
  if [[ "$dirty_count" -gt 0 ]]; then
    warn "${dirty_count} uncommitted change(s) — local patches not committed (see BOOTSTRAP.md)"
  fi
else
  warn "not a git repository"
fi

# --- Installed state (only meaningful on the host where install.sh ran) ---
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
installed_agents=$(find "${CLAUDE_DIR}/agents" -maxdepth 1 -name 'council-*.md' 2>/dev/null | wc -l | tr -d ' ')
installed_skill="${CLAUDE_DIR}/skills/council/SKILL.md"

if [[ "$installed_agents" -eq 0 && ! -f "$installed_skill" ]]; then
  warn "Council not installed under ${CLAUDE_DIR} (run ./install.sh; ignore if checking from another machine)"
else
  [[ "$installed_agents" -eq "$agent_count" ]] \
    && pass "${installed_agents}/${agent_count} agents installed in ${CLAUDE_DIR}/agents" \
    || warn "Installed agents (${installed_agents}) != repo agents (${agent_count}) — re-run ./install.sh"
  if [[ -f "$installed_skill" ]]; then
    if cmp -s SKILL.md "$installed_skill"; then
      pass "Installed SKILL.md matches repo"
    else
      warn "Installed SKILL.md differs from repo — re-run ./install.sh to sync"
    fi
  else
    warn "Skill not installed at ${installed_skill}"
  fi
  detect_installed="${CLAUDE_DIR}/skills/council/scripts/detect-providers.sh"
  [[ -x "$detect_installed" ]] \
    && pass "Installed detect-providers.sh present (needed by SKILL.md Step 1)" \
    || warn "Installed detect script missing at ${detect_installed} — auto-routing will fail"
fi

echo
echo "== Result: ${FAILS} failure(s), ${WARNS} warning(s) =="
[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
