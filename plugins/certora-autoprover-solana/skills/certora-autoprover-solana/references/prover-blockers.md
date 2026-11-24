# Prover blockers: errors, wrong values and their workarounds

A rule can stop before its property is checked: the prover refuses it with an error, the job
gives no verdict, or a counterexample shows values the program cannot produce. This file lists the
blockers seen most often on Solana programs, how to recognise each one, why it happens, what removes
it, and what the workaround costs. Match the error code, the message or the symptom here before
you improvise. Each entry is one of three kinds:

- **exact**: the workaround changes how the program or the rule is written, not what it computes;
  a verdict means what it meant before;
- **over-approximation**: the workaround admits more behaviours than the program has; a VERIFIED
  rule still holds for the program, but says nothing about the part replaced, and the rule's
  commentary says which part;
- **no workaround**: record the property as a `prover limitation`, quoting the message and the
  job.

The reference text `setup` writes covers the neighbouring ground; this file does not repeat it.
`reference/recipes/index.md` lists the recipes by trigger (K4 loops, K5 "Cannot overflow",
K7 descending to the accounting core, K8 timeouts, K9 halted jobs, K10 summaries, K13 `seeds`,
K14 `try_accounts`), and `reference/cvlr.md` covers `NativeInt`, reachability probes and the
forked Anchor's panicking `require!`.

## Patching a dependency

Several recipes below change a dependency's source, by the same mechanics as a dependency move
(`references/dependency-moves.md`). Unlike a move that clears a refusal of `setup`, these patches are
made during Phase 6 without asking the user: the run does not stop for approval. Make one at a
barrier, since the workspace `Cargo.toml` is shared by every component, and record it in
`certora/analysis/dependency_moves.json` with the function changed and why the change keeps the
behaviour. The mechanics:

1. Copy the crate at the exact version `Cargo.lock` names into the workspace, for example
   `certora-patches/<crate>-<version>/`. A registry crate is under `~/.cargo/registry/src/`; a git
   dependency, Certora's Anchor fork included, is under `~/.cargo/git/checkouts/`, at the commit
   the lock names.
2. Make only the change the recipe names.
3. Redirect the crate to the copy: `[patch.crates-io] <crate> = { path = "certora-patches/<crate>-<version>" }`
   in the workspace `Cargo.toml`. For a crate `setup` already patches to a fork (`anchor-lang`,
   `anchor-spl`, `anchor-lang-error`), change that entry's `git` and `branch` to the `path` of the
   copy, and check after every later `setup` run that it still points there.
4. Add `certora-patches` to `[workspace] exclude`. Without it, a copied crate that inherits from its
   own workspace (`version.workspace = true`) becomes a member of the program's workspace and fails
   to load.
5. Run `certora-cvlr check` and confirm the build uses the copy.

A `[patch]` applies to every build of the workspace, like the forks `setup` patches in; say in the
report that the verdicts are about the build with the patched crate. A patched
crate is compiled into every component's build, so it is a barrier change, like an edit to the
program's source: a generator that needs one writes a request, the orchestrator applies it at the
barrier, and every component's full `prove` runs again. Before you rely on a change that re-encodes
data (an instruction encoder, a numeric model), compare it with the original crate on many random
inputs in a small host test.

## Pointer-analysis errors

The pointer analysis runs on the whole compiled rule before any loop is unrolled or any solver
runs. It analyses every instruction in the binary that the rule can reach, so `--loop-iter` and
`--optimistic-loop` never remove one of its errors. It stops at the first error, so another one
can be behind the one you remove.

### A runtime switch does not hide code from it

- **Recognise:** an error in code that a stand-in was meant to replace, where the stand-in is chosen
  at run time (`if standin::enabled()`, a value read from an account, a `static mut` flag).
- **Cause:** the analysis is static: a branch the rule never takes is still analysed. A `static mut`
  also starts arbitrary at rule entry, not at its initial value (see *Writable globals* below).
- **Recipe:** gate the stand-in at compile time: `#[cfg(feature = "certora")]` on a block that
  returns early at the top of the function, or `if cfg!(feature = "certora_unit_<module>") { ...; return ...; }`,
  which the compiler folds, dropping the real body from that component's build only. Rules that
  need the real body belong to another component.
- **Soundness:** as the stand-in's own: exact, or an over-approximation constrained only by what the
  real function guarantees.

### `[3308]` at `sol_memcpy_` in `to_vec`, `to_owned` or `String::from`

- **Recognise:** `[3308] illegal dereference of an absolute address`, with the message
  `dereference of an absolute address 1 (0x1) at call sol_memcpy_` or `dereference of an absolute
  address although the actual address is unknown statically at call sol_memcpy_`, in
  `alloc/src/slice.rs`.
- **Cause:** two forms. An empty `Vec` holds a placeholder pointer (its alignment, `1` for bytes),
  and the analysis refuses a copy through it when it cannot see that the length is zero. Or the
  copy's source is one of many string constants a `match` chooses from, more than the analysis
  tracks, for example an error enum's `name()`, which builds the variant name for every Anchor
  error.
- **Recipe:** find the caller from the last `from:` line.
  - If it builds a value no rule reads (an error's name, a log message, CPI instruction data),
    summarize the caller (recipe K10, and the String layout note in SKILL.md). It must be a real
    symbol, not inlined: the job reports a directive that matches nothing. For an `#[error_code]`
    enum, the caller is `<crate>::error::<Enum>::name`:

    ```
    ; name() only builds the error's name String; no rule reads it.
    #[type((*i64)(r1+0):num)]
    #[type((*i64)(r1+8):ptr_heap)]
    #[type((*i64)(r1+16):num)]
    ^my_program::error::ErrorCode::name$
    ```

  - If the caller's outcome matters but its decoding does not, for example a program function
    that reads the instructions sysvar through `load_instruction_at_checked` or
    `get_processed_sibling_instruction`, replace that program function with a compile-time stand-in
    that keeps its cheap checks and returns an arbitrary `Ok` or `Err`.
- **Soundness:** the summary is exact except for the name's text. The sysvar stand-in is an
  over-approximation: a property proved with it holds for every outcome of the real check and says
  nothing about the check itself; the commentary says so.

### `[3308]` after a `Vec` grows

- **Recognise:** the same dangling-pointer `[3308]` in code that pushes onto a `Vec` or builds a
  `String`, with the growth step (`alloc::raw_vec::RawVec<T,A>::grow_one`,
  `alloc::raw_vec::RawVecInner<A>::reserve::do_reserve_and_handle`) among the functions `wait`
  lists as treated as external, or a starting directive for it that matches nothing.
- **Cause:** the growth step stays external, so the buffer keeps the empty `Vec`'s placeholder
  pointer.
- **Recipe:** summarize the growth step under the symbol your build has, with the buffer pointer at
  `+8` and the capacity at `+0`:

  ```
  ; grow_one only makes room in a Vec's buffer; it writes no data a rule reads.
  #[type((*i64)(r1+0):num)]
  #[type((*i64)(r1+8):ptr_heap)]
  ^alloc::raw_vec::RawVec<T,A>::grow_one(_[0-9][0-9]*)*$
  ```

  Typing `+0` as the pointer leaves the error in place on toolchains with the `{cap, ptr, len}`
  layout.
- **What it gives up:** the summary leaves the capacity arbitrary, and `Result<Vec<_>, _>` and
  `Option<Vec<_>>` keep their `Err` and `None` in a capacity no real `Vec` has. A function that
  returns one can then read back as `Err` or `None` although every element it pushed is right
  (`Ok` implies the right contents verifies, `is_ok()` fails). Where the property depends on it,
  pre-size the `Vec` where it is built, `Vec::with_capacity(<a bound the code never exceeds>)`, so
  the growth step is never reached: in the program under `cfg(feature = "certora")`, in a
  dependency through a patched copy. That is exact, since no code observes the capacity. Otherwise
  assert only on the contents.

### `[3308]` "unknown statically" on a constant table

- **Recognise:** `[3308] ... although the actual address is unknown statically` at a load through a
  register that holds a read-only data address plus a runtime index (`TABLE[i]`), for example a
  decimal library's power-of-ten table in its comparison, addition or division.
- **Cause:** the analysis types the computed address as a number, not a pointer into the table.
- **Recipe:** for a math library, replace the operations that index the table with a `NativeInt`
  model (*Math libraries* below). No flag of `prove` removes it.

### `[3001]` and `[3005]` in big-integer code

- **Recognise:** `[3001] access to an indeterminate stack location` (statically unknown stack
  offset) or `[3005] memcpy with dynamically sized length`, in `ruint` (`bits.rs`,
  `algorithms/mul.rs`, `algorithms/div/`) or any limb array indexed by a runtime value.
- **Cause:** stack accesses must be at offsets known statically, and big-integer code indexes its
  limbs by shift amounts, limb counts and loop counters.
- **Recipe:** reimplement the operation under `cfg(feature = "certora")`, exactly, over `NativeInt`
  (*Big-integer operations* below), returning `Err` or `None` exactly when the original does.
- **Soundness:** exact.

### `[3006]` illegal store of a stack pointer

The analysis forbids a pointer from the heap into the stack. Three shapes:

- **A generated CPI client builder** (`*CpiBuilder::new` and its setters box references to
  `AccountInfo`s that the program holds by value on the stack). Replace the program function that
  builds and invokes the CPI with a compile-time, record-only stand-in: compute the arguments the
  real code would pass (keys, authorities, amounts), record them, return `Ok(())`. As with every CPI
  stand-in, the callee's effects are not modelled: properties about the CPI's arguments are
  checkable, properties about its effects are not.
- **`filter().collect::<Vec<&T>>()` over data the rule built** (message `stack is escaping ... into
  Heap`, trace through `collect` or `spec_from_iter`). The rule passed a stack array where the
  program passes account data. Pass what the program passes: load the account the program loads,
  constrain its fields, and call with `&acc.field[..k]`, a small `k` keeping the loop within
  `--loop-iter`. Exact: it is the program's own call shape.
- **A rule that moves into a `Box` a value holding references to the rule's own stack locals** (an
  accounts struct, for example). Keep that value on the stack. Exact.

### `[3003]` at a byte compare

- **Recognise:** `[3003] dereference of a register (pointer) with unknown provenance` in
  `slice/cmp.rs`, usually where a rule compares a copy of an account struct held by value with a
  symbolic index.
- **Recipe:** *Byte-range equality* below.

## Anchor accounts and `init`

The generated `<Ctx as Accounts>::try_accounts` of an accounts struct is where most whole-struct
rules (recipe K14) stop. Two changes to the code generator of Certora's Anchor fork, made in a
patched copy (*Patching a dependency*), remove the main causes. Check the fork first: if its
generated `try_accounts` already panics on a failed constraint and has no `HashSet`, there is
nothing to patch.

### `try_accounts` times out: fail-fast constraints

- **Recognise:** a rule that calls `try_accounts(..).unwrap()` comes back TIMEOUT or halts the job,
  and the statistics put the branching in `InterfaceAccount::try_from`,
  `TokenAccount::try_deserialize_unchecked`, `Mint::try_deserialize_unchecked` or the struct's own
  `try_accounts`.
- **Cause:** every failed constraint builds an Anchor `Error` (the account name, the compared keys)
  and returns it through every later field to the rule's `.unwrap()`. With several token accounts,
  that `Err` plumbing, not the checks, is what the solver cannot finish.
- **Recipe:** in the patched copy of the fork, in `lang/syn/src/codegen/accounts/`:
  - in `constraints.rs`, make every check that fails a constraint panic where it detects the
    failure: each generated `return Err(...)`, and the error value `generate_custom_error`
    produces, becomes `::core::panic!()`;
  - in `try_accounts.rs`, make a field's own failure panic: the field's
    `try_accounts(..).map_err(|e| e.with_account_name(..))?` becomes
    `.unwrap_or_else(|_| ::core::panic!())`.

  Then state the property success-implies, one rule per struct, with the account data lengths
  pinned to the sizes the program uses.
- **Soundness:** exact for success-implies rules: the accepted inputs are the same, and `.unwrap()`
  already discarded every `Err` path. On chain a panic and an `Err` both abort the instruction. A
  rule of the form "this input is rejected, `is_err()`" loses every path and is vacuous; restate it
  success-implies.

### The duplicate-mutable-account check

- **Recognise:** a `try_accounts` rule stops on `Unwinding condition in a loop` in a set-bit loop
  (`x & (x - 1)`, `0x8080...` masks, often with "Imprecision detected: BWAnd"), or times out with
  an enormous path count, and the external functions include `core::hash::BuildHasher::hash_one` or
  `drop_in_place<std::collections::hash::set::HashSet<..>>`.
- **Cause:** Anchor generates a `std::collections::HashSet` of the keys of every mutable `Account`
  and `InterfaceAccount` field. The hash stays external, so the probe loop inlined into
  `try_accounts` runs over unconstrained bits, and no `--loop-iter` finishes it. A struct whose
  mutable fields are all `AccountLoader`, `UncheckedAccount`, `Signer` or `SystemAccount` has no
  such set.
- **Recipe:** in the same patched copy, in `try_accounts.rs`, `generate_duplicate_mutable_checks`:
  replace the set with comparisons of each mutable key with every earlier one, failing on the first
  equal pair with the same error and the later field's name (a panic under fail-fast). Keys of a
  nested struct (`duplicate_mutable_account_keys()`) are checked by a scan over the keys seen so
  far. The comparisons are unrolled when the macro expands: no loop, no hash. Do not raise
  `--loop-iter` and do not summarize: the code is inlined into `try_accounts`.
- **Soundness:** exact: `insert` returns false exactly when an equal key was inserted before.
  Properties that rely on the check ("a destination is never the source vault") become checkable.
  Whole-struct rules over such a struct also need fail-fast to finish.

### `[6002]` frame larger than 4096 bytes

- **Recognise:** ERROR `[6002]`: `try_accounts` "uses at least N bytes of stack, more than the
  4096-byte frame it was compiled for, and it passes arguments on the stack". The build log already
  says it, for free: `overflows the maximum allowed frame space` and `A function call in method ...
  overwrites values in the frame` on the same symbol.
- **Cause:** the fork keeps Anchor's `Error` by value, so every `Result<_, Error>` in the generated
  `try_accounts` is a large stack value. Past 4096 bytes, a call that passes stack arguments
  overwrites them, which is undefined on chain, and the prover refuses the function. No stack-size
  setting changes that.
- **Recipe:** the fail-fast copy above: no `Error` value is built or carried, and the frame shrinks.
  Rebuild and check that the build log no longer prints "overwrites values in the frame" on a
  `try_accounts` symbol. A large struct with several token accounts may then time out, as in the
  first entry.
- **Soundness:** as fail-fast.

### Framework functions left external

- **Recognise:** the functions `wait` lists as treated as external include
  `<Interface<T> as TryFrom<..>>::try_from`, `CheckOwner::check_owner`, `CheckId::check_id`,
  `AccountsExit::exit`, `AccountsClose::close`, `anchor_lang::common::close`, `reload`, or the
  `Box<T>`/`Option<T>` impls of `try_accounts` (spelled
  `anchor_lang::accounts::boxed::<impl anchor_lang::Accounts<B> for alloc::boxed::Box<T>>::try_accounts`).
- **Cause:** the starting configuration leaves most of `anchor_lang` unanalysed; these are outside
  its list of exceptions, and `prove` takes no inlining directives from you. An external function
  writes nothing: the check it makes is not analysed, and the `Result` it returns through memory is
  arbitrary.
- **Recipe:** none from the rule side. In the commentary of every rule whose external list names
  one, say which check was not analysed: an `InterfaceAccount` owner or program-id check, a close,
  a boxed field's constraints. For a whole-struct rule over a struct whose boxed `InterfaceAccount`
  fields are external, do not try to make the wrapper analysed (for example with `#[inline(always)]`
  on the fork's `Box<T>`/`Option<T>` impls in a patched copy). Measured: with it analysed, the
  struct had no accepted path, and every rule over it was vacuous. Skip the whole-struct rule, citing the job.
  Checking each account through its own `try_from` and asserting the struct's constraints on the
  fields is the route left; it is untested.

### `init`: the system-program instruction encoder

- **Recognise:** `Unwinding condition in a loop` inside `anchor_lang::system_program::{create_account,
  allocate, assign, transfer}` → `solana_system_interface::instruction::*` →
  `Instruction::new_with_bincode`, reached from an `#[account(init ...)]` or the program's own
  system-program CPI.
- **Cause:** bincode writes the 32-byte owner or address one byte at a time: a 32-iteration loop that
  no input bounds and `--loop-iter` 2 does not finish. The CPI itself is not executed by the prover;
  only the encoding is in the way.
- **Recipe:** patch the locked `solana-system-interface` (on Anchor 0.30 and older, the
  `system_instruction` module of `solana-program`). In `create_account`, `assign`, `transfer` and
  `allocate`, build the instruction data as a fixed byte array, the bytes bincode produces: the
  variant index as a little-endian `u32` (0 create, 1 assign, 2 transfer, 8 allocate), then the
  `u64` fields little-endian, then the address's 32 bytes; and build the instruction with
  `Instruction::new_with_bytes` and the same account metas. Compare it with bincode in a host test.
  No rule change, no `--loop-iter` change. A loop that remains is the handler's own (recipe K4, or
  *Loops in log lines* below).
- **Soundness:** exact: the same instruction data. The CPI's effect is not modelled either way.

### "Cannot overflow" before the rule's own assertion

- **Recognise:** a rule stops on `Cannot overflow: inferred pointer`, `Cannot overflow: computing TAC
  map index` or `Cannot overflow: Flipped sign`, often in `try_from`, `try_deserialize`, a token
  unpack, Anchor's `init` or its system-program helpers.
- **Cause:** a check the prover adds on pointer arithmetic. The operand is usually a stack word the
  path never wrote, which the encoding leaves without a 64-bit bound, so no bound on account values
  reaches it. That is why recipe K5's bound does not remove it when it comes back with the bound in
  place.
- **Recipe:** none that `prove` exposes. Do not add bounds on account values for this stop. Try K5's
  other move once, stating the property against a function below the handler (K7); otherwise record
  the property as a `prover limitation`, quoting the message and the job.

### No verdict: "processArgument is accessing stack at a non-constant offset"

- **Recognise:** the job ends with no verdicts and an internal error `processArgument is accessing
  stack at a non-constant offset [a, b]` (two or more offsets), typically on rules that build
  `Account<T>` of a borsh account type with several `Option` or enum fields.
- **Cause:** a summarized callee (usually `alloc::fmt::format::format_inner`, which writes the
  `String` it returns through `r1`) is reached from one call instruction with two different stack
  destinations, because LLVM tail-merged two `format!` error paths. The analysis needs one constant
  stack offset for every summarized write.
- **Recipe:** build without tail merging. Add to the project's `.cargo/config.toml`:

  ```toml
  [target.sbpf-solana-solana]
  rustflags = ["-C", "llvm-args=-enable-tail-merge=false"]
  ```

  It applies to every SBF build of the workspace: make it at a barrier, record it in
  `certora/analysis/source_edits.json`, and say in the report that the verdicts are about that
  build. The code of the whole program changes, so re-run every
  component's full `prove`. `-simplifycfg-sink-common=false` alone does not remove it. Do not
  summarize the deserialiser: it returns a `Result`.
- **Soundness:** exact: an optimisation setting; distinct call sites stay distinct.

## Values the program cannot produce

These come back as VIOLATED with a counterexample, or worse as VERIFIED, rather than as an error.
Before you call a counterexample a finding, check that the program can produce its values.

### "Imprecision detected" in the call trace

- **Recognise:** a VIOLATED rule whose call trace shows `Imprecision detected: mismatch: BWXOr(1, 42)
  = 43, but is 14` (or `BWAnd`, `BWOr`) on the path to the failing assertion.
- **Cause:** the default integer encoding approximates bitwise operations; the counterexample is
  spurious. It never makes a rule pass wrongly.
- **Recipe:** rerun that rule alone with the exact bit-vector encoding: `prove ... --rule <rule>
  --precise-bitwise "<the imprecision line>"`. It is slow on non-linear arithmetic, so never on a
  whole component. If the rule then times out, record it as a `prover limitation`, quoting the
  imprecision line; never as a genuine issue.
- **Soundness:** exact.

### Narrow fields read with impossible values

- **Recognise:** a counterexample logs a `bool`, `u8`, `u16` or `u32` field outside its type (a byte
  of 256 or more, a `bool` of 2 or more), or one field with two values on one path, or a value that
  logs as 0 while `== 0` fails; usually with no "Imprecision detected" line, and unchanged by
  `--precise-bitwise`.
- **Cause:** the prover's memory cells ignore the access width. A narrow read of a wider store, a
  narrower one, or a copy gets the whole stored register or a fresh unbounded value.
- **Recipe**, in order:
  1. Structs the rule builds and the program reads: write them in place, one field at a time, with
     `core::ptr::write_volatile(&mut s.field, value)`. Never build such a struct by value, return
     it by value or copy it.
  2. A narrow field that steers the code (a mode, a tag, a flag): split the rule by its values and
     write each case as a literal constant, not as a nondet value narrowed by an assumption.
  3. Otherwise, when the misread value is inside the program's own code, record the property as a
     `prover limitation`, quoting the out-of-range value.
- **Soundness:** 1 is exact. 2 is exact when the cases together cover the field's values.
- **False proofs:** the same cause can prove a false claim. Never take a VERIFIED as evidence when
  the property depends on a value truncated by a narrow store (`x as u8` stored, then compared with
  `x`).

### An `Err` that reads back as `Ok`

- **Recognise:** an `is_ok()` or "never returns `Err`" rule VERIFIED on inputs where the code returns
  `Err`, or a counterexample that goes on past an `unwrap()` with values that contradict the code.
- **Cause:** one of two. The `Err` path is pruned, because a narrow steering field is misread (the
  entry above). Or an external conversion that should build the `Err` writes nothing, so the
  `Result`'s tag is arbitrary; the external functions then include a `From<..> for
  anchor_lang::error::Error` conversion. Error formatting alone (`Display::fmt`,
  `alloc::fmt::format`) does not cause it.
- **Recipe:**
  1. Add a reachability probe on an input where the code returns `Err`:
     `cvlr_satisfy!(r.is_err())`. If it is not reached, the `Err` path is pruned: make the steering
     fields per-rule constants and rerun.
  2. If the probe is reached but an `Err` input still comes back `Ok`, restrict the rule to the
     domain where the conversion succeeds (`cvlr_assume!(amount <= i64::MAX as u64)` before a
     `try_into::<i64>()`). That is exact for properties about the success case.
  3. If the `Err` condition is not an input bound, record the property as a `prover limitation`,
     quoting the counterexample's inputs.
- **Soundness:** probes and constants are exact; the domain restriction is exact for success-case
  properties.

### The order of byte arrays and `Pubkey`s

- **Recognise:** a counterexample in which a sorted list gets a duplicate, a binary search misses a
  key that is present, or both `a < b` and `b < a` hold, where the code orders `[u8; N]`, `Pubkey`
  or `&[u8]` with `<`, `cmp`, `binary_search`, `sort` or a `BTreeMap` keyed by them.
- **Cause:** LLVM turns the lexicographic compare into byte swaps, which the prover does not model,
  and an unexpanded `memcmp` is encoded as equal or not equal only. Equality (`==`) is unaffected.
- **Recipe:** compare through a comparator without byte swaps: build each 8-byte big-endian word from
  one-byte `core::ptr::read_volatile` reads, `w = w.wrapping_mul(256) + byte as u64`, and compare
  the words in order. Use it for the rule's sortedness assumptions, and through a
  `cfg(feature = "certora")` replacement of the comparator the program's search or sort uses.
  Validated on a standalone program; untested inside a program's own search.
- **Soundness:** exact: the same lexicographic order.

### Byte-range equality

- **Recognise:** a VIOLATED "these bytes are unchanged" rule on bytes the code does not write;
  `[3003]` at `slice/cmp.rs`; or a VERIFIED byte-range equality whose length is not a multiple of 8.
- **Cause:** a compare of two stack copies at a symbolic index has no pointer the analysis can track
  (`[3003]`); a compare on the stack whose length is not a multiple of 8, or of non-constant length,
  gets an arbitrary result; and a compare outside the stack ignores the last `length % 8` bytes, so
  a range that differs only there compares equal.
- **Recipe:** snapshot the pre-state to the heap (`data[a..b].to_vec()` of the account bytes) and
  compare it with the account data after the call, so neither operand is on the stack. Compare
  fixed-size arrays whose length is a multiple of 8, then the remaining bytes one by one. A symbolic
  index is fine in this form. Never compare structs held by value; field-by-field equality is the
  other exact form.
- **Soundness:** exact. Re-check any VERIFIED equality of two byte ranges whose length is not a
  multiple of 8 and whose tail was not compared separately: it checked all but the tail.

### Calls through a trait object

- **Recognise:** the handler calls through a `Box<dyn Trait>` on the rule's path, and the rule is
  SANITY_FAILED, or what the callee computes is arbitrary, or a check behind the trait object never
  fails.
- **Cause:** the prover skips indirect calls: the callee never runs and writes nothing, including a
  `Result` it returns through memory.
- **Recipe:** under `cfg(feature = "certora")`, replace the dynamic dispatch with static dispatch: the
  function that builds the `Box<dyn Trait>` from a mode or tag becomes a `match` on the same value
  that calls the concrete type's method directly. Re-run every rule whose path crosses it: a rule
  that verified only because the call was skipped can change its verdict or time out.
- **Soundness:** exact.

### Writable globals start arbitrary

- **Recognise:** a rule depends on a `static mut` (a stand-in switch "off by default", a counter), and
  a counterexample shows it in a state the code never sets.
- **Cause:** the prover starts a writable global at an arbitrary value, not at its initial value,
  unless the code reads it in a way the prover recognises.
- **Recipe:** a rule that needs the global in a given state writes it before the call. A stand-in
  switch is better gated at compile time (*A runtime switch* above).

### A validator's success-shape rule fails with an input the code rejects

- **Recognise:** "call the validator, `.unwrap()`, then assert a clause" is VIOLATED, and evaluating
  the counterexample by hand shows the validator rejects that input; `--precise-bitwise` does not
  change it.
- **Cause:** a lost value in the validator's stack hand-offs, of the narrow-field kind; its exact
  mechanism is not known.
- **Recipe:** state the validator's acceptance condition as rejections, one rule per clause: nondet
  input, `cvlr_assume!(!clause)`, call, `cvlr_assert!(r.is_err())`. Add one `cvlr_satisfy!` that
  some valid input is accepted. Read each rule's sanity verdict: a clause enforced by a panicking
  check (`require!` in the fork) leaves its rejection rule vacuous, and success-implies is then the
  shape for that clause. Keep the success shape for claims about what the validator returns.
- **Soundness:** exact: "not the clause implies not `Ok`" is the contrapositive of "`Ok` implies the
  clause".

## Memory and parsing limits

### `[6001]` heap bound

- **Recognise:** ERROR `[6001] Heap allocations in this rule reached N bytes, exceeding the bound`,
  usually on a rule that keeps an `Err` path live (an `is_ok()` claim, a `satisfy(is_err)` probe, a
  `Result` not unwrapped) or drives a long handler.
- **Cause:** the bound charges every allocation site of the inlined rule and frees nothing, and a site
  whose size the analysis does not know costs 512 bytes. Error construction dominates: an
  `#[error_code]` enum's `name()` is a `match` with one `to_string` per variant, inlined at every
  error site.
- **Recipe:**
  1. Summarize `<crate>::error::<Enum>::name` as a `String` (the directive under the first `[3308]`
     entry). Do the same for other string builders no rule reads.
  2. If the error stays, the allocations are inside code LLVM inlined, such as the generated
     `From<Enum> for Error`, which must not be summarized because it returns an enum. Rerun the rule
     with `prove ... --rule <rule> --heap-size <BYTES>`, above the size the error names. A larger
     heap makes the rule slower; keep it on the rules that need it.
- **Soundness:** 1 is exact except for the name's text. `--heap-size` is exact: only the heap's
  address range grows.

### Too many commands after a long loop

- **Recognise:** the rule is refused for having too many commands or basic blocks (the limits are
  1,000,000 commands and 100,000 blocks), and the property makes a loop run past a capacity or a long
  counter (a ring of events filled from empty, many elapsed epochs), at a `--loop-iter` in the tens.
  It can also follow a `[6001]` that `--heap-size` removed.
- **Cause:** a long trace from the initial state, unrolled.
- **Recipe:** state the rule from a pre-state already at the boundary, and take one step: for a ring,
  a counter at or above the capacity; for time, any last update and one period later; other loops at
  zero trip count where the property allows it. Add a `cvlr_satisfy!` that the boundary event (the
  eviction, the wrap) happens. If the claim needs reachable states only, assume the invariants that
  describe them.
- **Soundness:** the pre-state is wider than what instructions reach: exact for "for all" claims; a
  claim false only on unreachable states needs the invariants.

### Token-2022 mint parsing

- **Recognise:** `Unwinding condition in a loop` inside `InterfaceAccount<Mint>::try_from` or
  `StateWithExtensions::unpack` (`type_and_tlv_indices`); or, at `--loop-iter` 84 and above, a rule
  refused for too many basic blocks.
- **Cause:** the 83 bytes between a mint's 82 and a token account's 165 must be zero, and the check is
  a byte loop. `--loop-iter` is one bound for every loop of the rule, so the 84 it needs unrolls all
  of them 84 times.
- **Recipe:**
  1. Patch the crate that holds `type_and_tlv_indices` (`spl-token-2022-interface`, or
     `spl-token-2022` in older releases): replace the padding check (`iter().any(|&b| b != 0)`, or a
     compare with `vec![0; n]`) with straight-line one-byte `read_volatile` loads, each returning
     "non-zero" early, written out by a macro. Volatile, so LLVM neither re-rolls nor merges them.
  2. In the same copy, create the `Vec` that `get_tlv_data_info` pushes into with
     `Vec::with_capacity(<more than the number of extension types>)` (*`[3308]` after a `Vec`
     grows*).
  3. Make the rule's own account builders loop-free: `d[a..b].fill(0)`, not a byte loop; nondet data
     written without a loop. An unwinding failure just after the account builder is the rule's own
     loop.
  4. `--loop-iter` to the number of extension entries plus 2 (3 for one extension).
- **Soundness:** exact: the same bytes, the same results.
- **Left open:** after the patch, a claim that a valid mint with extensions is admitted can still get
  a spurious `Err` from a later check. Refusal claims, and the decoded list of extensions, are
  decided. Give every admission claim a reachability probe; when it fails, record the property as a
  `prover limitation`, citing the probe.

### Loops in log lines

- **Recognise:** `Unwinding condition in a loop` whose loop is an iterator or `collect` feeding `msg!`
  or `format!` (a list of names, a `{:?}` of a computed `Vec`), often with a constant trip count
  above `--loop-iter` (an enum's variant count, a fixed array).
- **Cause:** `msg!` evaluates its arguments before it formats them; the formatting itself does not
  loop in the rule.
- **Recipe:** patch `solana-msg` (on older Solana, `solana-program`'s `msg!`): in the arm of `msg!`
  that formats its arguments, add a `#[cfg(feature = "certora")]` branch that only type-checks them
  inside a closure that is never called, and keep the original branch under `not`. A `cfg` inside a
  `macro_rules!` expansion is evaluated in the crate that invokes the macro, so the program's
  `certora` build gets the new form, and its deployed build and every dependency keep the original.
  A local `macro_rules! msg` in the program does not work: modules that glob-import
  `anchor_lang::prelude::*` then find `msg` ambiguous. Do not raise `--loop-iter`, and do not delete
  the line.
- **Soundness:** a panic or side effect inside a log argument is lost. That is sound for assertions;
  check the program's `msg!` arguments for calls with effects, and that no `satisfy` relies on one.

## Math libraries and `NativeInt`

### `NativeInt` is a 256-bit value

`cvlr.md` says to widen and bound in one move. The bound matters for a second reason: a `NativeInt`
is a 256-bit value in the prover, not an unbounded integer. A nondet `NativeInt` is any 256-bit word,
and arithmetic wraps at `2^256`.

- Take every operand from `u64` or `u128` nondets, or bound it, and keep every intermediate below
  `2^256`. A lemma that verified with an intermediate that can wrap is not the integer theorem.
- Comparisons are unsigned: `x >= NativeInt::from(0)` holds for every value and proves nothing.
  `slt` and `sle` are the signed comparisons.
- A fixed-point identity that cross-multiplies to degree 4 in 128-bit values (Q64.64 prices) cannot
  be stated in `NativeInt`. State it at function level instead, over calls of the program's own
  price and amount functions with ordered arguments.
- **Recognise:** a pure-math rule over `NativeInt` is VIOLATED with huge values, although the
  statement is a theorem over the integers.

### Big-integer operations (`ruint` and similar)

Reimplement each operation the rule reaches, under `cfg(feature = "certora")`, exactly over
`NativeInt`: convert a `U256` with `NativeInt::from_u256` on its four limbs, build results with
`U256::from_limbs`, and return `Err` or `None` exactly when the original does. A shift by a constant
multiple of 64 is a multiplication or division by a power of two. Define a function by its relation
where that is simpler, and keep the relation inside 256 bits. An integer square root, where the
program's function returns the floor of the root for every input:

```rust
#[cfg(feature = "certora")]
{
    let [a, b, c, d] = radicand.into_limbs();
    let x = NativeInt::from_u256(a, b, c, d);
    let (lo, hi): (u64, u64) = (nondet(), nondet());   // the root is below 2^128
    let r = NativeInt::from_u128(lo, hi);
    cvlr_assume!(r * r <= x);
    cvlr_assume!(x - r * r <= r + r);                  // x < (r + 1)^2, with no product past 2^256
    return Some(U256::from_limbs([lo, hi, 0, 0]));
}
```

Gate the model at compile time (*A runtime switch*), so the original body leaves the build. Exact,
so no property changes meaning. A rule that first gets past the pointer analysis this way can still
be vacuous for another reason: read its sanity verdict first.

### A decimal library (`rust_decimal`)

- **Recognise:** the `[3308]` "unknown statically" of its power-of-ten table in comparison,
  addition, subtraction, multiplication or division, or "Imprecision detected" on its flags words
  (multiples of 65536, values at or above `2^31`, `lo | mid << 32`).
- **Cause:** the table lookup at a runtime index, and flags packed and tested with masks and shifts
  that LLVM fuses further. `--precise-bitwise` removes the imprecision but not the `[3308]`, and the
  library's own loops then fail to unwind.
- **Recipe:** patch the locked version with a `certora` feature, enabled from the program's
  `certora` feature (`rust_decimal/certora`). Under it:
  - route the internal entry points of multiplication, division, addition and subtraction,
    comparison, `to_u64` and `trunc` to a `NativeInt` model of the value `±m / 10^s`: exact for
    comparison and `to_u64`, and for a product, sum or difference that fits 96 bits at its natural
    scale; otherwise a result rounded down or up at a nondet scale of at most 28, with at least 26
    significant digits unless exact; `Overflow` exactly when the integer part reaches `2^96`;
    division by zero exactly as the library;
  - write the flags accessors and constructors (`scale()`, `is_sign_negative()`, `is_zero()`,
    `mantissa()`, the `from_*` and `try_new` constructors) with `*`, `/` and `%`, and do every sign,
    scale and zero test inside the model through `NativeInt`: rewriting them with arithmetic in
    plain Rust is not enough, because LLVM turns them back into bit operations;
  - keep every intermediate below `2^256`; for a quotient, split off the integer part first.

  Check the model natively against the locked version on a large number of random operations, both
  signs and every scale, before you use it.
- **Soundness:** every value the library returns is admitted, and the model never fails where the
  library does not. Where the library rounds, the model admits both roundings: a property verified
  with it holds for the library, and a counterexample that depends on a rounding choice must be
  checked natively before it is called a bug. A result's representation (its scale) can differ from
  the library's while its value is equal; a rule that reads `scale()` or `mantissa()` of a result
  sees the model's. Reads of the library's `u32` words can still meet the narrow-field problem; no
  fix for that is validated.

## Rule shapes that keep verdicts honest

- **State rejections and constraints success-implies.** Call, `.unwrap()`, then assert what the check
  guarantees (`reference/author.md` and `cvlr.md` give the shape). A rule of the form "this input is
  rejected", asserting `is_err()`, is vacuous wherever the check panics instead of returning `Err`:
  `require!` in the forked Anchor, and every constraint of a fail-fast `try_accounts`.
- **One rejection rule per validator clause**, where the success shape gives an input the code
  rejects (*A validator's success-shape rule* above).
- **Probe every "never returns `Err`" claim.** An `is_ok()` rule that verifies proves nothing about
  inputs whose `Err` path is unreachable in the model. Give it a probe on an input where the code
  returns `Err`: the same pre-state, the call, `cvlr_satisfy!(r.is_err())`. It must be reached.
- **After removing a blocker, read the sanity verdict before the assertions'.** A rule that first
  gets past an error is often vacuous for a second reason further in.
- **Build the structs the program reads field by field,** in place, with `write_volatile`, never by
  value (*Narrow fields* above). Put the data a function reads where the program has it: account
  data in a loaded account, not a stack array.

## Timeouts

A rule that still times out after the steps of recipes K7 and K8 (its shape, then a bounded
stand-in for the function the statistics name, or a descent to the accounting core) is recorded as
a `prover limitation`, citing its timed-out jobs, and left. The budget is not spent on retries with
longer timeouts.
