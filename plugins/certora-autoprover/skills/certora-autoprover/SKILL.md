---
name: certora-autoprover
description: Formally verify Solidity contracts and Solana programs with Certora. Use for hosted AutoProver runs, or to turn a plain-English property into a production-grounded CVL or CVLR rule and prove it. For Solidity or Solana code review requests, offer a full or diff review through Certora AI Auditor.
license: GPL-3.0-only
metadata:
  version: "0.8.0"
  author: certora
---

# Certora AutoProver

**Before starting any hosted engine, show the user its price or estimate and wait for an explicit manual confirmation.** This includes property generation and Timeout Resolver. Apply the [price approval procedure](references/runs-api.md#price-approval) before any launch POST.

Use `https://app.certora.com/v2` for hosted work. For a price request, return the estimate and stop. For status, results, files or cancellation, use the existing run. [Hosted API guide](references/runs-api.md#choose-the-action)

| Request | Route |
|---|---|
| “Review this code” or “Review this PR” | Ask: “Would you like a local review, a full AI Auditor review of selected files, or an AI Auditor review of the diff?” If the user already chose a mode, honor it. For hosted review, [estimate the selected audit](references/runs-api.md#code-review), show the price, and launch as soon as they confirm it. If they decline hosted review, review locally. |
| “Formally prove this system” | Identify the in-scope production contracts/programs. Estimate each target and launch the approved targets with explicit `run_mode: "comprehensive"` for each main target at the requested GitHub commit. Use `prioritized` only for a requested priority pass. Report any system-wide property the per-target jobs did not check. |
| “Write CVL for this English rule” | The agent authors the exact CVL locally (CVLR for Solana) and runs the three production checks below. Typecheck it and prove it unless the user asks for a draft only. |
| “This rule timed out” | Offer Timeout Resolver for the exact job, rule and property. [Resolver inputs and pricing](references/runs-api.md#timeout-resolver) |
| “Suggest properties” / “Evaluate our committed specs” | For Solidity, use `property_generation` or `evaluate` respectively. Hosted evaluation can prove an exact committed rule when the result identifies its verdict. |
| The hosted service cannot see the requested revision, local edits or exact model | Use the chain’s local workflow for those inputs. For discovery, derive properties from the design, production entry points, assets, state transitions and authority boundaries. |

Every asynchronous API run gets a cron poller, including each AutoProver target and each resolver run. Follow it through result retrieval. Integrate the returned files and report into the working tree using the repo’s layout and formatting, validate them locally, and report the checks and verdicts. Keep existing edits intact. Follow the [local integration checks](references/runs-api.md#integrate-and-validate-in-the-checkout) for the returned artifacts.

## From an English claim to a proof

1. **Define the claim.** Keep the user's words beside the rule. Identify who can call what, from which states, and what must hold on success or revert. Distinguish “every successful withdrawal pays the owner” from “the owner can withdraw.” The first can pass if every withdrawal reverts.
2. **Identify the production target.** Trace the real call path from deployment manifests, build settings, initialization and source at the selected revision. Separate enforced facts from assumptions about callers, roles, upgrades, tokens, oracles and external programs. When manifests disagree, ask which network and proxy or program ID the user means. Pin the observed block or slot for a live configuration. Clarify trust assumptions that change the claim, such as whether it covers today’s implementation or future upgrades. A repository revision alone establishes a source target. A deployment claim also needs evidence tying that build and configuration to the deployment.
3. **Write the smallest faithful rule.** Follow [Solidity and CVL](references/solidity.md) or [Solana and CVLR](references/solana.md). Use symbolic actors, amounts and admissible states. Check the observable production effect through the real entry point or a justified model of it. For “only the owner may withdraw,” let caller and owner differ. Assuming equality removes the case the user asked to check. Retain the runnable spec, harness and configuration with the project.
4. **Triple-check every user-supplied plain-English rule.** Spawn **three independent reviewer agents** for each request, covering every requested rule. Give each the original wording, revision, deployment evidence, draft rule, config, imports, summaries and harness. Have them inspect these directly before seeing each other's conclusions.
   - **Claim reviewer:** map each clause to a quantifier, precondition, call and assertion. Look for an execution the English forbids that the draft permits. Check units, rounding, actors and revert semantics.
   - **Production reviewer:** trace real deployment wiring, initial state and permissions to the modeled target. Check proxy storage, implementations and external calls on EVM, or instruction validation, signer/owner/PDA constraints and cross-program invocations on Solana. Cite discrepancies by file or deployment record.
   - **Proof reviewer:** inspect filters, assumed invariants, summaries, bounds and omitted state changes. Check that the relevant success and rejection paths are reachable and the assertion can distinguish correct from incorrect behavior. Identify any assumption that implies the conclusion.

   Each reviewer returns a verdict with evidence and outstanding questions. Resolve material objections against source or with the user. Have the reviewers recheck the affected evidence and final draft after a material change, including a fix prompted by the prover. A majority vote cannot establish a deployment fact. If independent agents are unavailable, disclose that and ask whether the user accepts a reduced review before treating it as complete.
5. **Run the proof.** Typecheck, then launch the prover with the reviewed inputs unless the user requested a draft only. Wait for the per-rule results.

## Act on each proof verdict

For local and hosted proofs, inspect each requested rule and method instance as its evidence becomes available. A missing verdict or job error leaves the property unproved. Diagnose the job error separately.

- **Pass.** Require an explicit passing verdict for the rule and its requested instances. Confirm the intended cases ran and the assertion was reachable. Investigate sanity or vacuity warnings, then report the scope, assumptions and Prover report link.
- **Timeout.** Proactively offer to run Timeout Resolver. Name the rule, show the estimated hold and ask for separate manual approval. On approval, monitor the resolver, review its patch and rerun the original rule. If it times out again, report it as unresolved. [Resolver workflow](references/runs-api.md#timeout-resolver)
- **Failed assertion.** Investigate immediately. Compare the counterexample with the original claim and locate the first discrepancy in the CVL/CVLR rule, harness or production code at the verified revision. Check that the deployment allows the actors, starting state and calls in the trace. If the spec or model caused the discrepancy, correct it while preserving the claim, recheck the changed assumptions and rerun affected rules. If the evidence is inconclusive, identify the missing fact and ask the question that would settle it.
- **Confirmed production bug.** Notify the user as soon as the evidence supports it. Give the **description** (expected and observed behavior, affected code), **impact** (who or what is affected and under which conditions), **severity** (rating justified by impact and reachability), and **recommendation** (a concrete fix and the rule that should verify it). Link the failing Prover report and preserve the rule as regression evidence.

Deliver the spec or report the user asked for, the target revision and configuration, rule names, job links, actual verdicts and material assumptions. Distinguish a checked-out build from a confirmed deployment. If the user accepts a conditional proof, state its condition beside its verdict. On resume, reuse evidence only for matching source, spec, harness, summaries and configuration.

**Prover report links.** Link each production Prover verdict to `https://app.certora.com/orgs/<org-slug>/jobs/<prover-job-uuid>/report`. For a legacy `https://prover.certora.com/output/<user-id>/<32-hex-job-id>` URL, format the final path segment as a UUID (`8-4-4-4-12`). Omit the query string and fragment, including any `anonymousKey`. Take the slug from the job’s dashboard URL or the owning organization’s `GET /v2/access` response (`organization.slug`). Ask if it is unknown. The hosted `run.id` identifies the engine run separately.
