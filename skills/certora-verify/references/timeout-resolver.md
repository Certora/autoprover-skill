# Resolving a timeout with the hosted timeout resolver

The timeout resolver is a hosted AutoProver agent. Give it one prover run and one rule of that run. It searches for a pen-and-paper proof of the property and distills the lemmas the proof rests on. It instruments the source with inert hooks that encode those lemmas, discharges the lemmas in Lean, and runs the prover again. It returns patches for the source and the spec, the Lean file, and the evidence that the rule now verifies.

You drive it through the Zeus public API, the same API that drives AutoProver runs. Create a run, poll it, list its artifacts, and download them. Every call is a plain HTTPS request with a Zeus API key.

Use it in two cases:

- A rule ends `TIMEOUT` and the manual playbook in `prover-loop.md` did not fix it. Goal `resolve_timeout`.
- A rule is `VERIFIED` but its run takes long, and a split into lemma-backed pieces is worth the cost. Goal `modularize`.

Do not use it for `VIOLATED`, `SANITY_FAILED`, or `ERROR`. Those have their own rows in the playbook.

## What it needs

- A Zeus API key in the environment variable `CERTORA_API_KEY`. The user creates the key on the API page of the organization in the Zeus dashboard. The key needs the permissions "Create runs", "Read runs and results", and "Cancel runs". This is not `CERTORAKEY`, the prover key. If the variable is empty, stop and ask the user for a key. Never print the key.
- The API host. Production is `https://app.certora.com`. The dev and staging hosts are for Certora staff. The commands below keep the host in `ZEUS`.
- The run link that `certoraRun` printed, on `prover.certora.com`. Remove the `anonymousKey` part. The service strips it in any case. The run and the key must belong to the same environment. A key from `app.certora.com` resolves runs on `prover.certora.com` and nothing else.
- The rule name, and the property the rule formalizes: its `title`, `description`, and `sort` from `certora/properties/<slug>.properties.json`. The `rules` list in `certora/properties/<slug>.property_rules.json` maps the property to its rules.

You must own the run, or be a member of the owner's organization with read access to it. The service checks this before it starts anything, and the job reads the run with your identity. An anonymous key grants nothing. In this flow you submitted the run yourself, so this holds.

Before the first run, make sure that the key can start resolver runs:

```bash
ZEUS=https://app.certora.com
curl -sS "$ZEUS/v2/access" -H "Authorization: Bearer $CERTORA_API_KEY"
```

`capabilities.run_types` must list `timeout_resolver`. If it does not, the resolver is not enabled for this key. Say so and continue with the manual playbook.

## How the API answers

Every call carries `Authorization: Bearer $CERTORA_API_KEY`. Request and reply bodies are JSON. Every reply carries a `request_id`.

A refused call answers with `application/problem+json`. The body holds `status`, `code`, `detail`, `retryable`, and sometimes `field_errors`. Quote `code`, `detail`, and `request_id` when you report a refusal. A 422 names the bad field in `field_errors`. A 429 carries a `Retry-After` header in seconds. Wait that long, then retry. A request body is capped at 256 KiB. A resolver request is far below that.

## Starting a run

Start one run per rule. The create call needs an `Idempotency-Key` header of 1 to 200 characters. Use one key per rule, for example `<slug>-<ruleName>-1`. A retry with the same key and the same body returns the same run and starts nothing. A new key starts a new run, and a new run is a new charge.

```bash
curl -sS -X POST "$ZEUS/v2/timeout-resolver-runs" \
  -H "Authorization: Bearer $CERTORA_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <slug>-<ruleName>-1" \
  -d '{
    "run_url": "https://prover.certora.com/output/<user>/<job>/",
    "rule": "<ruleName>",
    "property": {
      "title": "<title>",
      "description": "<description>",
      "sort": "invariant|safety_property|attack_vector"
    },
    "goal": "resolve_timeout",
    "app_description": "<two or three sentences on the protocol, from certora/analysis/application.json>"
  }'
```

Optional fields:

- `contract` and `method` narrow a parametric rule to one instantiation.
- `time_budget` caps the wall clock, in seconds. Omit it to accept the cap of the service.
- `app_description` is optional, but it helps the proof search. Send it when `certora/analysis/application.json` exists.

The reply is `202` with a `run` object. Keep `run.id`. Record it in the commentary file of the component.

## Waiting

A run takes between 30 minutes and a few hours. Poll every 60 seconds, with a progress note on each poll:

```bash
curl -sS "$ZEUS/v2/runs/<run_id>" -H "Authorization: Bearer $CERTORA_API_KEY"
```

`run.status` is one of `queued`, `running`, `finalizing`, `succeeded`, `failed`, `cancelling`, `cancelled`. Stop polling at `succeeded`, `failed`, or `cancelled`. The other values mean the run is still moving. While it moves, `run.progress.phase` names the current step.

`succeeded` means the agent finished and wrote a result. It does not mean the rule verified. Read `result.json` for that. `failed` means the run did not complete. Then `run.failure` holds `code`, `detail`, and `retryable`. Quote `code` and `detail` in your report. Do not start a new run because `retryable` is true. Ask the user first.

To stop a run, cancel it:

```bash
curl -sS -X POST "$ZEUS/v2/runs/<run_id>/cancel" \
  -H "Authorization: Bearer $CERTORA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

The reply is `202`. The run moves through `cancelling` to `cancelled`.

## Reading the result

List the artifacts once the run is `succeeded`. Before that, the list call answers 409 with code `artifacts_not_ready`.

```bash
curl -sS "$ZEUS/v2/runs/<run_id>/artifacts" -H "Authorization: Bearer $CERTORA_API_KEY"
```

The reply holds `artifacts` and `next_cursor`. Each artifact has `name`, `path`, `category`, `size_bytes`, `last_modified_at`, and `download_url`. The resolver returns five files, so one page holds them all and `next_cursor` is null. Each `download_url` is a presigned link that expires after a short time. Download every file right after you list them. If a download is refused, list again and use the fresh link.

```bash
mkdir -p certora/resolver/<ruleName>
curl -sS -o "certora/resolver/<ruleName>/<name>" "<download_url>"
```

Do not send the `Authorization` header to a download link. The link carries its own credentials.

The directory then holds exactly five files:

- `result.json`. The `status` field is one of `resolved`, `gave_up`, `unresolved`, `invalid_input`, `dependency_error`, `budget_exhausted`, `cancelled`, `failed`. Only `resolved` means the rule verifies. `message` says why a run ended the way it did. `products` names the files the run wrote. `run.patch_base` names the directory the patches apply in. `outcome` is present for `resolved` and `gave_up`. A `resolved` outcome carries `executive_summary` and `why_sound`. Its `prover` record holds the final run link and the status of every path of the rule. Its `lean` record holds the Lean verdict. `budgets` records the caps the run ran under.
- `proof.md`. The informal proof the lemmas came from. Present whenever the proof search completed, whatever the status.
- `source.patch` and `spec.patch`. Unified diffs against the sources the run was submitted with. The `run.patch_base` field of `result.json` names the directory they apply in, relative to the sources root.
- `<ruleName>_lemmas.lean`. The Lean development that discharges the lemmas.

For `gave_up`, `unresolved`, or `budget_exhausted`, the rule still times out. Read `proof.md`. The proof often names the lemma that the prover cannot see, and that is a good starting point for a manual summary or a split. Then continue with the manual playbook. Do not weaken the property.

## Applying a resolution

1. Apply the patches inside the directory `run.patch_base.run_dir` names, relative to the project root. `.` means the project root itself.

   ```bash
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/source.patch
   git apply -p1 --directory=<run_dir> certora/resolver/<ruleName>/spec.patch
   ```

   The source patch touches helper contracts under `certora/` and sometimes the contracts in the scene. The spec patch adds a CVL summary for each hook and adjusts the rule. Read both before you apply them.
2. Copy the Lean file to `certora/lean/<ruleName>_lemmas.lean` and keep it with the spec. It is the certificate for the lemmas the hooks assume.
3. Typecheck, then run the full unfiltered prover run as usual. The completion gate does not change: the resolver's own final run is evidence, not a substitute for your run.
4. In the commentary file, record the resolver run id and the final run link from `result.json`. Record each hook with its inertness argument from `why_sound`, and the Lean file. In the report, these hooks are trust assumptions discharged in Lean, and the reviewer needs to see them.

## Cost

A resolver run is charged to your organization's balance. zeus reserves a fixed amount per run and refunds the unused part when the run settles. Start one resolver run per rule, not one per iteration. If a rule times out again after a resolution, go back to the manual playbook before starting a second run.
