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

A full run can take up to ~2h (`"global_timeout": 7200` caps it), longer than a single foreground command should hold your session. Aim for far less: see *Keep each run under about 15 minutes* below. Start it detached, with its output in a log and its PID in a file:

```bash
cd <project_root>
nohup certoraRun certora/confs/<slug>.conf > certora/logs/<slug>_run<N>.log 2>&1 &
echo $! > certora/logs/<slug>_run<N>.pid
```

### Waiting for a run

Wait for the run in the foreground, with a bounded loop that blocks on the certoraRun process. One call of it:

```bash
pid=$(cat certora/logs/<slug>_run<N>.pid)
end=$(( $(date +%s) + 90 ))       # stay under the timeout of this call, see below
while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 15; done
if kill -0 "$pid" 2>/dev/null; then echo RUNNING; else echo ENDED; fi
tail -n 5 certora/logs/<slug>_run<N>.log
```

If it prints `RUNNING`, write a one-line progress note (elapsed time and the last log line) and run the same call again. Repeat until it prints `ENDED`. `ENDED` means certoraRun exited, not that the job ended: check the job on the server (*Checking a job on the server* below) before you read results.

The bound must stay under the timeout of the call that runs the loop. Shell tools often stop a call after 2 minutes by default, and some then move it to the background and promise a notice when it ends. That is the wake-up wait this section forbids. The bound of 90 seconds fits a 2-minute timeout. To wait longer per call, pass a longer timeout on every wait call and set the bound about 2 minutes under it. Claude Code's shell tool, for example, defaults to 120 seconds and accepts up to `timeout: 600000` (10 minutes) per call, which fits a bound of 480. If you cannot set the timeout per call, keep 90.

Do not wait any other way:

- Do not start a background monitor, a watcher script, a scheduled check or a timer, and do not end your turn and expect a notice to wake you when the job ends. In real runs these wake-ups did not come, monitors expired, and the agent sat idle for hours after its job had finished.
- **A sub-agent never ends its turn while it owns a running job.** A job here is a certoraRun job or a Timeout Resolver run. The sub-agent repeats the wait call until the process ends, or until the resolver run reaches `succeeded`, `failed` or `cancelled` (`timeout-resolver.md`, *Waiting*). It reads the result, and only then continues or hands over. A sub-agent that must stop early, for example at a usage limit, says in its last message which job it owns and the job's link or resolver run id.
- The orchestrator does not take a quiet sub-agent as proof that its job is still running. Before it reports a sub-agent as idle or waiting, it checks the state of that sub-agent's job on the server: *Checking a job on the server* below for a certoraRun job, `GET <base>/v2/runs/<run_id>` for a resolver run. If the job has ended, it resumes the sub-agent and tells it which job ended.

With `wait_for_results: all` the command submits to the cloud, streams the prover log while waiting, prints the report link, and on completion prints a listing of *failing* rules only (or a bare success message when everything verified). Do not try to parse per-rule verdicts out of stdout — get them from the web report or the rule tree (method 2 below).

The streamed log prints a `Violated: <rule>-rule_not_vacuous` line for each rule (and each method of a parametric rule). That is the healthy outcome: the vacuity check asserts the rule's path is unreachable, and the violation is the prover finding a path. A vacuous rule is the one whose check is *not* violated, and it is reported as `SANITY_FAILED`.

### Report links and job ids

The report link comes in two shapes, depending on the certora-cli version and the key:

- `https://prover.certora.com/output/<user>/<job>?anonymousKey=<key>`: the legacy link. `<job>` is 32 hex characters.
- `https://<host>/orgs/<org>/jobs/<uuid>/report`: the app link. `<uuid>` is the same job id, written as a UUID with dashes. Remove the dashes to get the 32-character form. This link has no `anonymousKey`, so you read the job through the API with `CERTORAKEY` (method 2 below).

Wherever this skill says `<job>`, take it from whichever shape certoraRun printed. Newer certora-cli versions still write the legacy link, as `verification_report_url` in `.vscode_extension_info.json` inside the run's build directory under `.certora_internal/`. Use it where a step asks for a `prover.certora.com` link.

### When the log ends in an error

certoraRun streams the job's log from the server. If that stream fails (`ERROR: Error Status:: <code>` and `Server is currently unavailable`), certoraRun stops, prints `Violations were found` and exits with code 1. This can happen at any point, while the job is still queued or running. Neither the message nor the exit code is a verdict. Check the job on the server and wait for `SUCCEEDED` before you read results, and take the verdicts from the results, not from the log.

### Checking a job on the server

Ask the data API with `CERTORAKEY`, through the `prover-cli` that ships with autosetup. `<job>` is the job id in either form: the UUID from the app link, or the 32-hex `job_id` in `.certora_internal/.certora_recent_jobs.json`.

```bash
"$(uv tool dir)"/ai-composer/bin/prover-cli --job-id <job> --status-only --format json
```

`SUCCEEDED` means the job finished and its verdicts are final. `FAILED` and `HALTED` (for example the `global_timeout` limit) mean it ended without a full result. Any other status means it is still queued or running. If the command fails, the check failed: do not read it as "still running". `--full-report --format text` also prints the verdict counts.

### Keep each run under about 15 minutes

Each full run should finish in about 15 minutes. A rule that runs for an hour costs the cloud time and also stalls the whole round, because the barrier waits for the slowest component. When a run, or one rule in it, takes clearly longer, fix it before the next full run:

1. **Summarize expensive internals the property does not depend on.** Find what the slow rule spends its time in: heavy math, loops, hashing, deep internal calls. If the property does not depend on how that code computes its result, replace it with a sound summary: a ghost or an uninterpreted function with the facts the rule needs, or `DELETE` for a method the rule never calls. Record each summary and its soundness argument in the commentary. Never summarize the code the property is about.
2. **Split rules.** Give each case its own rule, or narrow a parametric rule into several rules, each over a group of methods. While you iterate, run only the slow rules with a `rule` filter.
3. **A timeout that remains** goes to the Timeout Resolver (`timeout-resolver.md`), once the steps above are exhausted.

The completion gate still needs one full unfiltered run.

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

     The archive exists only once the job has ended. A 404 means it is not ready yet: check the job on the server (above) and wait for `SUCCEEDED`.

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
| **TIMEOUT** | Reduce scope as in *Keep each run under about 15 minutes*: summarize expensive internals the property does not depend on (`DELETE` for timeout-causing irrelevant methods), split the rule, check the user-guide timeout page. If that does not resolve it, hand the run and the rule to the hosted Timeout Resolver (`timeout-resolver.md`), which finds the lemmas the proof rests on, encodes them as inert hooks with Lean certificates, and returns patches. |
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

VERIFIED→GOOD, VIOLATED→BAD, ERROR→ERROR, TIMEOUT→TIMEOUT, anything else→UNKNOWN. Record the report link per run, in the shape certoraRun printed it, so verdicts remain auditable.
