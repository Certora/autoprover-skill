<div align="center">

# certora-autoprover

**Formally verify a Solidity contract end to end with the Certora Prover.**

An agent skill that takes a Foundry or Hardhat project and one main contract, models the
system, builds a working prover setup with
[certora-autosetup](https://github.com/Certora/AutoProver), formulates security properties,
writes them as [CVL](https://docs.certora.com/en/latest/) rules and invariants, and runs
[`certoraRun`](https://docs.certora.com/en/latest/) until every rule is verified, flagged as
a suspected bug, or reported as unresolved or skipped, with a reason.

<p align="center">
  <a href="https://agentskills.io"><img src="https://img.shields.io/badge/SKILL.md-open_standard-blue?style=flat" alt="Agent Skills standard"></a>
  <a href="skills/certora-autoprover/SKILL.md"><img src="https://img.shields.io/badge/version-0.3.0-blue?style=flat" alt="version 0.1.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--only-lightgrey?style=flat" alt="GPL-3.0-only"></a>
  <a href="https://github.com/crytic/solc-select"><img src="https://img.shields.io/badge/compilers-solc--select-blue?style=flat" alt="compilers managed by solc-select"></a>
  <a href="https://github.com/Certora/autoprover-skill/stargazers"><img src="https://img.shields.io/github/stars/Certora/autoprover-skill?style=flat&logo=github&color=yellow" alt="GitHub stars"></a>
</p>

</div>

## What it does

1. Analyzes the project: its components, their entry points and state, and the contracts the
   prover must model. A design document helps but is optional.
2. Builds a working prover setup with `certora-autosetup`.
3. Writes security properties for each component and formalizes them in CVL.
4. Verifies them with the cloud prover, reviewing the specs and investigating failures,
   recording verified properties, suspected bugs, and unresolved cases.
5. Writes a report.

The report includes suspected bugs and counterexamples, alongside verified properties and
coverage gaps. The skill never weakens a spec to make a failing rule pass.

## Prerequisites

- A Foundry or Hardhat project that builds, with `forge` or `node`.
- Java 19 or newer.
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/). The installer uses it and
  does not install it: it refuses to run rather than download a program for you.
- `CERTORAKEY`, required: one organization API key, created on the API Access page at
  `app.certora.com`. Tick "Use Certora Prover" so it runs the prover. Tick "Create runs",
  "Read runs and results", "Cancel runs" and "Download artifacts".

## Install

```sh
git clone https://github.com/Certora/autoprover-skill.git
cd autoprover-skill
./install.sh
```

### What is being installed

The installer asks `uv` to install two things, and tells you the size and asks before it does:
`certora-autosetup` and `certoraRun`, built from the AutoProver repository at the commit in
`skills/certora-autoprover/AUTOPROVER_REF`, and `solc-select` from PyPI. Both belong to `uv`
afterwards, so `uv tool uninstall` removes them. It then links the skill into the skill
directory of every agent it finds, and always into `~/.agents/skills`:

| Agent | Skill directory |
|---|---|
| Claude Code | `~/.claude/skills` |
| Cursor | `~/.cursor/skills` |
| Gemini CLI | `~/.gemini/skills` |
| opencode | `~/.config/opencode/skills` |
| Codex | `~/.codex/skills` and `~/.agents/skills` |
| Goose | `~/.config/goose/skills` |
| anything else | `~/.agents/skills` |

For a project-local directory such as `.claude/skills`, pass `--dir <path>`.

Add the PATH line the installer prints to your shell startup file, export your keys there,
then restart your agent so it inherits the environment:

```sh
export PATH="$HOME/.local/bin:$PATH"   # example: use the path the installer prints
export CERTORAKEY=...
```

## Run it

Open your Solidity project in your agent and ask, for example:

> Use certora-autoprover to verify `src/Vault.sol:Vault`. The design document is `docs/design.md`.

If you have no design document, leave it out. The skill looks for one in the project and
continues without it. It checks its prerequisites first and stops with a message naming
anything missing. An interrupted run resumes from what it already wrote.

The skill installs the compiler versions the project's build configuration names.

## Where to find results

Everything goes under the project's `certora/` directory:

| Path | What it holds |
|---|---|
| `certora/report/report.md` | The report: per property outcomes, suspected bugs, skips with reasons, coverage. `report.json` holds the same data. |
| `certora/specs/` | The CVL specs and the generated summaries. |
| `certora/confs/` | The prover configurations, one per component. |
| `certora/logs/` | The log of every autosetup and prover run. |
| `certora/resolver/<rule>/` | If the skill used the Timeout Resolver, its proof, patches and Lean file. |

## Updating

| How you installed | How to update |
|---|---|
| `./install.sh` (symlink, the default) | `git pull` in this clone. The agents see the new files at once. |
| `./install.sh --copy` | `git pull`, then `./install.sh --skill-only --copy`. |
| `npx skills add` | Run the same `npx skills add` command again. |
| Claude Code plugin | `claude plugin marketplace update certora-skills && claude plugin update certora-autoprover` |

These update the skill, not its tools. If the update changes
`skills/certora-autoprover/AUTOPROVER_REF`, also run `./install.sh --deps-only --reinstall`.

## Other ways to install

These routes install the skill only. Install the tools afterwards with
`./install.sh --deps-only` from a clone of this repository.

```sh
# skills CLI
npx skills add Certora/autoprover-skill

# Claude Code plugin
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-autoprover@certora-skills
```

For an agent with no skill support, hand it [`AGENTS.md`](AGENTS.md) from the repository root,
or paste `skills/certora-autoprover/SKILL.md` into its context. Keep this repository accessible
to the agent so it can read the files `SKILL.md` refers to.

## Advanced

### Installer options

To see the whole plan without changing anything, run `./install.sh </dev/null`.

- `--skill-only` or `--deps-only` installs only the skill or only its tools.
- `--dir <path>` writes the skill to a directory of your choice.
- `--copy` copies the skill instead of symlinking it.
- `--reinstall` re-resolves the tools and lets uv take over command names another tool owns.
- `--autoprover-ref <ref>` builds from a different AutoProver commit.
- `--yes` answers every prompt.

### Updating AutoProver dependency

The skill relies on autosetup, a utility for preparing contracts for optimal formal verification.
The autosetup utility is part of [AutoProver](https://github.com/Certora/AutoProver).
The installer uses the AutoProver commit named in `skills/certora-autoprover/AUTOPROVER_REF`. To
take a newer one, write its SHA into that file and reinstall the tools:

```sh
git ls-remote https://github.com/Certora/AutoProver master   # the current master SHA
./install.sh --deps-only --reinstall
```

To try a branch or a commit without editing the file, pass `--autoprover-ref <ref>`.

### Manual installation

The installer runs this for the tools:

```sh
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
GIT_CONFIG_VALUE_0='git@github.com:' \
uv tool install --python 3.12 --with-executables-from certora-cli \
  "ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@$(cat skills/certora-autoprover/AUTOPROVER_REF)"
uv tool install solc-select
```

If uv answers `Executables already exist`, remove the standalone tool with
`uv tool uninstall certora-cli`, or add `--force`.

### Removing it

```sh
solc-select uninstall <version>             # each compiler, first
uv tool uninstall ai-composer solc-select   # the tools
rm ~/.agents/skills/certora-autoprover          # the skill, in each agent directory it was written to
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
