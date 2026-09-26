#!/usr/bin/env bash
#
# Installer for the certora-verify agent skill and the toolchain it drives.
#
# Four independent, idempotent steps, each skippable:
#
#   1. uv           - the Python tool installer everything else goes through.
#   2. ai-composer  - certora-autosetup, plus certora-cli's certoraRun linked
#                     out of the same tool venv (see link_certora_cli).
#   3. solc         - solc-select, with its artifact directories on PATH.
#                     No compiler is downloaded unless you ask for one.
#   4. the skill    - into the skill directory of each agent found on this box.
#
# Everything it creates is recorded in a state file and removable with
# --self-test exercises the plan and the error paths offline.
#
# Written for bash 3.2, the version macOS still ships: no associative arrays,
# no `readarray`, no `${var^^}`. Lists are space-separated strings.

set -euo pipefail

INSTALLER_VERSION="0.1.0"

SELF_NAME=${0##*/}
# A user CDPATH would make the cd below print, and possibly land, somewhere else.
unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")" && pwd -P)
SELF_PATH="$REPO_ROOT/$SELF_NAME"
SKILL_NAME="certora-verify"
SKILL_SRC="$REPO_ROOT/skills/$SKILL_NAME"

# The AutoProver commit this release of the skill is built against. The skill
# documents specific autosetup flags and behaviours, so tracking a moving HEAD
# would mean two people installing a week apart get different tools behind the
# same instructions. Bump it deliberately; --autoprover-ref overrides it for a
# single run. Any git ref works here: a SHA, a tag, or a branch name.
AUTOPROVER_REF="e6f9e2e4706225adb07178c1866ad61b4d827424"
AUTOPROVER_REPO="https://github.com/Certora/AutoProver"

# The package that ships certora-autosetup. It is not on PyPI, so it installs
# straight from the git URL. The [certora-cli] extra is mandatory, not a
# nicety: certora-cli is absent from [project.dependencies] and lives only in
# that extra, so without it the install has no certoraRun and autosetup cannot
# compile or submit anything. Exactly one of the certora-cli / certora-cli-beta
# / certora-cli-beta-mirror extras may be chosen - they are declared mutually
# exclusive and all ship the same module. [ml] is deliberately left out: it
# pulls torch and transformers (and the nvidia CUDA wheels on Linux) for the
# RAG path, which certora-autosetup never imports.
AI_COMPOSER_PKG='ai-composer[certora-cli]'
AI_COMPOSER_TOOL="ai-composer"
PYTHON_PIN="3.12"                    # the floor the project declares, and what its CI uses
MIN_JAVA_MAJOR=19                    # certora-cli's MIN_JAVA_VERSION
RECOMMENDED_JAVA_MAJOR=21

# autosetup's DEFAULT_SOLC_VERSION: the compiler any run falls back to when it
# cannot pin one from a pragma. Named in warnings, never installed behind your
# back.
AUTOSETUP_DEFAULT_SOLC="0.8.34"

# Where the installer keeps its own files: a record of what it installed, for a
# human to read afterwards. Nothing here removes anything.
STATE_DIR="$HOME/.certora/certora-verify"
STATE_FILE="$STATE_DIR/install-state"

# Agents whose skill directories this installer knows how to write.
AGENT_KEYS="claude codex cursor gemini opencode goose agents"

# ---------------------------------------------------------------- options ---

DO_UV=1
DO_COMPOSER=1
DO_SOLC=1
DO_SKILL=1
SOLC_ONLY=0
DO_SELF_TEST=0
TARGETS=""                # empty means "autodetect"
LINK_MODE="auto"          # auto | symlink | copy
SOLC_VERSIONS=""          # empty means "download nothing"
SOLC_EXPLICIT=0
PROJECT_PATH=""
BIN_DIR_OPT=""            # --bin-dir override; empty means "the uv tool bin dir"
DRY_RUN=0
ASSUME_YES=0
APPEND_PATH=0
REINSTALL=0
CHECK_JAVA=1

# adopt_uv prepends to PATH so the rest of this run can call uv by name. The
# reachability checks must not see that: they answer whether the user's next
# shell finds a command, so they read the PATH this script started with.
ORIG_PATH="$PATH"

# --------------------------------------------------------------- plumbing ---

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

DONE_LINES=""
SKIP_LINES=""
FAIL_LINES=""
record_done() { DONE_LINES="$DONE_LINES$1"$'\n'; }
record_skip() { SKIP_LINES="$SKIP_LINES$1"$'\n'; }
record_fail() { FAIL_LINES="$FAIL_LINES$1"$'\n'; }

toolchain_requested() {
  [ "$DO_UV" -eq 1 ] || [ "$DO_COMPOSER" -eq 1 ] || [ "$DO_SOLC" -eq 1 ]
}

# Membership test for our space-separated lists.
contains() {
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# contains() matches whole space-separated words; these match anywhere. The
# negated form is its own function because `check` runs its arguments as a
# command, where a leading `!` would be read as the command name.
holds() {
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

lacks() { holds "$@" && return 1; return 0; }

# Render a command the way you would have to type it, so the dry-run plan is
# copy-pasteable: arguments holding anything outside a conservative safe set
# (the package spec holds brackets and a space, for one) come back quoted.
pretty_cmd() {
  local out="" arg
  for arg in "$@"; do
    case "$arg" in
      ''|*[!A-Za-z0-9_@%+=:,./-]*) out="$out '$arg'" ;;
      *)                           out="$out $arg" ;;
    esac
  done
  printf '%s' "${out# }"
}

# Run a command, or in --dry-run just show it. Everything that changes the
# machine goes through here, which is what makes --dry-run trustworthy.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would run: %s\n' "$(pretty_cmd "$@")"
    return 0
  fi
  printf '  + %s\n' "$(pretty_cmd "$@")"
  "$@"
}

confirm() {
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
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

composer_spec() {
  printf '%s @ git+%s@%s' "$AI_COMPOSER_PKG" "$AUTOPROVER_REPO" "$AUTOPROVER_REF"
}

usage() {
  cat <<EOF
$SELF_NAME - install the certora-verify skill and the toolchain it drives.

Usage: ./$SELF_NAME [options]

What it installs, in order (each step is idempotent and re-runnable):
  1. uv                     if missing; you are asked before anything is piped to a shell
  2. ai-composer            certora-autosetup, plus certoraRun linked out of the same
                            tool venv so both are on PATH from one install
  3. solc-select            the standard compiler manager. Its artifact directories go
                            on PATH as they are, so autosetup reads its solc-0.8.34
                            naming. No compiler is downloaded unless you pass
                            --solc or --project.
  4. the skill              into every agent skill directory found on this machine

Options:
  --skill-only          install only the skill; touch no toolchain
  --deps-only           install only the toolchain; touch no skill directory
  --solc-only           only the compiler step: install solc-select and the
                        versions named by --solc / --project, and report the
                        PATH line
  --solc "<versions>"   compilers to install, space- or comma-separated.
                        Nothing is downloaded without this or --project.
                        $AUTOSETUP_DEFAULT_SOLC is autosetup's own default compiler.
  --project <path>      also derive the compilers that project's pragmas and
                        foundry.toml require, and install those too
                        (--for-project is accepted as the same thing)
  --autoprover-ref <r>  build ai-composer from this AutoProver ref instead of the
                        pinned $AUTOPROVER_REF
  --bin-dir <path>      link the certora-cli commands here instead of into the
                        uv tool bin dir (this directory is reported for PATH too)
  --target <agent>      write the skill for one agent only, or "all" for every
                        known one. Repeatable. Known: $AGENT_KEYS
  --copy                copy the skill instead of symlinking it
  --symlink             symlink even when this checkout is not a git clone
  --reinstall           reinstall ai-composer / solc-select even if present
  --append-path         append the PATH lines to your shell rc (off by default;
                        without them the lines are printed for you to add yourself)
  --no-java-check       do not fail preflight over a missing or old Java
  --self-test           check the plan and the error paths; needs no network
  --dry-run             print the whole plan and change nothing
  -y, --yes             answer yes to every prompt
  -h, --help            this text

What it writes, and nothing else. It deletes nothing, ever: everything below is
shared with other tools, so removing a piece is the job of the command that owns
it (README.md lists them):
  compiler store:     \$HOME/.solc-select   (solc-select's own, shared with slither et al)
  the toolchain:      \$(uv tool dir) and \$(uv tool dir --bin), where uv keeps its tools
  uv's own trees:     \$HOME/.cache/uv, and the managed CPython under \$HOME/.local/share/uv
  uv itself:          \$HOME/.local/bin, if you let it install uv
  its own state:      $STATE_DIR   (the state file recording what it installed)
  the skill:          the agent skill directories it names before it writes them

--project reads your project and writes nothing into it: autosetup's resolver logs
into .certora_internal/ in the working directory, so it is run from a temporary one.

It edits no shell startup file unless you pass --append-path: the uv installer is
run with INSTALLER_NO_MODIFY_PATH=1, which is what stops it writing to ~/.zshrc,
~/.profile and the fish config.
EOF
}

# ------------------------------------------------------------------- args ---

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      usage; exit 0 ;;
      --skill-only)   DO_UV=0; DO_COMPOSER=0; DO_SOLC=0 ;;
      --deps-only)    DO_SKILL=0 ;;
      --solc-only)    DO_UV=0; DO_COMPOSER=0; DO_SKILL=0; SOLC_ONLY=1 ;;
      --self-test)    DO_SELF_TEST=1 ;;
      --solc)
        [ $# -ge 2 ] || die "--solc needs a version list, e.g. --solc \"0.8.30 0.8.37\""
        SOLC_VERSIONS="$(printf '%s' "$2" | tr ',' ' ')"; SOLC_EXPLICIT=1; shift ;;
      --project|--for-project)
        [ $# -ge 2 ] || die "$1 needs a path"
        PROJECT_PATH="$2"; shift ;;
      --autoprover-ref)
        [ $# -ge 2 ] || die "--autoprover-ref needs a git ref (a SHA, tag or branch)"
        AUTOPROVER_REF="$2"; shift ;;
      --bin-dir)
        [ $# -ge 2 ] || die "--bin-dir needs a path"
        BIN_DIR_OPT="$2"; shift ;;
      --target)
        [ $# -ge 2 ] || die "--target needs an agent name, one of: $AGENT_KEYS all"
        TARGETS="$TARGETS $2"; shift ;;
      --copy)         LINK_MODE="copy" ;;
      --symlink)      LINK_MODE="symlink" ;;
      --reinstall)    REINSTALL=1 ;;
      --append-path)  APPEND_PATH=1 ;;
      --no-java-check) CHECK_JAVA=0 ;;
      --dry-run)      DRY_RUN=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      -*)             die "unknown option: $1 (try --help)" ;;
      *)              die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
  done

  if [ "$DO_SELF_TEST" -eq 1 ]; then
    return 0
  fi

  toolchain_requested || [ "$DO_SKILL" -eq 1 ] ||
    die "--skill-only and --deps-only together leave nothing to do."

  # A space in the compiler path is fatal downstream, not cosmetic: certora-cli
  # interpolates a compiler into a command string and then splits it on
  # whitespace, so a compiler reached through a path with a space in it is
  # broken before it runs.
  case "$BIN_DIR_OPT" in
    *[[:space:]]*) die "--bin-dir must not contain a space: certora-cli splits compiler paths on whitespace." ;;
  esac

  if [ -n "$PROJECT_PATH" ]; then
    [ -d "$PROJECT_PATH" ] || die "--project: not a directory: $PROJECT_PATH"
    [ "$DO_SOLC" -eq 1 ] ||
      die "--project derives compiler versions with autosetup's own pragma parser, which lives in the toolchain --skill-only skips."
  fi

  # Validate target names up front; a typo should not surface three steps later.
  local t
  for t in $TARGETS; do
    if [ "$t" != "all" ] && ! contains "$AGENT_KEYS" "$t"; then
      die "unknown --target: $t (known: $AGENT_KEYS all)"
    fi
  done
}

# ------------------------------------------------------------------ state ---

# The state file is a flat KEY=VALUE list, one per line, readable by anything
# that can read a text file: a person reads it back, and the skill reads it to
# find out where the commands and the compilers ended up. Scalar keys are
# overwritten on each run; list keys accumulate.
STATE_SCALARS="VERSION INSTALLED_AT AUTOPROVER_REF UV_BIN_DIR CLI_BIN_DIR SOLC_STORE SKILL_SRC ANTHROPIC_MODE UV_INSTALLED"
STATE_NEW=""
STATE_KEYS=""

state_set() {
  STATE_NEW="$STATE_NEW$1=$2"$'\n'
  contains "$STATE_KEYS" "$1" || STATE_KEYS="$STATE_KEYS $1"
}
state_add() { state_set "$@"; }

# All values recorded under one list key, one per line.
state_values() {
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE"
}

state_value() { state_values "$1" | tail -1; }

write_state() {
  [ -n "$STATE_NEW" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would record what was installed in $STATE_FILE"
    return 0
  fi
  local merged="" line key
  if [ -f "$STATE_FILE" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key=${line%%=*}
      # A scalar this run rewrote, or a list entry it repeated, is dropped here
      # and comes back from STATE_NEW below.
      if contains "$STATE_SCALARS" "$key" && contains "$STATE_KEYS" "$key"; then continue; fi
      case "$STATE_NEW" in *"$line"$'\n'*) continue ;; esac
      merged="$merged$line"$'\n'
    done < "$STATE_FILE"
  fi
  mkdir -p "$STATE_DIR"
  printf '%s%s' "$merged" "$STATE_NEW" > "$STATE_FILE"
  info "recorded this install in $STATE_FILE"
}

# -------------------------------------------------------------- preflight ---

# Split out from java_major so the parsing can be tested without a JVM.
# Handles both "21.0.1" and the old "1.8.0_292" spelling, where the major is
# the second component.
java_major_from_line() {
  local raw
  raw=$(printf '%s' "$1" | sed -n 's/.*"\([^"]*\)".*/\1/p')
  [ -n "$raw" ] || return 0
  case "$raw" in
    1.*) printf '%s' "$raw" | cut -d. -f2 | sed 's/[^0-9].*//' ;;
    *)   printf '%s' "$raw" | cut -d. -f1 | sed 's/[^0-9].*//' ;;
  esac
}

java_major() {
  local line
  line=$(java -version 2>&1 | head -1) || return 0
  java_major_from_line "$line"
}

java_install_hint() {
  case "$(uname -s)" in
    Darwin) printf 'brew install openjdk@%s   (then follow the symlink hint brew prints)' "$RECOMMENDED_JAVA_MAJOR" ;;
    Linux)  printf 'sudo apt-get install -y openjdk-%s-jdk   (or your distro'\''s equivalent)' "$RECOMMENDED_JAVA_MAJOR" ;;
    *)      printf 'install a JDK %s or newer' "$RECOMMENDED_JAVA_MAJOR" ;;
  esac
}

preflight() {
  step "Preflight"

  if [ "$DO_SKILL" -eq 1 ] && [ ! -d "$SKILL_SRC" ]; then
    die "no skill found at $SKILL_SRC -- run this script from inside a checkout of the skill repo."
  fi

  command -v git >/dev/null 2>&1 ||
    die "git is not on PATH. It is required: the toolchain installs from a git URL with a submodule. Install git and re-run."

  toolchain_requested || { info "toolchain steps skipped, nothing else to check"; return 0; }

  command -v curl >/dev/null 2>&1 ||
    die "curl is not on PATH. It is required to install uv and to download compilers. Install curl and re-run."

  # A dry run downloads nothing, so the probe is skipped outright rather than
  # run and downgraded to a warning. That is what makes --self-test offline.
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if ! curl -fsS -m 15 -o /dev/null https://github.com 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "cannot reach https://github.com; a dry run changes nothing, so this is a note rather than a failure."
    elif [ "$SOLC_ONLY" -eq 1 ]; then
      warn "cannot reach https://github.com; relinking what is already installed will still work, but no new compiler can be downloaded."
    else
      die "cannot reach https://github.com. The toolchain, the compilers and the skill's docs lookups all need network access; check your connection or proxy and re-run."
    fi
  else
    info "network: github.com reachable"
  fi

  if [ "$CHECK_JAVA" -eq 1 ] && [ "$DO_COMPOSER" -eq 1 ]; then
    local major
    if ! command -v java >/dev/null 2>&1; then
      die "java is not on PATH. certora-autosetup shells out to certora-cli's ASTExtraction.jar while resolving summaries and has no fallback for a missing JVM, so a run would die mid-way instead of at install time. Install it with: $(java_install_hint), or pass --no-java-check to install anyway."
    fi
    major=$(java_major)
    if [ -z "$major" ]; then
      warn "could not parse a version out of \`java -version\`; continuing, but confirm you have JDK $MIN_JAVA_MAJOR or newer."
    elif [ "$major" -lt "$MIN_JAVA_MAJOR" ]; then
      die "java $major is too old; certora-cli requires $MIN_JAVA_MAJOR or newer ($RECOMMENDED_JAVA_MAJOR recommended). Install it with: $(java_install_hint), or pass --no-java-check to install anyway."
    else
      info "java: $major (needs >= $MIN_JAVA_MAJOR)"
    fi
  fi

  # adopt_uv rather than a bare lookup: an installed-but-unsourced uv has to be
  # reachable by name before `uv python find` below means anything.
  if adopt_uv; then
    info "uv: $(uv_path)"
    # uv provisions a managed CPython when the host has no matching one, so a
    # missing 3.12 is a note about a download, not a failure.
    if uv python find "$PYTHON_PIN" >/dev/null 2>&1; then
      info "python $PYTHON_PIN: available to uv"
    else
      info "python $PYTHON_PIN: not present; uv will download a managed build (~16 MiB)"
    fi
  else
    info "uv: not installed (step 1 will offer to install it)"
  fi
}

# ------------------------------------------------------------------ uv ------

UV_INSTALL_URL="https://astral.sh/uv/install.sh"
UV_DEFAULT_BIN="$HOME/.local/bin"

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
  return 0
}

ensure_uv() {
  step "Step 1/3: uv"

  if adopt_uv; then
    info "already installed at $(uv_path) -- leaving it alone"
    record_skip "uv (already installed)"
    return 0
  fi

  say "  uv is missing. The official installer is a script fetched over https and piped to a shell:"
  say "      curl -LsSf $UV_INSTALL_URL | env INSTALLER_NO_MODIFY_PATH=1 sh"
  say "  It installs uv into $UV_DEFAULT_BIN. INSTALLER_NO_MODIFY_PATH=1 is what keeps it"
  say "  out of your ~/.zshrc, ~/.profile and fish config; the PATH line is printed here instead."
  say "  If you would rather not pipe a script to a shell, install uv your own way"
  say "  (brew install uv, pipx install uv, or your distro's package) and re-run this script."

  if ! confirm "  Run the official uv installer now?"; then
    record_fail "uv (declined; install it yourself and re-run)"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would run: curl -LsSf %s | env INSTALLER_NO_MODIFY_PATH=1 sh\n' "$UV_INSTALL_URL"
  else
    printf '  + curl -LsSf %s | env INSTALLER_NO_MODIFY_PATH=1 sh\n' "$UV_INSTALL_URL"
    curl -LsSf "$UV_INSTALL_URL" | env INSTALLER_NO_MODIFY_PATH=1 sh ||
      { record_fail "uv (installer exited non-zero)"; return 1; }
    adopt_uv || { record_fail "uv (installed but not found at $UV_DEFAULT_BIN)"; return 1; }
    state_set UV_INSTALLED "$(uv_path)"
  fi

  record_done "uv"
}

# ---------------------------------------------------------- ai-composer -----

tool_installed() {
  # `uv tool list` prints one "<name> v<version>" line per tool, then an
  # indented "- <script>" line per console script it provides.
  uv tool list 2>/dev/null | grep -q "^$1[[:space:]]"
}

tool_venv() { printf '%s/%s' "$(uv tool dir 2>/dev/null)" "$1"; }

install_ai_composer() {
  step "Step 2/3: certora-autosetup and certoraRun (the ai-composer package)"

  if [ "$DRY_RUN" -eq 0 ] && ! command -v uv >/dev/null 2>&1; then
    record_fail "ai-composer (uv unavailable)"
    return 1
  fi

  # Checked in --dry-run as well: `uv tool list` changes nothing, and a plan
  # that claims it would install what is already there is not a plan.
  if [ "$REINSTALL" -eq 0 ] && command -v uv >/dev/null 2>&1 && tool_installed "$AI_COMPOSER_TOOL"; then
    # Whatever ref the existing install was built from is not knowable from
    # here, so the pin is not recorded for it. --reinstall is what makes the
    # two agree.
    info "$AI_COMPOSER_TOOL is already installed -- leaving it alone"
    info "to rebuild it at AutoProver $AUTOPROVER_REF: re-run with --reinstall"
    record_skip "ai-composer (already installed)"
    link_certora_cli
    return 0
  fi

  say "  Will install: $(composer_spec)"
  say "  AutoProver:   pinned at $AUTOPROVER_REF (--autoprover-ref takes another)"
  say "  Into:         \$(uv tool dir)/$AI_COMPOSER_TOOL, with console scripts linked into \$(uv tool dir --bin)"
  say "  Python:       $PYTHON_PIN (uv downloads a managed build if the host has none)"
  say "  Size:         around 740 MB and 160-odd packages; several minutes on a cold cache."
  say "  Gives you:    certora-autosetup (and its alias autosetup), then certoraRun linked"
  say "                out of the same tool venv by the step right after this one."

  if ! confirm "  Proceed?"; then
    record_skip "ai-composer (declined)"
    return 0
  fi

  # AutoProver declares its graphcore submodule with an scp-style SSH URL, and
  # uv runs `git submodule update --recursive --init` while building. Without
  # this rewrite the build fails outright for anyone who has no GitHub SSH key,
  # even though graphcore is a public repo. The rewrite is passed per-command
  # through GIT_CONFIG_* so it leaves no state in the user's git config.
  local git_env="GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=git@github.com:"
  local force_flag=""
  if [ "$REINSTALL" -eq 1 ]; then force_flag="--force"; fi

  # shellcheck disable=SC2086  # git_env and force_flag are deliberate word lists
  if run env $git_env uv tool install --python "$PYTHON_PIN" $force_flag "$(composer_spec)"; then
    record_done "ai-composer at AutoProver $AUTOPROVER_REF (certora-autosetup)"
    state_set AUTOPROVER_REF "$AUTOPROVER_REF"
    state_add UV_TOOL "$AI_COMPOSER_TOOL"
  else
    record_fail "ai-composer (uv tool install failed -- see the uv output above)"
    return 1
  fi

  link_certora_cli
}

# `uv tool install` links only the console scripts of the package it was asked
# for, so ai-composer's 20-odd entry points reach the bin dir and certora-cli's
# do not, even though certora-cli is installed in the same venv by the
# [certora-cli] extra. autosetup then calls `certoraRun` by name through
# subprocess and gets FileNotFoundError, and the skill's Phase 0 gate fails.
#
# Symlinking out of the tool venv, rather than a second `uv tool install
# certora-cli`, keeps exactly one copy of certora-cli on the machine and makes
# a version mismatch between the two impossible: the binary on PATH IS the one
# ai-composer resolved.
#
# The version and the script names are read from the installed distribution, so
# neither is a literal in this file that could fall out of date.
cli_metadata() {
  "$1" - <<'PY'
import importlib.metadata as md
try:
    dist = md.distribution("certora-cli")
except md.PackageNotFoundError:
    raise SystemExit(0)
print(dist.version)
for ep in dist.entry_points:
    if ep.group == "console_scripts":
        print(ep.name)
PY
}

link_certora_cli() {
  local venv venv_bin py meta version names name src dest target bin existing
  venv=$(tool_venv "$AI_COMPOSER_TOOL")
  venv_bin="$venv/bin"
  py="$venv_bin/python"

  if [ ! -x "$py" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "would link certora-cli's console scripts (certoraRun and friends) out of $venv_bin"
      return 0
    fi
    record_fail "certoraRun (no tool venv at $venv)"
    return 1
  fi

  meta=$(cli_metadata "$py" 2>/dev/null || true)
  if [ -z "$meta" ]; then
    warn "certora-cli is not installed in $venv. The [certora-cli] extra is what brings it in; re-run with --reinstall."
    record_fail "certoraRun (certora-cli absent from the tool venv)"
    return 1
  fi

  version=$(printf '%s\n' "$meta" | head -1)
  names=$(printf '%s\n' "$meta" | tail -n +2)
  bin=$(cli_bin_dir)
  info "certora-cli $version in the tool venv; linking its commands into $bin"
  run mkdir -p "$bin"

  local linked=0
  for name in $names; do
    src="$venv_bin/$name"
    dest="$bin/$name"
    [ -x "$src" ] || { warn "$name is declared by certora-cli but missing from $venv_bin"; continue; }

    if [ -L "$dest" ]; then
      target=$(readlink "$dest")
      if [ "$target" = "$src" ]; then
        state_add CLI_LINK "$dest"
        linked=$((linked + 1))
        continue
      fi
    fi

    if [ -e "$dest" ] || [ -L "$dest" ]; then
      # Some other install owns this name. Replacing it would break whatever
      # put it there (a separate `uv tool install certora-cli` keeps a receipt
      # pointing at the file), so say what is there and leave it.
      existing=$("$dest" --version 2>/dev/null | head -1 || true)
      warn "$dest already exists and this installer did not create it${existing:+ (it reports: $existing)}. Leaving it alone; the tool venv has certora-cli $version. Remove it, or run \`uv tool uninstall certora-cli\`, if you want them to agree."
      continue
    fi

    if run ln -s "$src" "$dest"; then
      state_add CLI_LINK "$dest"
      linked=$((linked + 1))
    else
      record_fail "certora-cli command $name"
    fi
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    record_done "certora-cli $version commands linked into $bin"
    return 0
  fi

  # The point of the whole function: certoraRun has to resolve by name. The
  # subshell is so the probe PATH cannot leak into the rest of the run.
  # shellcheck disable=SC2030  # the subshell PATH is the point: it asks what a shell with $bin on PATH would find
  if ( PATH="$bin:$PATH"; command -v certoraRun >/dev/null 2>&1 ); then
    record_done "certora-cli $version: $linked command(s) in $bin, certoraRun among them"
  else
    warn "certoraRun is still not resolvable from $bin. autosetup calls it by name and will fail without it."
    record_fail "certoraRun (not resolvable from $bin)"
    return 1
  fi
}

# ------------------------------------------------------------------ paths ---

# Where the certora-cli commands
# command go. The default is the uv tool bin dir on purpose: the user already
# has to put that directory on PATH for certora-autosetup to run at all, so
# putting the compilers there means one PATH entry instead of two, and no
# install that is green while Phase 0 cannot find a compiler.
CLI_BIN_CACHE=""
cli_bin_dir() {
  if [ -n "$CLI_BIN_CACHE" ]; then printf '%s' "$CLI_BIN_CACHE"; return 0; fi
  if [ -n "$BIN_DIR_OPT" ]; then
    CLI_BIN_CACHE="$BIN_DIR_OPT"
  else
    CLI_BIN_CACHE=$(uv tool dir --bin 2>/dev/null || printf '%s' "$UV_DEFAULT_BIN")
  fi
  printf '%s' "$CLI_BIN_CACHE"
}

PATH_DIRS=""
note_path_dir() {
  contains "$PATH_DIRS" "$1" || PATH_DIRS="$PATH_DIRS $1"
}

on_path() {
  case ":$ORIG_PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

# The console scripts of every uv-installed tool land in one directory, and a
# fresh uv install does not put it on PATH. Checked once, after the toolchain
# steps, so it is reported even when every tool was already present.
#
# --bin-dir puts the certora-cli commands somewhere else, and that directory has
# the same problem: certoraRun is linked into it and the skill looks for
# certoraRun on PATH, so both directories are reported.
check_bin_path() {
  command -v uv >/dev/null 2>&1 || return 0
  local uv_bin cli_bin
  uv_bin=$(uv tool dir --bin 2>/dev/null || printf '%s' "$UV_DEFAULT_BIN")
  state_set UV_BIN_DIR "$uv_bin"
  on_path "$uv_bin" || note_path_dir "$uv_bin"
  cli_bin=$(cli_bin_dir)
  state_set CLI_BIN_DIR "$cli_bin"
  if [ "$cli_bin" != "$uv_bin" ]; then
    on_path "$cli_bin" || note_path_dir "$cli_bin"
  fi
}

# ------------------------------------------------------------------ solc ----

# Where solc-select keeps its compilers. The tool puts its store inside
# $VIRTUAL_ENV whenever that variable is set, which would hide the compilers
# in whatever venv happened to be active and contradict what this script says
# it writes. Every solc-select call below therefore runs with VIRTUAL_ENV
# cleared, and this is the one store either of them uses.
solc_select_dir() { printf '%s' "$HOME/.solc-select"; }

# `uv tool install` links its shims into `uv tool dir --bin`, which on a fresh
# machine is not on PATH yet - so the shim we just created has to be invoked by
# path, not by name.
solc_select_cmd() {
  if command -v solc-select >/dev/null 2>&1; then
    printf 'solc-select'
  else
    printf '%s/solc-select' "$(uv tool dir --bin 2>/dev/null || printf '%s' "$UV_DEFAULT_BIN")"
  fi
}



# solc-select serves native arm64 builds from 0.8.5 up (0.8.24+ are universal
# binaries). Below 0.8.5 the only macOS builds are x86_64, so on Apple silicon
# they run under Rosetta 2 or not at all - and the failure without it looks
# like a broken compiler rather than a missing translator.
version_below_0_8_5() {
  local minor patch
  case "$1" in 0.*) ;; *) return 1 ;; esac
  minor=$(printf '%s' "$1" | cut -d. -f2)
  patch=$(printf '%s' "$1" | cut -d. -f3)
  case "$minor$patch" in *[!0-9]*|'') return 1 ;; esac
  [ "$minor" -lt 8 ] && return 0
  [ "$minor" -eq 8 ] && [ "$patch" -lt 5 ] && return 0
  return 1
}

warn_about_rosetta() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ "$(uname -m)" = "arm64" ] || return 0
  local v old_ones=""
  for v in $1; do
    if version_below_0_8_5 "$v"; then old_ones="$old_ones $v"; fi
  done
  [ -n "$old_ones" ] || return 0
  # arch(1) succeeds only when the translator can actually run something.
  if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    info "rosetta: present (needed for${old_ones} -- no arm64 builds exist below 0.8.5)"
  else
    warn "these compilers are Intel-only and this is an Apple silicon Mac:${old_ones}. They will install but not run until you add Rosetta 2:  softwareupdate --install-rosetta"
  fi
}

# Prints the derived versions on stdout and NOTHING else - the caller reads it
# through a command substitution, so a stray progress line would be parsed as a
# compiler version. Chatter goes to stderr.
derive_project_versions() {
  local project="$1" py script derived work
  py="$(tool_venv "$AI_COMPOSER_TOOL")/bin/python"
  script="$REPO_ROOT/scripts/solc_versions.py"
  if [ ! -x "$py" ]; then
    warn "cannot derive compilers from $project: the ai-composer tool venv is not there yet. Install the toolchain first, then re-run with --project."
    return 1
  fi
  if [ ! -f "$script" ]; then
    warn "cannot derive compilers: $script is missing."
    return 1
  fi
  project=$(cd -- "$project" && pwd -P) || return 1
  info "reading pragmas and foundry.toml under $project" >&2
  # autosetup's resolver logs into .certora_internal/ in the current directory.
  # Running it from a throwaway directory is what keeps that tree out of
  # whoever's repo the installer happened to be invoked from.
  work=$(mktemp -d) || return 1
  derived=$(cd -- "$work" && "$py" "$script" "$project") || { rm -rf "$work"; return 1; }
  rm -rf "$work"
  printf '%s' "$(printf '%s' "$derived" | tr '\n' ' ')"
}

install_solc() {
  if [ "$SOLC_ONLY" -eq 1 ]; then
    step "Solidity compilers"
  else
    step "Step 3/3: Solidity compilers"
  fi

  local wanted="" v seen=""
  state_set SOLC_STORE "$(solc_select_dir)"

  # No compiler is downloaded unless one is asked for. A solc release is
  # 35-80 MB and which ones you need is a property of the project you are
  # verifying, not of this machine.
  if [ "$SOLC_EXPLICIT" -eq 1 ]; then
    wanted="$SOLC_VERSIONS"
  fi

  if [ -n "$PROJECT_PATH" ]; then
    local derived=""
    if [ "$DRY_RUN" -eq 1 ] && [ ! -x "$(tool_venv "$AI_COMPOSER_TOOL")/bin/python" ]; then
      info "would derive the project's compilers from its pragmas once the toolchain is installed"
    elif derived=$(derive_project_versions "$PROJECT_PATH"); then
      info "project needs: $derived"
      wanted="$wanted $derived"
    else
      record_fail "solc versions for $PROJECT_PATH (could not derive them)"
      return 1
    fi
  fi

  # Deduplicate without associative arrays.
  for v in $wanted; do
    contains "$seen" "$v" || seen="$seen $v"
  done
  wanted="${seen# }"

  if [ -n "$wanted" ] && ! contains "$wanted" "$AUTOSETUP_DEFAULT_SOLC"; then
    info "$AUTOSETUP_DEFAULT_SOLC is autosetup's default compiler, and is not in this set. Add it with --solc $AUTOSETUP_DEFAULT_SOLC if you want runs that fall back to the default to work."
  fi

  if [ -n "$wanted" ]; then
    say "  Will install solc-select (via uv), then these compilers: $wanted"
    say "  Compilers land in $(solc_select_dir)/artifacts (roughly 35-80 MB each)."
  else
    say "  No compiler was requested, so none is downloaded. Ask for one with:"
    say "      --solc \"$AUTOSETUP_DEFAULT_SOLC\"        a named list"
    say "      --project <path>          whatever that project's pragmas need"
  fi
  say "  solc-select keeps each release in its own directory as a binary named after it,"
  say "  solc-0.8.34 and so on. Those are the names autosetup writes into a compiler_map"
  say "  when it sees them on PATH, so putting the artifact directories on PATH is all"
  say "  that is needed. Nothing is symlinked and nothing is renamed."

  if ! confirm "  Proceed?"; then
    record_skip "solc compilers (declined)"
    return 0
  fi

  warn_about_rosetta "$wanted"

  # solc-select itself always goes in: it is what provisions a compiler later.
  # Only the downloads wait for --solc / --project.
  #
  # Installed as a uv tool rather than into a venv on purpose: uv's shims do
  # not export VIRTUAL_ENV, so nothing here drags the compiler store into
  # whatever venv happens to be active.
  if [ "$REINSTALL" -eq 0 ] && command -v uv >/dev/null 2>&1 && tool_installed "solc-select"; then
    info "solc-select already installed -- leaving it alone"
  else
    local force_flag=""
    if [ "$REINSTALL" -eq 1 ]; then force_flag="--force"; fi
    # shellcheck disable=SC2086
    run uv tool install $force_flag solc-select ||
      { record_fail "solc-select (uv tool install failed)"; return 1; }
    state_add UV_TOOL "solc-select"
  fi

  if [ -n "$wanted" ]; then
    # `solc-select install` takes several versions at once and is idempotent:
    # already-present versions print a skip line and exit 0.
    # shellcheck disable=SC2086
    run env -u VIRTUAL_ENV "$(solc_select_cmd)" install $wanted ||
      { record_fail "solc compilers (solc-select install failed)"; return 1; }
    record_done "solc-select and compilers: $wanted"
  else
    record_done "solc-select (no compiler requested)"
  fi

  report_solc_path
}

# Every installed release sits in its own directory holding one binary of the
# same name, so the artifact directories are what put solc-0.8.34 and friends
# on PATH. autosetup switches to that naming when it finds those names and no
# solc8.34-style ones (fixconf_prechecks.detect_solc_convention).
solc_path_line() {
  # shellcheck disable=SC2016  # the line is for the user's rc, so $HOME and $PATH stay unexpanded
  printf '%s' 'for d in "$HOME"/.solc-select/artifacts/*/; do PATH="$PATH:${d%/}"; done; export PATH'
}

report_solc_path() {
  local artifacts count
  artifacts="$(solc_select_dir)/artifacts"
  count=0
  if [ -d "$artifacts" ]; then
    for d in "$artifacts"/*/; do
      [ -d "$d" ] || continue
      count=$((count + 1))
    done
  fi

  if [ "$count" -eq 0 ]; then
    say ""
    say "  No compiler is installed yet, so there is nothing for the skill to compile with."
    say "  Install one with solc-select directly, or re-run this script:"
    say "      solc-select install $AUTOSETUP_DEFAULT_SOLC"
    say "      ./$SELF_NAME --solc-only --solc \"$AUTOSETUP_DEFAULT_SOLC\""
    record_skip "compilers (none installed; pass --solc or --project)"
    return 0
  fi

  info "$count compiler(s) in $artifacts"
  note_solc_path
}


# ----------------------------------------------------------------- skill ----

agent_home() {
  case "$1" in
    claude)   printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex)    printf '%s' "${CODEX_HOME:-$HOME/.codex}" ;;
    cursor)   printf '%s' "$HOME/.cursor" ;;
    gemini)   printf '%s' "$HOME/.gemini" ;;
    opencode) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ;;
    goose)    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/goose" ;;
    agents)   printf '%s' "$HOME/.agents" ;;
  esac
}

agent_skills_dir() { printf '%s/skills' "$(agent_home "$1")"; }

# The executable that means "this agent is installed here", where there is one.
# `agents` is the cross-agent alias directory rather than a product, so it has
# none and is detected purely by its directory existing.
agent_binary() {
  case "$1" in
    claude)   printf 'claude' ;;
    codex)    printf 'codex' ;;
    cursor)   printf 'cursor-agent' ;;
    gemini)   printf 'gemini' ;;
    opencode) printf 'opencode' ;;
    goose)    printf 'goose' ;;
    agents)   printf '' ;;
  esac
}

detect_agents() {
  local key found="" bin
  for key in $AGENT_KEYS; do
    bin=$(agent_binary "$key")
    if [ -d "$(agent_home "$key")" ]; then
      found="$found $key"
    elif [ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1; then
      found="$found $key"
    fi
  done
  printf '%s' "${found# }"
}

resolve_targets() {
  local t list=""
  if [ -z "$TARGETS" ]; then
    list=$(detect_agents)
  else
    for t in $TARGETS; do
      if [ "$t" = "all" ]; then
        list="$AGENT_KEYS"
        break
      fi
      contains "$list" "$t" || list="$list $t"
    done
  fi
  printf '%s' "${list# }"
}

install_skill() {
  step "Installing the $SKILL_NAME skill"

  local targets mode key dir dest
  targets=$(resolve_targets)

  if [ -z "$targets" ]; then
    warn "no agent found on this machine (looked for: $AGENT_KEYS)."
    say "  Pick one explicitly, e.g. --target claude, or --target agents for the"
    say "  cross-agent ~/.agents/skills directory that several agents read."
    record_fail "skill (no target agent detected)"
    return 1
  fi

  # A symlink means `git pull` in this checkout updates the installed skill. A
  # copy is the right answer when there is nothing to pull from, so the default
  # keys off whether this is a git checkout at all.
  if [ "$LINK_MODE" = "auto" ]; then
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      mode="symlink"
    else
      mode="copy"
    fi
  else
    mode="$LINK_MODE"
  fi

  say "  Source: $SKILL_SRC"
  if [ "$mode" = "symlink" ]; then
    say "  Mode:   symlink (a git pull in this checkout updates every install; --copy for a snapshot)"
  else
    say "  Mode:   copy (a snapshot; re-run this script to refresh it, or --symlink to track the checkout)"
  fi
  say "  Targets:"
  for key in $targets; do
    say "      $key -> $(agent_skills_dir "$key")/$SKILL_NAME"
  done

  if ! confirm "  Proceed?"; then
    record_skip "skill (declined)"
    return 0
  fi

  state_set SKILL_SRC "$SKILL_SRC"

  local failures=0
  for key in $targets; do
    dir=$(agent_skills_dir "$key")
    dest="$dir/$SKILL_NAME"

    if [ -L "$dest" ]; then
      local current
      current=$(readlink "$dest")
      if [ "$mode" = "symlink" ]; then
        if [ "$current" = "$SKILL_SRC" ]; then
          info "$key: already points at this checkout"
          record_skip "skill for $key (already current)"
          state_add SKILL_INSTALL "$key|symlink|$dest|$SKILL_SRC"
          continue
        fi
        # A symlink somewhere else is replaced in place by ln -sfn below.
      else
        # Copying through the link would write into whatever it points at -
        # which, for an install made by this script, is this checkout itself.
        warn "$key: $dest is a symlink to $current. --copy will not write through it; remove the symlink yourself and re-run."
        record_fail "skill for $key ($dest is a symlink; --copy needs it gone first)"
        failures=$((failures + 1))
        continue
      fi
    elif [ -e "$dest" ] && [ "$mode" = "symlink" ]; then
      # Replacing a real directory with a symlink would need a delete, and this
      # installer never deletes anyone's files. Say what to do instead.
      warn "$key: $dest exists and is a real directory. Move it aside yourself, or re-run with --copy to update it in place."
      record_fail "skill for $key ($dest is an existing directory)"
      failures=$((failures + 1))
      continue
    fi

    run mkdir -p "$dir" || { failures=$((failures + 1)); continue; }
    if [ "$mode" = "symlink" ]; then
      if run ln -sfn "$SKILL_SRC" "$dest"; then
        record_done "skill for $key (symlink -> $SKILL_SRC)"
        state_add SKILL_INSTALL "$key|symlink|$dest|$SKILL_SRC"
      else
        record_fail "skill for $key (could not create the symlink)"
        failures=$((failures + 1))
      fi
    else
      # cp -R of the contents, so an existing install is refreshed without
      # deleting anything. Files you removed upstream are not pruned.
      if run mkdir -p "$dest" && run cp -R "$SKILL_SRC/." "$dest/"; then
        record_done "skill for $key (copy in $dest)"
        state_add SKILL_INSTALL "$key|copy|$dest|$SKILL_SRC"
      else
        record_fail "skill for $key (copy failed)"
        failures=$((failures + 1))
      fi
    fi
  done

  [ "$failures" -eq 0 ]
}

# ------------------------------------------------------------------ PATH ----

shell_rc() {
  case "${SHELL##*/}" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    bash) if [ "$(uname -s)" = "Darwin" ]; then printf '%s' "$HOME/.bash_profile"
          else printf '%s' "$HOME/.bashrc"; fi ;;
    *)    printf '' ;;
  esac
}

PATH_MARKER="# added by certora-verify install.sh"

# Set when a compiler exists but its artifact directories are not on PATH.
NEED_SOLC_PATH=0
note_solc_path() {
  local d
  for d in "$(solc_select_dir)"/artifacts/*/; do
    [ -d "$d" ] || continue
    on_path "${d%/}" || { NEED_SOLC_PATH=1; return 0; }
  done
}

report_path() {
  [ -n "$PATH_DIRS" ] || [ "$NEED_SOLC_PATH" -eq 1 ] || return 0
  local dir line rc
  step "PATH"
  for dir in $PATH_DIRS; do
    line="export PATH=\"$dir:\$PATH\""
    say "  $dir is not on your PATH. Add this line to your shell startup file:"
    say ""
    say "      $line"
    say ""
    if [ "$APPEND_PATH" -eq 1 ]; then
      rc=$(shell_rc)
      if [ -z "$rc" ]; then
        warn "--append-path: cannot tell which startup file \$SHELL (${SHELL:-unset}) uses; add the line yourself."
      elif [ -f "$rc" ] && grep -Fq "$dir" "$rc" 2>/dev/null; then
        info "$rc already mentions $dir; leaving it alone"
      else
        if run sh -c 'printf "\n%s\n%s\n" "$1" "$2" >> "$3"' sh "$PATH_MARKER" "$line" "$rc"; then
          record_done "PATH line appended to $rc"
          state_add PATH_RC "$rc|$line"
        else
          record_fail "appending the PATH line to $rc"
        fi
      fi
    fi
  done

  if [ "$NEED_SOLC_PATH" -eq 1 ]; then
    line=$(solc_path_line)
    say "  The compilers are not on your PATH. solc-select keeps each release in its own"
    say "  directory, so one loop covers every version you have now or install later:"
    say ""
    say "      $line"
    say ""
    if [ "$APPEND_PATH" -eq 1 ]; then
      rc=$(shell_rc)
      if [ -z "$rc" ]; then
        warn "--append-path: cannot tell which startup file \$SHELL (${SHELL:-unset}) uses; add the line yourself."
      elif [ -f "$rc" ] && grep -Fq ".solc-select/artifacts" "$rc" 2>/dev/null; then
        info "$rc already puts the solc-select artifacts on PATH; leaving it alone"
      else
        if run sh -c 'printf "\n%s\n%s\n" "$1" "$2" >> "$3"' sh "$PATH_MARKER" "$line" "$rc"; then
          record_done "solc PATH line appended to $rc"
          state_add PATH_RC "$rc|$line"
        else
          record_fail "appending the solc PATH line to $rc"
        fi
      fi
    fi
  fi
  [ "$APPEND_PATH" -eq 1 ] ||
    say "  (or re-run with --append-path to have this script add it for you)"
}

# --------------------------------------------------------------- runtime ----

# certora_autosetup/setup/setup_summaries.py requires ANTHROPIC_API_KEY to be
# set at IMPORT time when there is no .env in the current directory, and never
# validates the value. --skip-llm then gates every actual LLM call. The skill
# runs autosetup with --skip-llm and exports a placeholder itself, so a machine
# with no Anthropic account needs nothing here.
anthropic_notes() {
  step "Anthropic API key"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    say "  ANTHROPIC_API_KEY is set in this environment, so autosetup can write its"
    say "  LLM-derived summaries for the library and external functions that are hard to"
    say "  summarize statically. The skill asks before using it, because those calls cost"
    say "  money and the default run makes none."
    state_set ANTHROPIC_MODE "env"
    return 0
  fi

  say "  Not needed. The skill runs autosetup with --skip-llm, which turns off every LLM"
  say "  call, and exports a placeholder for the import-time check that autosetup does on"
  say "  the variable without ever reading its value."
  say "  What that costs: summaries for library and external functions are static only, so"
  say "  the hard-to-summarize ones get none and specs that lean on them are weaker."
  say "  Export a real key in your own shell if you want them. This script writes no key,"
  say "  real or placeholder, into any rc file or .env."
  state_set ANTHROPIC_MODE "skip-llm"
}

runtime_notes() {
  step "Before your first verification run"
  say "  CERTORAKEY authenticates certoraRun against the Certora cloud prover."
  say "  It is not stored anywhere by this script; export it in your own shell."
}


# ------------------------------------------------------------- self-test ----

TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL  %s\n' "$1"
}

check() {
  local what="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$what"
  else
    printf '  FAIL  %s\n' "$what"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

check_fails() {
  local what="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL  %s (expected a non-zero exit)\n' "$what"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf '  ok    %s\n' "$what"
  fi
}

check_eq() {
  local what="$1" want="$2" got="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$want" = "$got" ]; then
    printf '  ok    %s\n' "$what"
  else
    printf '  FAIL  %s: wanted "%s", got "%s"\n' "$what" "$want" "$got"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Runs offline: every case is either a pure function or an argument-parsing
# path that exits before the first network call, which is what lets CI run it.
# Every command word this script uses has to resolve: a function it defines, a
# builtin, or something on PATH. A call left behind when its definition is
# deleted resolves to nothing, and `set -e` does not catch that in a function
# invoked under `||`, so the step reports success and skips its work.
# scripts/command_words.py does the parsing; resolving is this shell's job,
# because only it can see the functions defined above.
undefined_calls() {
  local words name
  words=$(python3 "$REPO_ROOT/scripts/command_words.py" "$SELF_PATH" 2>/dev/null) || return 0
  for name in $words; do
    command -v "$name" >/dev/null 2>&1 || printf '%s\n' "$name"
  done
}

self_test() {
  step "Self-test"

  say "  every call resolves"
  local unresolved
  unresolved=$(undefined_calls | tr '\n' ' ')
  check_eq "no call without a definition" "" "${unresolved% }"

  say "  the solc PATH line"
  check "it names solc-select's artifact directories" \
    holds "$(solc_path_line)" ".solc-select/artifacts"
  check "it creates no symlink" \
    lacks "$(solc_path_line)" "ln -s"
  check "it uses no Certora-style compiler name" \
    lacks "$(solc_path_line)" "solc8."

  say "  Rosetta band"
  check      "0.7.6 is below the arm64 floor"  version_below_0_8_5 0.7.6
  check      "0.8.4 is below the arm64 floor"  version_below_0_8_5 0.8.4
  check_fails "0.8.5 is not"                   version_below_0_8_5 0.8.5
  check_fails "0.8.30 is not"                  version_below_0_8_5 0.8.30

  say "  java version parsing"
  check_eq "modern spelling" "21" "$(java_major_from_line 'openjdk version "21.0.1" 2023-10-17')"
  check_eq "1.8 spelling"    "8"  "$(java_major_from_line 'java version "1.8.0_292"')"
  check_eq "unparseable"     ""   "$(java_major_from_line 'no version here')"

  say "  command rendering"
  check_eq "a spec with brackets is quoted" \
    "uv tool install 'ai-composer[certora-cli]'" "$(pretty_cmd uv tool install 'ai-composer[certora-cli]')"
  check_eq "a plain path is not" "ln -s /a/b /c/d" "$(pretty_cmd ln -s /a/b /c/d)"

  say "  the pinned ref reaches the install spec"
  case "$(composer_spec)" in
    *"@$AUTOPROVER_REF") pass "the spec ends with the pin" ;;
    *) fail "the spec does not end with the pin: $(composer_spec)" ;;
  esac

  say "  argument errors"
  check       "--help exits 0"                      "$SELF_PATH" --help
  check_fails "an unknown option is rejected"       "$SELF_PATH" --nope
  check_fails "a positional argument is rejected"   "$SELF_PATH" stray
  check_fails "--solc with no list is rejected"     "$SELF_PATH" --solc
  check_fails "--bin-dir with no path is rejected"  "$SELF_PATH" --bin-dir
  check_fails "--autoprover-ref with no ref is rejected" "$SELF_PATH" --autoprover-ref
  check_fails "an unknown --target is rejected"     "$SELF_PATH" --target notanagent --dry-run
  check_fails "--project on a missing path is rejected" "$SELF_PATH" --project /no/such/dir --dry-run
  check_fails "--skill-only --deps-only is rejected" "$SELF_PATH" --skill-only --deps-only
  check_fails "--bin-dir with a space is rejected"  "$SELF_PATH" --bin-dir "/tmp/a b" --dry-run
  local home plan
  home=$(mktemp -d)
  rm -rf "$home"

  say "  the dry run writes nothing"
  home=$(mktemp -d)
  plan=$(env HOME="$home" "$SELF_PATH" --dry-run --yes --skill-only --target agents 2>&1) || true
  check_eq "an empty HOME stays empty" "0" "$(find "$home" -mindepth 1 | wc -l | tr -d ' ')"
  case "$plan" in
    *"would run"*|*"Would install"*) pass "the plan is printed" ;;
    *) fail "the plan printed nothing recognisable" ;;
  esac
  rm -rf "$home"

  say "  the dry-run solc plan downloads nothing and renames nothing"
  home=$(mktemp -d)
  # A compiler has to be present for the reporting branch to run at all, so the
  # assertions below test that branch rather than an early return.
  mkdir -p "$home/.solc-select/artifacts/solc-0.8.34"
  printf '#!/bin/sh\n' > "$home/.solc-select/artifacts/solc-0.8.34/solc-0.8.34"
  chmod +x "$home/.solc-select/artifacts/solc-0.8.34/solc-0.8.34"
  plan=$(env HOME="$home" "$SELF_PATH" --dry-run --yes --solc-only 2>&1) || true
  # uv keeps its own bookkeeping under HOME, so the assertion here is about the
  # directories this script owns rather than about the whole tree.
  check_eq "no state dir"  "0" "$([ -e "$home/.certora" ] && echo 1 || echo 0)"
  check_eq "the staged compiler is untouched" "1" \
    "$([ -x "$home/.solc-select/artifacts/solc-0.8.34/solc-0.8.34" ] && echo 1 || echo 0)"
  case "$plan" in
    *"ln -s"*|*"solc8.34"*) fail "the plan creates a symlink or a renamed compiler" ;;
    *) pass "no symlink and no renamed compiler in the plan" ;;
  esac
  case "$plan" in
    *--solc*) pass "a plan with no compiler names --solc" ;;
    *) fail "a plan with no compiler does not name --solc" ;;
  esac
  rm -rf "$home"


  step "Self-test summary"
  if [ "$TESTS_FAILED" -eq 0 ]; then
    say "  $TESTS_RUN checks, all passed."
    return 0
  fi
  say "  $TESTS_RUN checks, $TESTS_FAILED failed."
  return 1
}

# --------------------------------------------------------------- summary ----

summary() {
  step "Summary"
  local heading="Installed:"
  if [ "$DRY_RUN" -eq 1 ]; then heading="Would install:"; fi
  if [ -n "$DONE_LINES" ]; then
    say "  $heading"
    printf '%s' "$DONE_LINES" | sed 's/^/    - /'
  fi
  if [ -n "$SKIP_LINES" ]; then
    say "  Skipped:"
    printf '%s' "$SKIP_LINES" | sed 's/^/    - /'
  fi
  if [ -n "$FAIL_LINES" ]; then
    say "  Failed:"
    printf '%s' "$FAIL_LINES" | sed 's/^/    - /'
  fi
  [ -n "$DONE_LINES$SKIP_LINES$FAIL_LINES" ] || say "  nothing to do"

  if [ "$DRY_RUN" -eq 1 ]; then
    say ""
    say "  This was a dry run. Nothing on this machine was changed."
  else
    say ""
    say "  What was installed is recorded in $STATE_FILE."
    say "  Nothing here removes anything: what you no longer want, you remove yourself."
  fi

  [ -z "$FAIL_LINES" ]
}

# ------------------------------------------------------------------ main ----

main() {
  parse_args "$@"

  if [ "$DO_SELF_TEST" -eq 1 ]; then
    say "certora-verify installer $INSTALLER_VERSION self-test"
    self_test
    return $?
  fi

  say "certora-verify installer $INSTALLER_VERSION"
  say "  repo:  $REPO_ROOT"
  say "  pin:   AutoProver $AUTOPROVER_REF"
  if [ "$DRY_RUN" -eq 1 ]; then say "  mode:  dry run, nothing will be changed"; fi

  preflight

  state_set VERSION "$INSTALLER_VERSION"
  state_set INSTALLED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local failed=0
  if toolchain_requested; then
    if [ "$DO_UV" -eq 1 ]; then ensure_uv || failed=1; fi
    # uv may be installed but unreachable by name in this shell; adopt it before
    # the steps that need it, so a --deps-only re-run works from a fresh shell.
    adopt_uv || true
    if [ "$failed" -eq 0 ] || [ "$DRY_RUN" -eq 1 ]; then
      if [ "$DO_COMPOSER" -eq 1 ]; then install_ai_composer || failed=1; fi
      if [ "$DO_SOLC" -eq 1 ]; then install_solc || failed=1; fi
    else
      warn "skipping the toolchain steps because uv is unavailable"
    fi
    check_bin_path
  else
    record_skip "toolchain (--skill-only)"
  fi

  if [ "$DO_SKILL" -eq 1 ]; then
    install_skill || failed=1
  elif [ "$SOLC_ONLY" -eq 1 ]; then
    record_skip "skill (--solc-only)"
  else
    record_skip "skill (--deps-only)"
  fi

  report_path
  if [ "$DO_COMPOSER" -eq 1 ]; then
    anthropic_notes
    runtime_notes
  fi

  write_state
  summary || failed=1
  return "$failed"
}

main "$@"
