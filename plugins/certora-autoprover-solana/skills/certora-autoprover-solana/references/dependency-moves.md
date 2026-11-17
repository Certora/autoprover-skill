# Moving a program's dependencies onto a version setup supports

`certora-cvlr setup` verifies a program on one Solana platform generation, and only on the
generations its message names under `Supported:`. It refuses a program that builds an older
Solana, and a program whose dependency graph links two Solana lines at once ("mixed
generations"). Many such programs verify after a change to their dependency versions alone, with
no change to the program's source. This file says how to make that change. It also says when the
change is not possible.

A dependency move is a verification-only change, in the same class as the forks `setup` patches
in. A property proved after a move is a property of the program built with the moved
dependencies. Whether it carries over to the deployed build is a judgement about the difference.
The move from Solana 1.17 to 1.18 changes little that a program's own logic sees. A move that
also changes a dependency's major version, or that edits a dependency's source, changes more,
and the report must say so.

## Before you start

- Tell the user what setup refused and that you propose a dependency move. Show the edits you
  plan, and wait for their go-ahead. Never move a dependency without it.
- Keep `Cargo.lock`. Re-resolve from it with `cargo update -p <crate>`, which changes only
  the crates you name and what they force. Never delete the lock: a fresh resolution also
  floats unrelated crates and git dependencies to newer releases, which can need crates the
  project never used.
- Save the lock first (`cp Cargo.lock certora/logs/Cargo.lock.before-move`), so that the
  report can show the difference.
- Run every `cargo update` and `cargo tree` with a current stable cargo (`cargo +stable ...`).
  A project often pins an old toolchain in `rust-toolchain.toml`, and the cargo of that
  toolchain cannot always read the lock format that `setup` writes.
- Record every edit in `certora/analysis/dependency_moves.json`: a list of
  `{file, change, reason}`, plus `{lock_before, lock_after}` for each Solana line that moved.
  Phase 7 reads it.

## Which line to move to

- A program older than every supported generation: move it to the oldest supported one.
  For a program on Solana 1.14 to 1.17 with a 1.18 generation supported, that is 1.18.
  `cvlr-solana` itself requires `solana-program` 1.18 or newer, so this move is needed
  before a CVLR dependency can resolve at all.
- Mixed generations: move to the line the program names in its own `Cargo.toml`. Find what pulls
  in the other line with `cargo +stable tree -i solana-program@<version> -p <package>`, and
  repeat it for any other platform crate that `setup` named with two versions. Often one or two
  dependencies are the whole cause: an oracle SDK, an `spl-*` helper crate, a crate with a
  feature that selects a Solana line.
- A program that names a line newer than every supported generation: if its dependencies
  allow it, move it to the newest supported one.

## Moving an older program up

1. Change every Solana requirement in the workspace `Cargo.toml` and in each member's
   `Cargo.toml` to the target, for example `solana-program = "1.18.0"`. That covers
   `solana-program`, `solana-sdk`, and the other `solana-*` crates the project names.
   Change requirements of the form `~1.17.18`, `<1.17` or `=1.17.x` too.
2. A git dependency whose own `Cargo.toml` caps Solana below the target: copy its source at
   the commit the lock names (cargo keeps it under `~/.cargo/git/checkouts/`), change the
   requirement in the copy, and redirect the dependency to the copy:

   ```toml
   [patch."https://github.com/<org>/<repo>.git"]
   <crate> = { path = "../<copy>/<path to the crate>" }
   ```

   Patch every crate of that repository that the program links. If you patch only one of them,
   the path dependencies between them pull in a second copy. A git dependency whose requirement
   already allows the target needs no patch.
3. Re-resolve: `cargo +stable update -p solana-program`. If that changes nothing, the
   `solana-*` crates in the lock pin each other with `=`, so name the one that holds the pin
   and the exact version: `cargo +stable update -p solana-zk-token-sdk --precise 1.18.26`,
   for example. If cargo then names another crate whose locked version is too old (for
   example, `num_enum`), add `-p <crate>@<locked version>` to the same command.
4. Check with `cargo +stable tree -p <package> -i solana-program` that one Solana line is
   left, then run `setup` again.

## Merging mixed generations

Try these in order, and stop at the first that leaves one line:

1. If the dependency's requirement allows the target line, move the extra copy:
   `cargo +stable update -p solana-program@<extra version> --precise <target version>`.
   If cargo says that a sibling crate pins the extra version exactly, run the same command on
   that sibling (for example, `solana-zk-token-sdk@2.0.0 --precise 1.18.17`).
2. If a feature of the dependency selects the line, choose the feature for the target line
   (for example, `default-features = false` with the dependency's own `solana-v3` feature).
3. If another release of the dependency is on the target line, move to it. A release that is
   already in the lock for another crate is the cheapest choice.
4. If no release fits, copy the registry crate (from `~/.cargo/registry/src/`), change
   its requirement in the copy, and redirect it with `[patch.crates-io] <crate> = { path =
   "../<copy>" }`. If the copy then fails to compile because an API moved between the two
   lines, the fix is a source edit in the dependency: list it in the report with the edit.

`setup` also refuses a program that links one of its forked crates more than once (for
example, two `anchor-lang` releases). For that refusal, use the same steps to merge them onto
one release.

## Build failures after a move

A move can bring a dependency onto a newer Rust compiler than the one its locked version
supports. If a crate fails to build with an error that it owns (not your edit), move it to the
newest release within its semver range: `cargo +stable update -p <crate>@<locked version>`.
Two seen often:

- `ahash` 0.7.6 to 0.7.7 and 0.8.5 to 0.8.6 fail with `unknown feature stdsimd`. A
  `cargo +stable update -p ahash@<version>` moves them to 0.7.8 and 0.8.12.
- `blake3` releases after 1.6.1 can need a newer compiler than the project pins:
  `cargo +stable update -p blake3 --precise 1.6.1`.

A host build script that compiles C (for example, `blake3`) can fail with `'assert.h' file
not found`. The cause is that the compiler `setup` chose for the SBF build reached the host
build too. Set the
host compiler for the host target alone and run `setup` again, for example
`CC_aarch64_apple_darwin=/usr/bin/clang` on an Apple silicon machine or
`CC_x86_64_unknown_linux_gnu=cc` on Linux.

When `setup`'s refusal names a remedy itself (for example, "move to fixed 1.23.1"), that remedy
is a dependency move too: apply it with the same steps and record it.

## When a move is not possible

Stop, tell the user, and do not continue to Phase 4, in these cases:

- The program, or a git dependency it links, uses Anchor 0.28. Anchor 0.28 requires
  `solana-program` `>=1.14, <1.17`, and Certora's fork of it has the same requirement. Reaching
  1.18 means porting the program to Anchor 0.29 or newer, which is a change to its source, not to
  its dependencies.
- The program uses Anchor older than 0.26. Certora's Anchor fork has no release before 0.26.

Anchor 0.26 and 0.27 are not on this list. Their requirements (`"1.13.5"` and `"1.14.16"`) are
caret ranges that cargo resolves to 1.18, so move them like any other dependency. If the build
then fails inside `anchor-lang` itself, treat it as the 0.28 case.
- A dev-dependency pins an old Solana exactly (an SDK or a test client crate). Cargo resolves
  dev-dependencies into the same lock, so the pin blocks the move although the program does not
  link it. Ask the user whether to remove that dev-dependency for verification. If they agree,
  remove it and record the removal like any other move.
- A copied dependency needs source edits beyond a changed import or requirement, or the move
  needs a new major release of a dependency whose API the program uses.

In each case, name the crate that blocks and the version it requires, so the user can decide
whether a port is worth it.
