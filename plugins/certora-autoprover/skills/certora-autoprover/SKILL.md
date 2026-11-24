---
name: certora-autoprover
description: End-to-end formal verification of a Solidity contract with the Certora Prover. Given a project (Foundry/Hardhat) and a main contract, this skill analyzes the system's components, runs certora-autosetup to build a working prover configuration and summaries, formulates security properties (invariants, safety properties, attack vectors) per component, formalizes them in CVL, and iterates certoraRun until every rule is verified, excused as a suspected bug, or skipped with justification — ending with a verification report. Use this whenever the user wants to formally verify a Solidity contract, prove properties about a contract, or generate CVL specs/rules/invariants and check them with the prover — e.g. "formally verify src/Vault.sol:Vault", "come up with properties for this contract and prove them", "write a Certora spec for X and run it". Also use it when the user asks to "audit contract X with the prover" or wants machine-checked guarantees rather than a manual review.
license: GPL-3.0-only
compatibility: >-
  Requires certoraRun (certora-cli) and certora-autosetup on PATH, a CERTORAKEY for the
  Certora cloud prover, Java 19+, network access to prover.certora.com, app.certora.com,
  data-api.certora.com and docs.certora.com, and the Solidity compilers the target project
  pins, which the skill installs with solc-select, plus forge or node to read the project's
  build plan. No Anthropic key is
  needed: autosetup runs with --skip-llm, and the variable it checks at import takes a
  placeholder. For the hosted property generator, which Phase 4 uses by default when the
  project is a pushed GitHub commit and the organization's balance covers it, and the hosted Timeout Resolver the skill can fall back
  on, the same key needs the Runs API permissions, and network access to app.certora.com.
metadata:
  version: "0.7.1"
  author: certora
---

# certora-autoprover

Formally verify a Solidity contract end-to-end: understand the system, set up the prover, decide *what* should be true, express it in CVL, and let the prover check it — iterating on failures until every claim is either proven, exposed as a real bug, or explicitly retired with a reason.

## Background: how Certora verification works

The **Certora Prover** takes compiled Solidity plus a specification written in **CVL** (Certora Verification Language) and *symbolically* checks every rule against **all possible inputs and starting states** — not test cases. A spec contains:

- **rules** — symbolic executions ending in `assert`/`satisfy` (a *parametric* rule takes a `method f` parameter and is checked once per contract method);
- **invariants** — state predicates proven *inductively*: they hold after the constructor, and assuming one holds before an arbitrary method call, it holds after;
- a **methods block** — declarations and **summaries** (replacements the prover uses for calls it cannot or should not analyze).

Two prover behaviors drive most of the work in this flow:

- **The scene.** The prover only models the contracts you give it. A call whose target/implementation isn't resolvable in the scene is a **havoc**: the prover assumes the call may arbitrarily change any state, which usually produces absurd counterexamples. Havocs are fixed by `link`ing contracts, adding them to the scene, or writing summaries.
- **Vacuity.** A rule whose preconditions contradict the code proves nothing (`assert false` would also "pass"). The prover makes basic rule sanity checks by default and flags vacuous rules as SANITY_FAILED.

A verdict of a VIOLATED rule comes with a concrete **counterexample** (a call trace). Deciding whether a counterexample means "my spec/setup is wrong" or "the contract has a bug" is the central judgment call of this entire flow — a rule that fails because it exposes a real bug is a **success**, to be reported, never hidden.

**Two prime directives:**

1. Your sole *authoritative* sources on CVL syntax and prover behavior are the official docs at https://docs.certora.com/en/latest/ and the bundled references. Do NOT assume the prover works some way because it is "intuitive" — retrieve the relevant docs page and check (`references/cvl-writing.md` has the page map and says how to retrieve a page with or without a web-fetch tool).
2. Do not reason yourself into whether a property is true — author CVL that lets the *prover* demonstrate it. Never narrow a rule because you judge a case unexploitable or harmless; formalize the full claim, let the prover rule, and grade severity in the report.

## Inputs, artifacts, resume

**Inputs**: a project root (Foundry or Hardhat), a main contract as `relative/path/File.sol:ContractName`, optionally a design document, and optionally a statement of which parties the deployment trusts (Phase 7 uses it to classify findings). Track the phases explicitly — one entry per phase in whatever task list or plan your agent keeps, marked done as you leave each phase; if it keeps none, state which phase you are entering each time you start one.

Every phase writes its result under the project's `certora/` directory, so an interrupted run resumes by reusing artifacts whose inputs haven't changed (check before redoing work, and say when you reuse):

| Artifact | Written by |
|---|---|
| `certora/analysis/application.json` | Phase 2 (component model) |
| `certora/analysis/closure.json` | Phase 3 (scene decision) |
| `certora/analysis/compilers.json` | Phase 3 (compiler selection) |
| `certora/analysis/source_edits.json` | Phase 3 (ERC-7201 annotations added to the sources) |
| `certora/confs/<Main>.conf`, `certora/specs/summaries/…`, `certora/specs/sanity-<Main>.spec` | Phase 3 (autosetup) |
| `certora/propgen/keys.json`, `certora/propgen/run.json` | Phase 1 (hosted property generation launched) |
| `certora/propgen/property_set.json`, `certora/propgen/assignment.json` | Phase 4 (hosted property set read and assigned) |
| `certora/properties/<slug>.properties.json` | Phase 4 |
| `certora/analysis/method_difficulty.json`, `certora/specs/summaries/<Main>_difficulty_summaries.spec`, `certora/specs/summary-soundness.spec` + `certora/confs/summary-soundness.conf` | Phase 5 |
| `certora/specs/invariants.spec` + `certora/confs/invariants.conf` (or one `invariants-<group>` pair per invariant unit) | Phase 6 |
| `certora/specs/<slug>.spec`, `certora/confs/<slug>.conf`, `certora/properties/<slug>.property_rules.json`, `certora/properties/<slug>.commentary.md`, `certora/properties/<slug>.judge-round<N>.md` | Phase 6 |
| `certora/report/report.json`, `certora/report/report.md` | Phase 7 |

Create the artifact directories up front so a redirect or a write never fails on a missing parent: `mkdir -p certora/analysis certora/confs certora/specs/summaries certora/properties certora/report certora/logs certora/resolver certora/lean certora/propgen` (spelled out rather than brace-expanded, so it also works when the command runs under a plain POSIX shell).

Long-running commands (autosetup, and the Phase 0-3 certoraRun calls that wait for results) take tens of minutes or more, longer than a single foreground command should hold your session. **Start them detached, then wait for them in the foreground with a bounded loop.** Starting needs nothing but a shell:

```bash
nohup <command> > certora/logs/<name>.log 2>&1 &
echo $! > certora/logs/<name>.pid
```

Then wait with a blocking call that ends after a fixed bound, and repeat that call until the process ends:

```bash
pid=$(cat certora/logs/<name>.pid)
end=$(( $(date +%s) + 90 ))       # stay under the timeout of this call, see below
while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 15; done
if kill -0 "$pid" 2>/dev/null; then echo RUNNING; else echo ENDED; fi
tail -n 5 certora/logs/<name>.log
```

The bound must stay under the timeout of the call that runs the loop. Shell tools often stop a call after 2 minutes by default, and some then move it to the background, which turns the wait into the wake-up wait forbidden below. The bound of 90 seconds fits a 2-minute timeout. To wait longer per call, pass a longer timeout on every wait call and set the bound about 2 minutes under it (Claude Code: `timeout: 600000` with a bound of 480). If you cannot set the timeout per call, keep 90.

Never block a single command on a whole run, and never re-run one just to see more output. After each call that prints `RUNNING`, **emit a short progress note** (elapsed time + the last log line) and call it again: an agent runtime may cut off a session that goes several minutes without output, so one long silent wait can lose the run even though the detached job is fine.

`ENDED` means certoraRun exited, not that the job ended: check the job on the server (`references/prover-loop.md`, *Checking a job on the server*) before you read results. The Phase 6 prover runs are submitted without waiting and waited on through the server instead (`references/prover-loop.md`, *Running*).

**Never wait through a background monitor, a watcher script, a timer, or a turn that ends in the hope that a notice wakes you.** In real runs those wake-ups did not come, and finished jobs sat unread for hours. You may start the command with your agent's own background-execution facility, but the wait is always this foreground loop. `references/prover-loop.md` (*Waiting for a run*) has the rules for sub-agents and the orchestrator, and how to read a job's state on the server.

## Phase 0 — Preflight

This skill is standalone: it needs nothing beyond the tools below. Fail fast with a specific message rather than improvising around a broken environment:

- `certoraRun` and `certora-autosetup` on PATH (`which certoraRun certora-autosetup`), built from the AutoProver commit this skill pins. If they are missing or stale, you install them as described here. There is no separate installer. `certoraRun` comes from `pip install certora-cli`; `certora-autosetup` is the CLI of the `ai-composer` package (https://github.com/Certora/AutoProver), which is not published on PyPI. One uv command brings in both. `certora-cli` arrives through the `[certora-cli]` extra, and `--with-executables-from` is what puts its commands on PATH: `uv tool install` otherwise links only the console scripts of the package you named, not those of its dependencies.

  The ref is pinned because this skill describes autosetup flags and behaviour that move with it. It is the single line in `AUTOPROVER_REF.txt`, the file beside this one; read it and substitute it for `<ref>`:

  ```bash
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
  GIT_CONFIG_VALUE_0='git@github.com:' \
  uv tool install --python 3.12 --with-executables-from certora-cli \
    'ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@<ref>'
  ```

  The `GIT_CONFIG_*` rewrite makes the build clone AutoProver's public `graphcore` submodule over HTTPS, so the install needs no GitHub SSH key.

  When the commands are on PATH, also make sure that they come from the pinned ref: `uv tool list --show-version-specifiers` names the git source of `ai-composer`, and the commit in it must be the one in `AUTOPROVER_REF.txt`. A different commit means the skill was updated after the tools were built. Then add `--reinstall` to the command above.

  Before you install or reinstall, tell the user what you will install: `ai-composer` with `certora-cli` from the AutoProver repository at that commit, and later `solc-select` and the project's compilers. Say that uv builds it and that it takes a few minutes. Ask for their go-ahead, and install only after they agree. `uv` itself must already be on PATH. If it is not, stop and point the user at https://docs.astral.sh/uv/getting-started/installation/. Never download and run an installer yourself.

  Then re-run `which certoraRun certora-autosetup`. If uv reports that the executables already exist, a separate `certora-cli` tool owns those names: `uv tool uninstall certora-cli` first, or add `--force` to let uv take them over. uv names the directory where it puts the tools, usually `~/.local/bin`. If that directory is not on PATH, use the full path for this session. Tell the user to add the directory to PATH. If the user declines or the install fails, stop and give the user the commands. Do not substitute or hand-roll a setup.
- `CERTORAKEY` set (cloud prover). No Anthropic key is required: **autosetup runs with `--skip-llm` by default in this flow**, which switches off every LLM call it would make.

  autosetup still reads `ANTHROPIC_API_KEY` while importing its summary module, and it checks only that the value is non-empty, never that it is a working key; a `.env` in the working directory is loaded instead and then nothing is checked at all. Nothing in this flow sends the value anywhere, so set the literal placeholder and move on. Do not read, copy or pass on whatever the user may already have in that variable:

  ```bash
  export ANTHROPIC_API_KEY=skip-llm-placeholder
  ```

  What the default costs: autosetup automatically applies prover-performance summaries only to a fixed curated list of complex library functions. Richer summaries that are specific to particular input protocols need a paid Anthropic key and a run without `--skip-llm`. That is the user's call and their money: tell them the option exists, and leave the key and the flag to them.
- The prover budget of this run (*Prover budget* in Phase 6). If `certora/logs/budget.json` does not exist, write it: `{"jobs": 500, "minutes": 5000, "group_id": "<a new UUID>"}` (`python3 -c 'import uuid; print(uuid.uuid4())'`), with the numbers the user gave if any. Every cloud prover job of the run carries that group id (*Prover budget* in Phase 6). On resume, keep the file as it is. Tell the user the budget.
- Java 19+ on PATH (`java -version`). autosetup shells out to the `ASTExtraction.jar` typechecker while resolving summaries and there is no fallback path, so an old or absent JDK fails mid-run rather than at startup.
- A compiler manager, and a way to read a project's build plan. `solc-select` on PATH (`uv tool install solc-select==1.2.0` when it is not, after the same go-ahead), plus `forge` when the target project has a `foundry.toml`, or `node` when it has a `hardhat.config.*`. No version is named here: which compilers a project needs is a property of that project, so Phase 3 derives it from the project's own build configuration and installs what it resolves to.

  Two machine facts that belong here rather than in Phase 3. solc-select moves its whole store into an active virtualenv, so every `solc-select` command in this flow runs under `env -u VIRTUAL_ENV`. And no directory holding a compiler may contain a space: certoraRun builds the compiler command as one string and splits it on whitespace.

- The main contract file exists, declares the named contract, and it is a concrete `contract` (not `abstract`/`interface` — the setup rejects those).
- Optional: the key in `CERTORAKEY` also carries the Runs API permissions. The hosted property generator needs `runs:create` and `runs:read` (`references/property-generation.md`), and the Timeout Resolver needs those two plus `runs:cancel` and `artifacts:read` (`references/timeout-resolver.md`). Their absence blocks nothing here: Phase 4 then drafts the properties itself, and Phase 6 uses the resolver only when a rule times out and the manual fixes are exhausted. Note what is missing, and if a timeout later calls for the resolver, ask the user for a key that has them.

## Phase 1 — Design document (optional but valuable)

If the user supplied a doc, use it. Otherwise spend a few minutes looking for one: shortlist by name/location (`docs/`, files named design/spec/architecture/whitepaper, top-level `*.md`, READMEs near the contract), then judge by content. A doc qualifies if it describes **intended behavior**: architecture/component breakdown, natural-language descriptions of inter-contract interactions, invariants ("total supply equals sum of balances"), accounting formulas, access-control rules, threat model. Build/deploy instructions, usage docs, changelogs, and generic READMEs do NOT qualify — never pass one off as a design doc. Proceeding without a doc is fine; say so and derive intent from the code.

**Then launch the hosted property generator** when the project qualifies, as `references/property-generation.md` describes: a GitHub commit that the service can read, with no uncommitted `.sol` change, and a key with the scopes it needs. Launch it without asking when the estimate says the balance covers it, and tell the user in one line. Do not wait for it: it runs while Phases 2 and 3 do, and Phase 4 reads its result. When something blocks it, tell the user what would fix it and let them fix it, unless the request said to work without asking; otherwise Phase 4 drafts the properties itself (`references/property-generation.md`, *When something blocks it*).

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
- The prover instantiates exactly **one** instance per contract declaration. If meaningful verification requires ≥2 instances of one contract, write minimal harnesses `contract XInstance1 is X {}` under `certora/harnesses/` and add them to the scene. Give every harness file an exact pragma: the version the build plan gives the code it wraps (`pragma solidity 0.8.17;`). The plan does not cover harness files, so autosetup compiles them with its default compiler and, when the pragma rejects that, moves each one to the version its pragma names; a range pragma that admits the default keeps the default. Usually not needed — skip unless the protocol's core state genuinely spans multiple instances.

Record the closure in `certora/analysis/closure.json`.

Two things in the closure need your input to autosetup, because the autosetup steps that would find them are LLM calls and `--skip-llm` turns them off:

- **Proxies.** For each closure contract that forwards calls to an implementation with `delegatecall` (UUPS, transparent, beacon, a diamond, or a custom forwarder), name the implementation contract(s) it forwards to. Pass each as `--proxy-mapping <Proxy>=<Impl>` (contract names, several implementations comma-separated, the flag repeated per proxy), and put the implementation files among the scene files. Autosetup then adds the implementations to the scene and maps them onto the proxy with `contract_extensions` before it resolves calls. Without the flag, every call through the proxy stays unresolved.
- **ERC-7201 namespaced storage.** Autosetup models a namespaced storage struct only when the struct carries a `/// @custom:storage-location erc7201:<namespace>` line. In each closure file, find structs reached through a slot computed as `keccak256(abi.encode(uint256(keccak256("<namespace>")) - 1)) & ~bytes32(uint256(0xff))`, usually a `bytes32` constant assigned to `$.slot` in assembly. For each one without the annotation, check the constant against `cast index-erc7201 <namespace>`. When they match, add `/// @custom:storage-location erc7201:<namespace>` on the line above the `struct`. When they differ, the struct is not ERC-7201: leave it. The annotation is a comment and changes no behavior. Edit nothing else in the user's sources. Record every added line, with file, struct and namespace, in `certora/analysis/source_edits.json`, and list them in the Phase 7 report.

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

Then give each one the name autosetup writes. It names a per-contract compiler in the Certora form `solc8.17`, while solc-select's store holds `solc-0.8.17`. A directory of aliases bridges the two:

```bash
bin=<project_root>/certora/solc-bin                     # a path with no space in it
mkdir -p "$bin"
ln -sf "$HOME/.solc-select/artifacts/solc-0.8.17/solc-0.8.17" "$bin/solc8.17"
export PATH="$bin:$PATH"
solc8.17 --version                                      # must report 0.8.17
```

If an alias does not run on this host, point it at another build of that version that does, and record where that binary came from (`binary_sources` in `compilers.json`, below).

One alias per installed version, named by dropping the leading `0.`: `0.8.17` becomes `solc8.17`, `0.7.6` becomes `solc7.6`. The path must hold no space, because certoraRun builds the compiler command as one string and splits it on whitespace; if the project path holds one, build the directory under `$HOME` instead, and if that holds one too, stop and say so. Export the PATH in the shell that runs autosetup and every later certoraRun. Nothing outside the run changes, and no compiler is selected globally.

Leave `--solc-default` off the autosetup command below, so autosetup writes versioned compiler names and the aliases answer to them. The conf then says which compiler compiled which contract. The flag only supplies a name for contracts nothing else pins; passing `--solc-default solc` makes every unpinned entry read `solc`, and those entries then follow whatever compiler the machine selected last.

**Several versions over the closure** is not a problem to avoid: install them all and let `compiler_map` carry them. Never put a newer compiler in place of a version the plan pinned, however wide the pragmas are, because the run would then answer for a build nobody ships. Two cases stop the run before it submits a job, and autosetup names both: a version that cannot be provisioned at all (`UnsatisfiableSolcPinError`, with the contract and its pragma), and one compilation unit whose files no single compiler satisfies (`ConflictingPragmaError`).

**Only Foundry carries a per-file compiler into the run.** Autosetup reads each contract's compiler from Foundry's build artifacts. With any other build system, it does not carry per-file assignments from the build plan: when Hardhat's `solidity.compilers[]` holds one version, autosetup seeds every contract with that version (only falling back to a contract's pragma if that compiler fails to parse it); otherwise it starts from its default name and falls back to pragma reading per contract. Either way, it ignores compiler versions set in Hardhat's `solidity.overrides`.

So before you run the autosetup command below on a project that is not built with Foundry, work out the compiler autosetup will actually use for each file you hand it and require it to equal the one the plan gives that file. That holds even when the closure needs only one compiler, including a closure holding only a single overridden file. If any file disagrees, **stop and tell the user**: name each file, the compiler the plan gives it, and the compiler the run would use. Neither `--extra-args` nor an edit to the conf afterwards repairs this: `--extra-args` only appends flags to the `certoraRun` command line — it does not update the conf autosetup writes, and passing `--compiler_map` there is rejected alongside the conf's own `solc` — while editing the conf afterwards is too late because autosetup submits real prover jobs while it works, so those jobs have already run at the wrong compiler. Two ways forward are honest. Verify a part of the system whose files all take the compiler the run would use anyway (not the same as a part that needs one compiler). Or get the per-file assignment carried into the run first.

When autosetup finishes, read the compiler names out of the conf it drove, `certora/confs/<Main>.conf`, and check each name twice: against the alias directory, and against the compiler the resolved plan gives that contract's file. Phase 6 writes `invariants.conf` and the per-property confs from that base; check their compiler names the same way when they are written.

A missing alias is the one unambiguous repair, because the name in the conf is already the plan's answer. A later `certoraRun` reporting `Solidity executable solc8.X not found in path` means that alias is absent: add it rather than retarget the conf at another compiler.

A name that disagrees with the plan is a stop, not a repair: report which contracts disagree, what the plan gives them, and what the conf says. Autosetup's own default name, `solc8.34`, is the one to read carefully, because it has two meanings and the plan separates them. Look up the contract's file in the plan's file lists (`.Solidity[].paths` for Foundry, the `compilers` entries and `overrides` keys for Hardhat). A file the plan does not cover is either one of your harnesses or a mock autosetup added. A harness must show the version its exact pragma names; any other name means its pragma is not exact, so fix the pragma and run autosetup again. A mock may keep whatever name it got. Do not install the default compiler for them: when it is absent, autosetup moves each such contract to an installed compiler its pragma admits. A file the plan does cover reached the conf with its assignment lost, and an alias would hide that, so stop and report it.

Record what you found in `certora/analysis/compilers.json`: `source` (resolved plan or pragma reading), `versions`, `closure_versions`, `alias_dir`, `aliases` as alias name to the version its binary reports, and `binary_sources` as alias name to the binary's path and where it came from, for every alias that does not point into solc-select's store. On resume, run `<alias> --version` for every entry and rebuild any alias that is missing or answers with a different version, instead of trusting the record.

Then build the prover setup with **certora-autosetup** (a tool that automates the fiddly part: compiler settings, contract linking, loop bounds, and generated summaries for hard-to-verify library functions). Full invocation, outputs, and failure modes: **`references/autosetup.md`**. In short, run this **detached** (it launches real prover jobs to resolve calls and tune bounds — tens of minutes is normal), from the project root:

```bash
cd <project_root>
nohup certora-autosetup --main-contract <rel_path>:<Main> \
  <rel_path>:<Main> <closure .sol files...> --no-strip-contracts --skip-llm \
  [--proxy-mapping <Proxy>=<Impl> ...] \
  > certora/logs/autosetup.log 2>&1 &
echo $! > certora/logs/autosetup.pid
```

Wait on it with the bounded foreground loop above (`<name>` is `autosetup`), reporting the elapsed time and the last log line after each call, until the loop prints `ENDED`. `--skip-llm` is the default here, so the summaries are static-only: carry that into the report's confidence notes in Phase 7. Drop the flag only when the user has an Anthropic key and has agreed to the LLM calls it bills for. Below, `<Main>` is the main contract's name. Its deliverables are the foundation for everything after:

- `certora/confs/<Main>.conf` — a working prover conf (files, compiler settings, `loop_iter`, hashing bounds). Note: contract *links* are NOT in the conf — they live as a CVL `links` block inside the call-resolution spec below.
- `certora/specs/summaries/<Main>_base_summaries.spec` AND `certora/specs/summaries/<Main>_call_resolution.spec` — generated summaries plus the links/DISPATCHER resolution. Every spec you write MUST import BOTH (copy the import lines verbatim from the top of `sanity-<Main>.spec`, which also cover `erc7201.spec` when present). Importing only the base summaries silently drops every link, and calls that sanity resolved will havoc in your rules.
- `certora/specs/sanity-<Main>.spec` — a parametric reachability rule proving every external method can execute end-to-end under this setup. A method failing sanity means the setup can't verify that method; investigate before writing specs.

If autosetup fails, read the log tail and fix the underlying issue (a solc version not provisioned yet, abstract main contract, stale caches — see the reference) instead of retrying blindly.

## Phase 4 — Property formulation (per main-contract component)

**When the hosted property generator was launched in Phase 1**, wait for it here and read its property set (`references/property-generation.md`, *Waiting* and *Reading the property set*). Its properties are the first round for each component: assign them to the Phase 2 components, then run one round of your own per component against the rules below. When it was not launched or ended without a property set, draft every round yourself.

For each component of the main contract, formulate **security properties** as an audit reviewer would. Each property gets a globally unique snake_case `title`, a `sort`, and a precise, concise description. Three sorts:

1. **invariant** — representational, holds always from construction. Good: "the sum of all user balances equals totalSupply". Bad: "state fields should be correct" (broad).
2. **safety_property** — a concrete statement about what must (not) be possible, *including intended normal behavior*. Good: "a user without the admin role cannot approve other admins"; "a depositor receives the appropriate amount of LP tokens". Bad: "users can't hack the protocol".
3. **attack_vector** — a *plausible* exploit hypothesis; no evidence of an actual bug required, only plausibility. Good: "a rounding discrepancy between swap and previewSwap could create arbitrage". Bad: "there could be a rounding error and that would be bad somehow".

A safety_property can also state that something must be **possible**. "A holder with a sufficient balance can always exit" and "no participant can make another participant's withdrawal revert" are safety properties. They are worth stating because every property of the form "if the call succeeds, the effects are correct" says nothing about a call that never succeeds.

**Work `references/property-classes.md` before you draft.** It holds the questions to ask of any component: who absorbs a change in value over time, what going first is worth, which way each division rounds, what must not be blocked and who can block it, who the attacker is allowed to be, and the rest. Naming a failure mode is not the same as asking a question. That is why a component ends up with twenty properties about one surface and none about the other. For each class, record the property it produced, or one line on why this component does not expose that surface. The record goes in the round's reasoning, and Phase 7 reads it for the coverage section.

Hard rules: derive from first principles — what the code SHOULD do, not what it currently does. Quality over quantity: no padding, no reframed duplicates, no trivial corollaries, no properties whose violation has no consequence. Exclude what the prover can't or shouldn't check: off-chain events (key compromise, phishing), hash collisions that cost an attacker 2^128 hashes or more (a full `keccak256`, for example; `references/hash-collisions.md` says which collisions are cheaper and must be checked), event emission, and anything already guaranteed by the type system (overflow reverts in Solidity ≥0.8 are uninteresting).

**Formalization direction is the same for all three sorts, and it is load-bearing:** every rule/invariant must be written so that VERIFIED means "the good thing holds / the bad thing cannot happen." An attack_vector is formalized as *the attack cannot occur*, not as *the attack occurs* — so a green result testifies to the **absence** of the problem, never its presence. If you catch yourself writing a rule that passes exactly when the exploit succeeds, invert it. (This is what makes a VIOLATED result meaningful in Phase 7 — see the expected-failure handling in `references/prover-loop.md`.)

Run up to **3 rounds** per component: after drafting a round, review it against the rules above, then do another pass asking "what did I miss?" — treating the earlier rounds' reasoning as the record of what was considered. **A round that adds nothing is the stop signal** — an empty round is the right answer for a well-covered component. Write the result to `certora/properties/<component-slug>.properties.json` (`[{title, sort, description}]`), where `<component-slug>` is the component name lowercased with every run of non-alphanumeric characters replaced by a single `-` (e.g. "ERC20 interface" → `erc20-interface`); the structural-invariants batch uses the reserved slug `invariants`.

Additionally formulate **structural invariants** for the main contract as their own batch (slug `invariants`): "sane state" facts that rule out infeasible starting states (e.g. a balance exceeding totalSupply) and thus kill spurious counterexamples later. They must be **inductive** — hold at construction and be preserved by every method; never "after calling F, P holds". Indicators: obvious to an informed reader, structural rather than mathematical, likely load-bearing for other properties.

## Phase 5 — Method difficulty and targeted summaries

Autosetup already ran every external method through the prover, and Phase 4 now knows which methods the properties are about. Before writing any rule, use both to find the methods that will be expensive in Phase 6 and make them cheaper, while you still have the full picture. This phase must not block the run: give it at most **30 minutes** of wall-clock time, then move on with what it has, and say what it did not finish.

1. **Difficulty.** Read how each method did in autosetup's sanity runs: its status and how long its instance of the `sanity` rule took (the run links are in `certora/logs/autosetup.log`; reading a run: `references/prover-loop.md`). If those runs do not give a time per method, run the sanity conf once more, detached, with a bound: `certoraRun certora/confs/<Main>.conf --global_timeout 600 --wait_for_results all --msg "difficulty: sanity"`. A method is **hard** when its sanity instance timed out, or took more than about 20-30 seconds.
2. **Importance.** For each method, count what Phase 4 hangs on it: the properties whose description or entry points name it, the invariants it writes, and the attack vectors aimed at it. A method many properties depend on is important, because a timeout there costs every one of them.
3. **Rank** the methods on both axes and record the table in `certora/analysis/method_difficulty.json`: method signature, sanity status, time, the properties and invariants that involve it, and whether it is selected. Select every hard method, and work them in order of importance, most important first.
4. **Find what makes each selected method hard.** Read it and the internal code it calls for the usual causes: non-linear arithmetic (`mulDiv`, exponentiation, square roots, fixed-point math), bitvector operations (shifts, masks, inline assembly), unbounded loops, and hashing. Name the function that does the expensive work. The method itself is never summarized: properties are about it.

   Summarize only functions that change no state: `pure` functions, and `view` functions. Never summarize a function that writes storage, transfers value or calls out to change state; a summary of one hides the very effects the properties check. A `view` function reads state, so its summary must depend on that state: pass the storage it reads into the summary (as arguments, or through ghosts that mirror it), never treat it as a function of its arguments alone. A summary that drops the state it reads lets the prover pick results the real code can never return.
5. **Summarize that function, soundly.** Write a summary for it in `certora/specs/summaries/<Main>_difficulty_summaries.spec`: an exact CVL version over `mathint` that the prover reasons about more easily, or an uninterpreted function with only the facts the properties need (bounds, monotonicity, rounding direction). For each summary, write a rule in `certora/specs/summary-soundness.spec` that shows the real code satisfies it: the real function, called through a harness when it is internal, gives the result the summary gives, or has each fact the summary assumes. Its conf `certora/confs/summary-soundness.conf` is the setup base without the new summaries. Consult the docs pages for summaries and ghost functions rather than guessing (`references/cvl-writing.md`).
6. **Check that the summaries help.** Typecheck, then run sanity on each selected method on its own, with the summaries imported, all detached and in parallel, each bounded by `--global_timeout 600`, in the run's group (*Prover budget* in Phase 6): `certoraRun <conf> --group_id <group_id> --rule sanity --method '<signature>' --global_timeout 600 --wait_for_results all --msg "difficulty: <method>"`. Keep a summary only if the method's sanity instance now passes faster than before. Record the before and after times in `method_difficulty.json`.

Do not wait in this phase for the soundness rules to be proven: they can take long, and that is Phase 6's work. They go into Phase 6 as one more unit, `summary-soundness`, generated, judged and gated like the others. A spec that imports `<Main>_difficulty_summaries.spec` relies on those summaries the way it relies on an invariant: it closes only when their soundness rules are VERIFIED.

When the 30 minutes run out, keep the summaries whose per-method check already passed, drop the rest, and record which methods were not handled. Phase 6 still has its own playbook for a slow rule (`references/prover-loop.md`, *Keep each run under about 30 minutes*).

## Phase 6 — CVL generation + prover loop (invariants and properties in parallel)

Each component gets one spec `certora/specs/<slug>.spec` + conf `certora/confs/<slug>.conf` covering all its properties. The structural invariants are formalized in the same loop: by default they form one more work unit, `invariants`, with `certora/specs/invariants.spec` and `certora/confs/invariants.conf`. A large batch (more than about 8 invariants) may be split into several invariant units, each owning its own file `certora/specs/invariants-<group>.spec` with conf `certora/confs/invariants-<group>.conf`; a component spec then imports the files whose invariants it uses. Phase 5's soundness rules, when it wrote any, are one more unit, `summary-soundness`, with `certora/specs/summary-soundness.spec` and its conf. Below, "unit" means a component, an invariant unit, or that unit. Not all invariants are required to prove all properties, so no need to sequence the properties after the invariants.

You are the **orchestrator**: generation and judging are separate passes, and a spec is never judged inside the pass that wrote it.

How you execute those roles depends on what your agent can do:

- **Parallel mode**: your agent can spawn sub-agents that run with their own context and hand a result back. Each round runs one generator sub-agent per open unit, invariant units and components alike, then one judge sub-agent per unit generated. Assume a sub-agent cannot spawn sub-agents, so a generator must never try to spawn its own judge. This keeps authoring parallel *and* review adversarial, and it is the mode the flow is designed around. Use it whenever you have the primitive.
- **Sequential mode**: your agent has no sub-agent primitive. Run the identical loop one unit at a time, under the discipline in *Sequential mode* below, which reconstructs the generator/judge separation inside a single context. It is slower and its review is weaker, but no step is dropped: the judging pass and the prover gate both still run.

The loop, the artifacts, the ownership rule for invariant files, the round cap and the completion gate are identical in both modes; only how each pass is run differs.

**Cloud jobs in parallel mode.** A sub-agent that has submitted a prover job or a Timeout Resolver run never ends its turn while that job runs. For a prover job it waits in the foreground loop of `references/prover-loop.md` (*Waiting for a run*) until every part's job has ended on the server. For a resolver run it waits in the foreground loop of `references/runs-api.md` (*Waiting*) until the run reaches `succeeded`, `failed` or `cancelled`. Then it reads the result. You, the orchestrator, never report a sub-agent as idle or still waiting on the strength of its silence. Check the state of its job on the server first: *Checking a job on the server* in `references/prover-loop.md` for a prover job, `GET <base>/v2/runs/<run_id>` for a resolver run. If the job has ended, resume the sub-agent and tell it which job ended.

### Invariant files: one owner each

Every component imports invariant files, so each file has exactly one writer: the generator of its invariant unit. A component generator never edits an invariant file. An invariant generator edits a working copy, typechecks it with its conf, and only then writes it over the shared file, so a sibling that imports the file never sees a version that does not parse.

A component may `import` an invariant file and `requireInvariant` any invariant declared in it **before that invariant is fully proven**. This should be done if the analysis of the counterexample shows that the initial state would be infeasible if the invariant were to hold. Add the matching `requireInvariant` naming the invariant, re-run, and see whether the counterexample goes away. A verdict that relies on an unproven invariant is conditional. The completion gate below turns it into a real one, or reopens the component.

When a rule fails on an impossible starting state, the generator first looks for the invariant among the ones already inferred: `certora/properties/invariants.properties.json` and the invariant files as they stand. If one fits, it uses it. If none does, it hands back a request for a new structural invariant, with the statement it needs and the counterexample that shows why. You forward the request to the owning invariant unit (or start a new one), which adds it to its list on its next generation. The requesting component keeps working meanwhile: it may record the dependency and continue with its other rules.

### The ping-pong loop

Keep a set of **open** units: every component and every invariant unit, from the first round. Each round:

1. **Generate** — run one *generator* per open unit. In parallel mode, spawn them all at once and wait for the batch before judging; in sequential mode, work through the open units one after another until each has a fresh spec. Give each generator: its unit's property list verbatim (each title, sort and description exactly as in `<slug>.properties.json`), the relevant contract source, the exact import lines to copy from `sanity-<Main>.spec`, the paths of the invariant files and of `certora/properties/invariants.properties.json`, `references/cvl-writing.md` + `references/cvl-pitfalls.md`, and — on rounds after the first — its previous spec plus the judge feedback that rejected it, and the invariant requests forwarded to it. It runs the **Generator procedure** below and produces: the spec + `property_rules.json` it wrote, its full prover status, the invariants it relies on (by file and name), any requests for new structural invariants, and notes. Never restate or narrow a property in the brief; any modelling advice of your own is labelled as advice, and the property's own text decides what must be formalized.
2. **Barrier housekeeping** — resolver patches are applied here, after all generation for the round and before any judging. A generator hands them back instead of applying them, because `source.patch` reaches scene contracts and shared helpers, and a patch applied inside the generation window changes the source underneath a parallel sibling. Apply them, then re-run the full run (every part) for every unit the patched files reach, invariant units included, and for every unit a judge already accepted on the earlier source. A clean run against source that a patch has since changed is not evidence. Forward the new invariant requests to their owners for the next round.
3. **Judge** — run one *judge* per unit that a generator just produced. In parallel mode, spawn the batch and wait for all of it; in sequential mode, judge each unit in turn under the discipline in *Sequential mode* below. Give each judge the **Judge inputs** below; each produces accept / reject + concrete feedback, written to `certora/properties/<slug>.judge-round<N>.md` in both modes, before any fix is applied.
4. **Partition** — a unit *leaves* the open set only when it meets the completion gate below this round. Everything else stays open, carrying its judge feedback into the next Generate. Regenerate and re-judge **only** the still-open units. A unit the barrier re-ran is partitioned on that re-run, never on the run its generator filed. A re-run that is not clean **reopens** the unit: replace its recorded prover status with the re-run, carry the patch that broke it as the feedback, and put it back in the open set before you partition. The report reads the replaced status, so a stale clean run never reaches it.
5. Repeat until the open set is empty (convergence) — or a unit hits the per-unit round cap (below), which closes it via the deadlock rule.

A unit that converges early is done while slower siblings keep ping-ponging; you only redo work for what remains open. Three things reopen a closed component: a barrier patch whose re-run it fails, a change to an invariant file it imports after its clean run, and an invariant it requires that ends up not VERIFIED (skipped, expected-to-fail, or closed by the round cap). In the last case, its rules that relied on that invariant lose the precondition: rewrite them without it, or mark them with the reason.

### Sequential mode (no sub-agents)

Without a sub-agent primitive you play both roles yourself, one unit at a time. The loop, the artifacts, the round cap and the completion gate are unchanged; what has to be manufactured is the separation between authoring and reviewing.

1. Work the open units in a fixed order, invariant units first in each round so a component's run sees their latest proven state. For each, run the **Generator procedure** to completion (spec, `property_rules.json`, commentary, prover status) and write all of it to disk before starting the next unit.
2. Judge only once every open unit has been regenerated. That preserves the round boundary, and with it the rule that resolver patches change the source only at the barrier: after all generation for the round, before any judging.
3. Judge from the files, not from memory. Re-read the spec, the contract source, the property list and the recorded prover status as if someone else had written them; take the **Judge inputs** below as your entire brief; and write the verdict to `certora/properties/<slug>.judge-round<N>.md`, naming each of the 8 criteria with either a concrete finding or an explicit "no issue", **before** you apply a single fix. A verdict that is not on disk before the fix does not count, and an accept whose file does not address all 8 criteria does not close the unit.
4. If your agent can start a second session against the same working tree (a fresh conversation, a separate process, a colleague's run), do the judging there. The review is only as adversarial as the context is fresh, and a genuinely new context is the closest sequential substitute for a judge sub-agent.

Say plainly to the user that you are in sequential mode, because self-review is its weak point: the context that chose a summary is the context least likely to reject it, so expect fewer rejections than a separate judge would produce, and treat a unit that closes on round 1 with suspicion. Two things keep the mode honest: the written verdict, and the prover half of the completion gate (a full run, every part, with every rule VERIFIED or explicitly expected-to-fail), which is unaffected by execution mode. Neither may be relaxed to make sequential mode faster.

### Generator procedure (the generator role)

Consult the docs pages while authoring — particularly Methods Block/summaries, Invariants, Rules — rather than guessing syntax; `references/cvl-writing.md` maps the pages and gives the retrieval recipe for an agent with no web-fetch tool.

- Give each property its own rule(s)/invariant(s), formalized in the **"VERIFIED = good"** direction from Phase 4.
- Write the strict property. A rule that permits a loss, a rounding error or any other tolerance must name the source of its bound: the design document, a comment in the code, or the property itself. With no such source, write the strict rule, and if you want to record the tolerance, put it in a separate rule. The judge rejects an unsourced tolerance (criterion 8).
- Import the setup's summary specs — base summaries AND call resolution, copied verbatim from the sanity spec's import lines (required) — `<Main>_difficulty_summaries.spec` from Phase 5 when it exists and your rules touch a method it covers, and the invariant files whose invariants you use. In a component, never edit an invariant file: `requireInvariant` what is there, proven or not, and request what is missing (*Invariant files: one owner each*). In an invariant unit, you own your file: edit a working copy and write it over the shared file only after it typechecks.
- Build the `property_rules` mapping (every non-skipped property title → the rule/invariant name(s) that verify it) and persist it to `certora/properties/<slug>.property_rules.json` — it gates completion and feeds the report, so it must survive a restart. Record there too which invariants, by file and name, your rules `requireInvariant`.
- Typecheck first: `certoraRun <conf> --compilation_steps_only` (fast ~1 min); fix all type/parse errors before anything else (the judge assumes the spec typechecks).
- Then prove: start each run detached and wait for it in the foreground loop, never with a background monitor. Split every spec into at most 5 parts of at most 20 rules and invariants each (at most 8 parametric), one prover job each, with all slow rules sharing one part rather than a part each, submitted one after another without waiting (`wait_for_results: none`) and waited on through the server; every job runs with `global_timeout` 1800 (30 minutes), raised only for a single rule after every scope reduction failed; never `-splitParallel` in a part with a parametric rule or an invariant. Aim for every full run to finish in about 30 minutes. When one runs longer, summarize the expensive internals the property does not depend on and split slow rules before the next full run (`references/prover-loop.md`, *Keep each run under about 30 minutes*). Build the conf as the setup base plus the overlay defined in `references/prover-loop.md` (single source of truth for the overlay; it sets `wait_for_results: "none"` and `global_timeout`, and the waiting is done on the server, never by a certoraRun process held open per job). Run certoraRun (mechanics, status parsing, counterexample extraction all in that reference). For each non-verified rule, analyze the trace, classify the root cause, and apply the remediation playbook there: missing-invariant `requireInvariant`, sound summaries for havocs (never `NONDET` on side-effecting functions, never `persistent` ghosts to dodge a havoc), `filtered` blocks at ~95% certainty, expected-failure for a rule that exposes a genuine bug OR that fails only due to an exhausted prover limitation (record which), skip for genuinely-invalid properties, contradictory-`require` hunt for sanity failures.
- A rule that still ends TIMEOUT after the playbook's scope reductions can go to the hosted Timeout Resolver: one call per rule with the run link and the property, as `references/timeout-resolver.md` describes. Download its files, then stop. Do not apply a resolver patch yourself: `source.patch` reaches scene contracts and shared helpers, so a patch applied inside the generation window changes the source underneath a parallel sibling and underneath a unit a judge has already accepted. Hand back the resolver result, the downloaded files and the patches you propose, the same way you hand back an invariant request, and let the barrier apply them. A resolver result other than `resolved` leaves the rule a TIMEOUT: read its informal proof for the missing lemma, then continue by hand.
- Iterate write→prove yourself until the full run (every part) is clean (all VERIFIED or expected-to-fail) or you've exhausted principled fixes. **A generator submits at most 8 prover runs per round.** A full run (every part) counts as 1, and so does a run of a few rules with a `rule` filter. Typechecks (`--compilation_steps_only`) and Timeout Resolver calls do not count. Make the 8th run the final full run. A rule that still fails or times out after 2 principled fixes is closed instead of iterated further: expected-to-fail as a finding when the counterexample shows a code issue, otherwise expected-to-fail as a prover limitation, or skipped, with the reason. Rounds 2 and 3 get 8 runs each. Write the per-unit commentary (`certora/properties/<slug>.commentary.md`). **Hand over** the final spec, `property_rules`, the full prover status (including expected-fail markings + reasons), the invariants your rules rely on, and any invariant requests, then stop generating and let the judging pass take over; generation never reviews its own work in the same pass.

### Judge inputs (the judge role)

A fresh adversarial reviewer: a separate sub-agent in parallel mode, a fresh-context review pass in sequential mode. Give it: the spec text, the contract source for the unit, the property list from `<slug>.properties.json` (never the generator's brief), the paths of the other units' specs (criterion 8 checks any part of a property left to another unit), the design document when there is one (criterion 8 checks the source of every tolerance against it), the generator's prover status (so it doesn't flag intended expected-fails — criterion 6), the invariants the spec relies on and whether each is proven yet, **and both the 8-criteria Judge checklist AND the 26 CVL guidelines from `references/cvl-writing.md`** (criterion 2 checks against those guidelines; criteria 3/6/7 need the source). It produces accept / reject + concrete feedback, on disk before anyone acts on it. A generator may rebut prior feedback on its next round, but only with hard evidence (a typecheck error, a persistent counterexample, a docs citation) — a rebuttal is not a get-out-of-jail-free card.

### Per-unit round cap / deadlock

If the judge keeps demanding a change that then makes the prover fail (or vice versa), a unit can ping-pong forever. Cap it at ~3 gen↔judge rounds without that unit converging. On hitting the cap, close it: keep the most defensible spec, and either record the offending property as skipped with the conflict documented, or mark the rule expected-to-fail with the reason. Cloud runs are expensive — an unbounded cycle is a failure mode, not diligence. A unit the barrier or an invariant change reopened starts a fresh count, because its earlier rounds did converge. If it reaches the cap again, close it the same way, and say in the report what reopened it.

### Prover budget

A skill run has a fixed prover budget: by default **500 prover jobs and 5000 prover minutes**, set in Phase 0 and stored in `certora/logs/budget.json`. Minutes are what the run costs: each job's runtime on the server, rounded up to whole minutes. Nothing stops a submission past the budget except you: never submit a job that does not fit what is left, and spread the budget so that every unit gets a fair share and no single hard property drains it.

Only cloud prover jobs count; a local run costs nothing. Every cloud `certoraRun` of the run passes `--group_id <group_id>`, the id in `budget.json`: autosetup's jobs (through `--extra-args`, `references/autosetup.md`), Phase 5's sanity runs, re-runs of the sanity spec, and every part of Phase 6. A typecheck (`--compilation_steps_only`) submits no job. The server lists the group's jobs with their runtimes, and this prints what is used, what is left, and the use per unit, taken from the first word of each job's `msg` (the parts' `msg` starts with the unit's slug):

```bash
"$(uv tool dir)"/ai-composer/bin/prover-cli --budget --budget-file certora/logs/budget.json
```

A job that has not finished counts as 30 minutes, the job cap, or its time so far if that is longer. With `--more-jobs <K>` it also says whether `K` more jobs fit, at one job and 30 minutes each, and exits with code 3 when they do not. A job submitted moments ago may not be listed yet; the next count includes it.

Run it at these points and write the numbers, with what you decided from them, into `certora/logs/budget.md`:

1. **After Phase 3** (setup and sanity) and **after Phase 5** (method difficulty). These phases cost roughly the same on every run; if they took more than a quarter of the budget, say so to the user before Phase 6.
2. **Before each round's Generate.** Split what is left among the open units, keeping back a tenth for the barrier:
   - **Round 1:** spend at most half of what is left, so rounds 2 and 3 still have room.
   - **Later rounds:** spend what is left, less the barrier's tenth.
   - **Weighting:** weight each unit by its open properties or invariants, and by their rank when the input lists carry one. Give no unit less than one full run of its spec.
   - **The brief:** put each unit's allowance, in jobs and minutes, into its generator's brief.
3. **At the barrier, before judging.** Compare each unit's use with its allowance and say which overran and why. Then estimate the next round from this round's spend per unit.
   - **If it does not fit,** regenerate only the units where it buys the most: rejected for a fixable reason, or with high-ranked properties still unresolved.
   - **Close the others now** on their latest full run, under the deadlock rule.
4. **Before Phase 7.** Write the final use per unit and in total. The report states it.

The generator works inside its allowance:
- **Check every submission.** Before each one, run the count above with `--more-jobs <K>`, `<K>` the number of parts. Submit only if it fits, and if your unit's allowance covers the parts at one job and 30 minutes each. Keep enough of the allowance for the final full run.
- **Spend cheaply.**
  - Use the fewest parts that fit the limits.
  - Iterate with one rule-filtered job that holds only the rules that failed or changed.
  - Submit at most two full runs per round.
- **No single property drains the budget.** A property may use at most a quarter of its unit's allowance. A rule that has timed out twice is closed: expected-to-fail as a prover limitation, with what was tried. It is not tried a third time. A hard property is recorded and left; it is not chased.
- **When the allowance or the budget runs out,** stop submitting. Hand over the latest results, with every rule that has no verdict listed as not proven because of the budget, never as verified.

When what is left of the run no longer covers one more job, nobody submits again. Read the jobs still in flight, close every open unit on its latest full run, and write the report. A Timeout Resolver call runs prover jobs outside the group, which this count cannot see: make at most 3 per run, and record each in `certora/logs/budget.md`.

### Completion (per unit)

Done means, for the spec that round produced: (a) the judge accepted it, (b) a full run (every part, from the same spec) shows every rule VERIFIED or explicitly expected-to-fail, (c) `property_rules` is total — every property mapped, or explicitly skipped with a justification the judge accepted, (d) for a component, every invariant its rules `requireInvariant` is VERIFIED in its owning unit's accepted, clean run, and the component's clean run in (b) used that same version of the invariant file. If the file changed after that run, re-run the component before it closes. And (e) when the spec imports `<Main>_difficulty_summaries.spec`, the `summary-soundness` unit has closed with every soundness rule VERIFIED. A soundness rule that ends otherwise reopens every component that imports the summaries: drop the summary it covers and re-run. Skips and expected failures are first-class outcomes, recorded with reasons — attempt every property before skipping any.

## Phase 7 — Report

Write `certora/report/report.json` and a human-readable `certora/report/report.md`:

- Per property: title, sort, description, component, the rules that formalize it, and each rule's outcome mapped to GOOD (verified) / BAD (violated) / ERROR / TIMEOUT / UNKNOWN, plus the prover run link.
- Group the properties into audit-style sections (roughly 8-25 for a real protocol; fewer is fine for small contracts) — each group one auditable claim with a short title and 1-3 sentence description; every property in exactly one group.
- List skipped properties with reasons. Split the expected-failure rules by *why* they were marked (Phase 6 recorded this): a rule marked expected-to-fail because it exposed a genuine issue is a **finding** — describe the counterexample scenario and its impact for a human security reviewer; a rule marked expected-to-fail only because of a prover limitation (spurious counterexample after exhausted reformulations) is NOT a bug — list it separately as a coverage gap so nobody chases a nonexistent vulnerability.
- Classify every finding by the trust it needs. A finding that needs a trusted party to misbehave is a hardening note, not a vulnerability, and listing it as one buries the findings that matter. The rule was written without trusting anyone (prime directive 2); this step is where trust is applied.
  - **Trusted parties.** Use the user's statement if one was given. Otherwise: every holder of a role or privilege the source grants (owner, admin, any role, manager, guardian, a privileged bridge sender), the deployer and initializer, and every external contract that a trusted party configures or that is fixed at deployment (vault, oracle, bridge, token). A trusted contract is assumed to follow its interface standard and behave honestly; the setup's mocks are deliberately freer than that.
  - **Decide from the counterexample and the source, not the finding's title.** Take the recorded actors (Phase 6 commentary). For each step, read the access control that gated it. For each external contract, compare what it did with what a standard, honest implementation does. Then pick one class:
    - `unprivileged`: an account with no role triggers it, every trusted party behaves honestly and within the ranges its setters accept, and the harm falls on someone other than the actor.
    - `trusted_party`: it needs a trusted party to act maliciously, to set a harmful value, to deploy or initialise non-atomically, or a trusted contract to deviate from its standard or from honest behaviour. Name the party and what it must do.
    - `self_harm`: only the acting account loses, for example a wrong receiver or tokens sent to the contract itself.
  - When some variants of the finding need trust and others do not, split it, or take the class of the weakest precondition that still produces the harm and say so.
  - Grade severity under the trust assumption: a `trusted_party` finding is informational unless the user said that party is untrusted. State what the severity would be without that trust in one clause. Grade a `self_harm` finding by how plausible the mistake is and what it costs. It is informational when it takes an unusual input that no normal use of the interface leads to, such as sending tokens to the contract's own address. It is graded higher when an ordinary call through the documented interface, or a common integration pattern, silently loses a material share of the caller's funds.
  - In `report.json`, give each finding `trust_class` and `trusted_preconditions` (a list of `<party>: <what it must do>`, empty for `unprivileged`). In `report.md`, list `unprivileged` findings first, then a section "Findings that need a trusted party", then `self_harm`.
- Coverage summary: totals per outcome, and anything that limits confidence (sanity failures, unresolved calls left summarized as NONDET, trust assumptions introduced via bare `require`, and a setup built with `--skip-llm`, whose summaries are static-only). Name the property classes from `references/property-classes.md` that produced no property for any component, with the one-line reason Phase 4 recorded for each. A reader needs to know which questions were asked and came back empty, and which were never asked. List every line added to the user's sources, from `certora/analysis/source_edits.json`, and the lines autosetup added to `.gitignore` and `.gitattributes` (see `git diff`).
- Method difficulty: the ranking from `certora/analysis/method_difficulty.json`, each summary Phase 5 added with the function it replaces, the sanity time before and after, and the status of its soundness rule. A summary is a trust assumption until its soundness rule is VERIFIED, so a reviewer needs to see both.
- Property sources: when the hosted property generator ran, say which properties it produced and which the local round added, the properties it produced that Phase 4 dropped with the reason for each, its run id, and the amount it charged (`run.billing.charged_usd`). When it did not run, say why in one line.
- Resolver hooks: for every rule the Timeout Resolver resolved, list the hooks it added, the lemma each one assumes, the Lean file that discharges it, and the resolver run id. They are trust assumptions with a certificate, and a reviewer needs to see them next to the bare `require`s.

Finish by telling the user: counts per outcome, suspected bugs (genuine-issue findings) first, `unprivileged` before `trusted_party` and `self_harm`, then prover-limitation gaps and skips with reasons, and links to the prover runs.
