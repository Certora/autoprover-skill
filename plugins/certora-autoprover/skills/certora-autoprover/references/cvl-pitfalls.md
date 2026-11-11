# CVL & prover pitfalls (the knowledge base)

Distilled tribal knowledge — traps that are NOT obvious from any single docs page. Scan the symptoms when the prover misbehaves; read the matching entry before "fixing" blindly.

## Summaries

- **Summary silently not applied** — `function Foo.f() external => NONDET;` only applies when the prover can *prove* the receiver is `Foo`. Calls through interfaces/unknown addresses stay unresolved. Fix: wildcard receiver `function _.f() external => NONDET;`. Check the report's "Rule Call Resolution" panel to see what actually applied.
- **Wildcard default policy is UNRESOLVED** — `_.f(...) => NONDET;` does not apply to calls whose target is known (linked/currentContract). Append `ALL` to force it. Exact-contract and internal summaries default to ALL.
- **Summaries never apply to direct CVL calls** — calling `f(e, args)` from a rule runs the real implementation, by design. Route through contract code if you need the summarized behavior.
- **`public` functions split** — solc splits public fns into internal impl + external wrapper. Summarize `internal` to catch both paths (usually what you want); an `external` summary misses internal calls.
- **Wildcard expression summaries need `expect`** — `function _.f() external => g() expect uint256;` (`expect void` for no return). A wrong `expect` type silently misinterprets values.
- **DISPATCHER is unsound unless justified** — it assumes the callee is one of the scene contracts. For generic tokens use the hybrid pattern: dispatch to known in-scene implementations, fall back to a sound ghost model for unknown callees. recent certora-cli versions make `DISPATCHER(true)` hard-fail if no scene contract implements the method (older versions instead produced silently vacuous results). DISPATCHER cannot summarize *library* calls.
- **CONSTANT/PER_CALLEE_CONSTANT can create vacuity** (esp. variable-sized returns) — prefer NONDET.
- **NONDET return-size mismatch** — a NONDET-summarized call may "return" the wrong number of bytes and the caller reverts on ABI decode. Ensure the methods-block entry declares the callee's true return type (for wildcard entries: a correct `expect` clause); the opt-in assumption is `"prover_args": ["-optimisticReturnsize true"]` (there is no top-level certoraRun flag for this).
- **`storage`-typed parameters can't reach CVL summaries** — use a rerouting summary to an external library harness function instead.
- **`with(env e)` semantics** — `e.msg.sender`/`e.msg.value` are from the most recent non-library external call (the immediate caller), not the rule's env. `e.tx.origin`/`e.block.timestamp` match the outermost env.
- **`calledContract` vs `executingContract`** — receiver of the summarized call vs the contract making it (differ only for non-delegate external calls). Use `calledContract` to distinguish which token a `_.transferFrom` summary fired on.
- **DELETE summaries remove the method from the scene** — parametric rules skip it entirely; calling it from CVL is a violation. Useful for timeout-causing irrelevant methods.

## Rules & revert reasoning

- **`lastReverted` is overwritten by EVERY contract call**, including non-`@withrevert` ones. `f@withrevert(); assert isPaused() => lastReverted;` is broken — `isPaused()` reset the flag. Capture state in variables *before* the `@withrevert` call.
- **Missing `env`** — every non-`envfree` call needs `env e` as first arg. Declaring `envfree` is verified by the prover.
- **`^` is exponentiation in CVL**; bitwise XOR is the keyword `xor`.
- **Vacuity** — if `assert false` would also pass, the rule proves nothing. Causes: contradictory requires, an always-reverting non-`@withrevert` call, unreachable asserts. `rule_sanity: basic` catches this (SANITY_FAILED); treat every sanity failure as "my preconditions contradict the code".
- **`require_` casts silently drop counterexamples** out of range; prefer `assert_` casts unless deliberately assuming.
- **`mathint` never overflows** — do arithmetic in mathint, compare against `max_uint256` explicitly if overflow is the property.
- **Out-of-bounds CVL array reads are undefined values, not reverts** — guard indices with requires.
- **Bitwise ops are over-approximated** by default → spurious CEXes; set `"precise_bitwise_ops": true` in the conf — trades time for precision.
- **Parametric rules/invariants cover ALL scene contracts' methods** (CLI ≥5) — a rule may fail on a secondary contract's method. Filter `f.contract == currentContract` only if that scope is genuinely wrong; the wider check often exposes real issues.

## Invariants

- **Preserved-block `require`s are unsoundness holes** — each one can mask violations; prefer `requireInvariant` of separately-proven invariants.
- **The invariant itself is auto-assumed in the prestate** — never manually require it in `preserved`.
- **Generic `preserved` doesn't cover the constructor** — add `preserved constructor() { ... }` for base-case failures.
- **Weak vs strong** — default invariants may not hold *during* execution across unresolved external calls; `strong invariant` asserts/assumes around havocs.
- **Invariant "passes" checklist** — filters exclude methods from the proof; reverting invariant expressions are vacuously true; always run with `rule_sanity`.

## Ghosts & hooks

- **Non-persistent ghosts are havoced together with storage** on unresolved-call havocs — a hook-maintained mirror can be trashed mid-rule. But do NOT reach for `persistent` to dodge a havoc: persistent ghosts are for *event* tracking ("a call happened"), never for state mirrors — fix the havoc with a proper summary instead.
- **Hooks don't fire recursively**, and don't fire from CVL storage reads at all — only contract code triggers them.
- **Prefer direct storage access** (`currentContract.x`, `token.balanceOf[user]`-style) over ghost mirrors when you only read the value.

## Types & syntax

- **Struct field assignment is illegal** — `require s.f == x;` instead.
- **User-defined types are contract-qualified** — `MyContract.MyStruct s;`.
- **Methods-block receiver = the contract that *defines* the method** — for inherited methods use the parent contract's name.
- **`optional` methods-block marker** — without it, an entry naming a nonexistent method errors (usually what you want; add `optional` for multi-version specs).
