# Running the prover and iterating on results

## Building the conf

Never hand-roll a conf — start from the autosetup base (`certora/confs/<Main>.conf`) and overlay. For component `<slug>`, write `certora/confs/<slug>.conf`:

```json
{
  ...everything from the base conf (files, compiler settings, loop_iter, hashing bounds)...,
  "verify": "<MainContract>:certora/specs/<slug>.spec",
  "parametric_contracts": ["<MainContract>"],
  "optimistic_loop": true,
  "rule_sanity": "basic",
  "wait_for_results": "all",
  "msg": "<slug> iter <N>"
}
```

- `rule_sanity: basic` is non-negotiable — it's what catches vacuous rules.
- `parametric_contracts` scopes which contracts' methods instantiate a `method f` parameter. Set it to `[<MainContract>]` by default so parametric rules range over the contract under verification. This is *not* the same knob as the `filtered { f -> f.contract == currentContract }` narrowing warned about in `cvl-pitfalls.md`: that pitfall is about not throwing away the wider all-scene-contracts check *inside* a rule. If a property should hold against a secondary in-scene contract's methods too, widen this list to include that contract rather than leaving it out.
- `msg` with an iteration counter makes runs identifiable in the prover dashboard. Allowed characters: letters, digits, spaces and `()[]'"-_.,:/\=*$` only — a `msg` containing a disallowed character (e.g. `#`) makes certoraRun abort before submitting anything. An over-256-char `msg` is not an error; certoraRun truncates it with a warning.
- To iterate on specific failing rules cheaply, add `"rule": ["ruleName", ...]` — but the completion gate requires a final run **without** any rule filter.
- The conf may need edits during the loop: adding a `files` entry (a contract you now dispatch to), or adding a `link` (`"Contract:field=Target"`). Note: certoraRun accepts a conf-level `link` key for simple top-level storage links even though autosetup itself expresses the links it resolved as a CVL `links` block in the call-resolution spec — both mechanisms are valid and coexist; put new links wherever is clearer and keep the edit minimal. Note edits in the commentary.

## Running

A full run takes minutes to ~2h (`"global_timeout": 7200` caps it), longer than a foreground tool call may live — run it in the background, redirect to a log, and poll:

```bash
cd <project_root>
certoraRun certora/confs/<slug>.conf > certora/logs/<slug>_run<N>.log 2>&1   # background this
```

With `wait_for_results: all` the command submits to the cloud, streams the prover log while waiting, prints the report link (`https://prover.certora.com/output/<user>/<job>?anonymousKey=<key>`), and on completion prints a listing of *failing* rules only (or a bare success message when everything verified). Do not try to parse per-rule verdicts out of stdout — get them from the web report or the treeView JSON (method 2 below).

**Typecheck-only gate:** `certoraRun <conf> --compilation_steps_only` is a fast (~1 min) syntax/type check — run it after every spec edit before paying for a full run (it's cheap enough to run in the foreground).

## Reading results

Statuses per rule: `VERIFIED`, `VIOLATED`, `TIMEOUT`, `SANITY_FAILED`, `SKIPPED`, `ERROR`. A parametric rule/invariant has one instance per method — the rule counts as verified only if **every** instance is.

For per-rule statuses and counterexamples:

1. **Web report** (preferred for a human): the printed `/output/` link → rule tree → call trace.
2. **Programmatic**: the run's full output is downloadable without login using the anonymousKey from the link:
   ```bash
   curl -s "https://prover.certora.com/jobData/<user>/<job>?anonymousKey=<key>" | jq -r .zipOutputUrl
   curl -sL "<zipOutputUrl>?anonymousKey=<key>" -o out.tar.gz && tar xzf out.tar.gz
   # append the key with '&' instead of '?' if zipOutputUrl already contains a '?'
   ```
   The archive usually extracts to a single top-level directory — descend into it first (`*/Reports/treeView/`). `Reports/treeView/treeViewStatus_<N>.json` (take the highest N) holds the rule tree with statuses; each violated leaf references an output JSON next to it whose `callTrace` is the counterexample. When reading a trace, skip "Setup" / "Global State" / "Evaluate branch condition" / "unknown loop source code" noise nodes.

   Shortcut: after a completed run certoraRun already writes the ready-to-use archive URL to `.certora_internal/.zip-output-url.txt`, so you can skip the `jobData` call and go straight to the download. The full archive can be hundreds of MB — you only need it to read a counterexample `callTrace`; for statuses alone the web report or the streamed stdout summary is enough.
3. **Local runs** (`--use-local-runner`-style setups / no cloud): results land in `emv-<N>-certora-<date>/Reports/` created in the directory certoraRun was invoked from (take the highest N), with the same structure.

## Counterexample analysis (per violated rule)

Reconstruct the concrete failing scenario from the trace — what state the prover chose, which method ran, where execution "went wrong" — keeping the original property in mind. Account for ghosts, hooks, and summaries in the trace. Then classify the root cause; that decides the fix:

| Root cause | Fix |
|---|---|
| **Impossible starting state** (e.g. balance > totalSupply prestate) | Best: formulate the missing structural invariant, prove it, `requireInvariant` it in the rule/preserved block. Second: a "justification rule" proving the assumption valid, then a bare `require` referencing it. Last resort: a `require` with a comment documenting the trust assumption. |
| **HAVOC from an unresolved call, callee IS in the scene** | The prover couldn't resolve/link it: add a `link` in the conf, or a `DISPATCHER` summary — but mind the unsoundness caveat below. |
| **HAVOC, callee NOT in the scene** | Write a summary that *soundly* models the callee, typically with ghost variables for its state. Never `NONDET` on a side-effecting function (results become meaningless); never mark ghost state `persistent` just to survive the havoc. |
| **Completely unresolved call (no selector)** | Dispatch-list summary: reason about what the callee could be at that site. |
| **The CEX looks like a genuine contract bug** — of *any* property sort: an attack_vector the prover confirms is reachable, a safety_property the code violates, or an invariant the code breaks | Mark the rule expected-to-fail with a written reason — this is a *finding* for the report, not a spec problem. Do NOT weaken the spec to make it pass; a red rule exposing a real bug is the intended result. (The other, distinct reason to mark expected-to-fail is an exhausted prover limitation — see the row below. Record which reason applies, so the report can separate real findings from limitations.) |
| **A spurious CEX that survives every sound reformulation** (a prover over-approximation, not a code bug) | Mark expected-to-fail with the reason "prover limitation" — but only after genuinely exhausting principled fixes. This is a coverage gap in the report, not a finding. |
| **Parametric rule persistently fails on a method that genuinely shouldn't be covered** | `filtered { f -> ... }` — only at ~95% certainty that exclusion is correct. |
| **The property itself is wrong** | Skip it with justification (judge must accept); remove its rules. |
| **SANITY_FAILED** | The assert is unreachable: your `require`s contradict the code's own assumptions, or a non-`@withrevert` call always reverts under your preconditions. Hunt the contradiction; don't paper over it. |
| **TIMEOUT** | Reduce scope: split the rule, summarize expensive irrelevant methods (`DELETE` for timeout-causing irrelevant ones), check the user-guide timeout page. |
| **ERROR** | Read the rule's error message in the report; often conf/scene problems (missing file, bad link). |

Anything else: consult the docs and make *principled* changes — never brute-force random edits hoping the prover accepts.

### DISPATCHER caveat

`DISPATCHER` unsoundly assumes the callee is one of the scene contracts. Fine when that's certain (a linked, known implementation). For generic callees like ERC20 tokens — where the scene happens to contain *a* token but the contract could face *any* token — use the hybrid approach: in a CVL summary, dispatch to known in-scene implementers by `calledContract`, and fall back to a sound ghost model for unknown callees.

## The generator's inner loop

This is the write↔prove loop a generator runs on its own component (the *judge* is a separate batch the orchestrator spawns between generation rounds — see SKILL.md Phase 6; a generator never runs the judge itself):

1. Edit spec → typecheck-only run → full (or rule-filtered) run.
2. Analyze every non-verified rule per the table; apply the fix; re-run. Iterate prover-only through tight counterexample-fix cycles.
3. Stop and return when a full **unfiltered** run has every rule VERIFIED or expected-to-fail (or you've exhausted principled fixes). Return the spec, `property_rules`, and the full prover status; the orchestrator's judge batch reviews it, and if it rejects, you get the feedback on your next round.

Keep a per-component commentary file (`certora/properties/<slug>.commentary.md`): decisions, summaries introduced and their soundness story, trust assumptions, expected failures with the CEX scenario and whether each is a genuine issue or a prover limitation. This becomes the raw material for the report.

## Outcome mapping for the report

VERIFIED→GOOD, VIOLATED→BAD, ERROR→ERROR, TIMEOUT→TIMEOUT, anything else→UNKNOWN. Record the `/output/` link per run so verdicts remain auditable.
