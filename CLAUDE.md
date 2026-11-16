# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

LEGO-related tools, data, and MOCs. This repo was derived from the [fini-net/template-repo](https://github.com/fini-net/template-repo) template and customized with `just clean_template`, so the template's test harness, `CHECKSUMS.json` manifest, `RELEASE_NOTES.md`, and template-only workflows have been removed. The `.just/` scaffolding that remains drives the command-line development process and can be refreshed from the template with `just update_from_template`.

## Development Workflow

This repo uses `just` (command runner) for all development tasks. The workflow is entirely command-line based using `just` and the GitHub CLI (`gh`).

### Standard development cycle

> **AI agents:** Do not run `just pr`. Hand off to the user so they can review and create the PR themselves.

1. `just branch <name>` - Create a new feature branch (format: `$USER/YYYY-MM-DD-<name>`)
2. Make changes and commit. The first commit on a branch must start with an emoji followed by a `[topic_area]` tag (e.g., `🚀 [docs] update CLAUDE.md`, `🐛 [fix] correct typo`). The emoji is a free choice by the committer — there is no recipe that picks one for you. This first commit message becomes the PR title.
3. `just pr` - Create PR, push changes, and watch checks
4. `just merge` - Squash merge PR, delete branch, return to main, and pull latest
5. `just sync` - Return to main branch and pull latest (escape hatch)

### AI Review Workflows

> **AI agents:** Do not run `just pr`. Hand off to the user so they can review and create the PR themselves.

**Claude Review** (enabled: `claude-review = true` in `.repo.toml`):

1. User runs `just pr` - Create PR (`.github/workflows/claude-code-review.yml` reviews it)
2. `just claude_review` - View Claude's latest PR code review comments
3. Make changes based on review feedback, then `just again` to push, update the PR description, and watch checks
4. Iterate as needed

**Copilot Review** (disabled: `copilot-review = false` in `.repo.toml`): the `copilot_pick`, `copilot_refresh`, and `copilot_rollback` recipes still exist, but no Copilot review is requested on PRs in this repo.

### Additional commands

- `just` or `just list` - Show all available recipes
- `just test` - Run the Perl test suite (see [Perl tools](#perl-tools))
- `just claude` - Launch Claude Code in the repo root
- `just prweb` - Open current PR in browser
- `just again` - Push changes, update PR description, and watch GHAs
- `just pr_update` - Update the "Done" section of PR description with current commits
- `just pr_verify` - Add or append to "Verify" section from stdin (with timestamp)
- `just compliance_check` - Run custom repo compliance checks
- `just shellcheck` - Run shellcheck on all bash scripts in just recipes
- `just cue-verify` - Verify `.repo.toml` validity and flag configuration
- `just cue-sync-from-github` - Sync description and topics from GitHub API into `.repo.toml`
- `just repo_toml_generate` - Generate shell variables from `.repo.toml`
- `just repo_toml_check` - Check if generated file is up-to-date
- `just claude_permissions_sort` - Sort Claude Code permissions in canonical order
- `just claude_permissions_check` - Check Claude Code permissions structure
- `just editorconfig_check` - Verify `.editorconfig` compliance (also runs in `_pr-hook`)
- `just release <version>` - Create a GitHub release with auto-generated notes
- `just release_age` - Check how long ago the last release was
- `just utcdate` - Print UTC date in ISO format (used in branch names)

## Template maintenance

This is a derived repo, so the template-sync recipes in `.just/template-sync.just` mostly reach out to the template itself:

- `just update_from_template` - Update `.just/` modules from [fini-net/template-repo](https://github.com/fini-net/template-repo) (safe, preserves local mods)
- `just checksums_verify` - Check local `.just/` files against template versions; fetches the checksum manifest from the template repo over the network
- `just checksums_diff <file>` - Show diff between a local `.just/*` file and the latest template version (also a network fetch)
- `just checksums_generate` - Template-repo only; prompts for confirmation here and would create a manifest that nothing in this repo consumes
- `just template_sync_test` - Template-repo only; prints a notice and exits 0 here because the test harness and fixtures were removed by `clean_template`

There is no local `.just/CHECKSUMS.json` or `.just/RELEASE_NOTES.md`; those files live only in the template repo. Version bumps and release-notes entries are template-repo concerns and do not apply to this repo.

## Architecture

### Modular justfile structure

The main `justfile` imports nine modules (each with `import?`, so a module can be removed without breaking the rest):

- `.just/compliance.just` - `compliance_check` (community-standards heuristics) and `editorconfig_check`
- `.just/gh-process.just` - Git/GitHub workflow automation (core PR lifecycle)
- `.just/pr-hook.just` - Pre-PR hook: runs `shellcheck`, `editorconfig_check`, and `claude_permissions_sort` before every `just pr` / `just again`
- `.just/shellcheck.just` - Shellcheck linting for bash scripts in just recipes
- `.just/cue-verify.just` - File format validation using Cue
- `.just/claude.just` - Claude Code permission management
- `.just/copilot.just` - GitHub Copilot integration recipes (review currently disabled via flag)
- `.just/repo-toml.just` - Repository metadata extraction and shell variable generation
- `.just/template-sync.just` - Template synchronization recipes (see [Template maintenance](#template-maintenance))

### Repository metadata extraction

The `.just/repo-toml.just` module provides shell variable generation:

- **Variable generation** - Exports `.repo.toml` data as sourceable shell variables
- **Automatic derivation** - Computes `ORG_NAME` and `REPO_NAME` from URLs
- **Format conversion** - Handles TOML arrays as both bash arrays and CSV strings
- **Conditional logic** - Enables flag-based feature toggling in recipes

The generated `.just/repo-toml.sh` file is gitignored and regenerated on demand using `just repo_toml_generate`.

### Git/GitHub workflow details

The `.just/gh-process.just` module implements the entire PR lifecycle:

- **Branch creation** - Dated branches with `$USER/YYYY-MM-DD-<name>` format
- **PR creation** - First commit message becomes PR title, all commits listed in "Done" section of PR body
- **Sanity checks** - Prevents empty PRs, enforces branch strategy via hidden recipes (`_on_a_branch`, `_has_commits`, `_main_branch`, `_on_a_pull_request`, `_wait_for_checks`)
- **Check watching** - Waits up to 30 seconds for checks to start, then watches them via `gh observer` if installed, falling back to `gh pr checks --watch -i 5`
- **AI integration** - After PR checks complete, conditionally displays Copilot and Claude Code review comments based on `.repo.toml` flags (`copilot-review` and `claude-review`); only Claude runs in this repo
- **Merge automation** - Squash merge, delete remote branch, return to main, pull latest
- **PR updates** - `pr_update` refreshes the "Done" section with current commits; `pr_verify` adds timestamped verification outputs

### Repository metadata

The `.repo.toml` file contains structured metadata:

- **about section** - Description, topics, and license
- **urls section** - Git SSH and web URLs
- **flags section** - Boolean feature flags (claude, claude-review, copilot-review, standard-release, asciinema-record)

The `cue-verify` recipe validates `.repo.toml` in three stages:

1. Cue validates TOML structure and types against `docs/repo-toml.cue` schema
2. Validates flags match actual configuration (checks for required files)
3. Validates GitHub metadata sync (description and topics match GitHub API)

### Shellcheck integration

The `.just/shellcheck.just` module extracts and validates bash scripts:

- **Script extraction** - Uses awk to identify recipes with bash shebangs (`#!/usr/bin/env bash` or `#!/bin/bash`)
- **Automatic detection** - Scans all justfiles in repo (main `justfile` and `.just/*.just`)
- **Temporary file handling** - Creates temporary files for each script and runs shellcheck with `-x -s bash` flags
- **Detailed reporting** - Shows which file and recipe each issue is in, with colored output
- **Exit code** - Returns 1 if issues found, 0 if all scripts pass

### Claude Code permission management

The `.just/claude.just` module manages `.claude/settings.local.json`:

- **Canonical sorting** - Groups permissions by type (Bash, WebFetch, WebSearch, Other) and sorts alphabetically within groups
- **Structure validation** - Checks for required JSON structure and permission arrays
- **Backup handling** - Creates backups before modifications and restores on error
- **Permission analytics** - Reports counts and breakdown by permission type

### Standard release workflow

The release workflow is enabled (`standard-release = true` in `.repo.toml`):

- **Release creation** - `just release <version>` creates GitHub releases with auto-generated notes
- **Signed assets** - The tag push fires `.github/workflows/release.yml`, which attaches a cosign-signed tarball, checksums, SBOM, GitHub-native attestations, and SLSA-3 provenance to the release (this is what satisfies OpenSSF Scorecard's Signed-Releases check)
- **Release monitoring** - `just release_age` checks release freshness and commit count since last release

### GitHub Actions

Workflows in `.github/workflows/`:

- **actionlint.yml** - Lints GitHub Actions workflow files
- **auto-assign.yml** - Automatically assigns issues/PRs to `chicks-net`
- **checkov.yml** - Security scanning for GitHub Actions (continues on error, outputs SARIF)
- **claude-code-review.yml** - Claude AI review automation on PRs
- **claude.yml** - Claude integration for `@claude` mentions and issue/PR events
- **cue-verify.yml** - Validates `.repo.toml` format and flags
- **dependency-review.yml** - Scans dependency changes in PRs for known vulnerabilities
- **editorconfig.yml** - Validates files against `.editorconfig`
- **gitleaks.yml** - Secret scanning
- **markdownlint.yml** - Enforces markdown standards using `markdownlint-cli2`
- **perl-test.yml** - Runs the Perl test suite
- **release.yml** - Attaches signed assets (cosign bundle, checksums, SBOM, attestations, SLSA-3 provenance) to `v*` tag releases
- **renovate-validate.yml** - Validates `.github/renovate.json` config
- **scorecards.yml** - OpenSSF Scorecard supply-chain security analysis
- **zizmor.yml** - Security analysis of GitHub Actions workflows

### Markdown linting

Configuration in `.markdownlint.yml`:

- MD013 (line length) is disabled
- MD041 (first line h1) is disabled
- MD042 (no empty links) is disabled
- MD004 (list style) enforces dashes
- MD010 (tabs) ignores code blocks

Run locally: `markdownlint-cli2 **/*.md`

One deliberate exception to the markdownlint habit: GitHub descriptions - issue bodies, PR descriptions, release notes, comments, anything posted to github.com via `gh` or the web UI - must not be hard-wrapped. Keep each paragraph, list item, and table row on a single line, no matter how long it gets. GitHub renders markdown in a column narrower than the usual 80-character wrap, so pre-wrapped text word-wraps earlier than it should to fit the page and breaks sentences mid-line instead of flowing to the full page width. The wrapping preference applies to `.md` files in the repo, not to text posted to GitHub.

### Perl tools

Perl code lives in `lib/Lego/` (modules), `bin/` (CLI entry points), and
`t/` (tests). Core modules only - there is no cpanfile and no CPAN
dependency; the system perl (>= 5.20) is enough. The one wrinkle is that
HTTPS fetching needs `IO::Socket::SSL` and `Net::SSLeay`, which aren't
core everywhere; the tools detect that and exit with a message. Perl files
are tab-indented per `.editorconfig`.

There are two CLIs, each a thin layer over a data-source client, a
`PartsList`, and a pure analysis module:

| CLI | Client (all I/O) | Analysis (no I/O) |
| --- | --- | --- |
| `bin/part-colors` | `Lego::Rebrickable` | `Lego::Compare` |
| `bin/brick-labels` | `Lego::BrickArchitect` | `Lego::LabelCoverage` |

- `lib/Lego/PartsList.pm` - parts lists from CSV files or Rebrickable set
  numbers, with LDraw/BrickLink variant-number resolution (3684c becomes
  3684). Both CLIs share it, so part-number handling stays consistent
- `lib/Lego/Rebrickable.pm` - Rebrickable API v3 client. Never follows
  redirects, so the `Authorization` key can't leak to another host
- `lib/Lego/BrickArchitect.pm` - scrapes Tom Alphin's LEGO Parts Guide and
  indexes the frozen v40 label zip. Unlike the Rebrickable client it
  *does* follow redirects, because the guide 301s old part numbers to new
  ones (`/parts/3684` -> `/parts/98560`) and that's how aliases are found.
  The HTML parsers are intentionally small and die loudly if the markup
  drifts. Label files are never stored or redistributed (see
  [issue #5][issue-5]) - only part numbers are read from them
- `lib/Lego/Constants.pm` - values shared across modules (`$SAFE_NUMBER`,
  the regex every part/set number must pass before it goes into a URL, and
  `$MOC_ISSUE_URL`). Only add things used by more than one module
- `bin/generate-rebrickable-fixtures` - refreshes the committed fixture
  cache in `t/fixtures/rebrickable/` from the live API; needs
  `REBRICKABLE_API_KEY` in the environment (a gitignored `.env` holds it).
  `t/fixtures/brickarchitect/` has no generator - those pages are
  hand-curated

Both clients share the same caching design: one file per URL under
`data/cache/` (gitignored), keyed by SHA-1 of the URL; 404s are cached as a
sentinel body so "not found" replays offline; and an `offline` mode dies on
any cache miss, which keeps tests hermetic. Each CLI's `--man` has the full
option docs.

Testing:

- `just test` runs the whole suite (`prove -lr t/`) against the committed
  fixtures, no network needed
- One file: `prove -l t/label-coverage.t` (add `-v` for per-test output)
- `t/brick-labels-cli.t` runs the actual script end to end against a cache
  pre-seeded from fixtures; CLI output bugs only show up there
- Live smoke tests in `t/live/` skip by default:
  `LIVE_API=1 REBRICKABLE_API_KEY=... prove -l t/live/api.t`,
  `LIVE_API=1 prove -l t/live/brickarchitect.t` (add `LIVE_LEGACY=1` to
  also pull the 20 MB v40 zip)

CI runs the suite in `.github/workflows/perl-test.yml`. Rebrickable removed
MOC endpoints from API v3 on 2020-04-19, so MOC parts lists come in via
`--parts-file` - background in [issue #2][issue-2].

[issue-2]: https://github.com/fini-net/chicks-bricks/issues/2
[issue-5]: https://github.com/fini-net/chicks-bricks/issues/5

## Dependencies

### Required tools

- `just` - Command runner for all recipes (>= 1.29.0: positional-argument recipes use the per-recipe `[positional-arguments]` attribute)
- `gh` - GitHub CLI for PR and release management
- `git` - Version control
- `perl` - Runs the tools in `bin/` and the test suite (>= 5.20, core modules only; `prove` ships with perl)

### Optional tools

- **gum** - Interactive spinner for check waiting and the `copilot_pick` picker
  - Install: `brew install gum` (macOS) or see <https://github.com/charmbracelet/gum>
- **asciinema** - Terminal recorder for `pr`/`again` recipes (only when `asciinema-record = true` in `.repo.toml`, which is currently `false` in this repo)
  - Install: `brew install asciinema` (macOS) or see <https://asciinema.org>
  - Usage: casts are recorded into `.cache/<recipe>-<PR#>-<pid>.cast` when enabled; casts may capture sensitive output (gh, tokens, file dumps) - review before sharing

## Important implementation notes

- All git commands in `.just/gh-process.just` use standard git (no aliases required)
- The `pr` recipe runs the `_pr-hook` recipe (shellcheck, editorconfig check, permission sort) before creating a PR; a failing hook blocks the PR
- The `.just` directory contains the modular just recipes, kept in sync with the template via `just update_from_template`. Treat `.just/**` as vendored: fix problems upstream in the template rather than here. `.github/instructions/review-guidance.instructions.md` came from the template too (which is why it calls this repo "a template") and lists bash idioms in `.just/` that are intentional, not bugs
- just catches errors from commands when the recipe isn't a shebang form that runs another scripting engine
- just colors come from built-in constants: `{{GREEN}}`, `{{BLUE}}`, `{{RED}}`, `{{YELLOW}}`, `{{NORMAL}}`
- Hidden recipes (prefixed with `_`) are internal helpers and not shown in `just --list`
- The `again` recipe is for iterating on PRs: push, update description, watch checks
- AI agents (Claude Code, Copilot, etc.) must not run `just pr`; the user should create the PR themselves after reviewing changes
