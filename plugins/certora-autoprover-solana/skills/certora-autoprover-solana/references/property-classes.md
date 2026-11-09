# Property classes: the questions to work through

Naming a failure mode is not the same as asking a question. "Consider front-running" produces nothing. "An actor sees this call before it lands. What is that worth to them?" That question produces a property, or a reason there is none.

Work this list for every component in Phase 4, before you draft. For each class, record the property it produced, or one line on why the component does not expose that surface. A class nobody mentions reads as a class nobody considered. That is how half a system ends up with no properties and the other half with twenty.

## Before any property: name who is harmed

Take each property and assume it is false. Name who is worse off. If the answer is "nobody, the system just behaves differently", the text describes the implementation. It is not a property.

The tell is simple. You wrote the property by reading one function body. A property derived from the code cannot fail, because the code is its definition. When the code is wrong, a green rule then certifies the bug instead of catching it.

## The classes

**Value conservation.** Can the total of everything the system owes exceed what it holds? Who can make that happen? This applies wherever claims are recorded against a pool: shares, debt, queued payouts, escrow, accrued rewards. Watch for claims outside the obvious accumulator, such as a pending queue or an uncollected fee.

**Who absorbs a change in value over time.** A flow captures an amount or rate at one moment, then acts on it later. In between, the backing moves through yield, loss, fee or a rate update. Someone absorbs that movement. This applies to every two-step flow: request then settle, queue then finalize, deposit then redeem, quote then execute. State the intended attribution. Do not state that the settled amount equals the amount recorded earlier. That form restates the implementation. When the attribution is wrong, that form is exactly the bug, and a green rule certifies it as correct.

**What going first is worth.** An actor sees a pending call. What is it worth to transact immediately before or after it? This applies wherever observable state feeds a price, rate, share count or fee, and some function updates that state. Express it as the absence of a profitable sequence. A call that commits value at a rate the caller cannot bound is exposed by construction. The missing bound is itself a finding.

**Which way each division rounds, and who gains.** Every division favors one side. This applies to any conversion between units, any truncation to a coarser precision, and any pair of functions that convert in opposite directions. State it this way: a round trip never returns more than it consumed, and a truncated remainder is refunded or accounted rather than dropped.

**The empty state and the first participant.** The component holds nothing, or one unit. What happens then? Can someone move its holdings directly and bypass the accounting meant to track them? This applies wherever a price or share is a ratio of two quantities, and either quantity changes from outside.

**What must not be blocked, and who can block it.** Which operations must succeed, for whom, and who is in a position to stop them? A system satisfies every property of the form "if the call succeeds, the effects are correct" and is still unusable. This applies to a loop over participants. It applies to a CPI into a program a participant chose. It applies to an operation gated behind a threshold or a queue position, and to a dependency on an external program that fails. Formalize it as a handler call that must return `Ok` under the stated conditions. Model the untrusted callee as free to fail. There are two traps. A reachability or `cvlr_satisfy!` rule shows that one execution succeeds, which is a weaker claim. A minimum meant as a guard rail leaves a small position with no way out.

**Who the attacker is allowed to be.** For each privileged action, who performs it, and does your rule's adversary respect that? The ordinary half is that an unprivileged caller cannot reach a privileged effect. The other half is a discipline on every adversarial rule. Constrain the adversary so that it does not hold the privileges the source grants to trusted parties. A counterexample where a trusted administrator attacks the system it administers is not a finding. It crowds out the real ones. Privilege transitions belong here, including a handover that leaves a required role with no holder.

**How stale a value from elsewhere is allowed to be.** The component reads values from an oracle, another program's account, a sysvar, or a cache. The component acts on such a value. How old is it allowed to be at that moment? What does its age cost? This applies to any read whose source updates independently of the call that reads it.

**What a callee can do with the accounts it is given.** The component makes a CPI into a program someone else controls, passing accounts it then reads again. At that moment, which of its own invariants are temporarily false, and which of the passed accounts can the callee change? Ask about state, not about code shape. Solana forbids reentry into the caller, but not a callee writing an account the caller passed as writable, nor the caller trusting data it read before the call.

**Fees, splits and intermediaries.** Does the sum of what every party receives equal what was paid? Can a share be taken twice, skipped through another path, or applied to a quantity it was not meant for?

**Lifecycle.** Which states can the component be in? Which transitions exist? Which operations stay available in each state? The interesting properties connect the halves: an operation that survives a pause, a transition that strands no value, a state nothing leaves.

**Two roles, one account.** Two accounts in an instruction are the same account, or two parties are the same signer. What happens then, and at the extremes of an amount? When the collapse breaks an accounting step, this is one property. Otherwise it is nothing.

## Where this sits among the three sorts

Most of these land as `safety_property` or `invariant`. The ones phrased as a profitable sequence land as `attack_vector`. A safety property can state that something must be possible, not only that something must not happen. "A holder with a sufficient balance can always exit" and "no participant can make another participant's withdrawal revert" are safety properties. They are the only place the blocking questions go.

## Classes Solana adds

An instruction's accounts are inputs the caller chooses. Most Solana exploits are an account the program trusted without checking it, so ask each of these of every handler that reads or writes an account.

**Who signed.** Which accounts must have signed for this instruction to do what it does? A property states that the handler fails when that signer is missing, or is not the key the state names (an owner, an authority, an admin). Check the key against the state, not only the `is_signer` flag.

**Who owns the account.** Every account the handler deserializes and trusts must be owned by the program that defines its type: this program for its own state, the token program for a token account. A property states that an account owned by another program is rejected. In Anchor, `Account<T>` checks this and `AccountInfo` / `UncheckedAccount` do not.

**Which account it is.** An account of the right type and owner can still be the wrong one: another user's position, another pool's vault, a mint the pool does not use. A property ties each account to the state that names it (`has_one`, a stored key, a PDA derived from it), and states that a substitute is rejected.

**Where a PDA comes from.** A PDA's seeds decide who can make one and which state it belongs to. A property states that the handler accepts only the address its seeds and canonical bump derive, and that two different states cannot derive the same address.

**Which program a CPI calls.** A CPI into a program id taken from an account is a call into whatever program the caller passed. A property states that the handler invokes only the program it means to (the token program, the system program, a known oracle).

**Closing and resizing an account.** Closing must move every lamport out, and leave nothing a later instruction can mistake for a live account in the same transaction. Resizing must keep the account rent-exempt and initialize what it adds. A property states each of those, and that a closed account cannot be used again.

**Arithmetic a release build does not check.** A Solana release build may wrap an integer operation that overflows instead of failing. Where the program uses unchecked arithmetic, a property states that the result is in range, or that the handler rejects inputs that would leave it. Saying that a handler "cannot panic" is not a property: a panic only fails the transaction.

**The accounts the instruction does not declare.** `remaining_accounts`, and accounts a handler indexes by position, carry no constraint unless the code checks them. A property states what the handler must check before trusting one.
