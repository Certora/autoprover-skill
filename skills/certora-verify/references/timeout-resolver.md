# Resolving a timeout with the hosted Timeout Resolver

The Timeout Resolver is a hosted AutoProver agent. Give it one prover run and one rule of that run. It searches for a pen-and-paper proof of the property and distills the lemmas the proof rests on. It instruments the source with inert hooks that encode those lemmas, discharges the lemmas in Lean, and runs the prover again. It returns patches for the source and the spec, the Lean file, and the evidence that the rule now verifies.

You drive it through the Certora Runs API, the same API that drives AutoProver runs. Create a run, poll it, read its result, then list and download its artifacts. Every call is a plain HTTPS request with a Certora API key.

Use it in two cases:

- A rule ends `TIMEOUT` and the manual playbook in `prover-loop.md` did not fix it. Goal `resolve_timeout`.
- A rule is `VERIFIED` but its run takes long, and a split into lemma-backed pieces is worth the cost. Goal `modularize`.

Do not use it for `VIOLATED`, `SANITY_FAILED`, or `ERROR`. Those have their own rows in the playbook.

## What it needs

- The organization API key in the environment variable `CERTORAKEY`, the same key the prover runs on. The user creates it on the API Access page of the organization, which is the **API** entry in the sidebar at `app.certora.com`. Four permissions matter here: "Create runs", "Read runs and results", "Cancel runs", and "Download artifacts". Permissions cannot be changed after the key is created. A key without "Download artifacts" completes the paid run and then cannot fetch one file. The Runs API also needs a plan that includes it. If the variable is empty, or the key lacks these permissions, stop and ask the user for a key that has them. Never print the key.
- The API host. Production is `https://app.certora.com`. The dev and staging hosts are for Certora staff. The commands below keep the host in `CERTORA_API_BASE_URL`, the name the API's own documentation uses.
- The run link that `certoraRun` printed, on `prover.certora.com`. Remove the `anonymousKey` part. The service strips it in any case. The run and the key must belong to the same environment. A key from `app.certora.com` resolves runs on `prover.certora.com` and nothing else.
- The rule name, and the property the rule formalizes: its `title`, `description`, and `sort` from `certora/properties/<slug>.properties.json`. The `rules` list in `certora/properties/<slug>.property_rules.json` maps the property to its rules.

You must own the run, or be a member of the owner's organization with read access to it. The service checks this before it starts anything, and the job reads the run with your identity. An anonymous key grants nothing. In this flow you submitted the run yourself, so this holds.

Before the first run, read the key's permissions:

```bash
CERTORA_API_BASE_URL=https://app.certora.com
curl -sS "$CERTORA_API_BASE_URL/v2/access" -H "Authorization: Bearer $CERTORAKEY"
```

`key.scopes` must hold `runs:create`, `runs:read`, `runs:cancel`, and `artifacts:read`. If one is absent, name it, tell the user the key has to be created again with that permission, and stop. Do not test `capabilities.run_types`: it is the same fixed list for every key and proves nothing.

Whether the organization is allowed to run the resolver shows on the create call, not here. `403 plan_gate` means the plan does not include the Runs API, and its `detail` names the plan that does. `503 integration_disabled` means an administrator turned API access off. `503 app_disabled` means the resolver is off in this environment. Both 503s carry `retryable: true`, and neither clears by retrying. Report the code and continue with the manual playbook.

## How the API answers

Every call carries `Authorization: Bearer $CERTORAKEY`. Request and reply bodies are JSON. Every reply carries a `request_id`.

A refused call answers with `application/problem+json`. The body holds `status`, `code`, `detail`, `retryable`, and sometimes `field_errors`. When you report a refusal, quote `code`, `detail`, and `request_id`. A 422 names the bad field in `field_errors`. A 429 carries a `Retry-After` header in seconds. Wait that long, then retry. Read `retryable` as a hint only: `code` decides, and this document names each code that is worth another call. A request body is capped at 256 KiB. A resolver request is far below that.

`409 idempotency_conflict` means the key is already bound to a different request. Any change to the body counts, a reworded property or summary among them. Reaching this refusal without meaning to is a sign that the body was rebuilt instead of replayed, and the first request launched. Do not mint a key to get past it. List the runs for that `client_reference`, and poll the run that exists. A new key belongs only to an attempt you mean to start, and its body is recorded with it.

## Starting a run

Start one run per rule. The create call needs an `Idempotency-Key` header of 1 to 200 characters, and the same string goes in the body as `client_reference`. Build the key out of the input it launches: `<slug>-<ruleName>-<job>`, where `<job>` is the job segment of the run link. The record behind a key never expires once it holds a run or a balance hold. A key reused against a later prover run therefore arrives with a different body, and it earns `409 idempotency_conflict` in place of a run. When you first send a key, write it and the exact body you sent to `certora/resolver/keys.json`, under its component and rule. On a retry or a resume, send the stored body under the stored key. Do not build the request again, because a body you rebuild is a body that can differ. A retry with the same key and the same body returns the same run and starts nothing. A fresh key starts a new run, and a new run is a new charge.

```bash
curl -sS -X POST "$CERTORA_API_BASE_URL/v2/timeout-resolver-runs" \
  -H "Authorization: Bearer $CERTORAKEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <slug>-<ruleName>-<job>" \
  -d '{
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
  }'
```

Optional fields:

- `contract` and `method` narrow a parametric rule to one instantiation.
- `time_budget` caps the wall clock, in seconds. Omit it to accept the cap of the service.
- `app_description` is optional, but it helps the proof search. When `certora/analysis/application.json` exists, send it.

The reply is `202` with a `run` object. Keep `run.id`. Record it in the commentary file of the component.

A `503 launch_outcome_unknown` is the one refusal that leaves the outcome open: the run has possibly started. Retry the create call with the original key and the unchanged body, a few seconds apart. The service looks for a recovered run before it replays anything, so the original key is what surfaces a run that did start. Never mint a second key for the same attempt, because that starts a second paid run. A `202` naming a run settles it, whether that is the replayed success or a run the service recovered: poll that run. Another `launch_outcome_unknown`, or a `503 launch_recovery_pending`, means the outcome is still open. Retry the same key about five times over a few minutes, then stop and hand the user the key and the run link. Launch nothing else.

The run list tells you whether a run exists:

```bash
curl -sS "$CERTORA_API_BASE_URL/v2/runs?run_type=timeout_resolver&client_reference=<slug>-<ruleName>-<job>" \
  -H "Authorization: Bearer $CERTORAKEY"
```

A run in the list is the one to poll. An empty list proves nothing: `client_reference` is written only after a launch returns a run id, so an ambiguous launch leaves it unset while the run exists. An empty list is never permission to create.

## Waiting

A run takes between 30 minutes and a few hours. Poll every 60 seconds, with a progress note on each poll:

```bash
curl -sS "$CERTORA_API_BASE_URL/v2/runs/<run_id>" -H "Authorization: Bearer $CERTORAKEY"
```

`run.status` is one of `queued`, `running`, `finalizing`, `succeeded`, `failed`, `cancelling`, `cancelled`. Stop polling at `succeeded`, `failed`, or `cancelled`. The other values mean the run is still moving. `run.progress` is null while the run is `queued`. From `running` on, `run.progress.phase` names the current step.

`succeeded` means the agent finished and wrote a result. It does not mean the rule verified. Read the result document for that. `run.result.available` says whether that document can be served. It stays false on a succeeded run whose document was never written. `failed` means the run did not complete. Then `run.failure` holds `code`, `detail`, and `retryable`. Quote `code` and `detail` in your report. Do not start a new run because `retryable` is true. Ask the user first.

To stop a run, cancel it:

```bash
curl -sS -X POST "$CERTORA_API_BASE_URL/v2/runs/<run_id>/cancel" \
  -H "Authorization: Bearer $CERTORAKEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

A `202` means the cancellation was taken, and the run moves through `cancelling` to `cancelled`. A `200` means the run was past cancelling already, `finalizing` included, and the reply's `run.status` is the real state. Neither answer is an error.

## Reading the result

Read the result document once the run is `succeeded`. It is not a downloadable artifact, and this route is the only way to read it.

```bash
curl -sS "$CERTORA_API_BASE_URL/v2/runs/<run_id>/result" -H "Authorization: Bearer $CERTORAKEY"
```

The reply body is `{request_id, result}`. The document is `result.data`. The envelope carries `result.schema_version`, the string `"1"`, beside `result.run_id` and `result.run_type`. The document has a `schema_version` of its own, the integer `1`. Inside `result.data`, rely on `operation`, `status`, `message`, `run`, `products`, `outcome`, `compiler_output`, and `error`. Every one of those keys is always there. An unpublished or unreached value is `null`, and `products.patches` is then `[]`. Decide on the value, never on the presence of the key. Do not depend on anything else.

A refusal on this route is not always a wait. `409 result_not_ready` means the document is not there yet, and the artifact route answers `409 artifacts_not_ready` for the same reason. Poll both a few more times. If a succeeded run keeps answering 409, the document was never written: report that and continue with the manual playbook. `502 result_unavailable` means the document is there but cannot be served. The artifacts still list, so download them and read `proof.md`. `409 result_unavailable` happens only on a failed or cancelled run. Never start a second run to get around any of these.

Take these from `result.data`:

- `status` is one of `resolved`, `gave_up`, `unresolved`, `invalid_input`, `dependency_error`, `budget_exhausted`, `cancelled`, `failed`. Only `resolved` means the rule verifies. The last two do not reach this route. The run's own status reports them.
- `message` says why the run ended the way it did.
- `products` names the files the run wrote, as `proof`, `patches` (a list of names) and `lean_file`.
- `run.patch_base.run_dir` names the directory the patches apply in.
- `outcome` is present for `resolved` and `gave_up`. A `resolved` outcome carries `executive_summary` and `why_sound`. Its `prover` record holds the status of every path of the rule, and the final run link in `outcome.prover.link`. Its `lean` record holds the Lean verdict.

Then list the artifacts. Before the run is `succeeded`, the list call answers 409 with code `artifacts_not_ready`.

```bash
curl -sS "$CERTORA_API_BASE_URL/v2/runs/<run_id>/artifacts" -H "Authorization: Bearer $CERTORAKEY"
```

The reply holds `artifacts` and `next_cursor`. Each artifact has `name`, `path`, `category`, `size_bytes`, `last_modified_at`, and `download_url`. A page holds the resolver's public files found in that page of everything the run stored. The run's other objects are private, so a page can hold none of the public files. `next_cursor` is non-null while objects remain. Download what the page holds, then list again with `?cursor=<next_cursor>`, until `next_cursor` is null. Each `download_url` is a presigned link that expires after a short time, so download each page before you list the next one. If a download is refused, list that page again and use the fresh link. Then check what you collected against `products`.

```bash
mkdir -p certora/resolver/<ruleName>
curl -sS -o "certora/resolver/<ruleName>/<name>" "<download_url>"
```

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
3. Typecheck, then run the full unfiltered prover run as usual. The completion gate does not change: the resolver's own final run is evidence, not a substitute for your run.
4. In the commentary file, record the resolver run id and the final run link from `outcome.prover.link`. Record each hook with its inertness argument from `why_sound`, and the Lean file. In the report, these hooks are trust assumptions discharged in Lean, and the reviewer needs to see them.

## Cost

A resolver run is charged to your organization's balance. At launch the service holds a fixed amount, and at settlement it refunds the unused part. `run.billing.reserved_usd` is the hold and `run.billing.charged_usd` the settled charge. Start one resolver run per rule, not one per iteration. If a rule times out again after a resolution, go back to the manual playbook before starting a second run.
