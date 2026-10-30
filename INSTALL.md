# Installing certora-autoprover

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

## Removing it

```sh
solc-select uninstall <version>             # each compiler, first
uv tool uninstall ai-composer solc-select   # the tools
claude plugin uninstall certora-autoprover  # or remove the skill from your agent's skill directory
```
