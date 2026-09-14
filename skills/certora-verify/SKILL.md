---
name: certora-verify
description: End-to-end formal verification of a Solidity contract with the Certora Prover. Given a project (Foundry/Hardhat) and a main contract, this skill analyzes the system's components, runs certora-autosetup to build a working prover configuration and summaries, formulates security properties (invariants, safety properties, attack vectors) per component, formalizes them in CVL while consulting the official docs at https://docs.certora.com/en/latest/, and iterates certoraRun until every rule is verified, excused as a suspected bug, or skipped with justification — ending with a verification report. Use this whenever the user wants to formally verify a Solidity contract, prove properties about a contract, or generate CVL specs/rules/invariants and check them with the prover — e.g. "formally verify src/Vault.sol:Vault", "come up with properties for this contract and prove them", "write a Certora spec for X and run it". Also use it when the user asks to "audit contract X with the prover" or wants machine-checked guarantees rather than a manual review.
---

# certora-verify

Formally verify a Solidity contract end-to-end: understand the system, set up the prover, decide *what* should be true, express it in CVL, and let the prover check it — iterating on failures until every claim is either proven, exposed as a real bug, or explicitly retired with a reason.

## Background: how Certora verification works

The **Certora Prover** takes compiled Solidity plus a specification written in **CVL** (Certora Verification Language) and *symbolically* checks every rule against **all possible inputs and starting states** — not test cases. A spec contains:

- **rules** — symbolic executions ending in `assert`/`satisfy` (a *parametric* rule takes a `method f` parameter and is checked once per contract method);
- **invariants** — state predicates proven *inductively*: they hold after the constructor, and assuming one holds before an arbitrary method call, it holds after;
- a **methods block** — declarations and **summaries** (replacements the prover uses for calls it cannot or should not analyze).

Two prover behaviors drive most of the work in this flow:

- **The scene.** The prover only models the contracts you give it. A call whose target/implementation isn't resolvable in the scene is a **havoc**: the prover assumes the call may arbitrarily change any state, which usually produces absurd counterexamples. Havocs are fixed by `link`ing contracts, adding them to the scene, or writing summaries.
- **Vacuity.** A rule whose preconditions contradict the code proves nothing (`assert false` would also "pass"). Running with `rule_sanity: basic` makes the prover flag these as SANITY_FAILED instead of green.

A verdict of VIOLATED comes with a concrete **counterexample** (a call trace). Deciding whether a counterexample means "my spec/setup is wrong" or "the contract has a bug" is the central judgment call of this entire flow — a rule that fails because it exposes a real bug is a **success**, to be reported, never hidden.

**Two prime directives:**

1. Your sole *authoritative* sources on CVL syntax and prover behavior are the official docs at https://docs.certora.com/en/latest/ and the bundled references. Do NOT assume the prover works some way because it is "intuitive" — fetch the relevant docs page and check (`references/cvl-writing.md` has the page map).
2. Do not reason yourself into whether a property is true — author CVL that lets the *prover* demonstrate it.

## Inputs, artifacts, resume

**Inputs**: a project root (Foundry or Hardhat), a main contract as `relative/path/File.sol:ContractName`, optionally a design document. Track phases with the task list — one task per phase.

Every phase writes its result under the project's `certora/` directory, so an interrupted run resumes by reusing artifacts whose inputs haven't changed (check before redoing work, and say when you reuse):

| Artifact | Written by |
|---|---|
| `certora/analysis/application.json` | Phase 2 (component model) |
| `certora/analysis/closure.json` | Phase 3 (scene decision) |
| `certora/confs/<Main>.conf`, `certora/specs/summaries/…`, `certora/specs/sanity-<Main>.spec` | Phase 3 (autosetup) |
| `certora/properties/<slug>.properties.json` | Phase 4 |
| `certora/specs/invariants.spec` + `certora/confs/invariants.conf` | Phase 5 |
| `certora/specs/<slug>.spec`, `certora/confs/<slug>.conf`, `certora/properties/<slug>.property_rules.json`, `certora/properties/<slug>.commentary.md` | Phase 6 |
| `certora/report/report.json`, `certora/report/report.md` | Phase 7 |

Create the artifact directories up front so writes and `tee` don't fail on a missing parent: `mkdir -p certora/{analysis,confs,specs/summaries,properties,report,logs}`.

Long-running commands (autosetup, and every full certoraRun) take tens of minutes to ~2h — longer than a foreground tool call may run. **Run them in the background**, redirect to a log file under `certora/logs/`, and poll the log; never block on them and never re-run one just to see more output. (Piping through `tee` still works, but the background handle is what lets you keep working while it runs.) While waiting, **emit a short progress note each time you poll** (elapsed time + the last log line) — a harness may kill an agent that produces no output for several minutes, so a single long silent wait can lose the run even though the background job is fine.

## Phase 0 — Preflight

This skill is standalone: it needs nothing beyond the tools below. Fail fast with a specific message rather than improvising around a broken environment:

- `certoraRun` and `certora-autosetup` on PATH (`which certoraRun certora-autosetup`). `certoraRun` comes from `pip install certora-cli`; `certora-autosetup` is a separate Certora tool that is NOT bundled with certora-cli and has no standalone pip package — if it's missing, stop and tell the user to obtain it from Certora. Do not substitute or hand-roll a setup.
- `ANTHROPIC_API_KEY` set (autosetup makes internal LLM calls) and `CERTORAKEY` set (cloud prover).
- The solc compiler(s) the project needs are on PATH under the `solcX.Y` naming convention. Determine the required version(s) from the project's `pragma solidity` statements and any `solc`/`solc_version` setting in `foundry.toml`/hardhat config, then check that each corresponding `solcX.Y` binary exists (e.g. a `pragma solidity ^0.8.29` project needs `solc8.29`). Don't assume a fixed version.
- The main contract file exists, declares the named contract, and it is a concrete `contract` (not `abstract`/`interface` — the setup rejects those).

## Phase 1 — Design document (optional but valuable)

If the user supplied a doc, use it. Otherwise spend a few minutes looking for one: shortlist by name/location (`docs/`, files named design/spec/architecture/whitepaper, top-level `*.md`, READMEs near the contract), then judge by content. A doc qualifies if it describes **intended behavior**: architecture/component breakdown, natural-language descriptions of inter-contract interactions, invariants ("total supply equals sum of balances"), accounting formulas, access-control rules, threat model. Build/deploy instructions, usage docs, changelogs, and generic READMEs do NOT qualify — never pass one off as a design doc. Proceeding without a doc is fine; say so and derive intent from the code.

## Phase 2 — Component analysis

Properties are formulated against *intent*, so first extract a structured model of what the application is supposed to be. Act as a system architect. Explore the source (skip `lib/`, `test/`, `node_modules/`, `.git`, JSON artifacts, and any existing `certora/`/`.certora_internal/` leftovers; read whole files, not fragments). Produce `certora/analysis/application.json`:

- `application_type` (broad category: "AMM", "Stablecoin", "Vault", ...) and a 2-3 sentence description.
- **Explicit contracts** — one per concrete contract/library in play: conceptual `name`, `solidity_identifier`, relative `path`, role description, and a `sort`: `singleton` / `dynamic` (created by the app via `new`) / `multiple` (several copies deployed externally).
- **External actors** — anything outside the core app (third-party protocols, oracles, admin EOAs, off-chain components): name, role, explicit **assumptions** about its behavior, interface path if any.
- Per contract, **components**: sub-units organizing related functionality (a well-known interface like "ERC20 interface" is a natural component). For each: description (*what* it does, not *how*), external entry points, key state variables, requirements phrased as "The implementation must ...", and interactions naming the target contract/component or external actor.

Rules that keep the model sound: the main contract MUST appear as an explicit contract with exactly the given identifier; names unique; every interaction references a declared contract/component/actor; enumerate interactions transitively but **halt at external-actor boundaries** (never speculate about what an oracle talks to). Interface heuristics: single in-repo implementation → explicit contract; well-known standard used generically (ERC20/721/4626) → external actor; several in-repo implementations → the interaction targets an external actor, but list the implementations as explicit contracts too. Natural language only — no pseudo-code. Validate these rules against your own JSON before moving on; violations poison everything downstream.

The **components of the main contract** become the unit of work for phases 4-6.

## Phase 3 — Scene analysis + setup

First decide the **scene** (which contracts the prover must model):

- Compute the transitive call closure of the main contract (follow `delegatecall`/proxy edges like calls; include implementers of interfaces used; exclude drivers that only call *into* the main contract).
- Classify each closure contract: a bog-standard ERC20 → note as ERC20 (the setup models tokens with dummy mocks); a meaningful ERC20 *extension* → keep as a real contract.
- The prover instantiates exactly **one** instance per contract declaration. If meaningful verification requires ≥2 instances of one contract, write minimal harnesses `contract XInstance1 is X {}` under `certora/harnesses/` and add them to the scene. Usually not needed — skip unless the protocol's core state genuinely spans multiple instances.

Record the closure in `certora/analysis/closure.json`. Then build the prover setup with **certora-autosetup** (a tool that automates the fiddly part: compiler settings, contract linking, loop bounds, and generated summaries for hard-to-verify library functions). Full invocation, outputs, and failure modes: **`references/autosetup.md`**. In short, run this **in the background** (it launches real prover jobs to resolve calls and tune bounds — tens of minutes is normal), from the project root:

```bash
cd <project_root>
certora-autosetup --main-contract <rel_path>:<Main> \
  <rel_path>:<Main> <closure .sol files...> --no-strip-contracts \
  > certora/logs/autosetup.log 2>&1
```

Poll `certora/logs/autosetup.log` for progress. Below, `<Main>` is the main contract's name. Its deliverables are the foundation for everything after:

- `certora/confs/<Main>.conf` — a working prover conf (files, compiler settings, `loop_iter`, hashing bounds). Note: contract *links* are NOT in the conf — they live as a CVL `links` block inside the call-resolution spec below.
- `certora/specs/summaries/<Main>_base_summaries.spec` AND `certora/specs/summaries/<Main>_call_resolution.spec` — generated summaries plus the links/DISPATCHER resolution. Every spec you write MUST import BOTH (copy the import lines verbatim from the top of `sanity-<Main>.spec`, which also cover `erc7201.spec` when present). Importing only the base summaries silently drops every link, and calls that sanity resolved will havoc in your rules.
- `certora/specs/sanity-<Main>.spec` — a parametric reachability rule proving every external method can execute end-to-end under this setup. A method failing sanity means the setup can't verify that method; investigate before writing specs.

If autosetup fails, read the log tail and fix the underlying issue (missing solc, abstract main contract, stale caches — see the reference) instead of retrying blindly.

## Phase 4 — Property formulation (per main-contract component)

For each component of the main contract, formulate **security properties** as an audit reviewer would. Each property gets a globally unique snake_case `title`, a `sort`, and a precise, concise description. Three sorts:

1. **invariant** — representational, holds always from construction. Good: "the sum of all user balances equals totalSupply". Bad: "state fields should be correct" (broad).
2. **safety_property** — a concrete statement about what must (not) be possible, *including intended normal behavior*. Good: "a user without the admin role cannot approve other admins"; "a depositor receives the appropriate amount of LP tokens". Bad: "users can't hack the protocol".
3. **attack_vector** — a *plausible* exploit hypothesis; no evidence of an actual bug required, only plausibility. Good: "a rounding discrepancy between swap and previewSwap could create arbitrage". Bad: "there could be a rounding error and that would be bad somehow".

Hard rules: derive from first principles — what the code SHOULD do, not what it currently does. Quality over quantity: no padding, no reframed duplicates, no trivial corollaries, no properties whose violation has no consequence. Exclude what the prover can't or shouldn't check: off-chain events (key compromise, phishing), hash-collision reasoning, event emission, and anything already guaranteed by the type system (overflow reverts in Solidity ≥0.8 are uninteresting).

**Formalization direction is the same for all three sorts, and it is load-bearing:** every rule/invariant must be written so that VERIFIED means "the good thing holds / the bad thing cannot happen." An attack_vector is formalized as *the attack cannot occur*, not as *the attack occurs* — so a green result testifies to the **absence** of the problem, never its presence. If you catch yourself writing a rule that passes exactly when the exploit succeeds, invert it. (This is what makes a VIOLATED result meaningful in Phase 7 — see the expected-failure handling in `references/prover-loop.md`.)

Run up to **3 rounds** per component: after drafting a round, review it against the rules above, then do another pass asking "what did I miss?" — treating the earlier rounds' reasoning as the record of what was considered. **A round that adds nothing is the stop signal** — an empty round is the right answer for a well-covered component. Write the result to `certora/properties/<component-slug>.properties.json` (`[{title, sort, description}]`), where `<component-slug>` is the component name lowercased with every run of non-alphanumeric characters replaced by a single `-` (e.g. "ERC20 interface" → `erc20-interface`); the structural-invariants batch uses the reserved slug `invariants`.

Additionally formulate **structural invariants** for the main contract as their own batch (slug `invariants`): "sane state" facts that rule out infeasible starting states (e.g. a balance exceeding totalSupply) and thus kill spurious counterexamples later. They must be **inductive** — hold at construction and be preserved by every method; never "after calling F, P holds". Indicators: obvious to an informed reader, structural rather than mathematical, likely load-bearing for other properties.

## Phase 5 — CVL: structural invariants first

Formalize the structural-invariants batch into `certora/specs/invariants.spec` (conf `certora/confs/invariants.conf`) using the Phase 6 Generator + Judge procedure as a **single batch** — one generator produces it, one judge reviews, ping-ponging until the judge accepts and the invariants verify. Do this batch FIRST and to completion: component specs then `import` it and `requireInvariant` its invariants as preconditions, and Phase 6's barrier housekeeping re-runs this same gate whenever a component asks to add an invariant to the file.

## Phase 6 — CVL generation + prover loop (batched ping-pong across components)

Each component gets one spec `certora/specs/<slug>.spec` + conf `certora/confs/<slug>.conf` covering all its properties. You are the **orchestrator**: you never author or judge in your own context — you run rounds of two barrier-synchronized subagent batches. This keeps authoring parallel *and* review adversarial, and it respects the one-level nesting limit (a subagent cannot spawn a subagent, so both batches must be spawned by you).

### The ping-pong loop

Keep a set of **open** components (initially all of them). Each round:

1. **Generate** — spawn one *generator* subagent per open component, all in parallel, and **wait for the whole batch** before continuing. Give each generator: its component's property list, the relevant contract source, the exact import lines to copy from `sanity-<Main>.spec`, `references/cvl-writing.md` + `references/cvl-pitfalls.md`, and — on rounds after the first — its previous spec plus the judge feedback that rejected it. It runs the **Generator procedure** below and returns: the spec + `property_rules.json` it wrote, its full prover status, any structural-invariant requests, and notes.
2. **Barrier housekeeping** — if any generator asked for a new structural invariant, add it to the shared `certora/specs/invariants.spec` **yourself now** (generators must never write that file — every component imports it, so parallel writes would race), re-verify it with the Phase 5 gate, and only then proceed, so the next batch imports a consistent, proven file.
3. **Judge** — spawn one *judge* subagent per component that a generator just produced, all in parallel, and **wait for the whole batch**. Give each judge the **Judge inputs** below; each returns accept / reject + concrete feedback.
4. **Partition** — a component *leaves* the open set only when, this round, its judge **ACCEPTED** the produced spec **and** that generator's full unfiltered prover run was clean (every rule VERIFIED or expected-to-fail). Everything else stays open, carrying its judge feedback into the next Generate. Regenerate and re-judge **only** the still-open components.
5. Repeat until the open set is empty (convergence) — or a component hits the per-component round cap (below), which closes it via the deadlock rule.

Because the batches are synchronized but the open set shrinks, a component that converges in round 1 is done while slower siblings keep ping-ponging; you only re-spawn work for what remains open.

### Generator procedure (each generator subagent)

Consult the docs pages while authoring — particularly Methods Block/summaries, Invariants, Rules — rather than guessing syntax.

- Give each property its own rule(s)/invariant(s), formalized in the **"VERIFIED = good"** direction from Phase 4.
- Import the setup's summary specs — base summaries AND call resolution, copied verbatim from the sanity spec's import lines (required) — and `invariants.spec` when useful. If you find you need a structural invariant that isn't in `invariants.spec`, do NOT edit that file; record a request and return it (the orchestrator adds it between rounds).
- Build the `property_rules` mapping (every non-skipped property title → the rule/invariant name(s) that verify it) and persist it to `certora/properties/<slug>.property_rules.json` — it gates completion and feeds the report, so it must survive a restart.
- Typecheck first: `certoraRun <conf> --compilation_steps_only` (fast ~1 min); fix all type/parse errors before anything else (the judge assumes the spec typechecks).
- Then prove: build the conf as the setup base plus the overlay defined in `references/prover-loop.md` (single source of truth for the overlay; it includes `wait_for_results: "all"`, load-bearing because the base conf ships `wait_for_results: none`). Run certoraRun (mechanics, status parsing, counterexample extraction all in that reference). For each non-verified rule, analyze the trace, classify the root cause, and apply the remediation playbook there: missing-invariant `requireInvariant`, sound summaries for havocs (never `NONDET` on side-effecting functions, never `persistent` ghosts to dodge a havoc), `filtered` blocks at ~95% certainty, expected-failure for a rule that exposes a genuine bug OR that fails only due to an exhausted prover limitation (record which), skip for genuinely-invalid properties, contradictory-`require` hunt for sanity failures.
- Iterate write→prove yourself until the full unfiltered run is clean (all VERIFIED or expected-to-fail) or you've exhausted principled fixes. Write the per-component commentary (`certora/properties/<slug>.commentary.md`). **Return** the final spec, `property_rules`, the full prover status (including expected-fail markings + reasons), and any structural-invariant requests — then stop; do not attempt to review your own work.

### Judge inputs (each judge subagent)

A fresh adversarial reviewer. Give it: the spec text, the contract source for the component, the property list, the generator's prover status (so it doesn't flag intended expected-fails — criterion 6), **and both the 8-criteria Judge checklist AND the 23 CVL guidelines from `references/cvl-writing.md`** (criterion 2 checks against those guidelines; criteria 3/6/7 need the source). It returns accept / reject + concrete feedback. A generator may rebut prior feedback on its next round, but only with hard evidence (a typecheck error, a persistent counterexample, a docs citation) — a rebuttal is not a get-out-of-jail-free card.

### Per-component round cap / deadlock

If the judge keeps demanding a change that then makes the prover fail (or vice versa), a component can ping-pong forever. Cap it at ~3 gen↔judge rounds without that component converging. On hitting the cap, close it: keep the most defensible spec, and either record the offending property as skipped with the conflict documented, or mark the rule expected-to-fail with the reason. Cloud runs are expensive — an unbounded cycle is a failure mode, not diligence.

### Completion (per component)

Done means, for the spec that round produced: (a) the judge accepted it, (b) a full certoraRun with **no** `rule` filter shows every rule VERIFIED or explicitly expected-to-fail, and (c) `property_rules` is total — every property mapped, or explicitly skipped with a justification the judge accepted. Skips and expected failures are first-class outcomes, recorded with reasons — attempt every property before skipping any.

## Phase 7 — Report

Write `certora/report/report.json` and a human-readable `certora/report/report.md`:

- Per property: title, sort, description, component, the rules that formalize it, and each rule's outcome mapped to GOOD (verified) / BAD (violated) / ERROR / TIMEOUT / UNKNOWN, plus the prover run link.
- Group the properties into audit-style sections (roughly 8-25 for a real protocol; fewer is fine for small contracts) — each group one auditable claim with a short title and 1-3 sentence description; every property in exactly one group.
- List skipped properties with reasons. Split the expected-failure rules by *why* they were marked (Phase 6 recorded this): a rule marked expected-to-fail because it exposed a genuine issue is a **finding** — describe the counterexample scenario and its impact for a human security reviewer; a rule marked expected-to-fail only because of a prover limitation (spurious counterexample after exhausted reformulations) is NOT a bug — list it separately as a coverage gap so nobody chases a nonexistent vulnerability.
- Coverage summary: totals per outcome, and anything that limits confidence (sanity failures, unresolved calls left summarized as NONDET, trust assumptions introduced via bare `require`).

Finish by telling the user: counts per outcome, suspected bugs (genuine-issue findings) first, then prover-limitation gaps and skips with reasons, and links to the prover runs.
