<div align="center">

# certora-autoprover

**Formal verification of your Solidity contract, without weeks of specialist work.**

An agent skill that derives your contract's security properties, writes them as
[CVL](https://docs.certora.com/en/latest/) rules and invariants, and proves them with the
[Certora Prover](https://docs.certora.com/en/latest/) for every input and every reachable
state, not just the cases a test or fuzzer tries. Each property comes back verified, flagged as a
suspected bug with a concrete counterexample, or reported as unresolved or skipped, with a
reason. No CVL expertise needed.

<p align="center">
  <a href="https://agentskills.io"><img src="https://img.shields.io/badge/SKILL.md-open_standard-blue?style=flat" alt="Agent Skills standard"></a>
  <a href="skills/certora-autoprover/SKILL.md"><img src="https://img.shields.io/badge/version-0.6.0-blue?style=flat" alt="version 0.6.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--only-lightgrey?style=flat" alt="GPL-3.0-only"></a>
  <a href="https://github.com/crytic/solc-select"><img src="https://img.shields.io/badge/compilers-solc--select-blue?style=flat" alt="compilers managed by solc-select"></a>
  <a href="https://github.com/Certora/autoprover-skill/stargazers"><img src="https://img.shields.io/github/stars/Certora/autoprover-skill?style=flat&logo=github&color=yellow" alt="GitHub stars"></a>
</p>

</div>

## Quick start

- A Foundry or Hardhat project that builds, with `forge` or `node`, Java 19 or newer, and
  [uv](https://docs.astral.sh/uv/getting-started/installation/).
- A `CERTORAKEY`: if you don't have one yet, create it at
  [app.certora.com](https://app.certora.com), and tick "Use Certora Prover", "Create runs",
  "Read runs and results", "Cancel runs" and "Download artifacts".

```sh
export PATH="$HOME/.local/bin:$PATH"   # uv places its tools here
export CERTORAKEY=...
claude plugin marketplace add Certora/autoprover-skill
claude plugin install certora-autoprover@certora-skills
```

Add the two exports to your shell startup file and (re)start your agent; for other agents,
updating and removing, see [INSTALL.md](INSTALL.md). Then point your agent at your project, and
optionally at a design document:

> Use certora-autoprover to verify `src/Vault.sol:Vault`. The design document is `docs/design.md`.

## Why formal verification

With formal verification you state what must always hold, not how it could break. Take
solvency: *the vault always holds enough assets to pay out every depositor.* You don't list
attack paths. The Prover searches every input, every caller and every reachable state for a
sequence of calls that breaks the property, and either finds one or proves that none exists.

Autoprover relieves you of writing the properties formally yourself. 
You write the properties in natural language, and Autoprover handles the technicalities,
the edge cases, the configuration, and the iterative process, until your properties are either 
proven or a bug is found.

**Are you a developer?** Autoprover helps you:
- **Think in properties.** It spells out what your protocol must and must not do, not how it is
  implemented.
- **Catch subtle design bugs** that testing rarely reaches, before you reach an auditor.
- **Keep them caught.** Add the generated specs to your CI and automatically check each code
  change with [certora-run-action](https://github.com/Certora/certora-run-action) against the
  same high-level properties.

**Are you a security researcher?** Autoprover helps you:
- **Get oriented fast.** On a new codebase you get its components and the properties each component
  should satisfy.
- **Start from concrete leads.** Every property the Prover breaks comes with the exact call
  sequence that breaks it.
- **Check your own attack vectors.** Use Autoprover to write a rule for a
  suspected issue and let the Prover search for an execution that confirms it.

## How it works

1. **Analyze** the project: its components, entry points and the contracts it calls.
2. **Set up** the prover with autosetup: compilers, contract links, and summaries, which are
   equivalent models of library code the prover cannot handle as written.
3. **Derive** security properties from the code and any design document.
4. **Formalize** them as CVL rules and invariants.
5. **Prove** them. Each counterexample is checked: a mistake in the spec or setup is fixed, and
   a real violation is reported as a suspected bug.

The agent writes, the prover checks: every verdict comes from the Certora Prover, never from the
agent.

**You get** a report in `certora/report/`:
- suspected bugs, each with its counterexample and impact;
- verified properties, each linked to its prover run;
- coverage gaps, with the reason;
- every assumption the setup relies on.

The report sits next to the specs and configurations, ready to rerun.

## FAQ

**How long does a run take?** Often 40 minutes to 2 hours; a day or more for contracts heavy in
nonlinear arithmetic and/or external dependencies. An interrupted run resumes where it stopped.

**What does it cost?** No LLM key beyond your agent's own. The prover runs in the Certora cloud:
2,000 free minutes per month, then paid; see [app.certora.com](https://app.certora.com).

**Where does my code go?** The prover runs in the Certora cloud, so each prover job uploads the
contracts it verifies. Your dashboard on [app.certora.com](https://app.certora.com) shows every
prover job with its results.

**What can it verify?** Solidity, in a Foundry or Hardhat project that builds. One main
contract per run, together with the contracts it calls.

**What if a property is hard for formal verification?** The skill summarizes code the property
does not depend on, splits the property, and can hand it to the hosted Timeout Resolver.
Anything still unsettled is reported as a coverage gap, never as verified or as a bug.

**Does a clean report mean my contract is secure?** No. A proof is only as good as the property
it proves: it shows the code satisfies the properties in the report, under the assumptions
listed there, and says nothing about properties nobody wrote. Read the properties, and treat the
report as strong evidence, not a guarantee.

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
