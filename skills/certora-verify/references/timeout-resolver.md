# Resolving a timeout with the hosted timeout resolver

The timeout resolver is a hosted AutoProver agent. Give it one prover run and one rule of that run. It searches for a pen-and-paper proof of the property and distills the lemmas the proof rests on. It instruments the source with inert hooks that encode those lemmas, discharges the lemmas in Lean, and runs the prover again. It returns patches for the source and the spec, the Lean file, and the evidence that the rule now verifies.

Use it in two cases:

- A rule ends `TIMEOUT` and the manual playbook in `prover-loop.md` did not fix it. Goal `resolve_timeout`.
- A rule is `VERIFIED` but its run takes long, and a split into lemma-backed pieces is worth the cost. Goal `modularize`.

Do not use it for `VIOLATED`, `SANITY_FAILED`, or `ERROR`. Those have their own rows in the playbook.

## What it needs

- The `certora-cloud` command on PATH. Install it with `uv tool install 'git+ssh://git@github.com/Certora/certora-cloud-cli.git'`. The first command opens a browser login and stores the credentials in the keyring. On a machine with no browser, stop and ask the user to log in once.
- The environment of the run. Pass `--env prod` for a run on `prover.certora.com`, `--env stg` for `vaas-stg.certora.com`, and `--env dev` for `vaas-dev.certora.com`. A run URL from another environment is refused.
- The run link that `certoraRun` printed. Remove the `anonymousKey` part. The service strips it in any case.
- The rule name, and the property the rule formalizes: its `title`, `description`, and `sort` from `certora/properties/<slug>.properties.json`. The `rules` list in `certora/properties/<slug>.property_rules.json` maps the property to its rules.

You must own the run, or be a member of the owner's organization with read access to it. The service checks this before it starts anything, and the job reads the run with your identity. An anonymous key grants nothing. In this flow you submitted the run yourself, so this holds. If the service answers 404 "Run not found.", the run is not yours to resolve.

If the service answers 409, the resolver is not enabled in that environment. Say so and continue with the manual playbook.

## Starting a run

```bash
certora-cloud aiss workflow resolve-timeout --env prod \
    --run-url "https://prover.certora.com/output/<user>/<job>/" \
    --rule <ruleName> \
    --property-title "<title>" \
    --property-text "<description>" \
    --property-sort invariant|safety_property|attack_vector \
    --goal resolve_timeout \
    --app-description "<two or three sentences on the protocol, from certora/analysis/application.json>" \
    --token-budget 50
```

Optional arguments:

- `--contract <Name>` and `--method <sig>` narrow a parametric rule to one instantiation.
- `--time-budget <seconds>` caps the wall clock. The default is 21600 (six hours).
- `--token-budget <usd>` caps the model spend. The default is 50 USD. A run of the resolver on a mid-size lending protocol cost about 6 USD.

The command prints the workflow as JSON. Keep `workflow.id` and `pre_audit_jobs[0].id`. Record both in the commentary file of the component.

## Waiting

A run takes between 30 minutes and a few hours. Poll it the way you poll a prover run, with a progress note on each poll:

```bash
certora-cloud aiss workflow get --env prod <workflow_id>
```

If the executor job's `job_status` is `SUCCEEDED`, `FAILED`, or `CANCELED`, the job is done. `SUCCEEDED` means the agent finished and wrote a result. It does not mean the rule verified. Read `result.json` for that. `FAILED` means the agent crashed. Read the logs:

```bash
certora-cloud aiss workflow logs --env prod <workflow_id>
```

## Reading the result

```bash
certora-cloud aiss workflow download-all --env prod <workflow_id> --output-dir certora/resolver/<ruleName>
```

The directory then holds:

- `result.json`. The `status` field is one of `resolved`, `gave_up`, `unresolved`, `invalid_input`, `dependency_error`, `budget_exhausted`, `cancelled`, `failed`. Only `resolved` means the rule verifies. A `resolved` result carries `executive_summary` and `why_sound`. Its `prover` record holds the final run link and the status of every path of the rule. Its `lean` record holds the Lean verdict.
- `proof.md`. The informal proof the lemmas came from. Present whenever the proof search completed, whatever the status.
- `source.patch` and `spec.patch`. Unified diffs against the sources the run was submitted with. The `patch_base` field of `result.json` names the directory they apply in, relative to the sources root.
- `<ruleName>_lemmas.lean`. The Lean development that discharges the lemmas.
- `ap_report/job_info.json`. The usage manifest. Not needed for the flow.

For `gave_up`, `unresolved`, or `budget_exhausted`, the rule still times out. Read `proof.md`. The proof often names the lemma that the prover cannot see, and that is a good starting point for a manual summary or a split. Then continue with the manual playbook. Do not weaken the property.

## Applying a resolution

1. Apply the patches inside the directory `patch_base.run_dir` names, relative to the project root. `.` means the project root itself.

   ```bash
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/source.patch
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/spec.patch
   ```

   The source patch touches helper contracts under `certora/` and sometimes the contracts in the scene. The spec patch adds a CVL summary for each hook and adjusts the rule. Read both before you apply them.
2. Copy the Lean file to `certora/lean/<ruleName>_lemmas.lean` and keep it with the spec. It is the certificate for the lemmas the hooks assume.
3. Typecheck, then run the full unfiltered prover run as usual. The completion gate does not change: the resolver's own final run is evidence, not a substitute for your run.
4. In the commentary file, record the resolver workflow id and the final run link from `result.json`. Record each hook with its inertness argument from `why_sound`, and the Lean file. In the report, these hooks are trust assumptions discharged in Lean, and the reviewer needs to see them.

## Cost

Each resolver run submits several cloud prover runs under your key and spends model tokens under the budget you pass. Start one resolver run per rule, not one per iteration. If a rule times out again after a resolution, go back to the manual playbook before starting a second run.
