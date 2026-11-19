# CVL writing: docs map, guidelines, judge checklist

## The official docs are the authority

CVL and prover behavior must come from https://docs.certora.com/en/latest/ — never from intuition or half-remembered Solidity semantics (CVL diverges in load-bearing ways: `^` is exponentiation, values are immutable, out-of-bounds reads don't revert...). When unsure about syntax or semantics, retrieve the relevant page below and read the whole section. Ask the docs single, self-contained "what" questions ("What is the syntax for a preserved block?"), locate the section, read it fully. Ignore changelog/"changes since" material.

Retrieve a page with whatever your agent has: a built-in web-fetch or browse tool if there is one, otherwise the shell. The pages are static HTML, so fetching one to a file and reading it works; strip the tags if the markup gets in the way. If you have neither, say so to the user, work from the bundled references alone, and flag every CVL construct you could not confirm; recollection is not an accepted substitute for the docs.

### CVL language reference — `https://docs.certora.com/en/latest/docs/cvl/<page>`

| Page | Covers | Consult when |
|---|---|---|
| `overview.html` | spec file anatomy | starting your first spec |
| `basics.html` | lexical rules, top-level constructs | — |
| `types.html` | `mathint`, (u)intK, `env`, `method`, `calldataarg`, `storage`, casts | typing questions, cast errors |
| `cvl2/changes.html` | which casts and other CVL2 changes exist | an unusual cast |
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

## CVL guidelines (26 rules)

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
24. Each call opcode has its own hook: `CALL` (ordinary calls), `STATICCALL` (calls to `view`/`pure` functions), `DELEGATECALL` (callee code run on the caller's storage, e.g. libraries and proxies) and `CALLCODE` (obsolete). A hook sees only its own opcode, so hook every call type you need to reason about. A call that cannot change state can still read it.
25. A property about one function is a rule that calls that function; a property about every function ("no entry point can ...") is a parametric rule (`method f`).
26. Re-entrancy through the external calls of a function `foo()`, that is, a callback into the contract while `foo()` is running, is checked in one of two ways:
    1. **The rule calls `foo()`.** Model `foo`'s external calls in enough detail to be faithful to the deployed code and sound for re-entrancy: dispatch or link them to real contracts or mocks, or apply CVL summaries where they are sound and appropriate. Every path by which an external call can re-enter the contract must exist in the model.

       Confirm with a `satisfy` that the callback into the contract is reachable. Then assert where the property is:
       - *At each external call* (a lock is held, state is already updated, what the callee can read back): hook the call opcodes and check every call, not just the last one. Assert in the hook itself, or record into a ghost that accumulates across calls (a flag that is set and never cleared, a count) and assert on it after `foo`. A ghost overwritten at each call keeps only the last one.
       - *After `foo()` returns*: on its return value, on storage, and with `@withrevert` on whether it reverted.
    2. **The rule starts mid-`foo()`.** The rule does not call `foo`. It starts from a state `require`d to be the one at `foo`'s external call, and calls the contract's entry point the callback would use, or a parametric `f` for all of them. Use it when the callee is arbitrary and no code or summary can stand for it soundly. It is weaker: it cannot state `foo`'s preconditions before the call or its postconditions after it. Its start state must include every context a callback can run in. Build that state from what holds at `foo`'s external calls: a rule of the first kind that asserts at each call proves it, so the start state rests on a proven fact rather than an assumption.

Casts — these are the ones that actually exist; verify against `types.html` and `cvl2/changes.html` in the CVL reference above before using an unusual one:
- `require_(u)intK` / `assert_(u)intK` — narrow `mathint` (or a wider/narrower `(u)intJ`) to `(u)intK`. Casting an `address` or `bytesN` **to** an integer type is NOT supported.
- `require_address` / `assert_address` — `bytes32` → `address` (there is no `to_address`).
- `to_bytesL` — `uint(L*8)` → `bytesL`; `to_bytes32` — `address` → `bytes32`.
- `to_mathint` exists but is rarely needed (operands auto-promote to `mathint`).

`require_*` casts silently drop out-of-range counterexamples (vacuity risk); prefer `assert_*` unless you deliberately mean to assume the range. CVL-only types: `storage` (whole blockchain state snapshot), `calldataarg`, `method`, `env`. Revert reasoning: call with `@withrevert`, inspect `lastReverted`.

## Judge checklist (the 8 feedback criteria)

The judge evaluates the spec against exactly these criteria — no style/maintainability feedback. This holds whether the judge is a separate sub-agent or the fresh-context review pass of Phase 6's sequential mode:

1. **Code smells** — pointless type-bound requires; requires that only prevent reverts of non-`@withrevert` calls; purposeless methods-block entries; tautological asserts. (A check that the *implementation's output* matches an independently-computed expectation is NOT a tautology.)
2. **Guideline compliance** — the 26 rules above (the reviewer must be given them, not just this checklist). Assume the spec already parses/typechecks. Prefer one "revert characteristic" rule (`assert lastReverted <=> <predicate>`) over many single-case revert rules — and inside such a rule a bare `require` should almost never appear (it silently truncates the `<=>` completeness claim); only `requireInvariant` is acceptable there.
3. **Precondition validity** — will rules fail on spurious starting states? Name the structural invariants needed.
4. **Overconstrained inputs** — every bare `require` (especially in preserved blocks) gets intense scrutiny; `requireInvariant` of a proven invariant is fine. A justification like "this state is impossible in a realistic deployment" must NOT be taken at face value — reject the assumption unless there is overwhelming, verifiable, outside-the-spec evidence for it. Carve-out: `require e.msg.sender != C` is acceptable only when C is part of the application but NOT of the current verification task (so the constraint can't be expressed here) — and it obligates a rule in C's own spec validating the assumed behavior.
5. **Trivializing summaries** — e.g. NONDET on balance-moving functions makes results meaningless.
6. **Manifest errors** — a rule that contradicts obviously-correct behavior. But NEVER flag a rule that fails because it exposes a real contract bug: that failure is the intended product.
7. **Meaningful contract interaction** — each rule's verdict must actually depend on contract behavior (a symbol read from the contract), not just free-variable arithmetic with decorative reads. Cure: assert against contract outputs.
8. **Property coverage** — every property in the batch formalized or validly skipped. Inexpressibility claims must be checked against the docs, not taken on faith. A rule that `require`s a bounded array size and then checks the elements one by one is a valid approach — do NOT reject it as overconstrained; only unbounded quantification over dynamic arrays legitimately can't be expressed. Suggestions to change the Solidity are invalid. A rule that permits a loss, a rounding error or a tolerance formalizes its property only if it names the source of its bound: the design document, a comment in the code, or the property itself. Otherwise reject it: the tolerance can accept the very behaviour the property is about. Ask for the strict property, with any tolerance recorded as a separate rule. A part of a property that the spec or its commentary leaves to another unit ("covered by the X component", "covered by the invariants") counts as formalized only when you find the rule or invariant in that unit's spec that states that part; read that spec to check. If no such rule exists, the part is unformalized. For a property about every occurrence of an event, list the sites from the source yourself, not from the generator's commentary, and check each is observed. An exclusion on impact grounds ("read-only", "benign") instead of the property's wording leaves that part unformalized.

The judge produces approve/reject + concrete feedback, written to the round's verdict file; it should stay consistent with its prior feedback across rounds unless given hard evidence.
