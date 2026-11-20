# Property classes: the questions to work through

Naming a failure mode is not the same as asking a question. "Consider front-running" produces nothing. "An actor sees this call before it lands. What is that worth to them?" That question produces a property, or a reason there is none.

Work this list for every component in Phase 4, before you draft. For each class, record the property it produced, or one line on why the component does not expose that surface. A class nobody mentions reads as a class nobody considered. That is how half a system ends up with no properties and the other half with twenty.

## Before any property: name who is harmed

Take each property and assume it is false. Name who is worse off. If the answer is "nobody, the system just behaves differently", the text describes the implementation. It is not a property.

The tell is simple. You wrote the property by reading one function body. A property derived from the code cannot fail, because the code is its definition. When the code is wrong, a green rule then certifies the bug instead of catching it.

## The classes

**Value conservation.** Can the total of everything the system owes exceed what it holds? Who can make that happen? This applies wherever claims are recorded against a pool: shares, debt, queued payouts, escrow, accrued rewards. Watch for claims outside the obvious accumulator, such as a pending queue or an uncollected fee.

**Who absorbs a change in value over time.** A flow captures an amount or rate at one moment, then acts on it later. In between, the backing moves through yield, loss, fee or a rate update. Someone absorbs that movement. This applies to every two-step flow: request then settle, queue then finalize, deposit then redeem, quote then execute. State the intended attribution. Do not state that the settled amount equals the amount recorded earlier. That form restates the implementation. When the attribution is wrong, that form is exactly the bug, and a green rule certifies it as correct.

**What going first is worth.** An actor sees a pending call. What is it worth to transact immediately before or after it? This applies wherever observable state feeds a price, rate, share count or fee, and some function updates that state. Express it as the absence of a profitable sequence. A call that commits value at a rate the caller cannot bound is exposed by construction. The missing bound is itself a finding. `reference/properties.md` excludes front-running as an off-chain event: no rule can say who lands first, since transaction ordering decides that. The profit is on-chain, and a rule can state it: run the first actor's function, then the victim's, and assert that the victim gets what it would have got alone, or that the first actor ends with no more than it started with.

**Which way each division rounds, and who gains.** Every division favors one side. This applies to any conversion between units, any truncation to a coarser precision, and any pair of functions that convert in opposite directions. State it this way: a round trip never returns more than it consumed, and a truncated remainder is refunded or accounted rather than dropped.

**The empty state and the first participant.** The component holds nothing, or one unit. What happens then? Can someone move its holdings directly and bypass the accounting meant to track them? This applies wherever a price or share is a ratio of two quantities, and either quantity changes from outside.

**What must not be blocked, and who can block it.** Which operations must succeed, for whom, and who is in a position to stop them? A system satisfies every property of the form "if the call succeeds, the effects are correct" and is still unusable. This applies to a loop over participants. It applies to a call into a contract a participant chose. It applies to an operation gated behind a threshold or a queue position, and to a dependency on an external contract that fails. Formalize it as a function call that must succeed under the stated conditions. There are two traps. A reachability or `cvlr_satisfy!` rule shows that one execution succeeds, which is a weaker claim. A minimum meant as a guard rail leaves a small position with no way out.

**Who the attacker is allowed to be.** For each privileged action, who performs it, and does your rule's adversary respect that? The ordinary half is that an unprivileged caller cannot reach a privileged effect. The other half is a discipline on every adversarial rule. Constrain the adversary so that it does not hold the privileges the source grants to trusted parties. A counterexample where a trusted administrator attacks the system it administers is not a finding. It crowds out the real ones. Privilege transitions belong here, including a handover that leaves a required role with no holder.

**How stale a value from elsewhere is allowed to be.** The component reads values from an oracle, another contract, the ledger (timestamp, sequence), or a cached entry in its own storage. The component acts on such a value. How old is it allowed to be at that moment? What does its age cost? This applies to any read whose source updates independently of the call that reads it.

**What a callee leaves behind.** The component calls another contract and then goes on reading its own storage. At that moment, which of its own invariants are temporarily false? Soroban's host forbids reentering a contract that is already on the call stack, so the callee cannot call back in — but the caller can still trust a value it read before the call that the call was supposed to change, and a `try_` call that failed changed nothing while the caller may proceed as if it had. Ask about state, not about code shape.

**Fees, splits and intermediaries.** Does the sum of what every party receives equal what was paid? Can a share be taken twice, skipped through another path, or applied to a quantity it was not meant for?

**Lifecycle.** Which states can the component be in? Which transitions exist? Which operations stay available in each state? The interesting properties connect the halves: an operation that survives a pause, a transition that strands no value, a state nothing leaves.

**Two roles, one address.** Two address arguments of a function are the same address, or two parties are the same signer. What happens then, and at the extremes of an amount? When the collapse breaks an accounting step, this is one property. Otherwise it is nothing.

## Where this sits among the three sorts

Most of these land as `safety_property` or `invariant`. The ones phrased as a profitable sequence land as `attack_vector`. A safety property can state that something must be possible, not only that something must not happen. "A holder with a sufficient balance can always exit" and "no participant can make another participant's withdrawal fail" are safety properties. They are the only place the blocking questions go.

## Classes Soroban adds

A Soroban contract's inputs are its arguments and its storage, and its gate is `require_auth`. Most Soroban exploits are an authorization the contract never asked for, an address it trusted without tying it to state, or an initialization it left open — so ask each of these of every function that reads or writes storage.

**Who must authorize.** Which address must have authorized this call for it to do what it does? A property states that the function succeeds only when that address authorized it — and that the address is the one the *state* names (the stored admin, the position's owner, the `from` of a transfer), not merely whichever address an argument happened to carry. The contract asking `require_auth` of an attacker-supplied address is the bug this class exists to catch. Formalize with `is_auth` as `reference/author.md`'s authorization section shows: record the condition, call, assert it held.

**Initialization, and what runs before it.** Who can run the constructor or `initialize`, can it run twice, and what does each function do on a contract where it has not run? A re-runnable initializer that overwrites the admin is a takeover. A function that works on uninitialized storage works on default values nobody chose. In a contract with an `initialize` function, these are properties; in one with a `__constructor` (soroban-sdk 22 and later), the host runs it once at deploy, so what remains checkable is what it establishes.

**Which entry, under which key.** Storage is key-value: an entry read under a key spelled differently from the one the writer used is a different entry, and the same logical key stored in two durabilities (instance, persistent, temporary) is two entries. A property ties each read to the entry the writer wrote: the balance read is the balance written, the admin checked is the admin stored. Rules cannot observe TTL or archival — that is host economics, excluded in `reference/properties.md` — but a value's round trip through the right key is the contract's own code.

**Which contract is called.** A cross-contract call to an address taken from an argument is a call into whatever contract the caller named. A property states that the function invokes only the contract the state names (the stored token address, the configured oracle) — that is this contract's code, checkable without following the call.

**Token movements.** When the contract moves SEP-41 tokens, does what it records match what the transfer moved, for exactly the parties involved? With `setup --token-model` on, balances are readable in rules and conservation is stated directly; the verdict then assumes a standard token (no fee on transfer, no hook), and the commentary must say so. Without the model, state the property over the contract's own storage, or skip it naming the unfollowed call.

**Arithmetic a release build does not check.** A release build may wrap an integer operation that overflows instead of failing. Check `overflow-checks` under `[profile.release]` in the workspace `Cargo.toml` first: with it set, an overflow fails the invocation and the host rolls the call back. Where the build wraps, a property states that the result is in range, or that the function rejects inputs that would leave it. Saying that a function "cannot panic" is not a property: a panic only fails the invocation. Amounts are `i128`, so ask separately about the negative range: a function that accepts a negative amount walks every balance check backwards.
