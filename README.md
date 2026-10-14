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

The skill is one `SKILL.md` plus five reference files. Any agent that loads skills from a
directory can run it. `install.sh` writes the files into every directory below that exists on
the machine.

| Agent | Skill directory |
|---|---|
| Claude Code | `~/.claude/skills`, or `.claude/skills` per project |
| Cursor | `~/.cursor/skills` |
| Gemini CLI | `~/.gemini/skills` |
| opencode | `~/.config/opencode/skills` |
| Codex | `~/.codex/skills` and `~/.agents/skills` |
| Goose | `~/.config/goose/skills` |
| anything else | `~/.agents/skills`, or `.agents/skills` per project |

The agent needs a shell that can keep a command running for up to two hours while it polls
the log, and a way to read https://docs.certora.com/en/latest/ (a web fetch tool or `curl`).

## Install

```sh
git clone https://github.com/Certora/autoprover-skill.git
cd autoprover-skill
./install.sh
```

`install.sh` installs the toolchain the skill drives and links the skill into every agent
skill directory it finds. It does not set `CERTORAKEY` or `CERTORA_API_KEY`. You export those
yourself. See [Requirements](#requirements).

It installs [solc-select](https://github.com/crytic/solc-select), which manages compilers, and
the skill installs the versions each project needs in Phase 3.

To see the whole plan without changing anything, run it with stdin closed:

```sh
./install.sh </dev/null
```

Options:

- `--skill-only` and `--deps-only` run one half.
- `--dir <path>` writes the skill to a directory of your choice.
- `--copy` copies the skill instead of symlinking it.
- `--reinstall` re-resolves the toolchain and lets uv take over command names another tool owns.
- `--autoprover-ref <ref>` builds from a different AutoProver commit.
- `--yes` answers every prompt.

`./install.sh --help` lists them all.

### Updating AutoProver

`install.sh` installs `ai-composer` from the AutoProver commit named in one file beside the
skill:

```sh
cat skills/certora-verify/AUTOPROVER_REF   # a 40-character commit sha, on one line
```

To take a newer AutoProver, write the new SHA into that file and re-run the installer:

```sh
git ls-remote https://github.com/Certora/AutoProver master   # the current master SHA
# write the SHA into skills/certora-verify/AUTOPROVER_REF, then
./install.sh --deps-only --reinstall
```

`--reinstall` is what makes the new commit take effect. To try a branch or a commit without
editing the file, pass `--autoprover-ref <ref>`.

### Updating

| How you installed | How to update |
|---|---|
| `./install.sh` (symlink, the default) | `git pull` in this clone. The skill is a symlink into it, so the agents see the new files at once. |
| `./install.sh --copy` | `git pull`, then `./install.sh --skill-only --copy` to overwrite the copies. |
| `npx skills add` | run the same `npx skills add` command again. |
| Claude Code plugin | `claude plugin marketplace update certora-skills && claude plugin update certora-verify`. |
| toolchain, after changing the AutoProver commit | `./install.sh --deps-only --reinstall`. |

### Removing it

There is no uninstall command, because everything the installer put in place is shared with
other tools on the machine. Each piece comes off with the command that owns it. `uv tool list`
shows what uv holds.

```sh
solc-select uninstall 0.8.34                # one compiler
uv tool uninstall ai-composer solc-select   # the toolchain, including the certora-cli commands
rm ~/.agents/skills/certora-verify          # the skill, in each agent directory it was written to
```

Remove compilers first: `solc-select uninstall` is the only command that knows the compiler
store. The installer writes to no shell startup file, so there is nothing to undo there.

### Manual install

Put `skills/certora-verify/` where your agent looks for skills. A symlink is enough, and it
keeps the skill updating with `git pull`. If the target directory does not exist, create it
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

The directory name must stay `certora-verify`. The Agent Skills standard requires it to match
the `name` in the frontmatter.

This installs the skill only. For the toolchain, run `./install.sh --deps-only` or follow
[Requirements](#requirements).

The [`skills` CLI](https://github.com/vercel-labs/skills) installs a skill from any GitHub
repository:

```sh
npx skills add Certora/autoprover-skill
```

### Claude Code plugin

This repository is also a one-plugin Claude Code marketplace named `certora-skills`:

```sh
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-verify@certora-skills
```

`.agents/plugins/marketplace.json` makes the repository a valid source for the agent-plugins
registry that VS Code, Copilot and Codex read. A plugin install gives you the skill only. The
toolchain and the compilers come from `install.sh` or from [Requirements](#requirements).

### Agents with no skill support

Hand the agent [`AGENTS.md`](AGENTS.md) from the repository root. It says what the skill is
for, which file to read, and what the environment must provide. Agents that read `AGENTS.md`
on their own pick it up once the repository is in the working tree.

Otherwise, paste `skills/certora-verify/SKILL.md` into the agent's context or system prompt.
It is self-contained apart from the five files under `references/`, which it names as each
phase needs them.

## What it does

The skill runs eight phases. Every phase writes its result under the target project's
`certora/` directory, so an interrupted run resumes from the artifacts instead of starting
over.

| Phase | What happens |
|---|---|
| 0. Preflight | Check `certoraRun`, `certora-autosetup`, `CERTORAKEY`, Java, a compiler manager and a way to read the project's build plan, and that the main contract is concrete. Stop with a specific message if anything is missing. |
| 1. Design document | Use a design doc if the user supplied one, otherwise look for one and judge it by content. Build instructions and generic READMEs do not count. Proceeding without one is fine. |
| 2. Component analysis | Produce `certora/analysis/application.json`: application type, explicit contracts, external actors, and per contract the components with their entry points, state and requirements. The main contract's components are the unit of work for phases 4 to 6. |
| 3. Scene analysis and setup | Compute the transitive call closure, decide which contracts the prover must model, then run `certora-autosetup` to get a working conf, generated summaries, call resolution and a sanity spec. |
| 4. Property formulation | Per component, formulate invariants, safety properties and attack vectors, each formalized so that VERIFIED means the good thing holds. Up to three rounds; a round that adds nothing is the stop signal. |
| 5. Structural invariants | Formalize the structural invariants batch first into `certora/specs/invariants.spec` and verify it, so component specs can import it and use its invariants as preconditions. |
| 6. CVL and prover loop | Per component, one spec and one conf. Generation and judging are separate roles: separate sub-agents where the agent has them, otherwise separate passes, with the judging pass re-reading everything from disk. Rounds repeat until the judge accepts and a full unfiltered run is clean, with a round cap to stop deadlocks. A rule that still times out can be handed to the hosted Timeout Resolver. |
| 7. Report | Write `certora/report/report.json` and `report.md`: per property outcomes, audit-style groups, skips with reasons, expected failures split into real findings versus prover limitations, and a coverage summary. |

A rule that fails because it exposes a real contract bug is the product of this flow, not a
defect in it. The skill reports such a rule and never weakens the spec to turn it green.

## Requirements

`install.sh` sets up everything in this section. It is written out so that a manual install
is possible, and so that you can see what is on your machine afterwards.

**`certora-autosetup`.** It is the CLI of the `ai-composer` package, which lives in
[Certora/AutoProver](https://github.com/Certora/AutoProver) and is not on PyPI. It installs
from the git URL at the pinned commit:

```sh
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
GIT_CONFIG_VALUE_0='git@github.com:' \
uv tool install --python 3.12 --with-executables-from certora-cli \
  "ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@$(cat skills/certora-verify/AUTOPROVER_REF)"
```

Keep the `GIT_CONFIG_*` variables. A submodule of AutoProver is recorded with an SSH URL, and
without the rewrite the install fails for anyone without a GitHub SSH key. Keep the
`[certora-cli]` extra. It is what brings in the prover CLI. Do not add the `ml` extra. It pulls
in torch and the CUDA wheels, and nothing on this path uses them. Expect a large install: about
164 packages and 736 MB, several minutes on a cold cache.

**`certoraRun`.** `--with-executables-from certora-cli` puts it on PATH together with the
other certora-cli commands, and `uv tool uninstall ai-composer` removes them again. If uv
answers `Executables already exist`, a standalone `certora-cli` tool owns those names. Remove
it with `uv tool uninstall certora-cli`, or add `--force`.

**PATH.** One directory must be on it:

```sh
export PATH="$(uv tool dir --bin):$PATH"
```

That is normally `~/.local/bin`. It holds `certora-autosetup`, `certoraRun`, `solc-select` and
the `solc` that solc-select dispatches. The installer prints the line. Add it to a startup
file yourself.

**Java.** `certora-autosetup` runs `java -jar` with no fallback, so Java 19 or newer is
required, 21 recommended. On macOS, `brew install openjdk@21` and follow the PATH hint brew
prints. On Debian or Ubuntu, install `openjdk-21-jdk`.

**`CERTORAKEY`.** Your account on the Certora cloud prover, and where the prover cost goes.
Phases 3, 5 and 6 submit real cloud jobs. A single full run takes tens of minutes and can run
up to the two hour job timeout. A verification of a real protocol runs many of them. Know
what a run costs before you start one on a metered account.

**`CERTORA_API_KEY`.** The organization API key of the Certora Runs API. Create it on the
organization's API Access page at `app.certora.com` with the scopes "Create runs", "Read runs
and results", "Cancel runs" and "Download artifacts". It is not `CERTORAKEY`. Only the hosted
Timeout Resolver in Phase 6 uses it, so a run with no timeout never asks for it.

**`ANTHROPIC_API_KEY`. Not required.** The skill runs `certora-autosetup --skip-llm`, which
makes no LLM calls. autosetup still refuses to start when the variable is empty, so the skill
exports a placeholder:

```sh
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-skip-llm-placeholder}"
```

With a real key you can drop `--skip-llm` and get LLM-written summaries for library and
external functions, billed to that key.

**solc.** The installer ships no Solidity compiler. Compilers are managed by
[solc-select](https://github.com/crytic/solc-select):

```sh
uv tool install solc-select                          # or pipx, or pip
env -u VIRTUAL_ENV solc-select install 0.8.27        # every version the project resolves to
```

Phase 3 answers which versions a project needs from the project's build plan, not from its
pragmas: `forge compiler resolve` for Foundry, the Hardhat configuration for Hardhat. The
skill installs each version. It gives each one the name autosetup writes into a conf, such as
`solc8.27`, through a directory of aliases it puts in front of PATH for the run. A project
that needs several compilers at once is ordinary. The conf records which compiler compiled
which contract.

Three details matter. Use `env -u VIRTUAL_ENV`, because solc-select moves its whole store
into `$VIRTUAL_ENV/.solc-select` when that variable is set. Keep spaces out of every path on
PATH, because `certoraRun` splits the compiler command on whitespace. On Apple silicon,
compilers before 0.8.5 are Intel only and need Rosetta 2 (`softwareupdate --install-rosetta`).

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
    timeout-resolver.md       handing a timed-out rule to the hosted Timeout Resolver
  evals/evals.json            eval set for working on the skill; not a benchmark
```

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
