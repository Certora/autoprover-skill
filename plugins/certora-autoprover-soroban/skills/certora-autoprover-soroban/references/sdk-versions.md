# Moving a contract onto a soroban-sdk release setup supports

`certora-cvlr setup` verifies a contract on one soroban-sdk generation, and only on the
generations its message names under `Supported:` — at this pin, soroban-sdk 22.x and 25.x, each
with a minimum patch release the message states. `cvlr-soroban` is cut per SDK generation, because
its helpers return the SDK's own types, so there is nothing to verify a contract on another
generation against. Two refusals look alike and take different answers.

## Locked below the minimum of a supported generation

A contract that declares `soroban-sdk = "22.0.0"` and is locked to a release below the minimum is
on the supported generation and still unresolvable: cargo reports the conflict as a version error
naming neither side's reason, so `setup` says it first. The fix is a re-resolution inside the same
generation, with no change to the contract's source:

- Tell the user what setup refused and that you propose the update. Show the command, and wait
  for their go-ahead. Never move a dependency without it.
- Keep `Cargo.lock`. Save it first (`cp Cargo.lock certora/logs/Cargo.lock.before-move`), then
  re-resolve only the SDK: `cargo update -p soroban-sdk --precise <minimum>` (or a newer release
  of the same generation). Never delete the lock: a fresh resolution also floats unrelated crates
  and git dependencies, which can need crates the project never used.
- Run the `cargo update` with a current stable cargo (`cargo +stable ...`). A Soroban project
  often pins an old toolchain in `rust-toolchain.toml`, and that cargo cannot always read the
  lock format in play.
- Record the edit in `certora/analysis/dependency_moves.json`: `{file, change, reason}` plus
  `{lock_before, lock_after}`. Phase 7 reads it.

A patch-level move within one SDK generation changes little that a contract's own logic sees; the
report still says the verdicts are about the build with the moved lock.

## On a generation setup does not support

A contract on soroban-sdk 20, 21, 23, 24, or a newer generation than the pin supports, is not a
dependency move. Changing a contract's SDK major version changes the host functions, the types and
sometimes the contract's own source; the result would be a different build from the one the user
ships, in ways no report caveat covers. Do not attempt it. Stop, relay setup's reason, and tell
the user which generations this pin supports; if they migrate the contract themselves, verify the
migrated contract.

## Two SDK generations in one workspace

A workspace whose members disagree on the SDK generation builds two copies of `soroban-sdk`, and
`setup` refuses the mix. When the contract under verification and the contracts it imports with
`contractimport!` are on one generation and only a dev- or test-only member is on another, the
move is confined to that member and is the user's call, under the same discipline as above.
Otherwise treat it as an unsupported generation: stop and relay.
