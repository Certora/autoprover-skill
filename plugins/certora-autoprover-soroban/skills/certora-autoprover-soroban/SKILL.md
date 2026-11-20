---
name: certora-autoprover-soroban
description: End-to-end formal verification of a Soroban contract with the Certora Soroban Prover. Given a Rust contract crate on soroban-sdk 22 or 25, this skill analyzes the contract's functions and storage, scaffolds a CVLR harness into the crate behind a cargo feature, formulates security properties (invariants, safety properties, attack vectors) per component, formalizes them as CVLR rules, and iterates the prover until every rule is verified, excused as a suspected bug, or skipped with justification — ending with a verification report. Use this whenever the user wants to formally verify a Soroban or Stellar smart contract, prove properties about one, or write and check CVLR rules for one — e.g. "formally verify contracts/token", "come up with properties for this Soroban contract and prove them", "write CVLR rules for the transfer function". Also use it when the user asks to "audit this Soroban contract with the prover" or wants machine-checked guarantees rather than a manual review.
license: GPL-3.0-only
compatibility: >-
  Requires uv, rustup and a C compiler; the skill checks for and, with the user's go-ahead,
  installs the pinned Rust toolchains and the wasm32v1-none target. Needs a CERTORAKEY for the
  Certora cloud prover and network access to prover.certora.com, crates.io, github.com and
  docs.certora.com. No model API key is needed.
metadata:
  version: "0.1.0"
  author: certora
---

# certora-autoprover-soroban

Formally verify a Soroban contract end-to-end: understand the contract, set up the prover, decide *what* should be true, express it as CVLR rules, and let the prover check it — iterating on failures until every claim is either proven, exposed as a real bug, or explicitly retired with a reason.

## Background: how Certora verifies a Soroban contract

The **Certora Soroban Prover** symbolically executes the contract's compiled wasm, so every rule is checked against **all possible inputs and storage states**, not test cases. Rules are written in **CVLR**, a Rust library: a rule is a `#[rule]` function (the attribute is `cvlr_soroban_derive`'s — `cvlr`'s own records rules in a section this prover does not read) in the contract's own crate, whose parameters are arbitrary inputs: an `e: Env` parameter is an environment over arbitrary contract storage. The body constrains the inputs with `cvlr_assume!`, calls one contract function directly — the way the contract's own tests do, with no dispatcher — and checks the result with `cvlr_assert!`.

Three facts drive most of the work:

- **Nothing proves an invariant for you.** CVLR has no counterpart of CVL's `invariant`, which the prover checks against every function by itself. A property that must hold of every reachable storage state is proved by hand: a base case per function that creates the state, and one step rule per function that writes it (Phase 5). Rules then assume the proved predicate with `cvlr_assume!`. And this CVLR line has no form that instantiates one specification across several functions, so a property that ranges over several functions is several rules.
- **A call into another contract is not followed.** It returns an arbitrary value and writes nothing, so two reads of one balance on another contract are two unrelated numbers. A property about what a called contract did cannot be proven against the real client; for SEP-41 token clients, `setup --token-model` can substitute an in-process model whose balances a rule can read (Phase 3 says when and at what cost).
- **Vacuity.** A rule whose assumptions contradict each other or the contract proves nothing. The prover checks this and reports such a rule `SANITY_FAILED`. The check runs after the prover's optimizer, so a contradiction the optimizer resolves by itself escapes it; a `cvlr_satisfy!` reachability rule over the same assumptions is the check that covers both.

A VIOLATED rule comes with a **counterexample**. Deciding whether it means "my rule or setup is wrong" or "the contract has a bug" is the central judgment of this flow. A rule that fails because it exposes a real bug is a **success**, to be reported, never hidden.

**Two prime directives:**

1. Your authoritative sources on CVLR and the prover are the reference text `certora-cvlr setup` writes (below), the CVLR crates' own source at the versions and revisions it names, and https://docs.certora.com/en/latest/docs/sunbeam/index.html. Do not assume the prover works some way because it is "intuitive".
2. Do not reason yourself into whether a property is true — write a rule that lets the *prover* demonstrate it.

## Inputs, artifacts, commands

**Inputs**: a project root (a Cargo workspace or package), the contract to verify when the workspace holds more than one (its package name), optionally a design document. Track the phases explicitly — one entry per phase in whatever task list or plan your agent keeps, marked done as you leave each phase; if it keeps none, state which phase you are entering each time you start one.

Every phase writes its result under the project's `certora/` directory, and the rules live in the contract's crate, so an interrupted run resumes by reusing artifacts whose inputs haven't changed (check before redoing work, and say when you reuse):

| Artifact | Written by |
|---|---|
| `certora/analysis/application.json` | Phase 2 (component model) |
| `certora/logs/setup.log`, and the edits it lists | Phase 3 (`certora-cvlr setup`) |
| `certora/analysis/dependency_moves.json` | Phase 3, only when setup refused on dependency versions |
| `certora/properties/<module>.properties.json`, `certora/properties/invariant_rules.properties.json` | Phase 4 |
| `<package>/src/certora/specs/invariants.rs`, `invariant_rules.rs` | Phase 5 |
| `<package>/src/certora/specs/<module>.rs`, `certora/properties/<module>.status.json`, `certora/properties/<module>.commentary.md`, `certora/properties/<module>.judge-round<N>.md` | Phase 6 |
| `certora/analysis/source_edits.json` | Phase 6 barrier, only when the contract's source was edited |
| `certora/report/report.json`, `certora/report/report.md` | Phase 7 |

On a resumed run, re-run `setup` naming every component before reusing anything: it is safe, and it refreshes what `certora-cvlr` writes into the project (the harness modules and `reference/`), which an upgrade of this skill changes.

`<module>` is a component's rule module name: snake_case, a valid Rust module name, unique in the contract. It names the component everywhere, including its artifacts. The shared invariants (Phase 5) are proved by the module `invariant_rules`, so their artifacts carry that name.

Create the artifact directories up front: `mkdir -p certora/analysis certora/properties certora/report certora/logs`.

**All mechanical work goes through one command, `certora-cvlr`,** from the AutoProver commit this skill pins. Never hand-write what it does: the scaffold, the cargo features, the build, the prover configuration, the rule list a job checks. Each of those fails quietly when done by hand. Its subcommands:

| command | what it does |
|---|---|
| `toolchain --chain soroban` | checks the Rust toolchains and the wasm target, and prints the command that installs each missing one |
| `setup <project> --component M ... [--token-model]` | scaffolds the crate, declares the rule modules, compiles, writes the reference text |
| `check <project> --component M` | type-checks one module as the prover's build does, in seconds |
| `prove <project> --component M [--rule R] [--loop-iter N] [--optimistic-loop WHY] [--unsat-core]` | builds one module to wasm, submits its rules, prints the job link |
| `wait <link> --for S --chain soroban` | waits at most `S` seconds, then prints `RUNNING`, or `FINISHED` and every rule's verdict, or `FAILED` |
| `cex <link> --rule R --chain soroban` | prints the counterexample of each violated instance of a rule: the call trace and the values the rule logged with `clog!` |
| `vacuity <link> --rule R` | prints the unsat core of a `prove --unsat-core` job, and whether the rule's assertion is in it |

`setup`, `check` and `prove` take `--package P` where the workspace has more than one contract; they detect the chain from the project, so they take no `--chain`. Each subcommand's `--help` lists its other flags.

**Waiting for a job.** A job takes minutes, longer than a single foreground command should hold your session. `prove` returns once the job is accepted; then call `certora-cvlr wait <link> --for <seconds> --chain soroban` in the foreground, and repeat it while it prints `RUNNING`. The bound must stay under the time your shell tool keeps a call in the foreground. That time is a parameter of the call; the tool's own description gives its name, its default, and its maximum. It is the parameter that backgrounds the command, or stops it, when the time runs out. Read it and pass it on every `wait` call, rather than a remembered default. A foreground limit of two minutes fits `--for 90`. A limit of 30 seconds does not: `wait` is still sleeping when the runtime backgrounds the call, which is the wake-up wait forbidden below. To wait longer, pass a longer limit and set `--for` about two minutes under it. A limit of 600000 milliseconds fits `--for 480`; use that pair when the tool allows it. If its maximum is lower, pass the maximum and set `--for` two minutes under that maximum, in seconds. If the tool has no such parameter, use `--for 20`. After each `RUNNING`, **emit a short progress note** (elapsed time and the status): an agent runtime may cut off a session that goes several minutes without output. **Never wait through a background monitor, a watcher script, a timer, or a turn that ends in the hope that a notice wakes you.** In real runs those wake-ups did not come, and finished jobs sat unread for hours. A tool description that promises a notice does not change that.

## Phase 0 — Preflight

Fail fast with a specific message rather than improvising around a broken environment.

- **`certora-cvlr`.** It is a command of the `ai-composer` package (https://github.com/Certora/AutoProver), which is not on PyPI. The commit is pinned because this skill names its subcommands and flags: it is the single line in `AUTOPROVER_REF.txt`, the file beside this one. Run it through `uvx`, never `uv tool install`: the Solidity skill in this marketplace installs the same package as a tool at its own pin, and two installs at two pins would replace each other. `uv` must already be on PATH; if it is not, stop and point the user at https://docs.astral.sh/uv/getting-started/installation/. Never download and run an installer yourself.

  Write a wrapper once, from the project root, substituting the pin for `<ref>`, and call it for every command below:

  ```bash
  mkdir -p .certora_internal/cvlr
  cat > .certora_internal/cvlr/certora-cvlr <<'EOF'
  #!/bin/sh
  exec env -u CERTORA \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_0='git@github.com:' \
    uvx --python 3.12 --from 'ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@<ref>' \
    certora-cvlr "$@"
  EOF
  chmod +x .certora_internal/cvlr/certora-cvlr
  ```

  The `GIT_CONFIG_*` rewrite clones AutoProver's public `graphcore` submodule over HTTPS, so no GitHub SSH key is needed. `env -u CERTORA` is load-bearing: a `CERTORA` variable in the environment makes the prover CLI refuse every submission before upload, with a message that names neither. Below, `certora-cvlr` means this wrapper, `<project root>/.certora_internal/cvlr/certora-cvlr`; give sub-agents its absolute path. When `AUTOPROVER_REF.txt` changes, rewrite it.

  The first call builds the package, which takes a few minutes; later calls reuse the build. Before that first call, tell the user what will be built (`ai-composer` with `certora-cli`, from the AutoProver repository at the pinned commit) and ask for their go-ahead.
- **The toolchain.** Run `certora-cvlr toolchain --chain soroban`. Every line must read `ok`. For a `MISSING` line with an `install:` command, show the user the commands and ask for their go-ahead, run them only after they agree, and run `toolchain` again. A `MISSING` line without one (rustup, a C compiler) is the user's to install: stop and tell them.
- **`CERTORAKEY`** set (cloud prover). No model API key is needed: AutoProver makes no model call in this flow.
- **The contract.** The project builds with `cargo`, and the contract's package has a library target (a `cdylib`) holding a `#[contract]` type, on soroban-sdk 22.x or 25.x. Other SDK generations are not supported yet. `setup` refuses a contract on a generation this AutoProver does not support with the reason; some such projects verify after a change to their dependency versions alone — see *When setup refuses* in Phase 3.

## Phase 1 — Design document (optional but valuable)

If the user supplied a doc, use it. Otherwise spend a few minutes looking for one: shortlist by name/location (`docs/`, files named design/spec/architecture/whitepaper, top-level `*.md`, READMEs near the contract), then judge by content. A doc qualifies if it describes **intended behavior**: the storage entries and who may change them, natural-language descriptions of contract flows, invariants ("a pool's recorded deposits never exceed its reserve"), accounting formulas, access-control rules, threat model. Build/deploy instructions, usage docs, changelogs and generic READMEs do NOT qualify. Proceeding without a doc is fine; say so and derive intent from the code.

## Phase 2 — Component analysis

Properties are formulated against *intent*, so first extract a structured model of what the contract is supposed to be. Act as a system architect. Explore the source (skip `target/`, `tests/`, `node_modules/`, `.git`, generated clients, and any existing `certora/` or `.certora_internal/` leftovers; read whole files, not fragments). Produce `certora/analysis/application.json`:

- `application_type` (broad category: "AMM", "Lending", "Vault", "Token", ...) and a 2-3 sentence description.
- **Contracts** — the contract under verification, with its `#[contract]` type and package name, and any other contract of the workspace it imports with `contractimport!` or invokes.
- **Storage** — each entry the contract keeps: its key (the variant of the contract's storage-key type, or the constant), its durability (instance, persistent or temporary), its value type, its role, and which functions create, write and remove it.
- **External actors** — anything the contract invokes but does not own (token contracts, oracles, other protocols) and the addresses it trusts (an admin, an upgrade authority): name, role, and explicit **assumptions** about its behavior.
- **Components**: groups of related contract functions (deposits, liquidation, admin configuration). For each: a `module` name (above), a description of *what* it does, its functions by their Rust names, the storage entries they read and write, requirements phrased as "The implementation must ...", and its cross-contract calls, naming the external actor.

Rules that keep the model sound: every contract function belongs to exactly one component; names unique; every cross-contract call names a declared external actor; halt at external-actor boundaries (never speculate about what an oracle does inside). Natural language only — no pseudo-code. Validate these rules against your own JSON before moving on.

The components become the unit of work for phases 4-6.

## Phase 3 — Setup

Run, from anywhere:

```bash
certora-cvlr setup <project> --component <module> [--component <module> ...] 2>&1 | tee certora/logs/setup.log
```

It edits the contract's crate, and reports every edit: a `certora` cargo feature and the CVLR dependencies, `[patch]` entries that read `cvlr-soroban` and `cvlr-soroban-derive` from their pinned git revisions, a `#[cfg(feature = "certora")] mod certora;` line, and `src/certora/` with the harness root, `soroban_nondet.rs` (arbitrary values of the SDK's types) and one rule module per component behind a feature of its own. It appends an `impl Nondet` to the contract's sources for every `#[contracttype]` and `#[contracterror]` it can build, and on a `#![no_std]` contract it gates what CVLR's `std` linkage requires under the feature. It also declares two modules of its own, `invariants` and `invariant_rules` (Phase 5), and compiles the result. Nothing it adds is compiled into the contract unless the `certora` feature is on.

Then read the end of its output:

- **`reference:`** names the directory of the CVLR reference text for this project's versions. Read its `README.md` now: it says what each file holds, and how to read the parts written for AutoProver's own agents. Read `cvlr.md` before writing any rule. Below, `reference/` means that directory. The Soroban reference has no `recipes/` directory; the triage ladder in Phase 6 stands in its place.
- **The rule modules**, each with the features that compile it.

Re-running `setup` is safe and changes nothing it already did. Every run must name **every** component: the list replaces the previous one, and a module file already written is kept. `setup` owns `src/certora/mod.rs` and `src/certora/specs/mod.rs` and rewrites them, so a module you declare there is dropped at the next run. Shared harness code of your own (helpers, `Nondet` and logging impls) goes in `invariants.rs` or in a submodule of it, `src/certora/specs/invariants/<name>.rs`, declared from `invariants.rs` (Phase 5).

**The token model.** When the contract calls SEP-41 tokens through `soroban_sdk::token` clients and Phase 4 will state properties about the balances those calls move, re-run setup with `--token-model`: it points the contract's token clients at an in-process model under the `certora` feature, so a rule can read a balance before and after the call. It is off by default for a reason, and the choice is the user's to approve: a verdict that reads the model assumes each token is a standard SEP-41 token (no fee on transfer, no hook, no call back into the contract), and on the current prover a contract that publishes events, and some soroban-sdk 22 builds, can return spurious counterexamples on rules that read the model's storage. Without it, a property about another contract's balances is skipped with that reason or restated over this contract's own storage.

**When setup refuses.** Read the reason. `setup` does not adapt a project it cannot verify, so any change is yours to propose and the user's to approve. A refusal over the soroban-sdk version can sometimes be cleared by moving the dependency within its supported generation, with no change to the contract's source. `references/sdk-versions.md`, beside this file, says how, and when it is not possible. Propose the move, wait for the user's go-ahead, record each edit in `certora/analysis/dependency_moves.json`, and run `setup` again. Any other refusal, or a move that file says is not possible: stop, and relay the reason.

List the edits setup made in the Phase 7 report (`git diff` shows them, and `setup.log` names them).

## Phase 4 — Property formulation (per component)

For each component, formulate **security properties** as an audit reviewer would. Read `reference/properties.md` first: it says what makes a property checkable by a rule, which is narrower than what is true. Each property gets a globally unique snake_case `title`, a `sort`, and a precise, concise description that **names the contract functions it is checked at**. Three sorts:

1. **invariant** — a relationship among storage entries that every function preserves. Good: "the supply entry is zero exactly when no balance entry is positive". Bad: "storage is consistent".
2. **safety_property** — a concrete statement about what a function must (not) allow, *including intended normal behavior*. Good: "`withdraw` succeeds only when the position's owner authorized the call"; "`deposit` mints shares in proportion to the pool's balance before the deposit". Bad: "users can't steal funds".
3. **attack_vector** — a *plausible* exploit hypothesis; no evidence of an actual bug required, only plausibility. Good: "passing the same address as both `from` and `to` of `transfer` could double-count the amount".

A safety_property can also state that something must be **possible**: "an owner with a sufficient balance can always withdraw".

**Work `references/property-classes.md` before you draft.** For each class, record the property it produced, or one line on why this component does not expose that surface. The record goes in the round's reasoning, and Phase 7 reads it for the coverage section.

Hard rules: derive from first principles — what the contract SHOULD do, not what it currently does. Quality over quantity: no padding, no reframed duplicates, no trivial corollaries, no properties whose violation has no consequence. Exclude what the prover can't or shouldn't check: off-chain events (key compromise, phishing), hash and signature collisions, published events, client-side code, storage TTL and fees, and "cannot panic" (a panic fails the invocation and the host rolls back its writes; `reference/properties.md` has the reasons and what to state instead).

**Formalization direction is the same for all three sorts, and it is load-bearing:** every rule must be written so that VERIFIED means "the good thing holds / the bad thing cannot happen." An attack_vector is formalized as *the attack cannot occur*. If you catch yourself writing a rule that passes exactly when the exploit succeeds, invert it.

Run up to **3 rounds** per component: after drafting a round, review it against the rules above, then do another pass asking "what did I miss?". **A round that adds nothing is the stop signal.** Write the result to `certora/properties/<module>.properties.json` (`[{title, sort, description, functions}]`).

**Then merge what several components state.** Read every component's properties together. Where several state the same contract-wide claim (conservation of the supply, "no function lets a non-owner move a position's funds"), keep one statement of it, over every function the members name, and move it to a component of its own, `protocol`. A merged property may state only what its members state: it names no function none of them names, and covers every member. Remove the members from their components. A property about one component's functions stays where it is. When you add `protocol`, re-run `setup` naming it too. This CVLR line has no macro that instantiates one specification across functions, so a merged property still costs one rule per function it names — the merge buys one statement of record and one place its verdicts are read, not fewer rules. Name the rules as one family (`<title>_<function>`).

Additionally formulate **shared invariants** as their own batch (`certora/properties/invariant_rules.properties.json`): "sane state" facts that rule out impossible starting states (a position with debt and no collateral, a balance entry on an uninitialized contract) and so kill spurious counterexamples later. Read `reference/invariants.md` for what makes a good candidate, and what an invariant may be about: entries under specific keys, read through the contract's own getters, with the contract's own initialization guard carried through. A relationship over every entry of a kind has no rule, since no read sees them all; state it at one arbitrary address, or restate it as what each function does to the entries it touches.

A shared invariant differs from an `invariant`-sort property in what it is for. Other rules assume a shared invariant, so it is proved at every writer in the contract before anything assumes it. An `invariant`-sort property is a claim reported in its own right, checked at the functions it names, in its component's module, and nothing assumes it. When a component's `invariant` property is one that other rules need to assume, move it to the shared batch instead of stating it twice.

## Phase 5 — Shared invariants first

The invariants are proved before any component, because components assume them. The method is `reference/invariants.md`, read in full before this phase. In short:

- **`invariants.rs`** holds each invariant as a `pub fn` returning `bool` over the environment (`fn solvent(e: &Env) -> bool`), reading storage through the contract's own getters or keys. Its doc comment lists every writer of each entry it reads, found in the code and followed up to the contract functions, across the whole contract. This module is compiled into **every** component's build, so it also owns the shared trait impls the predicates and rules need (`impl Nondet`, logging impls). A component that repeats one fails to compile (`E0119`), and uses the shared one instead. It holds no rules.
- **`invariant_rules.rs`** proves them: a base case per function that creates the state (the constructor or `initialize`: run it from arbitrary inputs and arbitrary prior storage, and assert the invariant), and one step rule per writer (an `e: Env` parameter is the arbitrary pre-state; assume the invariant, run the writer, assert it). A function that may either create or modify the same entry is both. Write each base case as a rule of its own, and generate the steps with a local `macro_rules!`, as `reference/invariants.md` shows — with `cvlr_soroban_derive::rule` inside the macro, as everywhere. Do not reach for cvlr-spec's `cvlr_rules!` or `cvlr_invariant_rules!`: they record rules in a section the Soroban Prover does not read.
- A step that fails from a pre-state no function produces means the invariant is too weak: strengthen it, and give the new conjunct its own steps. Most invariants here need the contract's own initialization guard (`!initialized(e) || ...`); `reference/invariants.md` says how to carry it.

Run it as a single batch through the Phase 6 generator and judge procedure, with `--component invariant_rules`. **The gate:** the judge accepted it, and a full `prove` of `invariant_rules` shows every rule VERIFIED. Nothing is ever marked expected-to-fail here: a component that assumed an invariant whose step was marked would assume exactly what failed to prove.

A component uses an invariant with `cvlr_assume!(<predicate>(&e))` on the rule's pre-state, the counterpart of CVL's `requireInvariant`, and its commentary names the step rules behind it. The judge rejects an assumption of a predicate that is not in `invariants.rs`, or whose steps did not all verify.

## Phase 6 — Rules and the prover loop (batched ping-pong across components)

Each component's rules go in its module, `<package>/src/certora/specs/<module>.rs`. You are the **orchestrator**: generation and judging are separate passes, and a module is never judged inside the pass that wrote it.

- **Parallel mode**: your agent can spawn sub-agents that run with their own context and hand a result back. Each round is two barrier-synchronized batches, both spawned by you; a generator never spawns its own judge. Start a batch's sub-agents together and wait for them in the foreground: if your agent's sub-agent tool can run them in the background, do not, and never end your turn while one is running. A background sub-agent's completion is a notice that wakes you, and the rule for prover jobs above applies to it too: in a headless run, an orchestrator that ended its turn "waiting for" a generator had that generator stopped by the runtime ten minutes later. Use it whenever you have the primitive. Generators of different components may build and prove at the same time: `prove` queues on the crate until a job is accepted, and one component's module is not compiled into another's build.
- **Sequential mode**: no sub-agent primitive. Run the identical loop one component at a time, under the discipline in *Sequential mode* below.

**Cloud jobs in parallel mode.** A sub-agent that has submitted a job never ends its turn while that job runs: it waits with `certora-cvlr wait` until the job is no longer `RUNNING`, then reads the result. You never report a sub-agent as idle or still waiting on the strength of its silence: run `certora-cvlr wait <link> --for 1 --chain soroban` on its job first, and if the job has ended, resume the sub-agent and tell it so.

### What changes only at the barrier

`invariants.rs` and **the contract's own source** are compiled into every component's build, so they change only between generation and judging, by you, never by a generator: an edit inside the generation window changes the build underneath a parallel sibling, and underneath a module a judge already accepted. `invariant_rules.rs` is compiled only into its own build, but every component assumes what it proves, so it too changes only at the barrier. A generator that needs a new invariant or a change to the contract writes a request and hands it back.

At the barrier, apply the requests, re-run the Phase 5 gate, and for a change to the contract's source, re-run the full `prove` of every component, including those already accepted: a clean run against source that has since changed is not evidence. A change to the contract's source is made only behind the `certora` feature where it can be (`#[cfg(feature = "certora")]`), never changes what the property is about, and is recorded with its reason in `certora/analysis/source_edits.json` for the report.

### The ping-pong loop

Keep a set of **open** components (initially all of them). Each round:

1. **Generate** — run one *generator* per open component, and **wait for the whole batch**. Give each generator: its component's properties, the functions' source, the path of the reference directory, the shared predicates in `invariants.rs`, and — on rounds after the first — its previous module plus the judge feedback that rejected it. It runs the **Generator procedure** below.
2. **Barrier** — apply the requests (above), and re-run what they invalidate.
3. **Judge** — run one *judge* per component a generator just produced, and wait for all of them. Each writes accept / reject + concrete feedback to `certora/properties/<module>.judge-round<N>.md` before any fix is applied.
4. **Partition** — a component *leaves* the open set only when, this round, its judge **ACCEPTED** the module **and** its last full `prove` (no `--rule`) was clean: every rule VERIFIED or marked expected-to-fail. A barrier re-run that is not clean **reopens** a component, with the change that broke it as its feedback.
5. Repeat until the open set is empty, or a component hits the round cap (below).

### Sequential mode (no sub-agents)

1. Work the open components in a fixed order. For each, run the **Generator procedure** to completion and write everything to disk before starting the next.
2. Judge only once every open component has been regenerated, so the barrier still falls between generation and judging.
3. Judge from the files, not from memory: re-read the module, the contract source, the properties and the recorded status as if someone else had written them; take the **Judge inputs** below as your entire brief; and write the verdict to `certora/properties/<module>.judge-round<N>.md`, with a finding or an explicit "no issue" for each point of `reference/judge.md`, **before** you apply a single fix.
4. If your agent can start a second session against the same working tree, do the judging there.

Say plainly to the user that you are in sequential mode, because self-review is its weak point: expect fewer rejections than a separate judge would produce, and treat a component that closes on round 1 with suspicion. The written verdict and the prover half of the completion gate are not relaxed in this mode.

### Generator procedure

Read `reference/cvlr.md` before the first rule, and `reference/author.md` by section as questions come up: it is what AutoProver's own rule author works from, and its sections answer most first-draft questions (storage and what a rule may say about it, authorization and `is_auth`, loops, arithmetic, when a rule should fail). Check what exists in the CVLR crates' own source — `cvlr`, and `cvlr-soroban` at the pinned revision — rather than guessing a helper.

- Give each property its own rule(s), formalized in the **"VERIFIED = good"** direction. Call the contract function directly as an associated function of the `#[contract]` type, with the environment, the way the contract's own tests do.
- `#[rule]` is `cvlr_soroban_derive`'s. A rule you wrote that `prove` does not list used the wrong attribute (`cvlr`'s own, or `cvlr_rules!`), or sits in a module the feature does not compile.
- Write the strict property. A rule that permits a loss, a rounding error or any other tolerance must name the source of its bound: the design document, a comment in the code, or the property itself.
- Assume shared invariants from `invariants.rs`; never restate one locally. If you need one that is not there, write a request.
- After every edit: `certora-cvlr check <project> --component <module>`, until it prints `ok`.
- Then `certora-cvlr prove <project> --component <module>`, and `wait` for it (`--chain soroban`). `prove` prints the rules the job checks; a rule you wrote and it does not list is not a rule.
- For each rule not VERIFIED, read the report `wait` prints and act:
  - **VIOLATED**: read the counterexample with `certora-cvlr cex <link> --rule <rule> --chain soroban`; never dig it out of the job's files. `clog!` the values your assertion reads, and the counterexample shows them (an `Address` or a `Map` is a host handle `clog!` cannot show — log the compared values instead). A starting state no function can produce is a missing invariant: request one. A rule that asserted something the property does not say is a rule bug: fix it. A real violation of the property is a finding: mark it **expected-to-fail** with the reason `genuine issue`, a description of the pre-state and the call, and keep the rule as it is. Never weaken a rule until it passes.
  - **SANITY_FAILED** (vacuous): read `reference/vacuity.md` first — it says where the contradiction usually is (the assume-violated-then-`assert!(false)` spelling of an access-control property is the classic; the reference's authorization section has the spelling that works). For the solver's own account: `certora-cvlr prove <project> --component <module> --rule <rule> --unsat-core`, `wait`, then `certora-cvlr vacuity <link> --rule <rule>`. A job that wrote no core is itself an answer that file explains.
  - An unwinding failure on a loop (*"Unwinding condition in a loop"*): bound what sets the trip count first — usually a `Vec` or `Map` length the rule left nondeterministic. Then raise `--loop-iter` if the real count is a known small constant. `--optimistic-loop "<why>"` is unsound and last. A loop in SDK code under the call (a token client, XDR serialization) that no bound discharges is a skip naming it.
  - **TIMEOUT**: the statistics `wait` prints under the verdicts name the functions that held the rule's time. Bound the symbolic operands of any nonlinear arithmetic by what the contract guarantees; split a rule doing two jobs; drop a function-level rule whose fact a rule on the contract's accounting function already proves and say how the two connect. After three jobs in a row with a timed-out rule, stop restating it — renaming or splitting a conjunct does not change what the rule runs over — and skip the property, citing the timed-out jobs. There are no prover summaries on Soroban: code in the way cannot be summarized out, so what remains is an assumption, a decomposition, or an honest skip. A job that **halted**, with no verdicts or with every unfinished rule cut off: find the rule that halts it by proving subsets (`--rule`), before resubmitting the rest.
  - The notes `wait` prints after the verdicts about calls treated as external are not a failure, but read them: a verified rule over an unfollowed cross-contract call proved less than it seems.
  - A property no rule can express, after a real attempt: **skip** it, with the reason. A reason that blames the prover cites the job that showed it.
- Record the module's state in `certora/properties/<module>.status.json`: `property_rules` (every property title → the rules that check it, or `skipped` with the reason), `expected_failures` (rule → `genuine issue` or `prover limitation`, the reason, the pre-state), the settings the last job used (`loop_iter`, `optimistic_loop` and why, whether the setup used `--token-model`), and the last full job's link and every rule's verdict.
- Iterate until a full `prove` is clean or the principled fixes are exhausted. Write `certora/properties/<module>.commentary.md`: what each rule drives, every assumption and why it holds, and — when the token model is on — the SEP-41 assumption on every rule that reads a balance. **Hand over** the module, the status file and the commentary, and any barrier requests; then stop.

### Judge inputs

A fresh adversarial reviewer: a separate sub-agent in parallel mode, a fresh-context pass in sequential mode. Give it: `reference/judge.md` (its brief), the module, the functions' source, the properties, the design document when there is one, `invariants.rs` with the Phase 5 status, the status file and the commentary. It produces accept / reject + concrete feedback, on disk before anyone acts on it. It checks in particular that every `cvlr_assume!` of a shared predicate names one whose steps all verified, that every rule's `#[rule]` is `cvlr_soroban_derive`'s and appears in a job's rule list, and that no rule was weakened until it passed. A generator may rebut feedback on its next round only with hard evidence: a compile error, a counterexample, a job link.

### Per-component round cap

Cap each component at about 3 generate↔judge rounds without converging. At the cap, close it: keep the most defensible module, and either skip the offending property with the conflict documented, or mark the rule expected-to-fail with the reason. Cloud runs cost the user time: an unbounded cycle is a failure mode, not diligence. A component the barrier reopened starts a fresh count.

### Completion (per component)

Done means: (a) the judge accepted the module, (b) a full `prove` with no `--rule` shows every rule VERIFIED or explicitly expected-to-fail, and (c) `property_rules` is total — every property mapped, or skipped with a justification the judge accepted.

## Phase 7 — Report

Write `certora/report/report.json` and a human-readable `certora/report/report.md`:

- Per property: title, sort, description, component, functions, the rules that check it, and each rule's outcome mapped to GOOD (VERIFIED) / BAD (VIOLATED) / VACUOUS (SANITY_FAILED) / ERROR / TIMEOUT / SKIPPED / UNKNOWN, plus the job link.
- Group the properties into audit-style sections — each group one auditable claim with a short title and 1-3 sentence description; every property in exactly one group.
- List skipped properties with reasons. Split the expected-failure rules by *why* they were marked: a rule that exposed a genuine issue is a **finding** — describe the pre-state, the function and its impact for a human security reviewer; a rule marked only because of a prover limitation is NOT a bug — list it separately as a coverage gap.
- Coverage and confidence: totals per outcome, and everything that limits confidence: sanity failures, every `optimistic_loop` with its reason, every bare `cvlr_assume!` that is not a proved invariant, every cross-contract call the prover did not follow in a verified rule, and — when `--token-model` was on — the SEP-41 assumption, stated once and tied to the rules that read the model. Name the property classes that produced no property for any component, with the one-line reason Phase 4 recorded.
- The changes made to the user's crate: the edits `setup` made (the token-model rewiring included, when on), every dependency move from `certora/analysis/dependency_moves.json`, and every edit to the contract's source from `certora/analysis/source_edits.json`, each with its reason. A property proved after a dependency move is a property of the build with the moved dependencies. Say so next to the verdicts.
- How to re-run: `certora-cvlr prove <project> --component <module>` for each component, with the settings each one needs.

Finish by telling the user: counts per outcome, suspected bugs (genuine-issue findings) first, then prover-limitation gaps and skips with reasons, and links to the prover jobs.
