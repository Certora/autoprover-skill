# The Certora Runs API

The hosted property generator (`property-generation.md`) and the Timeout Resolver (`timeout-resolver.md`) are both driven through the Certora Runs API. This page holds what the two share: the key, how the API answers, starting a run exactly once, waiting for it, reading its result and what it costs. Each service's page says what is its own.

Every call is a plain HTTPS request, by whatever means your agent has. Every call carries the key as a bearer token, sends and receives JSON, and answers with a `request_id`. `<base>` is `https://app.certora.com`.

## The key

The organization API key is in the environment variable `CERTORAKEY`, the same key the prover runs on. The user creates it on the API Access page of the organization, which is the **API** entry in the sidebar at `app.certora.com`. Each service's page lists the permissions it needs. Permissions cannot be changed after the key is created. A key from the older `prover.certora.com` settings is not an organization API key, and the Runs API answers it with `401 invalid_api_key`. The Runs API also needs a plan that includes it. Never print the key.

Before the first run of a service, read the key's permissions from `GET <base>/v2/access`. `key.scopes` lists them. Do not test `capabilities.run_types`: it is the same fixed list for every key and proves nothing. `billing.balance_usd` is the organization's balance.

The organization's own limits can show on any call, this one included. `403 plan_gate` means the plan does not include the Runs API, and its `detail` names the plan that does. `503 integration_disabled` means an administrator turned API access off. `503 app_disabled` means the service is off. Both 503s carry `retryable: true`, and neither clears by retrying. Report the code and continue without the service.

## How the API answers

A refused call answers with `application/problem+json`. The body holds `status`, `code`, `detail`, `retryable`, and sometimes `field_errors`. When you report a refusal, quote `code`, `detail`, and `request_id`. A 422 names the bad field in `field_errors`. A 429 carries a `Retry-After` header in seconds. Wait that long, then retry. Read `retryable` as a hint only: `code` decides, and these pages name each code that is worth another call. A request body is capped at 256 KiB.

These refusals can come from any call:

- `401 invalid_api_key`: the key is wrong, revoked, or not an organization API key. Stop and ask the user for a valid key.
- `403 insufficient_scope`: the key lacks a permission the call needs. `detail` names it. Stop and ask for a key that has it.
- `402 insufficient_balance`: the organization's balance cannot cover the hold. Tell the user to top up the balance, and launch nothing else.
- `404 run_not_found`: the service cannot see the run you named, or the key belongs to another organization than the run's owner. Check the run and the key.
- `503 audit_backend_error`: the service could not reach its backend, and nothing started. Retry with the same idempotency key and the same body, a few seconds apart.
- `409 idempotency_in_progress`: a request with the same key is still being handled. Wait the `Retry-After` seconds, then send the same request again.

## Starting a run exactly once

A create call needs an `Idempotency-Key` header of 1 to 200 characters, and the same string goes in the body as `client_reference`. Each service's page says how to build the key from the input it launches, and where to record it. When you first send a key, write it and the exact body you sent to that file. On a retry or a resume, send the stored body under the stored key. Do not build the request again, because a body you rebuild is a body that can differ.

The service ties a key to the organization, the API key and the endpoint, and compares bodies as JSON values: key order and whitespace do not matter, any changed value does. Then:

- The same key and the same body return the same run and start nothing. A record that holds a run never expires, so this holds across later sessions too.
- A refused launch may be answered with the same refusal for up to 24 hours, even after its cause is fixed.
- A key sent under another API key is a new key. A new key starts a new run, and a new run is a new charge.

`409 idempotency_conflict` means the key is already bound to a different request. Any change to the body counts. Reaching this refusal without meaning to is a sign that the body was rebuilt instead of replayed, and the first request launched. Do not mint a key to get past it. List the runs for that `client_reference`, and use the run that exists. A new key belongs only to an attempt you mean to start, and its body is recorded with it.

A `503 launch_outcome_unknown` is the one refusal that leaves the outcome open: the run has possibly started. Retry the create call with the original key and the unchanged body, a few seconds apart. The service looks for a recovered run before it replays anything, so the original key is what surfaces a run that did start. Never mint a second key for the same attempt, because that starts a second paid run. A `202` naming a run settles it, whether that is the replayed success or a run the service recovered: poll that run. Another `launch_outcome_unknown`, or a `503 launch_recovery_pending`, means the outcome is still open. Retry the same key about five times over a few minutes, then stop and hand the user the key and the run link. Launch nothing else.

The run list tells you whether a run exists: `GET <base>/v2/runs?run_type=<run_type>&client_reference=<key>`. A run in the list is the one to poll. An empty list proves nothing: `client_reference` is written only after a launch returns a run id, so an ambiguous launch leaves it unset while the run exists. An empty list is never permission to create.

## Waiting

Wait for a run in the foreground, the same way `prover-loop.md` (*Waiting for a run*) waits for a prover job. Each wait is one shell call that polls `GET <base>/v2/runs/<run_id>` every 60 seconds and stops after 90 seconds at most. Save each reply to a file and read it with the `ai-composer` tool's Python. The reply has `run.status`. A refusal has no `run`, and its `status` and `code` say why. The call ends early when the run reaches `succeeded`, `failed` or `cancelled`, or when the reply is a 4xx refusal.

A `429` refusal means wait and make the same call again. Any other 4xx refusal means stop polling and report the code: the key was revoked, lost a permission, or names another organization, and polling again does not change that. If the status is still another value, write a one-line progress note (elapsed time and the status) and make the same call again. Repeat until the run is `succeeded`, `failed` or `cancelled`. The bound follows the rule in `prover-loop.md`: 90 seconds fits a 2-minute shell timeout, and a longer bound needs a longer timeout passed on every call. Do not wait through a background monitor, a timer or a turn that ends in the hope of a notice. A sub-agent that started the run never ends its turn while the run is moving.

`run.status` is one of `queued`, `running`, `finalizing`, `succeeded`, `failed`, `cancelling`, `cancelled`. Stop polling at `succeeded`, `failed`, or `cancelled`. The other values mean the run is still moving. `run.progress` is null while the run is `queued`. From `running` on, `run.progress.phase` names the current step.

`succeeded` means the run finished and wrote a result. `run.result.available` says whether that result can be served. It stays false on a succeeded run whose result was never written. `failed` means the run did not complete. Then `run.failure` holds `code`, `detail`, and `retryable`. Quote `code` and `detail` in your report. Do not start a new run because `retryable` is true. Ask the user first.

To stop a run, cancel it: `POST <base>/v2/runs/<run_id>/cancel`, as JSON, with an empty object as the body. A `202` means the cancellation was taken, and the run moves through `cancelling` to `cancelled`. A `200` means the run was past cancelling already, `finalizing` included, and the reply's `run.status` is the real state. Neither answer is an error.

## Reading the result

Read the result once the run is `succeeded`: `GET <base>/v2/runs/<run_id>/result`. The reply body is `{request_id, result}`. The envelope carries `result.schema_version`, the string `"1"`, beside `result.run_id` and `result.run_type`, and the document is `result.data`. Each service's page says what the document holds.

`409 result_not_ready` means the result is not there yet. Poll a few more times. `409 result_unavailable` means the run ended without a result: a failed or cancelled run, or a succeeded run whose `run.result.available` is false. Never start a second run to get around either.

## Cost

A run is charged to the organization's balance. At launch the service holds an amount, and at settlement it refunds the unused part. `run.billing.reserved_usd` is the hold and `run.billing.charged_usd` the settled charge, which `GET <base>/v2/runs/<run_id>` shows once the run settles.
