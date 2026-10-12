---
name: certora-verify
description: End-to-end formal verification of a Solidity contract with the Certora Prover. Given a project (Foundry/Hardhat) and a main contract, this skill analyzes the system's components, runs certora-autosetup to build a working prover configuration and summaries, formulates security properties (invariants, safety properties, attack vectors) per component, formalizes them in CVL, and iterates certoraRun until every rule is verified, excused as a suspected bug, or skipped with justification — ending with a verification report. Use this whenever the user wants to formally verify a Solidity contract, prove properties about a contract, or generate CVL specs/rules/invariants and check them with the prover — e.g. "formally verify src/Vault.sol:Vault", "come up with properties for this contract and prove them", "write a Certora spec for X and run it". Also use it when the user asks to "audit contract X with the prover" or wants machine-checked guarantees rather than a manual review.
license: GPL-3.0-only
compatibility: >-
  Requires certoraRun (certora-cli) and certora-autosetup on PATH, a CERTORAKEY for the
  Certora cloud prover, Java 19+, network access to prover.certora.com and
  docs.certora.com, and the Solidity compilers the target project pins, which Phase 3
  installs with solc-select, plus forge or node to read the project's build plan. No Anthropic key is
  needed: autosetup
  runs with --skip-llm, and the variable it checks at import takes a placeholder. For the
  hosted Timeout Resolver that Phase 6 can fall back on, also a CERTORA_API_KEY and network
  access to app.certora.com.
metadata:
  version: "0.1.0"
  author: certora
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

1. Your sole *authoritative* sources on CVL syntax and prover behavior are the official docs at https://docs.certora.com/en/latest/ and the bundled references. Do NOT assume the prover works some way because it is "intuitive" — retrieve the relevant docs page and check (`references/cvl-writing.md` has the page map and says how to retrieve a page with or without a web-fetch tool).
2. Do not reason yourself into whether a property is true — author CVL that lets the *prover* demonstrate it.

## Inputs, artifacts, resume

**Inputs**: a project root (Foundry or Hardhat), a main contract as `relative/path/File.sol:ContractName`, optionally a design document. Track the phases explicitly — one entry per phase in whatever task list or plan your agent keeps, marked done as you leave each phase; if it keeps none, state which phase you are entering each time you start one.

Every phase writes its result under the project's `certora/` directory, so an interrupted run resumes by reusing artifacts whose inputs haven't changed (check before redoing work, and say when you reuse):

| Artifact | Written by |
|---|---|
| `certora/analysis/application.json` | Phase 2 (component model) |
| `certora/analysis/closure.json` | Phase 3 (scene decision) |
| `certora/analysis/compilers.json` | Phase 3 (compiler selection) |
| `certora/confs/<Main>.conf`, `certora/specs/summaries/…`, `certora/specs/sanity-<Main>.spec` | Phase 3 (autosetup) |
| `certora/properties/<slug>.properties.json` | Phase 4 |
| `certora/specs/invariants.spec` + `certora/confs/invariants.conf` | Phase 5 |
| `certora/specs/<slug>.spec`, `certora/confs/<slug>.conf`, `certora/properties/<slug>.property_rules.json`, `certora/properties/<slug>.commentary.md`, `certora/properties/<slug>.judge-round<N>.md` | Phase 6 |
| `certora/report/report.json`, `certora/report/report.md` | Phase 7 |

Create the artifact directories up front so a redirect or a write never fails on a missing parent: `mkdir -p certora/analysis certora/confs certora/specs/summaries certora/properties certora/report certora/logs certora/resolver certora/lean` (spelled out rather than brace-expanded, so it also works when the command runs under a plain POSIX shell).

Long-running commands (autosetup, and every full certoraRun) take tens of minutes to ~2h, longer than a single foreground command should hold your session. **Start them detached and poll their log.** The portable formulation needs nothing but a shell:

```bash
nohup <command> > certora/logs/<name>.log 2>&1 &
echo $! > certora/logs/<name>.pid
```

Read progress with `tail -n 20 certora/logs/<name>.log`, and check liveness with `kill -0 $(cat certora/logs/<name>.pid)` (exit 0 = still running). If your agent has its own background-execution facility, use that instead; it amounts to the same thing, and a log file plus a PID is the fallback when it doesn't. Never block a single command on a whole run, and never re-run one just to see more output. While waiting, **emit a short progress note each time you poll** (elapsed time + the last log line): an agent runtime may cut off a session that goes several minutes without output, so one long silent wait can lose the run even though the detached job is fine.

## Phase 0 — Preflight

This skill is standalone: it needs nothing beyond the tools below. Fail fast with a specific message rather than improvising around a broken environment:

- `certoraRun` and `certora-autosetup` on PATH (`which certoraRun certora-autosetup`). `certoraRun` comes from `pip install certora-cli`; `certora-autosetup` is the CLI of the `ai-composer` package (https://github.com/Certora/AutoProver), which is not published on PyPI. One uv command brings in both. `certora-cli` arrives through the `[certora-cli]` extra, and `--with-executables-from` is what puts its commands on PATH: `uv tool install` otherwise links only the console scripts of the package you named, not those of its dependencies.

  The ref is pinned because this skill describes autosetup flags and behaviour that move with it. It is the single line in `AUTOPROVER_REF`, the file beside this one; read it and substitute it for `<ref>`:

  ```bash
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
  GIT_CONFIG_VALUE_0='git@github.com:' \
  uv tool install --python 3.12 --with-executables-from certora-cli \
    'ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@<ref>'
  ```

  The `GIT_CONFIG_*` rewrite makes the build clone AutoProver's public `graphcore` submodule over HTTPS, so the install needs no GitHub SSH key.

  Then re-run `which certoraRun certora-autosetup`. If uv reports that the executables already exist, a separate `certora-cli` tool owns those names: `uv tool uninstall certora-cli` first, or add `--force` to let uv take them over. If you cannot install here, stop and give the user those commands, or point them at this repo's `install.sh`, which does all of it. Do not substitute or hand-roll a setup.
- `CERTORAKEY` set (cloud prover). No Anthropic key is required: **autosetup runs with `--skip-llm` by default in this flow**, which switches off every LLM call it would make (`setup_prover.py:1526` sets `enable_llm = not skip_llm`, and `setup_summaries.py:2507` gates the calls on it).

  autosetup still reads `ANTHROPIC_API_KEY` while importing its summary module, and it checks only that the value is non-empty, never that it is a working key (`certora_autosetup/setup/setup_summaries.py:70-93`); a `.env` in the working directory is loaded instead and then nothing is checked at all. So export a placeholder for the import and move on:

  ```bash
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-skip-llm-placeholder}"
  ```

  What the default costs: summaries for library and external functions are static only, so the ones that are hard to summarize statically get none, and specs that lean on them are weaker. If the user has a real Anthropic key and wants those summaries, drop `--skip-llm` and say that the run will make LLM calls they pay for. Ask first; never spend their key by default.
- Java 19+ on PATH (`java -version`). autosetup shells out to the `ASTExtraction.jar` typechecker while resolving summaries and there is no fallback path, so an old or absent JDK fails mid-run rather than at startup.
- A compiler manager, and a way to read a project's build plan. `solc-select` on PATH (`uv tool install solc-select` when it is not), plus `forge` when the target project has a `foundry.toml`, or `node` when it has a `hardhat.config.*`. No version is named here: which compilers a project needs is a property of that project, so Phase 3 derives it from the project's own build configuration and installs what it resolves to.

  Two machine facts that belong here rather than in Phase 3. solc-select moves its whole store into an active virtualenv, so every `solc-select` command in this flow runs under `env -u VIRTUAL_ENV`. And no directory holding a compiler may contain a space: certoraRun builds the compiler command as one string and splits it on whitespace.

- The main contract file exists, declares the named contract, and it is a concrete `contract` (not `abstract`/`interface` — the setup rejects those).
- Optional: a Certora API key in `CERTORA_API_KEY` (`references/timeout-resolver.md`). Phase 6 uses it only when a rule times out and the manual fixes are exhausted. Its absence blocks nothing here; note it, and if a timeout later calls for the resolver, ask the user for a key then.

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

Record the closure in `certora/analysis/closure.json`.

### Compiler selection

Which compilers this project needs is a property of the project, so derive it here rather than in preflight: a `git pull` in the target repo can change the answer.

Read the **resolved build plan**, not the pragmas. Pragmas say what each file tolerates; the build plan says what the project actually compiles with, which is what autosetup has to agree with. For Foundry, from the project as the working directory (`--root` on its own returns `{}`):

```bash
cd <project_root>
forge compiler resolve --json -vv 2>certora/logs/forge-resolve.err
```

`.Solidity[].version` is one entry per compilation unit, so deduplicate it; `.Solidity[].paths` is the file list each version covers. `No such file or directory` lines under `lib/` in the error log mean the project's dependencies are not checked out and the answer came from a partial source graph: run the project's own dependency step (`forge install`, or `git submodule update --init --recursive`) and read it again, because autosetup needs those sources too.

For Hardhat, run autosetup's own extractor rather than parsing the config, which is code and can read the environment:

```bash
extractor=$("$(uv tool dir)"/ai-composer/bin/python -c \
  'import certora_autosetup, pathlib; print(pathlib.Path(certora_autosetup.__file__).parent / "build_systems/hardhat_config_extractor.js")')
cd <project_root> && node "$extractor"
```

Take `.solidity.compilers[].version` plus every `.solidity.overrides[*].version`, since an override is a per-file compiler. `.solidityImplicitDefault: true` means the project declares nothing and the version shown is Hardhat's own built-in default, which says nothing about these sources: treat it as no answer. `{}` means the config would not load, so run the project's install step first.

With neither available, read the `pragma solidity` line of each file **in the closure** and take the newest release all of them admit. Say in the log that this is a pragma reading rather than a resolved plan: it over-reports. On one real project the resolved plan is a single 0.8.27 while a repository-wide pragma reading adds a second version that must never reach a `compiler_map`.

Then intersect with the closure. A version whose files are all tests, scripts or library code outside the closure is not your problem.

Install every version the closure resolves to:

```bash
env -u VIRTUAL_ENV solc-select install 0.8.17 0.8.21
```

Then give each one the name autosetup writes. Its only name for a per-contract compiler is the Certora form `solc8.17` (`enhanced_config_manager.py:745-761`, the convention fixed at `autosetup.py:446`), while solc-select's store holds `solc-0.8.17`. A directory of aliases bridges the two:

```bash
bin=<project_root>/certora/solc-bin                     # a path with no space in it
mkdir -p "$bin"
ln -sf "$HOME/.solc-select/artifacts/solc-0.8.17/solc-0.8.17" "$bin/solc8.17"
export PATH="$bin:$PATH"
solc8.17 --version                                      # must report 0.8.17
```

One alias per installed version, named by dropping the leading `0.`: `0.8.17` becomes `solc8.17`, `0.7.6` becomes `solc7.6`. The path must hold no space, because certoraRun builds the compiler command as one string and splits it on whitespace; if the project path holds one, build the directory under `$HOME` instead, and if that holds one too, stop and say so. Export the PATH in the shell that runs autosetup and every later certoraRun. Nothing outside the run changes, and no compiler is selected globally.

Leave `--solc-default` off the autosetup command below, so autosetup writes the per-contract names the build plan resolved to and the aliases answer to them. The conf then says which compiler compiled which contract. The flag only supplies a name for contracts nothing else pins (`compilation_workarounds.py:337-349`); the bare `solc` makes every entry read `solc`, and the conf follows whatever the machine selected last.

**Several versions over the closure** is not a problem to avoid: install them all and let `compiler_map` carry them. Never put a newer compiler in place of a version the plan pinned, however wide the pragmas are, because the run would then answer for a build nobody ships. Two cases stop the run before it submits a job, and autosetup names both: a version that cannot be provisioned at all (`UnsatisfiableSolcPinError`, with the contract and its pragma), and one compilation unit whose files no single compiler satisfies (`ConflictingPragmaError`).

**Only Foundry carries a per-file assignment into the run.** Autosetup reads Foundry's build artifacts for the compiler each contract was built with and writes them into `compiler_map` (`setup_prover.py:199-214`), then applies Foundry's `compilation_restrictions` on top (`foundry.py:104`). For any other build system both steps are skipped: the precompute returns the conf untouched (`setup_prover.py:213-214`) and the per-contract hook is a no-op (`base.py:74-88`). Hardhat's per-file compiler, the `solidity.overrides` block, is read by nobody: the extractor hands it over and the version extraction takes `solidity.compilers[]` alone (`hardhat.py:291-306`). One entry in `compilers` plus an override on one file therefore reaches autosetup as a single-version project, every entry in the seeded map gets the same value, the map collapses back to a scalar `solc` (`compilation_workarounds.py:366-374`), and both files compile at the version the override exists to avoid.

So before you run the autosetup command below, work out the compiler autosetup will really use for each file you hand it. Require that compiler to equal the one the plan gives that file. The rule holds whatever the closure needs, and Foundry meets it by construction. For every other build system the effective compiler is one value for the whole run. It is the single version in `solidity.compilers[]` when that list holds one (`hardhat.py:291-306`), and otherwise the default name plus a pragma reading per contract. An override that moves one file off that value disagrees. That holds when the closure needs a single compiler, and when the closure holds only that one file. On any disagreement, **stop and tell the user**: name each file, the compiler the plan gives it, and the compiler the run would use. No flag repairs this. `--extra-args` reaches only the certoraRun command line (`cli.py:150`, `autosetup.py:737`), the command line shadows the conf one key at a time (`certoraConfigIO.py:67-70`), and a compiler map standing next to the conf's own `solc` is refused outright (`certoraContextValidator.py:425-431`). A conf edited afterwards is too late as well, because autosetup submits real prover jobs while it works: by the time there is a conf to fix, the jobs that resolved the calls and tuned the bounds have already run at the wrong compiler. Two ways forward are honest. Verify a part of the system whose files all take the compiler the run would use anyway. That is not the same as a part that needs one compiler. Or get the per-file assignment carried into the run first.

When autosetup finishes, read the compiler names out of the conf it drove and out of the siblings beside it (`invariants.conf`, the per-property confs), and check each name twice: against the alias directory, and against the compiler the resolved plan gives that contract's file.

A missing alias is the one unambiguous repair, because the name in the conf is already the plan's answer. A later `certoraRun` reporting `Solidity executable solc8.X not found in path` means that alias is absent: add it rather than retarget the conf at another compiler.

A name that disagrees with the plan is a stop, not a repair: report which contracts disagree, what the plan gives them, and what the conf says. Autosetup's own default name, `solc8.34` (`constants.py:53`), is the one to read carefully, because it has two meanings and the plan separates them. Look up the contract's file in the plan's file lists (`.Solidity[].paths` for Foundry, the `compilers` entries and `overrides` keys for Hardhat). A file the plan does not cover was never assigned a compiler, so the default is the right answer: install that version and alias it too. A file the plan does cover reached the conf with its assignment lost, and an alias would hide that, so stop and report it.

Record what you found in `certora/analysis/compilers.json`: `source` (resolved plan or pragma reading), `versions`, `closure_versions`, `alias_dir`, and `aliases` as alias name to the version its binary reports. On resume, run `<alias> --version` for every entry and rebuild any alias that is missing or answers with a different version, instead of trusting the record.

Then build the prover setup with **certora-autosetup** (a tool that automates the fiddly part: compiler settings, contract linking, loop bounds, and generated summaries for hard-to-verify library functions). Full invocation, outputs, and failure modes: **`references/autosetup.md`**. In short, run this **detached** (it launches real prover jobs to resolve calls and tune bounds — tens of minutes is normal), from the project root:

```bash
cd <project_root>
nohup certora-autosetup --main-contract <rel_path>:<Main> \
  <rel_path>:<Main> <closure .sol files...> --no-strip-contracts --skip-llm \
  > certora/logs/autosetup.log 2>&1 &
echo $! > certora/logs/autosetup.pid
```

Poll it with `tail -n 20 certora/logs/autosetup.log`, reporting the elapsed time and the last line each time, until the process exits (`kill -0 $(cat certora/logs/autosetup.pid)` fails). `--skip-llm` is the default here, so the summaries are static-only: carry that into the report's confidence notes in Phase 7. Drop the flag only when the user has an Anthropic key and has agreed to the LLM calls it bills for. Below, `<Main>` is the main contract's name. Its deliverables are the foundation for everything after:

- `certora/confs/<Main>.conf` — a working prover conf (files, compiler settings, `loop_iter`, hashing bounds). Note: contract *links* are NOT in the conf — they live as a CVL `links` block inside the call-resolution spec below.
- `certora/specs/summaries/<Main>_base_summaries.spec` AND `certora/specs/summaries/<Main>_call_resolution.spec` — generated summaries plus the links/DISPATCHER resolution. Every spec you write MUST import BOTH (copy the import lines verbatim from the top of `sanity-<Main>.spec`, which also cover `erc7201.spec` when present). Importing only the base summaries silently drops every link, and calls that sanity resolved will havoc in your rules.
- `certora/specs/sanity-<Main>.spec` — a parametric reachability rule proving every external method can execute end-to-end under this setup. A method failing sanity means the setup can't verify that method; investigate before writing specs.

If autosetup fails, read the log tail and fix the underlying issue (a solc version not provisioned yet, abstract main contract, stale caches — see the reference) instead of retrying blindly.

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

Formalize the structural-invariants batch into `certora/specs/invariants.spec` (conf `certora/confs/invariants.conf`) using the Phase 6 Generator + Judge procedure for a **single batch**: one generation pass produces it, one judging pass reviews, ping-ponging until the judge accepts and the invariants verify (in either of Phase 6's execution modes). Do this batch FIRST and to completion: component specs then `import` it and `requireInvariant` its invariants as preconditions, and Phase 6's barrier housekeeping re-runs this same gate whenever a component asks to add an invariant to the file.

## Phase 6 — CVL generation + prover loop (batched ping-pong across components)

Each component gets one spec `certora/specs/<slug>.spec` + conf `certora/confs/<slug>.conf` covering all its properties. You are the **orchestrator**: generation and judging are separate passes, and a spec is never judged inside the pass that wrote it.

How you execute those roles depends on what your agent can do:

- **Parallel mode**: your agent can spawn sub-agents that run with their own context and hand a result back. Each round is two barrier-synchronized batches, both spawned by you: assume a sub-agent cannot spawn sub-agents, so a generator must never try to spawn its own judge. This keeps authoring parallel *and* review adversarial, and it is the mode the flow is designed around. Use it whenever you have the primitive.
- **Sequential mode**: your agent has no sub-agent primitive. Run the identical loop one component at a time, under the discipline in *Sequential mode* below, which reconstructs the generator/judge separation inside a single context. It is slower and its review is weaker, but no step is dropped: the judging pass and the prover gate both still run.

The loop, the artifacts, the barrier rule for `invariants.spec`, the round cap and the completion gate are identical in both modes; only how each pass is run differs.

### The ping-pong loop

Keep a set of **open** components (initially all of them). Each round:

1. **Generate** — run one *generator* per open component. In parallel mode, spawn them all at once and **wait for the whole batch** before continuing; in sequential mode, work through the open components one after another until each has a fresh spec. Give each generator: its component's property list, the relevant contract source, the exact import lines to copy from `sanity-<Main>.spec`, `references/cvl-writing.md` + `references/cvl-pitfalls.md`, and — on rounds after the first — its previous spec plus the judge feedback that rejected it. It runs the **Generator procedure** below and produces: the spec + `property_rules.json` it wrote, its full prover status, any structural-invariant requests, and notes.
2. **Barrier housekeeping** — if any generator asked for a new structural invariant, add it to the shared `certora/specs/invariants.spec` **yourself now**, at the barrier: after all generation for the round, before any judging (a generator never writes that file: every component imports it, so an edit inside the generation window either races a parallel generator or silently changes the file underneath a spec that was already judged), re-verify it with the Phase 5 gate, and only then proceed, so the next round of generation imports a consistent, proven file. Resolver patches are barrier work for the same reason. A generator hands them back instead of applying them, because `source.patch` reaches scene contracts and shared helpers. Apply them here, re-run the Phase 5 gate on `invariants.spec`, then re-run the full unfiltered run for every component the patched files reach, including a component its judge already accepted on the earlier source. A clean run against source that a patch has since changed is not evidence.
3. **Judge** — run one *judge* per component that a generator just produced. In parallel mode, spawn the batch and **wait for all of it**; in sequential mode, judge each component in turn under the discipline in *Sequential mode* below. Give each judge the **Judge inputs** below; each produces accept / reject + concrete feedback, written to `certora/properties/<slug>.judge-round<N>.md` in both modes, before any fix is applied.
4. **Partition** — a component *leaves* the open set only when, this round, its judge **ACCEPTED** the produced spec **and** that generator's full unfiltered prover run was clean (every rule VERIFIED or expected-to-fail). Everything else stays open, carrying its judge feedback into the next Generate. Regenerate and re-judge **only** the still-open components.
5. Repeat until the open set is empty (convergence) — or a component hits the per-component round cap (below), which closes it via the deadlock rule.

Because rounds are synchronized but the open set shrinks, a component that converges in round 1 is done while slower siblings keep ping-ponging; you only redo work for what remains open.

### Sequential mode (no sub-agents)

Without a sub-agent primitive you play both roles yourself, one component at a time. The loop, the artifacts, the round cap and the completion gate are unchanged; what has to be manufactured is the separation between authoring and reviewing.

1. Work the open components in a fixed order. For each, run the **Generator procedure** to completion (spec, `property_rules.json`, commentary, prover status) and write all of it to disk before starting the next component.
2. Judge only once every open component has been regenerated. That preserves the round boundary, and with it the rule that `certora/specs/invariants.spec` changes only at the barrier: after all generation for the round, before any judging.
3. Judge from the files, not from memory. Re-read the spec, the contract source, the property list and the recorded prover status as if someone else had written them; take the **Judge inputs** below as your entire brief; and write the verdict to `certora/properties/<slug>.judge-round<N>.md`, naming each of the 8 criteria with either a concrete finding or an explicit "no issue", **before** you apply a single fix. A verdict that is not on disk before the fix does not count, and an accept whose file does not address all 8 criteria does not close the component.
4. If your agent can start a second session against the same working tree (a fresh conversation, a separate process, a colleague's run), do the judging there. The review is only as adversarial as the context is fresh, and a genuinely new context is the closest sequential substitute for a judge sub-agent.

Phase 5 works the same way: one generation pass over `invariants.spec`, then a fresh-context judging pass with the same written-verdict rule.

Say plainly to the user that you are in sequential mode, because self-review is its weak point: the context that chose a summary is the context least likely to reject it, so expect fewer rejections than a separate judge would produce, and treat a component that closes on round 1 with suspicion. Two things keep the mode honest: the written verdict, and the prover half of the completion gate (a full unfiltered run with every rule VERIFIED or explicitly expected-to-fail), which is unaffected by execution mode. Neither may be relaxed to make sequential mode faster.

### Generator procedure (the generator role)

Consult the docs pages while authoring — particularly Methods Block/summaries, Invariants, Rules — rather than guessing syntax; `references/cvl-writing.md` maps the pages and gives the retrieval recipe for an agent with no web-fetch tool.

- Give each property its own rule(s)/invariant(s), formalized in the **"VERIFIED = good"** direction from Phase 4.
- Import the setup's summary specs — base summaries AND call resolution, copied verbatim from the sanity spec's import lines (required) — and `invariants.spec` when useful. If you find you need a structural invariant that isn't in `invariants.spec`, do NOT edit that file; record a request and hand it over. The request is applied to `invariants.spec` at the barrier, after all generation for the round and before any judging, never by the generator itself.
- Build the `property_rules` mapping (every non-skipped property title → the rule/invariant name(s) that verify it) and persist it to `certora/properties/<slug>.property_rules.json` — it gates completion and feeds the report, so it must survive a restart.
- Typecheck first: `certoraRun <conf> --compilation_steps_only` (fast ~1 min); fix all type/parse errors before anything else (the judge assumes the spec typechecks).
- Then prove: build the conf as the setup base plus the overlay defined in `references/prover-loop.md` (single source of truth for the overlay; it includes `wait_for_results: "all"`, load-bearing because the base conf ships `wait_for_results: none`). Run certoraRun (mechanics, status parsing, counterexample extraction all in that reference). For each non-verified rule, analyze the trace, classify the root cause, and apply the remediation playbook there: missing-invariant `requireInvariant`, sound summaries for havocs (never `NONDET` on side-effecting functions, never `persistent` ghosts to dodge a havoc), `filtered` blocks at ~95% certainty, expected-failure for a rule that exposes a genuine bug OR that fails only due to an exhausted prover limitation (record which), skip for genuinely-invalid properties, contradictory-`require` hunt for sanity failures.
- A rule that still ends TIMEOUT after the playbook's scope reductions can go to the hosted Timeout Resolver: one call per rule with the run link and the property, as `references/timeout-resolver.md` describes. Download its files, then stop. Do not apply a resolver patch yourself: `source.patch` reaches scene contracts and shared helpers, so a patch applied inside the generation window changes the source underneath a parallel sibling and underneath a component a judge has already accepted. Hand back the resolver result, the downloaded files and the patches you propose, the same way you hand back a structural-invariant request, and let the barrier apply them. A resolver result other than `resolved` leaves the rule a TIMEOUT: read its informal proof for the missing lemma, then continue by hand.
- Iterate write→prove yourself until the full unfiltered run is clean (all VERIFIED or expected-to-fail) or you've exhausted principled fixes. Write the per-component commentary (`certora/properties/<slug>.commentary.md`). **Hand over** the final spec, `property_rules`, the full prover status (including expected-fail markings + reasons), and any structural-invariant requests, then stop generating and let the judging pass take over; generation never reviews its own work in the same pass.

### Judge inputs (the judge role)

A fresh adversarial reviewer: a separate sub-agent in parallel mode, a fresh-context review pass in sequential mode. Give it: the spec text, the contract source for the component, the property list, the generator's prover status (so it doesn't flag intended expected-fails — criterion 6), **and both the 8-criteria Judge checklist AND the 23 CVL guidelines from `references/cvl-writing.md`** (criterion 2 checks against those guidelines; criteria 3/6/7 need the source). It produces accept / reject + concrete feedback, on disk before anyone acts on it. A generator may rebut prior feedback on its next round, but only with hard evidence (a typecheck error, a persistent counterexample, a docs citation) — a rebuttal is not a get-out-of-jail-free card.

### Per-component round cap / deadlock

If the judge keeps demanding a change that then makes the prover fail (or vice versa), a component can ping-pong forever. Cap it at ~3 gen↔judge rounds without that component converging. On hitting the cap, close it: keep the most defensible spec, and either record the offending property as skipped with the conflict documented, or mark the rule expected-to-fail with the reason. Cloud runs are expensive — an unbounded cycle is a failure mode, not diligence.

### Completion (per component)

Done means, for the spec that round produced: (a) the judge accepted it, (b) a full certoraRun with **no** `rule` filter shows every rule VERIFIED or explicitly expected-to-fail, and (c) `property_rules` is total — every property mapped, or explicitly skipped with a justification the judge accepted. Skips and expected failures are first-class outcomes, recorded with reasons — attempt every property before skipping any.

## Phase 7 — Report

Write `certora/report/report.json` and a human-readable `certora/report/report.md`:

- Per property: title, sort, description, component, the rules that formalize it, and each rule's outcome mapped to GOOD (verified) / BAD (violated) / ERROR / TIMEOUT / UNKNOWN, plus the prover run link.
- Group the properties into audit-style sections (roughly 8-25 for a real protocol; fewer is fine for small contracts) — each group one auditable claim with a short title and 1-3 sentence description; every property in exactly one group.
- List skipped properties with reasons. Split the expected-failure rules by *why* they were marked (Phase 6 recorded this): a rule marked expected-to-fail because it exposed a genuine issue is a **finding** — describe the counterexample scenario and its impact for a human security reviewer; a rule marked expected-to-fail only because of a prover limitation (spurious counterexample after exhausted reformulations) is NOT a bug — list it separately as a coverage gap so nobody chases a nonexistent vulnerability.
- Coverage summary: totals per outcome, and anything that limits confidence (sanity failures, unresolved calls left summarized as NONDET, trust assumptions introduced via bare `require`, and a setup built with `--skip-llm`, whose summaries are static-only).
- Resolver hooks: for every rule the Timeout Resolver resolved, list the hooks it added, the lemma each one assumes, the Lean file that discharges it, and the resolver run id. They are trust assumptions with a certificate, and a reviewer needs to see them next to the bare `require`s.

Finish by telling the user: counts per outcome, suspected bugs (genuine-issue findings) first, then prover-limitation gaps and skips with reasons, and links to the prover runs.
