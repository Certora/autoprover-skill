<div align="center">

# certora-verify

**Formally verify a Solidity contract end to end with the Certora Prover.**

An agent skill that takes a Foundry or Hardhat project and one main contract, models the
system, builds a working prover setup with
[certora-autosetup](https://github.com/Certora/AutoProver), formulates security properties,
writes them as [CVL](https://docs.certora.com/en/latest/) rules and invariants, and runs
[`certoraRun`](https://docs.certora.com/en/latest/) until every rule is verified, flagged as
a suspected bug, or retired with a written reason.

<p align="center">
  <a href="https://agentskills.io"><img src="https://img.shields.io/badge/SKILL.md-open_standard-blue?style=flat" alt="Agent Skills standard"></a>
  <a href="skills/certora-verify/SKILL.md"><img src="https://img.shields.io/badge/version-0.1.0-blue?style=flat" alt="version 0.1.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--only-lightgrey?style=flat" alt="GPL-3.0-only"></a>
  <img src="https://img.shields.io/badge/access-Certora_internal-critical?style=flat" alt="private repository">
</p>

</div>

## Which agents it runs in

The skill is one `SKILL.md` plus four reference files, so any agent that loads skills from a
directory can run it. **No agent has loaded it yet.** The directories below are where each
agent looks, and `install.sh` writes the files there; nobody has started one of these agents
and watched it pick the skill up.

| Agent | Skill directory | Where the path comes from |
|---|---|---|
| Claude Code | `~/.claude/skills`, or `.claude/skills` per project | Anthropic's skills documentation |
| Cursor | `~/.cursor/skills` | Cursor's skills documentation |
| Gemini CLI | `~/.gemini/skills` | Gemini CLI's skills documentation |
| opencode | `~/.config/opencode/skills` | opencode's skills documentation |
| Codex | `~/.codex/skills` | the [`skills` CLI](https://github.com/vercel-labs/skills) agent table, not OpenAI's docs |
| Goose | `~/.config/goose/skills` | the `skills` CLI agent table; the vendor page is 404 today |
| anything else | `~/.agents/skills`, or `.agents/skills` per project | cross-agent convention, read by Codex, Cursor, Gemini CLI, opencode and others |

OpenAI's own Codex documentation lists `.agents/skills` (walking up from the working
directory), `~/.agents/skills` and `/etc/codex/skills`, and does not mention `~/.codex/skills`.
Installing to both covers it, which is what `./install.sh --target codex --target agents`
does.

Two things the skill needs from the host agent regardless of which one it is: a shell that can
leave a command running for up to about two hours while the agent polls its log, and some way
to read pages under https://docs.certora.com/en/latest/, either a web fetch tool or `curl`.
Sub-agents are used when available and are not required.

## Install

The repository is private, so clone it with credentials you already have:

```sh
gh repo clone Certora/autoprover-skill
# or, over SSH:
git clone git@github.com:Certora/autoprover-skill.git

cd autoprover-skill
./install.sh
```

`install.sh` installs the toolchain the skill drives and links the skill into every agent
skill directory it finds on the machine. It does not set `CERTORAKEY` or `ANTHROPIC_API_KEY`;
those are yours to export. See [Requirements](#requirements) for what each piece is for.

**It downloads no Solidity compilers by default.** It sets up solc-select and the `solcX.Y`
bridge, and compilers arrive only when you ask for them:

```sh
./install.sh --solc "0.8.34 0.8.30 0.7.6"   # named versions
./install.sh --project ~/code/my-protocol   # whatever that project's pragmas need
```

Both flags work on their own later too, through `./install.sh --bridge-only` or the
`solc-bridge` command the installer writes. With no compiler bridged, the installer says so
and names those two flags rather than reporting a green install.

Other options worth knowing: `--dry-run` prints the whole plan and changes nothing,
`--skill-only` and `--deps-only` split the two halves, `--target <agent>` writes one agent's
skill directory instead of all of them, `--copy` copies the skill instead of symlinking it,
`--append-path` appends the PATH line to your shell rc instead of printing it for you,
`--reinstall` re-resolves the toolchain, `--bin-dir <path>` puts the compiler symlinks and
`solc-bridge` somewhere other than the uv bin directory, `--no-anthropic-key` prints the
static-only fallback recipe for a machine with no Anthropic key, and `--self-test` runs the
plan and error-path checks without touching the network. `./install.sh --help` lists them all.

### The AutoProver pin

`install.sh` installs `ai-composer` from a **fixed AutoProver commit**, not from `master`, so
two people installing a month apart get the same `certora-autosetup` behaviour that SKILL.md
documents. The commit lives in one variable at the top of the script:

```sh
AUTOPROVER_REF="<40-character commit sha>"
```

To take a newer AutoProver, replace that SHA and re-run the installer:

```sh
git -C /path/to/AutoProver fetch origin && git -C /path/to/AutoProver rev-parse origin/master
# or, with no local clone:
git ls-remote https://github.com/Certora/AutoProver master

# edit AUTOPROVER_REF in install.sh, then
./install.sh --deps-only --reinstall
```

`--reinstall` is what makes the new pin take effect: without it an already-installed
`ai-composer` is left alone. To try a branch or a newer commit without editing the file, pass
`--autoprover-ref <ref>`.

### Updating

| How you installed | How to update |
|---|---|
| `./install.sh` (symlink, the default) | `git pull` in this checkout. The skill is a symlink into it, so the agents see the new files immediately. |
| `./install.sh --copy` | `git pull`, then `./install.sh --skill-only --copy` to overwrite the copies. |
| `npx skills add` | run the same `npx skills add` command again. |
| Claude Code plugin | `claude plugin marketplace update certora-skills && claude plugin update certora-verify`. |
| toolchain, after a pin bump | `./install.sh --deps-only --reinstall`. |

### Uninstall

```sh
./install.sh --uninstall --dry-run   # list what would be removed
./install.sh --uninstall
```

It reverses what the installer created. Run the dry run first and read the list: the compiler
store, the uv tool tree and uv itself are shared with other tools on the machine.

### Manual install

Put `skills/certora-verify/` where your agent looks for skills. A symlink is enough, and it
keeps the skill updating with `git pull`. The target directory may not exist yet, so create it
first:

```sh
# Claude Code, for this project only
mkdir -p .claude/skills && ln -s "$PWD/skills/certora-verify" .claude/skills/certora-verify
# Claude Code, for every project
mkdir -p ~/.claude/skills && ln -s "$PWD/skills/certora-verify" ~/.claude/skills/certora-verify
# Codex
mkdir -p ~/.codex/skills && ln -s "$PWD/skills/certora-verify" ~/.codex/skills/certora-verify
# Cursor
mkdir -p ~/.cursor/skills && ln -s "$PWD/skills/certora-verify" ~/.cursor/skills/certora-verify
# Gemini CLI
mkdir -p ~/.gemini/skills && ln -s "$PWD/skills/certora-verify" ~/.gemini/skills/certora-verify
# opencode
mkdir -p ~/.config/opencode/skills && ln -s "$PWD/skills/certora-verify" ~/.config/opencode/skills/certora-verify
# any agent that reads the shared location
mkdir -p ~/.agents/skills && ln -s "$PWD/skills/certora-verify" ~/.agents/skills/certora-verify
```

The directory name has to stay `certora-verify`, because the Agent Skills standard requires it
to match the `name` in the frontmatter.

This installs the skill only. The toolchain it drives is still yours to set up: see
[Requirements](#requirements), which gives every command `install.sh` would have run.

The [`skills` CLI](https://github.com/vercel-labs/skills) also handles private repositories, by
reusing your git or `gh` credentials. The SSH form is the most reliable one for this repo:

```sh
DO_NOT_TRACK=1 npx skills add git@github.com:Certora/autoprover-skill.git
```

Nobody has run that against this repository yet. The CLI documents the SSH source form and the
private-repo fallbacks (git credential helper, then `gh repo clone`, then SSH); if it fails,
the symlink above does the same job.

### Claude Code plugin

`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` make this repo a
one-plugin Claude Code marketplace named `certora-skills`, and `.agents/plugins/marketplace.json`
does the same for the agent-plugins registry that VS Code, Copilot and Codex read. The
Claude Code route is:

```sh
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-verify@certora-skills
```

Claude Code's plugin documentation says private repositories are supported and that these
commands reuse your existing git credential helpers; `owner/repo` shorthand clones over SSH
unless you set `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`. That route has not been run against this
repository, so treat it as the documented path rather than a tested one. What is checked here:
`claude plugin validate .` passes on this checkout, and CI keeps the three manifests agreeing
on name, version and license.

VS Code and Copilot add an agent-plugins marketplace through their own plugin interface rather
than through a command given here; `.agents/plugins/marketplace.json` is what makes this repo a
valid source for that, and it is untested as well.

A plugin install gives you the skill and nothing else. The toolchain, the compilers and the
`solc-bridge` command still come from `install.sh` or from the manual commands in
[Requirements](#requirements).

### Agents with no skill support

Hand the agent [`AGENTS.md`](AGENTS.md) from the repository root. It says what the skill is
for, which file to read, and what the environment has to provide. Agents that read `AGENTS.md`
automatically will pick it up on their own once the repo is in the working tree.

Failing that, paste `skills/certora-verify/SKILL.md` into the agent's context or system
prompt. It is self-contained apart from the four files under `references/`, which it names as
each phase needs them.

## What it does

The skill runs eight phases. Every phase writes its result under the target project's
`certora/` directory, so an interrupted run resumes from the artifacts instead of starting
over.

| Phase | What happens |
|---|---|
| 0. Preflight | Check `certoraRun`, `certora-autosetup`, `CERTORAKEY`, `ANTHROPIC_API_KEY`, the `solcX.Y` binaries the project's pragmas need, and that the main contract is concrete. Stop with a specific message if anything is missing. |
| 1. Design document | Use a design doc if the user supplied one, otherwise look for one and judge it by content. Build instructions and generic READMEs do not count. Proceeding without one is fine. |
| 2. Component analysis | Produce `certora/analysis/application.json`: application type, explicit contracts, external actors, and per contract the components with their entry points, state and requirements. The main contract's components are the unit of work for phases 4 to 6. |
| 3. Scene analysis and setup | Compute the transitive call closure, decide which contracts the prover must model, then run `certora-autosetup` to get a working conf, generated summaries, call resolution and a sanity spec. |
| 4. Property formulation | Per component, formulate invariants, safety properties and attack vectors, each formalized so that VERIFIED means the good thing holds. Up to three rounds; a round that adds nothing is the stop signal. |
| 5. Structural invariants | Formalize the structural invariants batch first into `certora/specs/invariants.spec` and verify it, so component specs can import it and use its invariants as preconditions. |
| 6. CVL and prover loop | Per component, one spec and one conf. Generation and judging are separate roles: separate sub-agents where the agent has them, otherwise separate passes, with the judging pass re-reading everything from disk. Rounds repeat until the judge accepts and a full unfiltered run is clean, with a round cap to stop deadlocks. |
| 7. Report | Write `certora/report/report.json` and `report.md`: per property outcomes, audit-style groups, skips with reasons, expected failures split into real findings versus prover limitations, and a coverage summary. |

A rule that fails because it exposes a real contract bug is the product of this flow, not a
defect in it. The skill reports such a rule and never weakens the spec to turn it green.

## Requirements

Everything in this section is what `install.sh` does for you. It is written out so a manual
install is possible, and so you can see what is on your machine afterwards.

**`certora-autosetup`.** It is the CLI of the `ai-composer` package, which lives in
[Certora/AutoProver](https://github.com/Certora/AutoProver) and is not published on PyPI, so
it installs from the git URL at the pinned commit:

```sh
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
GIT_CONFIG_VALUE_0='git@github.com:' \
uv tool install --python 3.12 \
  'ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@e6f9e2e4706225adb07178c1866ad61b4d827424'
```

The `GIT_CONFIG_*` variables are load bearing. AutoProver's `graphcore` submodule is recorded
with an SSH URL, and `uv` initializes submodules while it builds, so without the rewrite the
install fails for anyone without a GitHub SSH key. `graphcore` itself is public. The
`[certora-cli]` extra is mandatory rather than a nicety: `certora-cli` is declared only in
that extra, so without it the environment has no prover CLI at all. Do not add the `ml`
extra; nothing on the autosetup path imports it, and it pulls in torch and the CUDA wheels.
Expect a large install: 164 packages, about 736 MB, several minutes on a cold cache.

**`certoraRun`.** The command above does not put it on PATH. `uv tool install` links the
console scripts of the package you named, so `ai-composer`'s scripts are linked and
`certora-cli`'s stay inside the tool environment, unreachable. The extra did install
`certora-cli` there, so the fix is to link those scripts out rather than install a second copy:

```sh
tooldir=$(uv tool dir)/ai-composer
bindir=$(uv tool dir --bin)
for c in certoraRun certoraEVMProver certoraMutate certoraEqCheck certoraRanger \
         certoraCVLFormatter certoraSolanaProver certoraSorobanProver certoraSuiProver; do
  [ -x "$tooldir/bin/$c" ] && ln -sfn "$tooldir/bin/$c" "$bindir/$c"
done
```

`install.sh` does this, reading the script names out of the installed distribution rather than
from a list, so the `certoraRun` on your PATH is always the one `ai-composer` resolved. A plain
`uv tool install certora-cli` also works and is what to use if you want certora-cli on its own,
at the cost of a second copy that can drift to a different version.

**PATH.** One directory has to be on it:

```sh
export PATH="$(uv tool dir --bin):$PATH"
```

That is normally `~/.local/bin`. It holds `certora-autosetup`, `certoraRun`, `solc-select`, the
`solcX.Y` compiler names and the `solc-bridge` command, because the installer puts the compiler
symlinks beside the commands rather than in a directory of their own. `uv tool install
solc-select` also drops a `solc` shim there, which exits with a Python traceback until someone
runs `solc-select use`, so the installer chooses a global version when the user has not, which
is what makes the bare `solc` name work for autosetup's last-resort fallback. The installer
prints the export line; `--append-path` appends it to your shell rc for you.

**Java.** `certora-cli` ships jars and shells out to them. `certoraRun` on its own only warns
when Java is absent and skips local CVL typechecking, but `certora-autosetup` runs
`java -jar` on the summary resolution path with no fallback, so for this skill Java 19 or
newer is a hard requirement, 21 recommended. On macOS `brew install openjdk@21`, which is
keg-only, so follow the symlink hint brew prints or add
`/opt/homebrew/opt/openjdk@21/bin` to PATH yourself. On Debian or Ubuntu a JDK 21 package such
as `openjdk-21-jdk` does the job.

**`CERTORAKEY`.** This is an account on the Certora cloud prover, and it is where the money
goes. Phases 3, 5 and 6 submit real cloud jobs. A single full run takes tens of minutes and
can run up to the two hour job timeout, and a verification of a real protocol runs many of
them. Do not start one on a metered account without knowing what it will cost.

**`ANTHROPIC_API_KEY`.** `certora-autosetup` makes its own LLM calls, and it checks the
variable while importing its summary module, so the binary exits 1 without it even for
`--help`. The check is that the value is non-empty; it never tries the key
(`certora_autosetup/setup/setup_summaries.py:70-93`). A `.env` file in the current working
directory is loaded instead, and then the variable is not checked at all.

Someone with no Anthropic key can still run autosetup: export any non-empty placeholder and
pass `--skip-llm`, which switches off every LLM call (`setup_prover.py:1526` sets
`enable_llm = not skip_llm`, and `setup_summaries.py:2507` gates the calls on it). The price is
real: summaries are then static-only, so the hard-to-verify library functions that most need an
LLM-written summary get none, and every spec downstream inherits the weaker setup. It is a
fallback to choose deliberately and say out loud, never the default. With a real key, use the
key.

**solc.** Nothing in the install ships a Solidity compiler, and the installer downloads none
unless you ask. The Certora tooling looks for compilers on PATH under the name `solcX.Y`,
where `X.Y` is the minor and patch of the release, so `solc8.29` is 0.8.29 and `solc7.6` is
0.7.6. One project routinely needs several at once, because autosetup emits a `compiler_map`
pinning different contracts to different compilers.

[solc-select](https://github.com/crytic/solc-select) is the usual way to get the binaries, but
it puts a single switchable `solc` shim on PATH rather than the per version names, so it needs
a bridge. `install.sh` sets up both and writes a `solc-bridge` command beside `certoraRun`:

```sh
solc-bridge                      # relink whatever compilers are installed
solc-bridge --solc "0.8.29"      # install named versions, then relink
solc-bridge --project .          # work out what this project needs, install it, relink
```

SKILL.md Phase 0 tells the agent to run `solc-bridge` when a version the project needs is
missing, so an agent working on a machine where it does not exist will report a missing
command and stop. The command is a thin front end onto `install.sh --bridge-only`: it needs
the checkout it was installed from to still be there, and it says so plainly if that checkout
has moved or gone.

Doing it by hand, for a machine where `install.sh` was never run:

```sh
uv tool install solc-select
env -u VIRTUAL_ENV solc-select install 0.8.34 0.8.30    # the versions your project needs

out=$(uv tool dir --bin)      # where certora-autosetup and certoraRun already are
usable=""
for d in "$HOME"/.solc-select/artifacts/solc-*/; do
  d=${d%/}; v=${d##*/solc-}; bin="$d/solc-$v"
  [ -x "$bin" ] || continue
  case "$v" in 0.*) name="solc${v#0.}" ;; *) name="solc$v" ;; esac
  ln -sfn "$bin" "$out/$name"
  ln -sfn "$bin" "$out/solc-$v"
  usable="$usable $v"
done
[ -n "$usable" ] || { echo "nothing under $HOME/.solc-select/artifacts to bridge" >&2; exit 1; }
highest=$(printf '%s\n' $usable | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
ln -sfn "$HOME/.solc-select/artifacts/solc-$highest/solc-$highest" "$out/solc"
```

Each compiler gets both names the tooling understands, `solc8.34` and `solc-0.8.34`, and plain
`solc` points at the highest installed version. The sort is numeric per component on purpose:
sorted as text, `0.8.9` outranks `0.8.36` and plain `solc` ends up on the older compiler.

Three details worth knowing. `env -u VIRTUAL_ENV` matters because solc-select relocates its
whole store into `$VIRTUAL_ENV/.solc-select` when that variable is set, and the bridge then
finds an empty store. The bridge directory must not contain a space, because `certoraRun`
builds the compiler command as a string and splits it on whitespace. And on Apple silicon,
0.8.5 and later are native or universal binaries, while anything older is Intel only and needs
Rosetta 2 (`softwareupdate --install-rosetta`).

Phase 0 of the skill checks all of the above and stops with a specific message if something is
missing.

## Layout

```
install.sh                    installs the toolchain and links the skill; holds the AutoProver pin
README.md                     this file
AGENTS.md                     entry point for agents with no skill mechanism
LICENSE                       GNU General Public License v3
scripts/
  solc_versions.py            derives a project's solc versions with autosetup's own pragma parser
.claude-plugin/
  plugin.json                 Claude Code plugin manifest
  marketplace.json            Claude Code marketplace holding that one plugin
.agents/plugins/
  marketplace.json            agent-plugins marketplace, read by VS Code, Copilot and Codex
.github/workflows/check.yml   CI: shell lint, JSON validity, manifest agreement, SKILL.md frontmatter
skills/certora-verify/
  SKILL.md                    the skill itself: phases 0-7
  references/
    autosetup.md              certora-autosetup invocation, outputs, failure modes
    cvl-writing.md            docs map, writing guidelines, judge checklist
    cvl-pitfalls.md           traps that aren't on any single docs page
    prover-loop.md            building confs, running certoraRun, reading results
    timeout-resolver.md       handing a timed-out rule to the hosted timeout resolver
  evals/evals.json            dev-time eval set for skill authoring
```

## Evals

`skills/certora-verify/evals/evals.json` is an eval set for working on the skill. It is not a
benchmark. There are no published results from it, and no number in this README comes from
running it.

It describes its fixtures by shape rather than by path, so a runner supplies its own
equivalent projects. Evals 1 and 2 submit real cloud prover jobs, so they cost money and take
a long wall clock time. Eval 3 is offline and cheap.

## What has actually been tested

The installer has been run end to end on macOS (Apple silicon, zsh), from an empty HOME with
nothing but `/usr/bin:/bin` on PATH: uv, `ai-composer` at the pinned commit, `certora-cli`
8.19.2 with `certoraRun` reachable on PATH, solc-select, the `solcX.Y` bridge, and the skill
symlinked. A second run is a no-op. `--uninstall` removes the uv tools, the command symlinks,
the compiler symlinks, the shim and the state file, and leaves the solc-select compiler store
alone because other tools share it. No shell startup file is written. `--self-test` runs 35
checks and `shellcheck` is clean apart from two intentional subshell notices.

What has not been tested: no agent has loaded this skill yet, in any harness, and no
verification run has been driven through this installer from Phase 0 to a report. The
per-agent skill directories come from vendor documentation and the skills CLI's own table
rather than from a run in each agent, so treat the table in
[Which agents it runs in](#which-agents-it-runs-in) as the claim it is.

## License

GNU General Public License v3.0 only (SPDX: `GPL-3.0-only`). The full text is in
[LICENSE](LICENSE).

Copyright (C) 2026 Certora Ltd.

This skill is a derivative work of [AutoProver](https://github.com/Certora/AutoProver), which
is licensed GPL-3.0-only by Certora Ltd. The verification methodology it documents was
condensed from AutoProver's prompt templates and knowledge base, covering the component model,
the property sorts, the CVL guidelines and the reviewer criteria, and the sanity rule snippet
in `references/autosetup.md` is reproduced from AutoProver verbatim. `certora-autosetup`,
which the skill drives, is a console script of the same project.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
the GNU General Public License for more details.
