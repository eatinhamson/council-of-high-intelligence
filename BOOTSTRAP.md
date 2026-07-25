# BOOTSTRAP — Local Setup & Operations

> Local usage notes for this clone of [0xNyk/council-of-high-intelligence](https://github.com/0xNyk/council-of-high-intelligence).
> This is an **upstream clone with local patches** — upstream docs (README.md, SKILL.md, CONTRIBUTING.md) are left as-is.
> See README.md for the full project docs; this file covers what's specific to running it here.

## What this is

A Claude Code / Codex **skill + agent pack** (prompt engineering, no application code): the `/council`
slash command convenes 3–18 historical-thinker personas (defined in `agents/council-*.md`) for
structured multi-round deliberation, optionally routing members across Anthropic, OpenAI (`codex`),
Google (`gemini`), and Ollama for genuine model diversity.

## Setup (this machine)

```bash
cd ~"/Vault Keeper/Tooling/council-of-high-intelligence"
./install.sh --dry-run     # preview
./install.sh               # installs 18 agents -> ~/.claude/agents/
                           #          skill     -> ~/.claude/skills/council/SKILL.md
                           #          detect script -> ~/.claude/skills/council/scripts/
./install.sh --codex       # optionally also install the Codex skill -> ~/.codex/skills/council/
```

Restart Claude Code afterwards, then: `/council --quick Should we add caching here?`

**No `.env` file is needed.** This project reads no environment variables and stores no API keys —
external providers authenticate through their own CLIs (`codex`, `gemini`, `ollama`). That is why
there is no `.env.example` here.

## Health check

```bash
./scripts/health_check.sh                    # read-only: repo integrity + installed state + provider probe
./scripts/council-simulation-checklist.sh    # deeper validation (runs install.sh --dry-run, writes /tmp logs)
```

`health_check.sh` is a local addition (not upstream). It exits 0 when healthy and warns when:
- only one LLM provider is available (multi-provider routing inactive),
- the installed copy under `~/.claude/` is missing or stale vs the repo,
- there are uncommitted local patches.

Re-run `./install.sh` whenever the repo changes — the skill runs from `~/.claude/`, **not** from this clone.

## Local patches (uncommitted, on top of upstream c4d91f0)

The working tree carries local consistency fixes not yet committed or upstreamed:

- `SKILL.md` — member count corrected 11 → 18 in the `--members` flag and `classic` profile
- `agents/*.md` (ada, aristotle, aurelius, karpathy, machiavelli, sutskever, torvalds) —
  `duo_keywords`, `triads`, `polarity_pairs`, `profiles` frontmatter aligned with SKILL.md's
  duo-pair / triad tables (e.g. sutskever↔machiavelli pairing, aurelius in `ai-safety` triad)
- `configs/provider-model-slots.example.yaml` — model IDs updated (`gpt-5` → `gpt-5.4`,
  dropped `xai/grok-4` seat in favor of ollama)

**Action item:** commit these on a local branch (or PR upstream) so `git pull` doesn't force a merge
and the patches can't be lost to a stray `git checkout -- .`.

## Known issues & maintenance notes

1. **Four sources of truth for the roster.** The member table, triads, and polarity pairs are
   duplicated across `README.md`, `SKILL.md`, `SKILL.codex.md`, and per-agent frontmatter. Drift has
   already happened once (upstream said "2-11 members"). When editing, update all four, then run the
   checklist script.
2. **Hardcoded model IDs.** `scripts/detect-providers.sh` (gpt-5.4, gemini-2.5-pro) and
   `configs/auto-route-defaults.yaml` duplicate model names; they will go stale as providers ship new
   models. Keep them in sync with each other.
3. **Checklist requires python3.** `council-simulation-checklist.sh` uses python3 to count agents; if
   python3 is missing, `agent_count` becomes `unknown` and the later `-eq` comparison aborts the
   script under `set -e`.
4. **No uninstall path.** `install.sh` copies 18 files into the shared `~/.claude/agents/` namespace
   with no `--uninstall`; remove with `rm ~/.claude/agents/council-*.md` and
   `rm -rf ~/.claude/skills/council` if needed.
5. **`codex exec` invocation may drift.** SKILL.md dispatches OpenAI members via
   `codex exec -c model=... -c auto_approve=true`; verify against the installed codex CLI version
   before relying on multi-provider mode.
6. **Detection assumes Anthropic is always available** (true inside Claude Code, not elsewhere).

## Repo map

| Path | Role |
|------|------|
| `SKILL.md` / `SKILL.codex.md` | Coordinator protocol (modes, routing, verdict templates) |
| `agents/council-*.md` | 18 persona definitions with routing frontmatter |
| `install.sh` | Installer (`--dry-run`, `--codex`, `--copy-configs`) |
| `scripts/detect-providers.sh` | Provider probe, emits JSON (used by SKILL.md Step 1) |
| `scripts/council-simulation-checklist.sh` | Upstream validation suite |
| `scripts/health_check.sh` | Local read-only health check |
| `configs/` | Auto-route tier defaults + manual seat-mapping example |
| `demos/` | Session pack + verdict template examples |
