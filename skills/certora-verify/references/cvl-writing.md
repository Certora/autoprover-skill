# CVL writing: docs map, guidelines, judge checklist

## The official docs are the authority

CVL and prover behavior must come from https://docs.certora.com/en/latest/ — never from intuition or half-remembered Solidity semantics (CVL diverges in load-bearing ways: `^` is exponentiation, values are immutable, out-of-bounds reads don't revert...). When unsure about syntax or semantics, fetch the relevant page below and read the whole section. Ask the docs single, self-contained "what" questions ("What is the syntax for a preserved block?"), locate the section, read it fully. Ignore changelog/"changes since" material.

### CVL language reference — `https://docs.certora.com/en/latest/docs/cvl/<page>`

| Page | Covers | Fetch when |
|---|---|---|
| `overview.html` | spec file anatomy | starting your first spec |
| `basics.html` | lexical rules, top-level constructs | — |
| `types.html` | `mathint`, (u)intK, `env`, `method`, `calldataarg`, `storage`, casts | typing questions, cast errors |
| `expr.html` | expressions, `lastReverted`, quantifiers | expression semantics |
| `statements.html` | `require`/`assert`/`satisfy`, `havoc`, control flow | statement semantics |
| `imports.html` | `import`/`use` | wiring in summaries/invariants specs |
| `using.html` | `using C as c` — referring to other scene contracts | multi-contract specs |
| `methods.html` | **the methods block and every summary type** (NONDET, DISPATCHER, expression, ghost, ALWAYS, dispatch lists, `expect`, ALL/UNRESOLVED policies) | the most-consulted page; any summary work, any havoc remediation |
| `rules.html` | rules, parametric rules, `filtered`, `@withrevert` | rule structure |
| `builtin.html` | built-in rules (sanity, deep sanity) | — |
| `functions.html` | CVL functions | shared spec logic |
| `invariants.html` | invariants, `preserved` blocks, `requireInvariant`, strong vs weak | any invariant work |
| `ghosts.html` | ghosts, `init_state`, `persistent` | ghost modeling |
| `defs.html` | `definition` named constants/predicates | naming magic numbers |
| `hooks.html` | Sstore/Sload hooks | hook-based tracking |
| `transient.html`, `storage-extension-annotations.html`, `sorts.html` | niche | as needed |

### Prover + user guide — for diagnosis, not authoring

- `https://docs.certora.com/en/latest/docs/prover/cli/options.html` — every conf/CLI flag.
- `https://docs.certora.com/en/latest/docs/prover/checking/sanity.html` — what `rule_sanity` failures mean.
- `https://docs.certora.com/en/latest/docs/user-guide/` — spec-writing patterns, timeout troubleshooting (`out-of-resources/timeout.html`), glossary.

## CVL guidelines (23 rules)

1. Every rule ends in an `assert` or `satisfy` statement (a conditional containing them is not enough).
2. The CVL must be well-typed.
3. Numeric variables default to `mathint` — exception: values passed TO contract functions, results OF contract calls, and array indices use the appropriate `(u)intK`.
4. Mathematical operations produce `mathint`; narrow with `require_(u)intK` or `assert_(u)intK`.
5. Every contract function implicitly takes an `env` first argument unless declared `envfree` in the methods block.
6. Methods block specifics:
   - `internal` functions are never `envfree`.
   - Expression summaries on `_.method(...)` entries MUST include an `expect` clause.
   - The operand of `ALWAYS` must be a constant.
   - Reference types in *internal* signatures always include the data location; ditto *external library* signatures; elsewhere it's optional.
   - An unqualified entry (`function foo() ...`) binds the contract under verification; `function _.foo() ...` matches any contract.
   - Signatures using a user-defined type alias must use the alias, not the underlying type.
7. Parameter types in `preserved` blocks, signature literals, and dispatch lists do NOT include data locations.
8. The contract name in a methods block is the contract *type* name, not a `using` alias.
9. Except ghosts, CVL values are immutable — constrain with `require`, don't reassign. Unconstrained variables take nondeterministic values.
10. Bitwise operations are over-approximated — avoid when possible.
11. Ghosts revert with blockchain state on revert unless marked `persistent`.
12. `method` variables are declared as a rule parameter or directly in the rule body (both are legal — the autosetup sanity spec uses the body form); they may NOT be nested inside `if` statements or declared inside CVL functions.
13. Quantifier bodies must not contain contract calls or `require_*`/`assert_*` casts.
14. Every CVL function ends with `return` (even void).
15. Void CVL functions omit the returns clause (`returns void` is illegal).
16. The return value of an `@withrevert` call is undefined if it reverted — rarely use it.
17. A methods-block entry with neither `envfree` nor a summary is useless — external methods are auto-exposed.
18. Proving invariant I checks `assume I; m(); assert I` for every method m — `preserved` blocks add to the prestate *on top of* I; never manually `require` I itself.
19. Comparison/arithmetic operands auto-promote to `mathint`; explicit `to_mathint` is rarely needed.
20. `persistent` ghosts sparingly — never for ghosts mirroring contract state.
21. Name meaningful numeric constants with `definition`.
22. Prefer invariant *parameters* over `forall` (`invariant foo(uint i) p(i)` — parameters are implicitly universally quantified).
23. Prefer **direct storage access** over ghost+hook mirroring; hooks/ghosts only when the state is used beyond simply reading values.

Casts — these are the ones that actually exist; verify against `docs/cvl/types.html` / `cvl2/changes.html` before using an unusual one:
- `require_(u)intK` / `assert_(u)intK` — narrow `mathint` (or a wider/narrower `(u)intJ`) to `(u)intK`. Casting an `address` or `bytesN` **to** an integer type is NOT supported.
- `require_address` / `assert_address` — `bytes32` → `address` (there is no `to_address`).
- `to_bytesL` — `uint(L*8)` → `bytesL`; `to_bytes32` — `address` → `bytes32`.
- `to_mathint` exists but is rarely needed (operands auto-promote to `mathint`).

`require_*` casts silently drop out-of-range counterexamples (vacuity risk); prefer `assert_*` unless you deliberately mean to assume the range. CVL-only types: `storage` (whole blockchain state snapshot), `calldataarg`, `method`, `env`. Revert reasoning: call with `@withrevert`, inspect `lastReverted`.

## Judge checklist (the 8 feedback criteria)

The reviewer subagent evaluates the spec against exactly these criteria — no style/maintainability feedback:

1. **Code smells** — pointless type-bound requires; requires that only prevent reverts of non-`@withrevert` calls; purposeless methods-block entries; tautological asserts. (A check that the *implementation's output* matches an independently-computed expectation is NOT a tautology.)
2. **Guideline compliance** — the 23 rules above (the reviewer must be given them, not just this checklist). Assume the spec already parses/typechecks. Prefer one "revert characteristic" rule (`assert lastReverted <=> <predicate>`) over many single-case revert rules — and inside such a rule a bare `require` should almost never appear (it silently truncates the `<=>` completeness claim); only `requireInvariant` is acceptable there.
3. **Precondition validity** — will rules fail on spurious starting states? Name the structural invariants needed.
4. **Overconstrained inputs** — every bare `require` (especially in preserved blocks) gets intense scrutiny; `requireInvariant` of a proven invariant is fine. A justification like "this state is impossible in a realistic deployment" must NOT be taken at face value — reject the assumption unless there is overwhelming, verifiable, outside-the-spec evidence for it. Carve-out: `require e.msg.sender != C` is acceptable only when C is part of the application but NOT of the current verification task (so the constraint can't be expressed here) — and it obligates a rule in C's own spec validating the assumed behavior.
5. **Trivializing summaries** — e.g. NONDET on balance-moving functions makes results meaningless.
6. **Manifest errors** — a rule that contradicts obviously-correct behavior. But NEVER flag a rule that fails because it exposes a real contract bug: that failure is the intended product.
7. **Meaningful contract interaction** — each rule's verdict must actually depend on contract behavior (a symbol read from the contract), not just free-variable arithmetic with decorative reads. Cure: assert against contract outputs.
8. **Property coverage** — every property in the batch formalized or validly skipped. Inexpressibility claims must be checked against the docs, not taken on faith. A rule that `require`s a bounded array size and then checks the elements one by one is a valid approach — do NOT reject it as overconstrained; only unbounded quantification over dynamic arrays legitimately can't be expressed. Suggestions to change the Solidity are invalid.

The judge returns approve/reject + concrete feedback; it should stay consistent with its prior feedback across rounds unless given hard evidence.
