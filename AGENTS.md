# AGENTS.md

This repository is one skill: `certora-autoprover`, an end-to-end formal-verification flow for
Solidity contracts using the Certora Prover. If your agent loads `SKILL.md` files on its own,
you do not need this file: read `skills/certora-autoprover/SKILL.md` instead.

## When it applies

Use it when the request is to formally verify a Solidity contract, prove properties about one,
or produce and check CVL specs, rules or invariants with the prover: "formally verify
src/Vault.sol:Vault", "come up with properties for this contract and prove them", "audit
contract X with the prover", "write a Certora spec for X and run it".

## What to read

`skills/certora-autoprover/SKILL.md` is the flow of record: phases 0-7. Read it in full before
acting. It names six references, each read when its phase needs it:

- `skills/certora-autoprover/references/autosetup.md`, `certora-autosetup` invocation, outputs, failure modes
- `skills/certora-autoprover/references/property-classes.md`, the questions to work through before drafting properties
- `skills/certora-autoprover/references/cvl-writing.md`, docs map, the CVL guidelines, the judge checklist
- `skills/certora-autoprover/references/cvl-pitfalls.md`, prover traps that are on no single docs page
- `skills/certora-autoprover/references/prover-loop.md`, building confs, running `certoraRun`, reading results
- `skills/certora-autoprover/references/timeout-resolver.md`, handing a timed-out rule to the hosted Timeout Resolver and applying what it returns

`skills/certora-autoprover/evals/evals.json` is a dev-time eval set for working on the skill, not
part of running it. Two of its three evals submit real cloud prover jobs and cost money.

## What the flow needs from you

- A shell and file read/write, plus the ability to leave a command running for up to about 2h
  while you wait on it. `nohup <cmd> > certora/logs/<name>.log 2>&1 &` starts it, and a bounded
  foreground loop on its PID waits for it, called again until the process ends. Never wait
  through a background monitor or a wake-up notice. See SKILL.md, "Inputs, artifacts, resume".
- Some way to read pages under https://docs.certora.com/en/latest/, a web-fetch tool or `curl`
  from the shell. Those docs are the authority on CVL; never answer from memory.
- Sub-agents, if you have them: the CVL and prover loop runs generator and judge batches in
  parallel. Without that primitive, run the same two roles one component at a time and keep
  them separate: the generation pass never accepts its own work, and the judging pass re-reads
  the spec, the contract and the recorded prover status from disk rather than from memory. A
  second session is the stronger separation where you can get one.

## Environment

The flow opens by checking the machine: `certoraRun`, `certora-autosetup`, `CERTORAKEY`,
Java 19 or newer, and a compiler manager. It stops with a specific message if one is missing.
When a tool is missing, it says what it will install and asks before it installs it.

Three things to know before you stop over them:

- `CERTORAKEY` carries one organization API key, for the prover and for the Certora Runs
  API behind the Timeout Resolver. A run with no timeout never reaches that API, so a key
  without its permissions still gets through the rest of the flow.
  `references/timeout-resolver.md` lists the permissions the key needs.
- No Anthropic key is needed. The flow runs `certora-autosetup --skip-llm`, which turns off
  every LLM call autosetup makes. The variable is still read at import and only its
  non-emptiness is checked, never the value, so export a placeholder and move on. Summaries
  are then static only, which weakens the specs built on them; a user with a real key can drop
  `--skip-llm` and pay for the better summaries.
- Compilers are a per-project question, answered while the project's setup is built rather
  than at install time. Read the project's resolved build plan (`forge compiler resolve
  --json -vv` for Foundry, autosetup's own extractor for Hardhat) rather than its pragmas,
  install what it resolves to with `solc-select install`, and reach each version through a
  directory of aliases named the way autosetup names a compiler in a conf, put in front of
  PATH for the run alone. Nothing is selected globally. Foundry's per-file assignments reach
  the conf. For a build system whose per-file assignments autosetup drops, Hardhat among them,
  the setup stops before autosetup when the plan gives different compilers to different files,
  and says which files disagree.

## House rules for this flow

- A rule that fails because it exposes a real contract bug is the product, not a defect.
  Report it, never weaken the spec to make it green.
- Skips and expected failures are first-class outcomes, recorded with reasons.
- Everything lands under the target project's `certora/` directory, so an interrupted run
  resumes from the artifacts rather than starting over.

## License

Copyright (C) 2026 Certora Ltd. Licensed under the GNU General Public License v3.0 only
(SPDX: `GPL-3.0-only`); the full text is in [LICENSE](LICENSE). This skill is a derivative
work of [AutoProver](https://github.com/Certora/AutoProver), which Certora Ltd. licenses
GPL-3.0-only, and which provides `certora-autosetup`.
