# AutoSetup: invocation, outputs, failure modes

AutoSetup turns "a Foundry/Hardhat project + a main contract" into "a prover setup that works": a conf with the right compiler settings/bounds, generated CVL summaries for hard-to-verify library functions, contract links resolved into a call-resolution spec, and a sanity spec proving every external method is reachable under that setup. Run it once per project+contract before writing any spec.

## Availability

`certora-autosetup` (alias `autosetup`) must be installed and on PATH. It is NOT part of `pip install certora-cli`: it is the CLI of the `ai-composer` package (https://github.com/Certora/AutoProver), which is not published on PyPI. The install command, with the pin it needs, lives in **SKILL.md Phase 0** and only there, so there is one copy of it to keep right.

Two things about that install are worth knowing here. autosetup shells out to `certoraRun`, so certora-cli has to be on the same PATH, which is what `--with-executables-from certora-cli` arranges: `uv tool install` links the console scripts of the package it was given, not those of its dependencies. And exactly one of the `certora-cli`, `certora-cli-beta` and `certora-cli-beta-mirror` extras may be chosen: they are declared mutually exclusive and all ship the same `certora_cli` module.

Requires `ANTHROPIC_API_KEY` to be set to something in the environment (or a `.env` in the working directory), and the check fires at import time regardless of flags, so even `--skip-llm` runs need it set. What it tests is that the value is non-empty, never that it authenticates (`certora_autosetup/setup/setup_summaries.py:70-93`); with a `.env` present the file is loaded and the value is not tested at all. In this flow the value is a literal placeholder and goes nowhere. `CERTORAKEY` is needed for the cloud prover jobs it submits.

## Invocation

From the target project root:

```bash
nohup certora-autosetup \
  --main-contract src/Vault.sol:Vault \
  src/Vault.sol:Vault src/Escrow.sol:Escrow ... --no-strip-contracts \
  > certora/logs/autosetup.log 2>&1 &
echo $! > certora/logs/autosetup.pid
# follow with: tail -n 20 certora/logs/autosetup.log
```

- Positional args: the scene — the main contract plus the transitive-closure contracts from your scene analysis (`--no-strip-contracts` keeps them all). With NO positional files it auto-detects *every* contract in the project — usually too much; pass the closure explicitly.
- Useful flags: `--use-local-runner` (local prover instead of cloud), `--skip-llm` (the default in this flow: it turns off every LLM call, and the `ANTHROPIC_API_KEY`/`.env` variable must still hold something non-empty, though nothing reads the value, so the placeholder is what this flow sets), `--skip-warmup` (skip the cache-priming job; saves time), `--build-system {auto,foundry,hardhat}`, `--solc-default <name>` (the compiler name for contracts nothing else pins, `solc8.34` by default; this flow does not pass it, see SKILL.md Phase 3), `--dummy-erc20 N`, `--extra-args "<quoted certoraRun args>"`, `--clear-cache`.
- Expect several prover jobs and LLM calls: compilation analysis → summary generation → call resolution loop (links + DISPATCHER summaries, ≤10 prover rounds) → loop_iter/hashing-bound tuning via parallel sanity jobs → warmup. Tens of minutes on a real protocol is normal.

## Outputs (what you use downstream)

| Path | What / why |
|---|---|
| `certora/confs/<Main>.conf` | The base prover conf: `files`, compiler maps, `loop_iter`, `optimistic_hashing` + `hashing_length_bound`, packages, `wait_for_results: none`. Your per-spec confs are this + an overlay. (Contract links are NOT here — they live in the call-resolution spec below.) |
| `certora/specs/summaries/<Main>_base_summaries.spec` | Aggregator importing all generated per-contract summaries. |
| `certora/specs/summaries/<Main>_call_resolution.spec` | The `links` block + DISPATCHER summaries produced by call resolution. Imported by the *sanity spec only* — NOT pulled in by the base-summaries aggregator. **Every spec you write must import BOTH this and the base summaries** (mirror the sanity spec's import lines, including `erc7201.spec` when present) or your rules lose every link and havoc on calls that sanity had resolved. |
| `certora/specs/sanity-<Main>.spec` | `rule sanity { env e; calldataarg args; method certoraF; certoraF(e, args); satisfy true, "sanity check failed"; }` — parametric reachability over every external method (the method variable is deliberately not named `f`; real projects have symbols named `f`). Sanity green = the setup (links, summaries, bounds) lets each method execute end-to-end. |
| `certora/mocks/DummyERC20Impl.sol`, `certora/harnesses/*.sol` | Token mocks / indexed-storage harnesses added to the scene. |
| `.certora_internal/autosetup_result.json` | Machine-readable result: conf path, summaries path, and build config/metadata (paths only — the sanity *analysis* is not serialized here; read the log tail for how sanity went). |
| `.certora_internal/all_user_defined_types.json`, `all_methods.json` | Type/method inventories — handy when writing methods blocks. |

Machine-readable alternative: add `--composer-setup out.json` — it writes `{"contract_to_summary": {...}, "contract_to_config": {...}}` for programmatic consumption (note: it also skips warmup and ignores any cached result, though it still writes a fresh cache entry).

## Verify before proceeding

1. Exit code 0 and `certora/confs/<Main>.conf` exists.
2. Skim the log tail for the sanity summary; a method failing sanity means specs touching it will misbehave (rules on it come back vacuous or erroring). Investigate — usually an unresolved call or too-low bounds — before writing CVL.
3. `certoraRun certora/confs/<Main>.conf --wait_for_results all` re-runs the sanity spec any time you want to re-validate the setup (the base conf sets `wait_for_results: none`, so without the override it submits and returns immediately with no verdicts).

## Failure modes

- **Main contract is abstract/interface** → explicit error; point at a concrete contract.
- **Unset or empty ANTHROPIC_API_KEY with no .env** → immediate exit while importing, before any work. The check runs regardless of flags, so provide the variable either way. Since only non-emptiness is tested, the placeholder together with `--skip-llm` gives a run with static-only summaries: a real quality loss on hard-to-verify library functions, which is the trade this flow makes by default. Say so, and leave a paid run to the user.
- **Compilation failures** → it auto-tries per-contract compiler maps and an import-patching retry; if it still fails, read the solc errors in the log — usually a compiler that has not been provisioned yet, or a remapping problem. Two messages are terminal and say exactly what is wrong: `UnsatisfiableSolcPinError` names a contract whose pragma no installed compiler satisfies, and `ConflictingPragmaError` means one compilation unit spans files no single compiler can serve. A conf full of `solc8.X` names that nothing on PATH answers to means the alias directory is off PATH or short an alias; see SKILL.md Phase 3.
- **"please check llm_summaries.spec for syntax errors"** → a generated summary didn't compile; the typechecker loop (10 rounds) gave up. Inspect `certora/specs/summaries/`.
- **"Tried to register X as C but C does not exist"** → stale `<Main>_call_resolution.spec` from a previous scene. Current autosetup resets this file automatically at the start of every run, so seeing it means an outdated install or something else rewrote the file — empty the file, re-run, and consider upgrading.
- **Stale cache after changing flags OR the scene** — the content cache keys on all project sources + main contract + solc version, but NOT on stage-skipping flags (`--skip-*`) and NOT on the positional contract list, so changing the closure you pass can silently reuse the previous scene's result. `--clear-cache` whenever you change flags or the scene.
- **"Cache warmup failed - stopping orchestration"** is a catch-all — read the preceding log lines. If the summary-compilation test or the typechecker prep failed, the setup is broken and `--skip-warmup` won't help. Only if the final priming job itself failed may the setup still be fine — check that conf + sanity spec exist and sanity passed, or re-run with `--skip-warmup`.
