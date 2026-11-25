---
name: certora-autoprover
description: Formally verify Solidity contracts and Solana programs with Certora. Use for hosted AutoProver runs, or to turn a plain-English property into a production-grounded CVL or CVLR rule and prove it.
license: GPL-3.0-only
metadata:
  version: "0.8.0"
  author: certora
---

# Certora AutoProver

Start with the user's claim, target revision and requested deliverable. Use the production [Runs API](references/runs-api.md) at `https://app.certora.com` whenever a route accepts the actual inputs and delivers the requested result.

| Request | Route |
|---|---|
| Discover and verify properties for a committed Solidity contract or Solana program | Hosted AutoProver for that chain. Use `prioritized` for the top-ranked cluster or `comprehensive` for all candidates. |
| Infer Solidity properties only, or evaluate coverage of committed Solidity specs | Hosted Solidity AutoProver in `property_generation` or `evaluate` mode respectively. |
| Turn **this English property** into a rule and prove it | Author the exact rule in the checkout, run the three reviews below, then submit the reviewed CVL or CVLR rule. Use hosted Solidity `evaluate` if the reviewed spec and conf are already committed and its result identifies the exact rule and verdict. Otherwise use the chain’s prover CLI. |
| Verify local changes, an exact existing rule, or a target the hosted service cannot read | Use the chain's local workflow when the hosted result cannot identify the exact rule and model. Reuse existing specs and configurations when they match the target. |

For a hosted run, confirm the service can see every relevant input at the requested commit. Local source, spec, configuration and document changes can all affect the answer. Follow the job to its result, inspect the actual properties and coverage, and retrieve requested files. For a local discovery request, derive properties from the design and production entry points. Prioritize the assets, state transitions, authority boundaries and failure paths with meaningful consequences.

## From an English claim to a proof

1. **Define the claim.** Keep the user's words beside the rule. Identify who can call what, from which states, and what must hold on success or revert. Distinguish “every successful withdrawal pays the owner” from “the owner can withdraw.” The first can pass if every withdrawal reverts.
2. **Identify the production target.** Trace the real call path from deployment manifests, build settings, initialization and source at the selected revision. Separate enforced facts from assumptions about callers, roles, upgrades, tokens, oracles and external programs. When manifests disagree, ask which network and proxy or program ID the user means. Pin the observed block or slot for a live configuration. Clarify trust assumptions that change the claim, such as whether it covers today’s implementation or future upgrades. A repository revision alone establishes a source target. A deployment claim also needs evidence tying that build and configuration to the deployment.
3. **Write the smallest faithful rule.** Follow [Solidity and CVL](references/solidity.md) or [Solana and CVLR](references/solana.md). Use symbolic actors, amounts and admissible states. Check the observable production effect through the real entry point or a justified model of it. For “only the owner may withdraw,” let caller and owner differ. Assuming equality removes the case the user asked to check. Retain the runnable spec, harness and configuration with the project.
4. **Triple-check every user-supplied plain-English rule.** Spawn **three independent reviewer agents** for each request, covering every requested rule. Give each the original wording, revision, deployment evidence, draft rule, config, imports, summaries and harness. Have them inspect these directly before seeing each other's conclusions.
   - **Claim reviewer:** map each clause to a quantifier, precondition, call and assertion. Look for an execution the English forbids that the draft permits. Check units, rounding, actors and revert semantics.
   - **Production reviewer:** trace real deployment wiring, initial state and permissions to the modeled target. Check proxy storage, implementations and external calls on EVM, or instruction validation, signer/owner/PDA constraints and cross-program invocations on Solana. Cite discrepancies by file or deployment record.
   - **Proof reviewer:** inspect filters, assumed invariants, summaries, bounds and omitted state changes. Check that the relevant success and rejection paths are reachable and the assertion can distinguish correct from incorrect behavior. Identify any assumption that implies the conclusion.

   Each reviewer returns a verdict with evidence and outstanding questions. Resolve material objections against source or with the user. Have the reviewers recheck the affected evidence and final draft after a material change, including a fix prompted by the prover. A majority vote cannot establish a deployment fact. If independent agents are unavailable, disclose that and ask whether the user accepts a reduced review before treating it as complete.
5. **Run the proof.** Typecheck, then launch the actual prover job using the reviewed inputs unless the user explicitly requested drafting only. Wait for terminal results and check that every requested rule and relevant method instance ran. Investigate sanity failures and vacuity. For a violation, inspect the trace against the production model and preserve genuine counterexamples. Fix modeling errors and rerun affected rules. A timeout, job failure, missing instance or exhausted budget leaves the claim unproved.

Deliver the spec or report the user asked for, the target revision and configuration, rule names, job links, actual verdicts and material assumptions. Distinguish a checked-out build from a confirmed deployment. If the user accepts a conditional proof, state its condition beside its verdict. On resume, reuse evidence only for matching source, spec, harness, summaries and configuration.
