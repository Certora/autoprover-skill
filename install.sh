#!/usr/bin/env bash
#
# Installer for the certora-verify agent skill and the toolchain it drives.
#
# Two jobs, each skippable:
#
#   1. the toolchain - one `uv tool install` that brings in certora-autosetup
#                      and certora-cli together. uv itself is a prerequisite:
#                      this script never downloads a program to run it.
#   2. the skill     - into the skill directory of each agent found here.
#
# It installs no Solidity compiler. Which compilers a project needs is a
# property of that project, not of this machine, so the skill works it out in
# Phase 3 from the project's own build configuration.
#
# Nothing here deletes anything. Everything it installs belongs to uv, so
# `uv tool uninstall` is what removes it; the skill is a symlink or a copy you
# can remove yourself.
#
# Written for bash 3.2, the version macOS still ships: no associative arrays,
# no `readarray`, no `${var^^}`. A directory a user names can hold a space, so
# the install targets travel as an indexed array and as one line each, never as
# a space-separated string.

set -euo pipefail

INSTALLER_VERSION="0.1.0"

SELF_NAME=${0##*/}
# A user CDPATH would make the cd below print, and possibly land, somewhere else.
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")" && pwd -P)
SKILL_NAME="certora-verify"
SKILL_SRC="$REPO_ROOT/skills/$SKILL_NAME"

# The AutoProver commit this release of the skill is built against, kept in one
# file beside the skill so the skill carries its own pin wherever it is
# installed. The skill documents specific autosetup flags and behaviours, so
# tracking a moving HEAD would mean two people installing a week apart get
# different tools behind the same instructions.
REF_FILE="$SKILL_SRC/AUTOPROVER_REF"
AUTOPROVER_REPO="https://github.com/Certora/AutoProver"

# The package that ships certora-autosetup. It is not on PyPI, so it installs
# straight from the git URL. The [certora-cli] extra is mandatory, not a
# nicety: certora-cli is absent from [project.dependencies] and lives only in
# that extra, so without it the install has no certoraRun and autosetup cannot
# compile or submit anything. [ml] is deliberately left out: it pulls torch and
# transformers for the RAG path, which certora-autosetup never imports.
AI_COMPOSER_PKG='ai-composer[certora-cli]'
AI_COMPOSER_TOOL="ai-composer"
CLI_PKG="certora-cli"
PYTHON_VERSION="3.12"                    # the floor the project declares, and what its CI uses
MIN_JAVA_MAJOR=19                    # certora-cli's MIN_JAVA_VERSION

UV_INSTALL_DOCS="https://docs.astral.sh/uv/getting-started/installation/"
UV_DEFAULT_BIN="$HOME/.local/bin"

# Agents whose skill directories this installer knows how to write, as
# key|config-home|binary. A row is chosen when its home exists or its binary is
# on PATH. `agents` is the cross-agent convention rather than one product's
# private config, so it has no binary and is always written.
AGENT_TABLE="claude|${CLAUDE_CONFIG_DIR:-$HOME/.claude}|claude
codex|${CODEX_HOME:-$HOME/.codex}|codex
cursor|$HOME/.cursor|cursor
gemini|$HOME/.gemini|gemini
opencode|${XDG_CONFIG_HOME:-$HOME/.config}/opencode|opencode
goose|${XDG_CONFIG_HOME:-$HOME/.config}/goose|goose
agents|$HOME/.agents|"

# ---------------------------------------------------------------- options ---

DO_TOOLCHAIN=1
DO_SKILL=1
COPY=0
REINSTALL=0
ASSUME_YES=0
SKILL_DIRS=()             # --dir overrides the table entirely
REF_OVERRIDE=""
WARNINGS=""

# adopt_uv prepends to PATH so the rest of this run can call uv by name. The
# reachability check must not see that: it answers whether the user's next
# shell finds a command, so it reads the PATH this script started with.
ORIG_PATH="$PATH"

# --------------------------------------------------------------- plumbing ---

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Collected and reprinted at the end. A warning never changes the exit code:
# it is for things you can fix afterwards without re-running this script.
warn() {
  printf 'warning: %s\n' "$*" >&2
  WARNINGS="$WARNINGS
  $*"
}

# Echo, then run. A failing command aborts the script under `set -e`; the one
# place that is not wanted is the per-directory loop in install_skill, which
# checks the status itself.
run() {
  printf '  + %s\n' "$*"
  "$@"
}

# Dies when stdin is not a terminal, which is what makes `./install.sh
# </dev/null` print the whole plan and exit having changed nothing.
confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "$1 -- stdin is not a terminal, so re-run with --yes to accept non-interactively."
  fi
  printf '%s [y/N] ' "$1"
  local reply=""
  read -r reply </dev/tty || reply=""
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<EOF
$SELF_NAME - install the certora-verify skill and the toolchain it drives.

Usage: ./$SELF_NAME [options]

Requires uv (https://docs.astral.sh/uv/). This script installs no program it
downloads: it refuses to run rather than fetch one.

What it installs:
  the toolchain    one command that brings in certora-autosetup and
                   certora-cli together, both owned by uv:
                     uv tool install --with-executables-from $CLI_PKG \\
                       '$AI_COMPOSER_PKG @ git+$AUTOPROVER_REPO@<ref>'
                   plus solc-select, which manages Solidity compilers.
  the skill        into every agent skill directory found on this machine.

It installs no Solidity compiler. The skill reads the target project's build
configuration and provisions what that project needs, in Phase 3.

Options:
  --skill-only          install only the skill; touch no toolchain
  --deps-only           install only the toolchain; touch no skill directory
  --dir <path>          write the skill here instead of the detected
                        directories. Repeatable.
  --copy                copy the skill instead of symlinking it
  --reinstall           reinstall the toolchain even if it is present, and let
                        uv take over command names another tool owns
  --autoprover-ref <r>  build from this AutoProver ref instead of the pinned one
  -y, --yes             answer yes to every prompt
  -h, --help            this text

With stdin closed (./$SELF_NAME </dev/null) it prints what it would do and
exits without changing anything.

Removing it again: \`uv tool uninstall $AI_COMPOSER_TOOL solc-select\` takes back
every command it installed, and the skill is a symlink or directory you can
remove yourself.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      usage; exit 0 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      --skill-only)   DO_TOOLCHAIN=0 ;;
      --deps-only)    DO_SKILL=0 ;;
      --copy)         COPY=1 ;;
      --reinstall)    REINSTALL=1 ;;
      --dir)
        [ $# -ge 2 ] || die "--dir needs a path."
        SKILL_DIRS+=("$2"); shift ;;
      --autoprover-ref)
        [ $# -ge 2 ] || die "--autoprover-ref needs a git ref."
        REF_OVERRIDE="$2"; shift ;;
      -*)             die "unknown option: $1 (try --help)" ;;
      *)              die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
  done

  if [ "$DO_TOOLCHAIN" -eq 0 ] && [ "$DO_SKILL" -eq 0 ]; then
    die "--skill-only and --deps-only together leave nothing to do."
  fi
}

# ------------------------------------------------------------- preflight ----

autoprover_ref() {
  if [ -n "$REF_OVERRIDE" ]; then
    printf '%s' "$REF_OVERRIDE"
    return 0
  fi
  [ -f "$REF_FILE" ] || die "$REF_FILE is missing; it holds the AutoProver ref this skill is built against."
  tr -d '[:space:]' < "$REF_FILE"
}

java_major() {
  local line raw
  command -v java >/dev/null 2>&1 || return 0
  line=$(java -version 2>&1 | head -1) || return 0
  raw=$(printf '%s' "$line" | sed -n 's/.*"\([^"]*\)".*/\1/p')
  [ -n "$raw" ] || return 0
  # Both the "21.0.1" and the old "1.8.0_292" spellings.
  case "$raw" in
    1.*) printf '%s' "$raw" | cut -d. -f2 | sed 's/[^0-9].*//' ;;
    *)   printf '%s' "$raw" | cut -d. -f1 | sed 's/[^0-9].*//' ;;
  esac
}

preflight() {
  step "Preflight"
  [ -d "$SKILL_SRC" ] || die "$SKILL_SRC is missing; run this from a checkout of the skill repository."
  info "skill source: $SKILL_SRC"

  local major
  major=$(java_major)
  # A warning, not a failure: this script installs no JVM, and the skill
  # placement does not need one. Phase 0 of the skill stops a verification run
  # over a missing Java, which is the only thing it actually breaks.
  if [ -z "$major" ]; then
    warn "no Java found. certora-autosetup shells out to certora-cli's typechecker jars, so install a JDK $MIN_JAVA_MAJOR or newer before a verification run."
  elif [ "$major" -lt "$MIN_JAVA_MAJOR" ]; then
    warn "Java $major is older than the $MIN_JAVA_MAJOR certora-cli needs; a verification run will fail until you upgrade it."
  else
    info "java: $major"
  fi
}

# ------------------------------------------------------------------- uv ------

# uv on PATH, or at the place its own installer puts it. Both are checked
# because the PATH export this script makes after installing uv is
# process-local: without the second check a re-run from a shell that never
# sourced the new PATH would decide uv is missing and download it again.
uv_path() {
  if command -v uv >/dev/null 2>&1; then
    command -v uv
    return 0
  fi
  if [ -x "$UV_DEFAULT_BIN/uv" ]; then
    printf '%s\n' "$UV_DEFAULT_BIN/uv"
    return 0
  fi
  return 1
}

# Puts uv on PATH for the rest of this run if it is installed but unreachable
# by name, so every later `uv ...` call works without a shell restart.
adopt_uv() {
  local found
  found=$(uv_path) || return 1
  if ! command -v uv >/dev/null 2>&1; then
    PATH="${found%/*}:$PATH"
    export PATH
  fi
}

# uv is a prerequisite, not something this script fetches. Installing it means
# running a program this repository has not seen, which is exactly what a
# reader of an install script should not have to accept on trust.
ensure_uv() {
  step "uv"
  if adopt_uv; then
    info "already installed at $(uv_path)"
    return 0
  fi

  die "uv is required and was not found.
  Install it: $UV_INSTALL_DOCS
  Then re-run this script."
}

# ------------------------------------------------------------- toolchain ----

install_toolchain() {
  step "certora-autosetup, certora-cli and solc-select"

  local ref spec bin force=""
  ref=$(autoprover_ref)
  spec="$AI_COMPOSER_PKG @ git+$AUTOPROVER_REPO@$ref"
  [ "$REINSTALL" -eq 0 ] || force="--force"

  bin=$(uv tool dir --bin) || die "\`uv tool dir --bin\` failed; is this uv installation healthy?"

  say "  uv tool install --python $PYTHON_VERSION --with-executables-from $CLI_PKG \\"
  say "    '$spec'"
  say "  uv tool install solc-select"
  say ""
  say "  Commands land in $bin. Expect roughly 740 MB and several minutes on a cold cache."
  confirm "  Proceed?" || die "declined."

  # The submodule rewrite is load bearing: AutoProver's graphcore submodule is
  # recorded with an SSH URL and uv initializes submodules while it builds, so
  # without this the install needs a GitHub SSH key. graphcore itself is public.
  # shellcheck disable=SC2086  # $force is one optional flag, split on purpose
  if ! GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
       GIT_CONFIG_VALUE_0='git@github.com:' \
       run uv tool install --python "$PYTHON_VERSION" $force \
         --with-executables-from "$CLI_PKG" "$spec"; then
    if uv tool list 2>/dev/null | grep -q "^$CLI_PKG "; then
      die "uv refused to take command names that a separate $CLI_PKG tool already owns.
  Either let uv take them over, with:   ./$SELF_NAME --reinstall
  or remove the standalone tool first:  uv tool uninstall $CLI_PKG"
    fi
    die "uv tool install failed; its own error above names what it could not reach."
  fi

  # uv exits 0 when a tool is already installed without necessarily reconciling
  # the entry points, so the thing the flag exists for gets checked directly.
  # shellcheck disable=SC2030  # the subshell PATH is the point: it asks what a shell with $bin on PATH would find
  if ! ( PATH="$bin:$PATH"; command -v certoraRun >/dev/null 2>&1 ); then
    die "certoraRun is not in $bin after the install. Re-run with --reinstall to have uv relink it."
  fi
  info "certoraRun and certora-autosetup are in $bin"

  # shellcheck disable=SC2086  # same optional flag
  run uv tool install $force solc-select
}

# ------------------------------------------------------------------ PATH ----

on_path() {
  # shellcheck disable=SC2031  # ORIG_PATH is deliberately the pre-adopt_uv value
  case ":$ORIG_PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

report_path() {
  local bin
  bin=$(uv tool dir --bin) || return 0
  on_path "$bin" && return 0
  step "PATH"
  warn "$bin is not on your PATH, so nothing you just installed is reachable yet."
  say "  Add this line to your shell startup file:"
  say ""
  say "      export PATH=\"$bin:\$PATH\""
}

# ----------------------------------------------------------------- skill ----

# The directories to write, one per line: --dir if given, else every row of
# AGENT_TABLE whose home exists or whose binary is on PATH.
skill_targets() {
  local dir key home binary
  if [ "${#SKILL_DIRS[@]}" -gt 0 ]; then
    for dir in "${SKILL_DIRS[@]}"; do printf '%s\n' "$dir"; done
    return 0
  fi
  while IFS='|' read -r key home binary; do
    [ -n "$key" ] || continue
    # The cross-agent directory is written whether or not it exists yet, so the
    # target list is never empty and a machine with no agent still gets the
    # skill somewhere an agent will look.
    if [ "$key" = "agents" ] || [ -d "$home" ] ||
       { [ -n "$binary" ] && command -v "$binary" >/dev/null 2>&1; }; then
      printf '%s/skills\n' "$home"
    fi
  done <<EOF
$AGENT_TABLE
EOF
}

install_skill() {
  step "The $SKILL_NAME skill"

  local mode dir dest failures=0 current
  # One line per directory, read into an array, so a path that holds a space
  # stays one destination and a path that holds a wildcard stays itself.
  local targets=()
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    targets+=("$dir")
  done <<EOF
$(skill_targets)
EOF
  [ "${#targets[@]}" -gt 0 ] || die "no skill directory to write."

  # A symlink means `git pull` in this checkout updates every install. A copy
  # is the right answer when there is nothing to pull from, so the default
  # keys off whether this is a git checkout at all.
  if [ "$COPY" -eq 1 ]; then
    mode="copy"
  elif git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    mode="symlink"
  else
    mode="copy"
  fi

  say "  Source: $SKILL_SRC"
  say "  Mode:   $mode"
  say "  Into:"
  for dir in "${targets[@]}"; do say "      $dir/$SKILL_NAME"; done
  confirm "  Proceed?" || die "declined."

  for dir in "${targets[@]}"; do
    dest="$dir/$SKILL_NAME"

    if [ -L "$dest" ]; then
      current=$(readlink "$dest") || current=""
      if [ "$mode" = "symlink" ] && [ "$current" = "$SKILL_SRC" ]; then
        info "$dest already points at this checkout"
        continue
      fi
      if [ "$mode" = "copy" ]; then
        # Copying through the link would write into whatever it points at,
        # which for an install made by this script is this checkout itself.
        warn "$dest is a symlink to $current; --copy will not write through it. Remove the symlink and re-run."
        failures=$((failures + 1)); continue
      fi
    elif [ -e "$dest" ] && [ "$mode" = "symlink" ]; then
      # Replacing a real directory with a symlink needs a delete, and this
      # script never deletes anyone's files. Say what to do instead.
      warn "$dest is a real directory. Move it aside yourself, or re-run with --copy to update it in place."
      failures=$((failures + 1)); continue
    fi

    run mkdir -p "$dir" || { failures=$((failures + 1)); continue; }
    if [ "$mode" = "symlink" ]; then
      run ln -sfn "$SKILL_SRC" "$dest" || { failures=$((failures + 1)); continue; }
    else
      # cp -R of the contents, so an existing install is refreshed without
      # deleting anything. Files removed upstream are not pruned.
      if ! run mkdir -p "$dest" || ! run cp -R "$SKILL_SRC/." "$dest/"; then
        failures=$((failures + 1)); continue
      fi
    fi
  done

  [ "$failures" -eq 0 ]
}

# ----------------------------------------------------------------- notes ----

notes() {
  step "Before your first verification run"
  say "  CERTORAKEY authenticates certoraRun against the cloud prover. This script stores no"
  say "  key; export it in your own shell. No Anthropic key is needed: the skill runs autosetup"
  say "  with --skip-llm and exports a placeholder for the check it makes without reading it."
  say "  Compilers are per project: the skill reads the project's build configuration in"
  say "  Phase 3 and installs what it resolves to, through solc-select."
}

summary() {
  step "Done"
  if command -v uv >/dev/null 2>&1; then
    say "  What uv now owns:"
    uv tool list 2>/dev/null | sed 's/^/    /' || true
  fi
  if [ -n "$WARNINGS" ]; then
    printf '\n== Warnings%s\n' "$WARNINGS"
  fi
}

main() {
  parse_args "$@"
  say "certora-verify installer $INSTALLER_VERSION"

  preflight
  if [ "$DO_TOOLCHAIN" -eq 1 ]; then
    ensure_uv
    install_toolchain
    report_path
  fi
  if [ "$DO_SKILL" -eq 1 ]; then
    install_skill || die "the skill could not be written everywhere; see the warnings above."
  fi
  notes
  summary
}

main "$@"
