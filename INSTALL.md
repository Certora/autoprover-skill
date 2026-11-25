# Install Certora AutoProver

In Claude Code, install the marketplace and plugin.

```sh
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-autoprover@certora-skills
```

For other agents, point the skill installer at `Certora/autoprover-skill` and select `certora-autoprover`. Both Solidity and Solana use that name. If you previously installed `certora-autoprover-solana`, switch to the unified plugin. Agents that read instruction files directly can open [SKILL.md](plugins/certora-autoprover/skills/certora-autoprover/SKILL.md) with its sibling files available.

Create an organization key in the API section of [app.certora.com](https://app.certora.com) and make it available to the agent as `CERTORAKEY`. Hosted runs use `runs:create` and `runs:read`. Downloading artifacts requires `artifacts:read`. Cancelling a run requires `runs:cancel`. For direct prover jobs, enable “Use Certora Prover”. Local rule authoring also requires the target project's build tools, as described in the chain-specific reference.

Update the plugin in Claude Code.

```sh
claude plugin marketplace update certora-skills
claude plugin update certora-autoprover
```

Remove the plugin with this command.

```sh
claude plugin uninstall certora-autoprover
```
