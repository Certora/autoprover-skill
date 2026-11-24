# Hash collisions: which to assume away and which to report

A hash collision is two different inputs with the same hash value. The work an attacker needs to find one decides whether you can assume it away. That work depends on two facts: how many bits of the hash the code keeps, and who chooses the inputs.

## What the prover assumes

The prover treats the full 256-bit `keccak256` as injective (distinct inputs give distinct outputs). A rule over full hashes never gets a collision counterexample, and needs no `require` against one.

When the code keeps only part of a hash, that part is not injective. Examples are a cast to `uint128`, `bytes20` or `address`, a mask, a shift, and a `%`. The prover can then pick two inputs whose kept bits are equal. A counterexample that rests on such a pair is not spurious by default. It is a collision, and this file decides whether an attacker can find it.

An encoding ambiguity is not a hash collision. Examples are `abi.encodePacked` over two dynamic values, or a key that leaves out a field that tells two records apart. The two inputs to the hash are then already the same bytes, so the collision costs nothing. Never assume it away.

## The work an attacker needs

For a hash that keeps `n` bits:

- Collision (birthday bound): about 2^(n/2) hashes. If the attacker chooses both inputs, this bound applies.
- Second preimage: about 2^n hashes. If the attacker must match an input that someone else chose and fixed first, this bound applies. If the attacker can match any one of 2^k such inputs, the work drops to about 2^(n-k).
- Preimage (an input for a given hash value): about 2^n hashes.

| Bits kept | Typical source | Collision | Second preimage |
|---|---|---|---|
| 256 | `keccak256`, `bytes32` key | 2^128 | 2^256 |
| 160 | `address` from `CREATE2`, `bytes20(keccak256(...))` | 2^80 | 2^160 |
| 128 | `uint128`, `bytes16`, a 128-bit mask | 2^64 | 2^128 |
| 64 | `uint64`, an 8-byte tag | 2^32 | 2^64 |
| 32 | `bytes4` function selector | 2^16 | 2^32 |

The rule: if the attack costs at least 2^128 hashes, assume the collision away. Report every cheaper one. For scale, the Bitcoin network computes about 2^94 hashes a year, so 2^80 is in reach of a funded attacker and 2^64 is cheap.

## Which bound applies

Read who controls each input to the hash, and when.

- If one actor can supply both inputs, use the collision bound. A permissionless registry, where anyone can store data under a key derived from that data, is the usual case. The attacker hashes many candidates of two kinds, finds a pair that matches, and stores the harmful one first. If the attacker proposes the input that a victim later uses, use it too.
- If the other input was fixed before the attacker acted, and the attacker cannot change it, use the second-preimage bound. Use it only then. An existing honest user's id is an example.
- When you cannot tell, use the collision bound.

So a full `keccak256` key is safe either way. A 160-bit or 128-bit key is safe against second preimages, but not against collisions. A key of 64 bits or fewer is never safe.

## Properties (Phase 4)

If a key, an id or an address comes from part of a hash, ask two questions. Can two different inputs get the same key? Who gains if they do? State the answer as a property of the protocol. The data stored under a key is the data its own input describes. A second input with the same key cannot overwrite that data, be read as it, or take its place. Do not restate the cast. Look for three patterns:

- a store that silently keeps the first writer's data,
- a lookup by key that trusts the stored data,
- a check that compares keys but not the inputs behind them.

## Counterexamples (Phase 6)

When a counterexample rests on two different inputs whose kept hash bits are equal, read the code that computes the key. Find how many bits it keeps, and which bound applies under *Which bound applies*.

- At least 2^128: the collision is out of reach. Add a narrowly scoped `require` that the two specific inputs in the rule have different keys. Comment it with the bits kept, the bound, and the work. List it as a trust assumption.
- Less than 2^128: this is a finding. Mark the rule expected-to-fail with the reason "reachable hash collision", and keep it with no collision `require`. You can add a companion rule that requires distinct keys and is VERIFIED. It shows that the collision is the only path to the violation.

Never put a no-collision `require` in a shared helper or a `preserved` block where it covers rules you did not check against this file.

## Report (Phase 7)

A reachable collision is a finding like any other. Give the bits kept, the bound that applies, the work in hashes, and what the colliding input gets the attacker. Grade its severity by that impact, then lower it only when the work is near the 2^128 limit. A no-collision `require` at 2^128 or more goes under trust assumptions, with the bits kept and the bound.
