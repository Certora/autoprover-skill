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
  <a href="https://github.com/crytic/solc-select"><img src="https://img.shields.io/badge/compilers-solc--select-blue?style=flat" alt="compilers managed by solc-select"></a>
  <a href="https://github.com/Certora/autoprover-skill/stargazers"><img src="https://img.shields.io/github/stars/Certora/autoprover-skill?style=flat&logo=github&color=yellow" alt="GitHub stars"></a>
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
Installing to both covers it, which is what `./install.sh --dir ~/.codex/skills --dir ~/.agents/skills`
does.

Two things the skill needs from the host agent regardless of which one it is: a shell that can
leave a command running for up to about two hours while the agent polls its log, and some way
to read pages under https://docs.certora.com/en/latest/, either a web fetch tool or `curl`.
Sub-agents are used when available and are not required.

## Install

```sh
git clone https://github.com/Certora/autoprover-skill.git
cd autoprover-skill
./install.sh
```

`install.sh` installs the toolchain the skill drives and links the skill into every agent
skill directory it finds on the machine. It does not set `CERTORAKEY`; that one is yours to
export. See [Requirements](#requirements) for what each piece is for.

**It installs no Solidity compiler.** It installs
[solc-select](https://github.com/crytic/solc-select), which manages them, and stops there:
which compilers a project needs is a property of that project, so the skill reads the
project's build configuration and installs what it resolves to, in Phase 3.

Run it with stdin closed to see the whole plan without changing anything:

```sh
./install.sh </dev/null
```

The options: `--skill-only` and `--deps-only` split the two halves, `--dir <path>` writes the
skill somewhere specific instead of the detected directories, `--copy` copies it instead of
symlinking, `--reinstall` re-resolves the toolchain and lets uv take over command names
another tool owns, `--autoprover-ref <ref>` builds from a different AutoProver commit, and
`--yes` answers every prompt. `./install.sh --help` lists them all.

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

### Removing it again

There is no uninstall subcommand, deliberately: everything it would delete is shared with
other tools on the machine, and getting that wrong costs a user their files. Each piece comes
off with the command that owns it, and `uv tool list` shows what uv is holding, which is
everything the installer put on your PATH.

```sh
uv tool uninstall ai-composer solc-select   # the toolchain
solc-select uninstall 0.8.34                # one compiler, from the store slither shares
rm ~/.agents/skills/certora-verify          # the skill, per agent directory it was written to
```

The certora-cli commands come from the same uv tool, so `uv tool uninstall` takes them with
it. The installer writes to no shell startup file, so there is nothing to undo there.

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

The [`skills` CLI](https://github.com/vercel-labs/skills) installs a skill from any GitHub
repository:

```sh
npx skills add Certora/autoprover-skill
```

Nobody has run that against this repository yet; if it fails, the symlink above does the same
job.

### Claude Code plugin

`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` make this repo a
one-plugin Claude Code marketplace named `certora-skills`, and `.agents/plugins/marketplace.json`
does the same for the agent-plugins registry that VS Code, Copilot and Codex read. The
Claude Code route is:

```sh
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-verify@certora-skills
```

That route has not been run against this repository, so treat it as the documented path rather
than a tested one. What is checked here: `claude plugin validate .` passes on this checkout,
and CI keeps the three manifests agreeing on name, version and license.

VS Code and Copilot add an agent-plugins marketplace through their own plugin interface rather
than through a command given here; `.agents/plugins/marketplace.json` is what makes this repo a
valid source for that, and it is untested as well.

A plugin install gives you the skill and nothing else. The toolchain and the compilers still
come from `install.sh` or from the manual commands in [Requirements](#requirements).

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
| 0. Preflight | Check `certoraRun`, `certora-autosetup`, `CERTORAKEY`, Java, the compilers the project's pragmas need, and that the main contract is concrete. Stop with a specific message if anything is missing. |
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
uv tool install --python 3.12 --with-executables-from certora-cli \
  "ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@$(cat skills/certora-verify/AUTOPROVER_REF)"
```

The `GIT_CONFIG_*` variables are load bearing. AutoProver's `graphcore` submodule is recorded
with an SSH URL, and `uv` initializes submodules while it builds, so without the rewrite the
install fails for anyone without a GitHub SSH key. `graphcore` itself is public. The
`[certora-cli]` extra is mandatory rather than a nicety: `certora-cli` is declared only in
that extra, so without it the environment has no prover CLI at all. Do not add the `ml`
extra; nothing on the autosetup path imports it, and it pulls in torch and the CUDA wheels.
Expect a large install: 164 packages, about 736 MB, several minutes on a cold cache.

**`certoraRun`.** `--with-executables-from certora-cli` is what puts it on PATH. Without that
flag `uv tool install` links the console scripts of the package you named and leaves
`certora-cli`'s inside the tool environment, unreachable; with it, uv links all nine of them
and records them in the same receipt, so `uv tool uninstall ai-composer` takes them back too.
No second copy of certora-cli exists to drift.

If uv answers `Executables already exist`, a standalone `certora-cli` tool already owns those
names: remove it with `uv tool uninstall certora-cli`, or add `--force` to let uv take them.

**PATH.** One directory has to be on it:

```sh
export PATH="$(uv tool dir --bin):$PATH"
```

That is normally `~/.local/bin`, and it holds `certora-autosetup`, `certoraRun` and
`solc-select`, plus the `solc` that solc-select dispatches to the version you selected. The
installer prints the line; adding it to a startup file is yours to do.

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

**`ANTHROPIC_API_KEY`. Not required.** The skill runs `certora-autosetup --skip-llm`, which
switches off every LLM call it would make (`setup_prover.py:1526` sets
`enable_llm = not skip_llm`, and `setup_summaries.py:2507` gates the calls on it), so the
verification flow makes no Anthropic calls and needs no Anthropic account.

autosetup still reads the variable while importing its summary module, and exits 1 without it
even for `--help`. The check is only that the value is non-empty; it never tries the key
(`certora_autosetup/setup/setup_summaries.py:70-93`), and a `.env` file in the working
directory is loaded instead, after which the variable is not checked at all. So a placeholder
satisfies it, and the skill exports one itself:

```sh
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-skip-llm-placeholder}"
```

What the default costs: summaries for library and external functions are static only, so the
ones that are hard to summarize statically get none, and specs that lean on them are weaker.
With a real key you can drop `--skip-llm` and get the LLM-written summaries, at the price of
LLM calls billed to that key.

**solc.** Nothing in the install ships a Solidity compiler, and the installer installs none.
Compilers are managed by [solc-select](https://github.com/crytic/solc-select), the same way the
rest of the Solidity tooling does it:

```sh
uv tool install solc-select                          # or pipx, or pip
env -u VIRTUAL_ENV solc-select install 0.8.27        # the version the project resolves to
env -u VIRTUAL_ENV solc-select use 0.8.27
```

Which version is not a question about your machine, so the skill answers it per project in
Phase 3, from the project's resolved build plan rather than from its pragmas:
`forge compiler resolve --json -vv` for Foundry, autosetup's own
`hardhat_config_extractor.js` for Hardhat. Pragmas say what each file tolerates; the build plan
says what the project actually compiles with. On one real project the resolved plan is a single
0.8.27 while a repository-wide pragma reading adds a second version that must never reach a
`compiler_map`.

With one compiler selected, the skill passes `--solc-default solc` to autosetup, which pins
every contract to that bare name and collapses the map back to a scalar, so the conf follows
whatever solc-select has selected. Leaving the flag off is the trap: autosetup pins its own
default `solc8.34` into the compiler map while the switch that would let it substitute a
compiler you do have was already computed as off, so a missing compiler becomes a compile
failure with no explanation.

A project that genuinely needs several compilers at once is the exception, and the limit is
autosetup's rather than certoraRun's: autosetup's only name for a per-contract compiler is the
Certora form `solc8.27` (`enhanced_config_manager.py:745-761`, with the convention hardcoded at
`setup_prover.py:259-267`), and solc-select's store holds no such name. certoraRun itself is
not fussy: `solc` and every `compiler_map` value may be a bare name on PATH, an absolute path
or a cwd-relative path (`certoraValidateFuncs.py:409-420`, `:125-160`), and the version comes
from running the binary (`CompilerCollectorFactory.py:142-169`), never from parsing its name.

Three details worth knowing. `env -u VIRTUAL_ENV` matters because solc-select relocates its
whole store into `$VIRTUAL_ENV/.solc-select` when that variable is set, and then the artifact
directories above are empty. No path on PATH may contain a space, because `certoraRun` builds
the compiler command as a string and splits it on whitespace. And on Apple silicon, 0.8.5 and
later are native or universal binaries, while anything older is Intel only and needs Rosetta 2
(`softwareupdate --install-rosetta`).

Phase 0 of the skill checks all of the above and stops with a specific message if something is
missing.

## Layout

```
install.sh                    installs the toolchain and links the skill
README.md                     this file
AGENTS.md                     entry point for agents with no skill mechanism
LICENSE                       GNU General Public License v3
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

Measured on macOS (Apple silicon, zsh). The installer runs end to end from an empty HOME with
nothing but `/usr/bin:/bin` on PATH, into scratch uv directories: `ai-composer` at the pinned
commit, `certora-cli` 8.19.2 with `certoraRun` reachable from the bin dir it reports,
`solc-select`, and the skill symlinked. A second run is a no-op. With stdin closed it prints
the plan, exits non-zero and leaves HOME byte-identical. No shell startup file is written.
`shellcheck` is clean.

Also measured, because the design rests on it: `uv tool install --with-executables-from
certora-cli` does expose certora-cli's nine commands even though certora-cli arrives through an
extra, uv records all nine in its receipt, and `uv tool uninstall ai-composer` takes all thirty
back. A standalone `certora-cli` tool collides, and uv says so plainly rather than silently
taking the name.

On compilers, measured by running autosetup against a Foundry project that pins
`solc_version = "0.8.21"`, on a PATH holding only a solc-select-selected `solc` and no
Certora-form binary. `forge compiler resolve --json` returned `{0.8.21}`, the pin. autosetup
then wrote `solc8.21` into the conf from the build configuration, found no such binary, applied
its `solc_not_found_fallback`, and the conf it drove came out as `"solc": "solc"`. It compiled
and submitted four cloud jobs.

Two things that run showed, which the recipe alone does not. `--solc-default solc` does not
decide the conf's `solc` when the project declares a version: the build configuration wins
(`build_systems/base.py:113-117`), and what rescues the run is the fallback, which is only
armed because the conf is pinned. And the fallback rewrites the conf autosetup drives, while
the sibling confs it also writes (`invariants.conf` and the per-property confs) keep the
declared `solc8.21`, so those still want that binary by name.

Read from AutoProver's source rather than measured: that certoraRun accepts absolute compiler
paths, and that a project declaring no version at all loses the fallback entirely.

What has not been tested: no agent has loaded this skill yet, in any harness, and no
verification run has been driven through this installer from Phase 0 to a report. The Hardhat
extractor path has not been exercised from this skill against a real Hardhat project, and
neither has a genuinely multi-compiler project. The
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
