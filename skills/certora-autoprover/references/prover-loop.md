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

A full run takes minutes to ~2h (`"global_timeout": 7200` caps it), longer than a single foreground command should hold your session — start it detached, redirect to a log, and poll the log:

```bash
cd <project_root>
nohup certoraRun certora/confs/<slug>.conf > certora/logs/<slug>_run<N>.log 2>&1 &
echo $! > certora/logs/<slug>_run<N>.pid
# progress:  tail -n 20 certora/logs/<slug>_run<N>.log
# liveness:  kill -0 $(cat certora/logs/<slug>_run<N>.pid)
```

With `wait_for_results: all` the command submits to the cloud, streams the prover log while waiting, prints the report link (`https://prover.certora.com/orgs/<org>/jobs/<uuid>/report`), and on completion prints a listing of *failing* rules only (or a bare success message when everything verified). Do not try to parse per-rule verdicts out of stdout — get them from the web report or the output archive (method 2 below).

The streamed log prints a `Violated: <rule>-rule_not_vacuous` line for each rule (and each method of a parametric rule). That is the healthy outcome: the vacuity check asserts the rule's path is unreachable, and the violation is the prover finding a path. A vacuous rule is the one whose check is *not* violated, and it is reported as `SANITY_FAILED`.

**Typecheck-only gate:** `certoraRun <conf> --compilation_steps_only` is a fast (~1 min) syntax/type check — run it after every spec edit before paying for a full run (short enough to wait on directly instead of detaching).

## Reading results

Statuses per rule: `VERIFIED`, `VIOLATED`, `TIMEOUT`, `SANITY_FAILED`, `SKIPPED`, `ERROR`. A parametric rule/invariant has one instance per method — the rule counts as verified only if **every** instance is.

For per-rule statuses and counterexamples:

1. **Web report** (preferred for a human): the printed report link → rule tree → call trace.
2. **Programmatic**: download the run's output archive with `CERTORAKEY`.

   - The job id: certoraRun records every job it submits in `.certora_internal/.certora_recent_jobs.json`, under the project's path, one entry per job with its `job_id` and `notify_msg` (the run's `--msg`). Take the entry for this run. When several runs go in parallel, give each its own `--msg` and match on it.
   - Fetch and unpack:

     ```bash
     curl -fsSL -H "Authorization: Bearer $CERTORAKEY" \
       "https://data-api.certora.com/v1/domain/jobs/<job_id>/f/outputs" -o certora/logs/<slug>_run<N>.tar.gz
     mkdir -p certora/logs/<slug>_run<N>_out && tar xzf certora/logs/<slug>_run<N>.tar.gz -C certora/logs/<slug>_run<N>_out
     ```

     The endpoint redirects to a presigned storage URL, and that storage rejects a request carrying the `Authorization` header. `curl -L` drops the header when the redirect changes host. A client that keeps it on redirect, such as Python's `urllib`, gets a 400.

   The archive extracts to a single top-level directory. Read it with the results parser that ships with autosetup, rather than writing your own:

     ```bash
     "$(uv tool dir)"/ai-composer/bin/python -c '
     import sys, pathlib
     from composer.prover.results import read_and_format_run_result
     results = read_and_format_run_result(pathlib.Path(sys.argv[1]), "evm")
     if isinstance(results, str): sys.exit(results)
     for r in results.values():
         print(r.path.rule, r.path.contract or "", r.path.method or "", r.status, sep="\t")
         for m in r.error_messages: print("  error:", m)
         if r.counterexample: print(r.counterexample.render())
     ' certora/logs/<slug>_run<N>_out/*/
     ```

     It prints one line per rule, and one per method for a parametric rule or invariant: rule, contract, method, status. Under each violated one it prints the counterexample: the failing assert, its spec line, and the call trace with the values filled in and the setup frames dropped.

     When you need something the parser does not print, read the archive directly. `Reports/treeView/treeViewStatus_<N>.json` (take the highest N) holds the rule tree: each node has `name`, `status`, `errors`, `children` (one per method for a parametric rule) and `output`, a list of `rule_output_<k>.json` file names in the same directory. That file holds `assertMessage`, `jumpToDefinition` and the `callTrace` tree (`message`, `childrenList`). Each `message` is `{text, arguments}`: `text` is a template, and `'{i}'` in it stands for `arguments[i].value`.

   `.certora_internal/<job_id>.zip` is the input bundle certoraRun uploaded, not the output. The full output archive can be hundreds of MB — you only need it to read a counterexample; for statuses alone the web report or the streamed stdout summary is enough.
3. **Local runs** (`--use-local-runner`-style setups / no cloud): results land in `emv-<N>-certora-<date>/Reports/` created in the directory certoraRun was invoked from (take the highest N); pass the `emv-<N>-certora-<date>/` directory to the parser above.

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
| **TIMEOUT** | Reduce scope: split the rule, summarize expensive irrelevant methods (`DELETE` for timeout-causing irrelevant ones), check the user-guide timeout page. If that does not resolve it, hand the run and the rule to the hosted Timeout Resolver (`timeout-resolver.md`), which finds the lemmas the proof rests on, encodes them as inert hooks with Lean certificates, and returns patches. |
| **ERROR** | Read the rule's error message in the report; often conf/scene problems (missing file, bad link). |

Anything else: consult the docs and make *principled* changes — never brute-force random edits hoping the prover accepts.

### DISPATCHER caveat

`DISPATCHER` unsoundly assumes the callee is one of the scene contracts. Fine when that's certain (a linked, known implementation). For generic callees like ERC20 tokens — where the scene happens to contain *a* token but the contract could face *any* token — use the hybrid approach: in a CVL summary, dispatch to known in-scene implementers by `calledContract`, and fall back to a sound ghost model for unknown callees.

## The generator's inner loop

This is the write↔prove loop the generator role runs on its own component (judging is a separate step that happens after generation — see SKILL.md Phase 6; the generator never judges its own spec in the same pass, and in sequential mode judging is a deliberate fresh-context re-read of the files on disk):

1. Edit spec → typecheck-only run → full (or rule-filtered) run.
2. Analyze every non-verified rule per the table; apply the fix; re-run. Iterate prover-only through tight counterexample-fix cycles.
3. Stop when a full **unfiltered** run has every rule VERIFIED or expected-to-fail (or you've exhausted principled fixes). Hand over the spec, `property_rules`, and the full prover status; the judging step reviews it, and if it rejects, its written feedback is the input to the next generation round.

Keep a per-component commentary file (`certora/properties/<slug>.commentary.md`): decisions, summaries introduced and their soundness story, trust assumptions, expected failures with the CEX scenario and whether each is a genuine issue or a prover limitation. This becomes the raw material for the report.

## Outcome mapping for the report

VERIFIED→GOOD, VIOLATED→BAD, ERROR→ERROR, TIMEOUT→TIMEOUT, anything else→UNKNOWN. Record the report link per run so verdicts remain auditable.
