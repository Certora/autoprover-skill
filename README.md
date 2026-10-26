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
  <a href="skills/certora-autoprover/SKILL.md"><img src="https://img.shields.io/badge/version-0.5.0-blue?style=flat" alt="version 0.5.0"></a>
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
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/). The skill installs its tools
  with it. It does not install uv itself.
- `CERTORAKEY`, required: one organization API key, created on the API Access page at
  `app.certora.com`. Tick "Use Certora Prover" so it runs the prover. Tick "Create runs",
  "Read runs and results", "Cancel runs" and "Download artifacts".

Export the key in your shell startup file, and put `~/.local/bin`, where uv places its tools,
on your PATH. Then restart your agent so it inherits both:

```sh
export PATH="$HOME/.local/bin:$PATH"
export CERTORAKEY=...
```

## Install

### Claude Code

```sh
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-autoprover@certora-skills
```

### Any agent with skill support

```sh
npx skills add Certora/autoprover-skill
```

### By hand

Clone this repository and link `skills/certora-autoprover` into your agent's skill directory:

```sh
git clone https://github.com/Certora/autoprover-skill.git
ln -s "$PWD/autoprover-skill/skills/certora-autoprover" ~/.claude/skills/certora-autoprover
```

| Agent | Skill directory |
|---|---|
| Claude Code | `~/.claude/skills` |
| Cursor | `~/.cursor/skills` |
| Gemini CLI | `~/.gemini/skills` |
| opencode | `~/.config/opencode/skills` |
| Codex | `~/.codex/skills` or `~/.agents/skills` |
| Goose | `~/.config/goose/skills` |
| anything else | `~/.agents/skills` |

For an agent with no skill support, hand it [`AGENTS.md`](AGENTS.md) from the repository root,
or paste `skills/certora-autoprover/SKILL.md` into its context. Keep this repository accessible
to the agent so it can read the files `SKILL.md` refers to.

### The tools

The skill installs its own tools the first time it runs. It says what it will install and asks
you before it runs anything:

- `certora-autosetup` and `certoraRun`, built with uv from the AutoProver repository at the
  commit in `skills/certora-autoprover/AUTOPROVER_REF`.
- `solc-select`, from PyPI, and the compiler versions your project's build configuration names.

The tools belong to uv afterwards, so `uv tool uninstall` removes them.

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
| Claude Code plugin | `claude plugin marketplace update certora-skills && claude plugin update certora-autoprover` |
| `npx skills add` | Run the same `npx skills add` command again. |
| By hand | `git pull` in your clone. A symlinked skill sees the new files at once. |

These update the skill. An update can change `skills/certora-autoprover/AUTOPROVER_REF`. Then
at its next run the skill sees that its tools come from another commit. It asks you before it
reinstalls them.

### Updating the AutoProver dependency

The skill relies on autosetup, a utility for preparing contracts for optimal formal verification.
The autosetup utility is part of [AutoProver](https://github.com/Certora/AutoProver).
The skill builds its tools from the AutoProver commit named in
`skills/certora-autoprover/AUTOPROVER_REF`. To take a newer one, write its SHA into that file:

```sh
git ls-remote https://github.com/Certora/AutoProver master   # the current master SHA
```

### Removing it

```sh
solc-select uninstall <version>             # each compiler, first
uv tool uninstall ai-composer solc-select   # the tools
claude plugin uninstall certora-autoprover  # or remove the skill from your agent's skill directory
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
