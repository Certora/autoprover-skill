# Certora AutoProver

Formally verify a Solidity contract or Solana program. Give the agent a project, a target, and optionally a property in plain English. It uses the Certora Runs API for supported requests. For a custom proof, it writes a CVL or CVLR rule, checks the rule against the production setup with three independent reviewers, submits it to the prover, and reports the result and assumptions.

> Prove that only an authorized signer can withdraw from the vault in `programs/vault`. The production program ID and account layout are in `docs/deployment.md`.

> Write and prove a CVL rule that redeeming shares from `src/Vault.sol:Vault` pays the specified receiver. The deployed proxy configuration is in `deployments/`.

Install the `certora-autoprover` plugin for either chain. [Installation](INSTALL.md) · [Skill instructions](plugins/certora-autoprover/skills/certora-autoprover/SKILL.md)

<a href="plugins/certora-autoprover/skills/certora-autoprover/SKILL.md"><img src="https://img.shields.io/badge/version-0.8.0-blue?style=flat" alt="version 0.8.0"></a>

## License

Copyright (C) 2026 Certora Ltd. Licensed under GPL-3.0-only. This skill derives from Certora's AutoProver. [License](LICENSE) · [AutoProver](https://github.com/Certora/AutoProver)
