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

**What must not be blocked, and who can block it.** Which operations must succeed, for whom, and who is in a position to stop them? A system satisfies every property of the form "if the call succeeds, the effects are correct" and is still unusable. This applies to a loop over participants. It applies to control handed to an address a participant chose. It applies to an operation gated behind a threshold or a queue position, and to a dependency on an external system that fails. Formalize it with a reverting call and an assertion that it did not revert. Model the untrusted callee as free to revert. There are two traps. A reachability or `satisfy` rule shows that one execution succeeds, which is a weaker claim. A minimum meant as a guard rail leaves a small position with no way out.

**Who the attacker is allowed to be.** For each privileged action, who performs it, and does your rule's adversary respect that? The ordinary half is that an unprivileged caller cannot reach a privileged effect. The other half is a discipline on every adversarial rule. Constrain the adversary so that it does not hold the privileges the source grants to trusted parties. A counterexample where a trusted administrator attacks the system it administers is not a finding. It crowds out the real ones. Privilege transitions belong here, including a handover that leaves a required role with no holder.

**How stale a value from elsewhere is allowed to be.** The component reads values from an oracle, another contract, another chain, or a cache. The component acts on such a value. How old is it allowed to be at that moment? What does its age cost? This applies to any read whose source updates independently of the call that reads it.

**What a re-entering actor can do.** The component hands control to an address someone else controls. At that moment, which of its own invariants are temporarily false? Ask about state, not about code shape. "The transfer happens before the write" observes the implementation. The property is different: the invariant holds at the moment control leaves, or no re-entrant path exploits the gap.

**Fees, splits and intermediaries.** Does the sum of what every party receives equal what was paid? Can a share be taken twice, skipped through another path, or applied to a quantity it was not meant for?

**Lifecycle.** Which states can the component be in? Which transitions exist? Which operations stay available in each state? The interesting properties connect the halves: an operation that survives a pause, a transition that strands no value, a state nothing leaves.

**Two roles, one address.** Two parties in a flow are the same address. What happens then, and at the extremes of an amount? When the collapse breaks an accounting step, this is one property. Otherwise it is nothing.

## Where this sits among the three sorts

Most of these land as `safety_property` or `invariant`. The ones phrased as a profitable sequence land as `attack_vector`. A safety property can state that something must be possible, not only that something must not happen. "A holder with a sufficient balance can always exit" and "no participant can make another participant's withdrawal revert" are safety properties. They are the only place the blocking questions go.
