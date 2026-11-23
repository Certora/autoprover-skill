# Resolving a timeout with the hosted Timeout Resolver

The Timeout Resolver is a hosted AutoProver agent. Give it one prover run and one rule of that run. It searches for a pen-and-paper proof of the property and distills the lemmas the proof rests on. It instruments the source with inert hooks that encode those lemmas, discharges the lemmas in Lean, and runs the prover again. It returns patches for the source and the spec, the Lean file, and the evidence that the rule now verifies.

You drive it through the Certora Runs API: create a run, poll it, read its result, then list and download its artifacts. `runs-api.md` holds what every Runs API service shares: the key, how the API answers, starting a run exactly once, waiting, reading the result, and cost. This page says what is the resolver's own.

Use it in two cases:

- A rule ends `TIMEOUT` and the manual playbook in `prover-loop.md` did not fix it. Goal `resolve_timeout`.
- A rule is `VERIFIED` but its run takes long, and a split into lemma-backed pieces is worth the cost. Goal `modularize`.

Do not use it for `VIOLATED`, `SANITY_FAILED`, or `ERROR`. Those have their own rows in the playbook.

## What it needs

- The organization API key in `CERTORAKEY` (`runs-api.md`, *The key*). Five permissions matter here: "Use Certora Prover", so that the same key runs `certoraRun`, and for the resolver "Create runs", "Read runs and results", "Cancel runs", and "Download artifacts". A key without "Download artifacts" completes the paid run and then cannot fetch one file. If the variable is empty, or the key lacks these permissions, stop and ask the user for a key that has them.
- The run link that `certoraRun` printed. Both shapes work. Send an app link (`<base>/orgs/<org>/jobs/<uuid>/report`) as it is, when its host is the API host. Send a legacy link (`https://prover.certora.com/output/<user>/<job>/`) without the `anonymousKey` part. The service strips that part in any case. The run and the key must belong to the same environment. A key from `app.certora.com` resolves runs on `prover.certora.com` and nothing else.
- The rule name, and the property the rule formalizes: its `title`, `description`, and `sort` from `certora/properties/<slug>.properties.json`. The `rules` list in `certora/properties/<slug>.property_rules.json` maps the property to its rules.

You must own the run, or be a member of the owner's organization with read access to it. The service checks this before it starts anything, and the job reads the run with your identity. An anonymous key grants nothing. In this flow you submitted the run yourself, so this holds.

`key.scopes` must hold `runs:create`, `runs:read`, `runs:cancel`, and `artifacts:read`. If one is absent, name it, tell the user the key has to be created again with that permission, and stop. When an organization limit from `runs-api.md` (*The key*) shows, continue with the manual playbook.

## Starting a run

Start one run per rule, exactly once, as `runs-api.md` (*Starting a run exactly once*) describes. Build the idempotency key out of the input it launches: `<slug>-<ruleName>-<job>`, where `<job>` is the job segment of the run link. If that is longer than 200 characters, shorten the slug and the rule name, never the job. A key reused against a later prover run arrives with a different body, a reworded property or summary among the changes, and it earns `409 idempotency_conflict` in place of a run. Record the key and the exact body in `certora/resolver/keys.json`, under its component and rule.

`POST <base>/v2/timeout-resolver-runs`, as JSON, with the bearer token and an
`Idempotency-Key` header holding `<slug>-<ruleName>-<job>`. The body:

```json
{
  "run_url": "https://prover.certora.com/output/<user>/<job>/",
  "rule": "<ruleName>",
  "property": {
    "title": "<title>",
    "description": "<description>",
    "sort": "invariant|safety_property|attack_vector"
  },
  "goal": "resolve_timeout",
  "app_description": "<two or three sentences on the protocol, from certora/analysis/application.json>",
  "client_reference": "<slug>-<ruleName>-<job>"
}
```

Optional fields:

- `contract` and `method` narrow a parametric rule to one instantiation.
- `time_budget` caps the wall clock, in seconds. Omit it to accept the cap of the service.
- `app_description` is optional, but it helps the proof search. When `certora/analysis/application.json` exists, send it.

The reply is `202` with a `run` object. Keep `run.id`. Record it in the commentary file of the component.

A `503 launch_outcome_unknown` is handled as `runs-api.md` describes. To find a run that exists, read `GET <base>/v2/runs?run_type=timeout_resolver&client_reference=<slug>-<ruleName>-<job>`.

## Waiting

A run takes between 30 minutes and a few hours. Wait for it in the foreground, as `runs-api.md` (*Waiting*) describes. `succeeded` means the agent finished and wrote a result. It does not mean the rule verified: read the result document for that. To stop a run, cancel it (`runs-api.md`, *Waiting*).

## Reading the result

Read the result document once the run is `succeeded`, as `runs-api.md` (*Reading the result*) describes. It is not a downloadable artifact, and that route is the only way to read it. The document has a `schema_version` of its own, the integer `1`. Inside `result.data`, rely on `operation`, `status`, `message`, `run`, `products`, `outcome`, `compiler_output`, and `error`. Every one of those keys is always there. An unpublished or unreached value is `null`, and `products.patches` is then `[]`. Decide on the value, never on the presence of the key. Do not depend on anything else.

The artifact route answers `409 artifacts_not_ready` for the same reason the result answers `409 result_not_ready`. Poll both a few more times. If a succeeded run keeps answering 409, the document was never written: report that and continue with the manual playbook. `502 result_unavailable` means the document is there but cannot be served. The artifacts still list, so download them and read `proof.md`.

Take these from `result.data`:

- `status` is one of `resolved`, `gave_up`, `unresolved`, `invalid_input`, `dependency_error`, `budget_exhausted`, `cancelled`, `failed`. Only `resolved` means the rule verifies. The last two do not reach this route. The run's own status reports them.
- `message` says why the run ended the way it did.
- `products` names the files the run wrote, as `proof`, `patches` (a list of names) and `lean_file`.
- `run.patch_base.run_dir` names the directory the patches apply in.
- `outcome` is present for `resolved` and `gave_up`. A `resolved` outcome carries `executive_summary` and `why_sound`. Its `prover` record holds the status of every path of the rule, and the final run link in `outcome.prover.link`. Its `lean` record holds the Lean verdict.

Then list the artifacts. Before the run is `succeeded`, the list call answers 409 with code `artifacts_not_ready`.

Read `GET <base>/v2/runs/<run_id>/artifacts`.

The reply holds `artifacts` and `next_cursor`. Each artifact has `name`, `path`, `category`, `size_bytes`, `last_modified_at`, and `download_url`. A page holds the resolver's public files found in that page of everything the run stored. The run's other objects are private, so a page can hold none of the public files. `next_cursor` is non-null while objects remain. Download what the page holds, then list again with `?cursor=<next_cursor>`, until `next_cursor` is null. Each `download_url` is a presigned link that expires after a short time, so download each page before you list the next one. If a download is refused, list that page again and use the fresh link. Then check what you collected against `products`.

Save each file under `certora/resolver/<ruleName>/<name>`, creating that directory first.

Do not send the `Authorization` header to a download link. The link carries its own credentials.

The directory then holds the files `products` names:

- `proof.md`. The informal proof the lemmas came from. Present whenever the proof search completed, whatever the status.
- `source.patch` and `spec.patch`. Unified diffs against the sources the run was submitted with. A side that did not change gets no patch, so `products.patches` names one of the two, both, or neither.
- `<ruleName>_lemmas.lean`. The Lean development that discharges the lemmas. `products.lean_file` is null on a run that reached no Lean proof.

For `gave_up`, `unresolved`, or `budget_exhausted`, the rule still times out. Read `proof.md`. The proof often names the lemma that the prover cannot see, and that is a good starting point for a manual summary or a split. Then continue with the manual playbook. Do not weaken the property.

For `invalid_input`, the request did not match the run. Read `message` and correct the run link, the rule, the contract or the method. With a different input, create a run again under a new idempotency key. For `dependency_error`, the service got no usable workspace out of the run, a run that does not compile being one case. `compiler_output` then holds what the compiler printed. Report `message` and continue with the manual playbook.

## Applying a resolution

1. Apply the patches that `products.patches` names, inside the directory `run.patch_base.run_dir` names, relative to the project root. `.` means the project root itself. A patch the list does not name is not on disk, so do not run `git apply` on it.

   ```bash
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/source.patch
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/spec.patch
   ```

   The source patch touches helper contracts under `certora/` and sometimes the contracts in the scene. The spec patch adds a CVL summary for each hook and adjusts the rule. Read both before you apply them.
2. Copy the Lean file to `certora/lean/<ruleName>_lemmas.lean` and keep it with the spec. It is the certificate for the lemmas the hooks assume.
3. Typecheck, then run the full prover run (every part) as usual. The completion gate does not change: the resolver's own final run is evidence, not a substitute for your run.
4. In the commentary file, record the resolver run id and the final run link from `outcome.prover.link`. Record each hook with its inertness argument from `why_sound`, and the Lean file. In the report, these hooks are trust assumptions discharged in Lean, and the reviewer needs to see them.

## Cost

A resolver run is charged as `runs-api.md` (*Cost*) describes. At launch the service holds a fixed amount. Before a launch, read `billing.balance_usd` from `GET <base>/v2/access`. If it is below the hold, tell the user before you launch. Start one resolver run per rule, not one per iteration. If a rule times out again after a resolution, go back to the manual playbook before starting a second run.
