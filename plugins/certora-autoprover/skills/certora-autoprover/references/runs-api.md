# Hosted verification

Use `https://app.certora.com/v2` for hosted runs. Authenticate API requests with `Authorization: Bearer <organization key>`. Use `CERTORAKEY` for a shared prover/REST key or `CERTORA_API_KEY` for a dedicated REST key. Keep credentials out of logs and saved requests. Every plan includes the API. Check `GET /access` for `key.scopes` and `billing.balance_usd`. Launch and read require `runs:create` and `runs:read`. Downloading artifacts requires `artifacts:read`. Only cancellation requires `runs:cancel`.

## Choose the action

Start with the requested deliverable. A run ID, dashboard link or saved launch record identifies existing work. If several runs match and the choice matters, ask which one the user means.

| When the user asks… | Next call or action |
| --- | --- |
| “Can this key run it? What balance is available?” | `GET /access`. Read the scopes and balance. |
| “What would it cost?” | POST to the selected engine’s estimate route below and return the estimate. Timeout Resolver has no estimate route. Stop after answering the price question. |
| “Where is my run?” / “Is it finished?” | With an ID, `GET /runs/{run_id}`. Otherwise list `GET /runs` with known filters such as commit or client reference. Return progress or terminal status. |
| “Show me the report” / “Download the generated spec” | Check the run status. For a ready report, `GET /runs/{run_id}/result`. For files after success, `GET /runs/{run_id}/artifacts`. If the user wants the eventual result, attach to the existing poller or restore it. |
| “Stop this run” / “Commit its files to the PR” | For cancellation, `POST /runs/{run_id}/cancel`. For explicitly requested delivery to the PR bound at launch, `POST /runs/{run_id}/generated-files/commit`. Retry interrupted delivery on that same ID. |
| A rule returns `TIMEOUT` during verification, or the user brings a timed-out rule | After manual price approval, submit `POST /timeout-resolver-runs` for each eligible rule with its finished **Prover job URL**, exact rule and property. Use the same cron and integration flow. On resume reuse the resolver run. If the resolver exhausts its attempts or its patch fails verification, record the unresolved verdict and evidence. |
| “Formally prove this system” | Identify the in-scope Solidity contracts or Solana programs at the requested revision and price each target before launching the approved AutoProver runs with explicit `run_mode: "comprehensive"` for each target. Track each run ID and report cross-contract or cross-program claims separately where individual target proofs leave gaps. |
| “Start new work on this revision” | Pick the engine below by the requested evidence. A lost launch response goes through [launch recovery](#estimate-and-launch) using the original key. |

## Choose the engine

Paths are relative to the production v2 base. Consult the [production OpenAPI schema](https://app.certora.com/v2/openapi.json) for deployed operations, accepted fields and response types. AutoProver reads an immutable GitHub commit. Check that the requested source, specs, configs and design documents match that commit, including local changes. Use the local prover for inputs the service cannot see or express.

| Formal verification | Launch (POST) | Estimate (POST) | Inputs and modes |
| --- | --- | --- | --- |
| Solidity | `/auto-prover-runs` | `/auto-prover-runs/estimate` | `contract: {path, name}`. `prioritized` attempts the top-ranked cluster, `comprehensive` attempts all candidates, `evaluate` runs committed specs and confs. `property_generation` returns `result.data.property_set` without proving rules. |
| Solana | `/auto-prover-solana-runs` | `/auto-prover-solana-runs/estimate` | `program.path` is the crate's `src/lib.rs`. `program.name` is optional. Modes are `prioritized` and `comprehensive`. |
| Timeout Resolver | `/timeout-resolver-runs` | None | Send a finished, same-environment `run_url` owned by the organization, the timed-out `rule`, and `property: {title, description, sort}`. Optional `contract` and `method` select one instance. |

### Code review

For a general code review, offer local review, hosted full review, or hosted diff review. Recommend diff for a PR and full for a scoped snapshot. Use the user's choice. For hosted reviews, resolve the GitHub repository and immutable revisions from the checkout or PR:

- **Full:** send `source.commit_sha` and a nonempty `scope` of repo-relative paths or globs for automatic context.
- **Diff:** send distinct `source.base_commit_sha` and `source.head_commit_sha`. For a PR, use its base and head. If relevant changes exist only in the working tree, offer to review those locally.

Use the matching estimate and launch routes below. Show the estimate for the selected scope and [obtain manual price approval](#price-approval). An explicit yes to that priced review triggers the launch immediately. Follow the run with cron, save the returned audit report in the checkout and present its findings.

| Other requests | Launch (POST) | Estimate (POST) |
| --- | --- | --- |
| Full AI audit | `/ai-auditor-full-runs` | `/ai-auditor-full-runs/estimate` |
| Audit a diff | `/ai-auditor-diff-runs` | `/ai-auditor-diff-runs/estimate` |
| Validate an audit finding | `/ai-auditor-finding-validations-runs` | `/ai-auditor-finding-validations-runs/estimate` |
| Fuzz a Solidity contract | `/auto-fuzzer-runs` | `/auto-fuzzer-runs/estimate` |
| Verify a Soroban contract | `/auto-prover-soroban-runs` | `/auto-prover-soroban-runs/estimate` |

An English rule has no dedicated input field on the contract/program routes. Author and review the exact rule locally. For Solidity, hosted `evaluate` can run it once the reviewed spec and conf are present at the requested commit. Require evidence identifying that rule and its verdict.

## Estimate and launch

Before launching, verify that a cron scheduler can run an authenticated status check for the lifetime of the job. Use the agent runtime’s recurring-job tool or a user crontab with a local polling command. If neither is available, surface the blocker before starting paid work.

Example Solidity body, using repository-relative paths:

```json
{
  "source": {
    "repository_url": "https://github.com/acme/vault",
    "commit_sha": "<full lowercase 40-character SHA>",
    "authentication": {"type": "public"}
  },
  "contract": {"path": "src/Vault.sol", "name": "Vault"},
  "run_mode": "comprehensive",
  "client_reference": "<unique logical launch ID>"
}
```

For private repos use authorized repository access, e.g. `organization_github_app`. Include committed design or threat-model files through `documents.design` and `documents.threat_model`. Persist the target, exact body and a durable `Idempotency-Key` before submission so resume can recover the same run.

### Price approval

1. **Price the exact request.** For every engine with an estimate route, POST the intended launch body with `Content-Type: application/json` to `/estimate` under that engine. Estimates are free. Show the engine, target, revision, mode, estimated USD cost and minimum required balance. Explain any variable charge, including runtime billed on top of a Solidity balance hold. For multiple targets, itemize each run and show the total estimate.
2. **For Timeout Resolver**, which has no estimate endpoint, obtain current organization-specific pricing from the dashboard, billing terms or the user. Show the fixed reservation and how usage determines the final charge. If pricing cannot be established, leave the run pending.
3. **Ask and wait.** For example: “Launch the two comprehensive runs listed above for an estimated $18 total, plus the disclosed runtime charges?” Proceed only after the user explicitly confirms those priced runs. A verification request, budget, sufficient balance, standing instruction or elapsed time is insufficient. On refusal or silence, leave the work unsubmitted. Record the confirmation with the approved body and pricing so a resumed agent can identify it.
4. **Launch the approved request.** Check `can_launch` where available. POST the approved JSON and durable `Idempotency-Key`. Solidity AutoProver and AutoFuzzer also take `Estimate-Quote-Id` within 15 minutes. If the quote expires while awaiting approval, re-estimate the same body. If the price, reservation, billing terms or scope changes, show the update and get fresh confirmation. Solana, Soroban, AI Auditor and Resolver launches omit the quote header.

Save the accepted `run.id`, `run.dashboard_url` and actual `run.billing.reserved_usd`. To recover an ambiguous approved launch, reuse its endpoint, credential, idempotency key and body. Recovery and polling of the same run need no new approval. A new billable attempt, including a resolver run following an approved proof, needs its own price approval. Accepted, reservation-backed and unresolved launches have no time-based expiry. Only completed pre-dispatch client failures with no run or reservation may expire after 24 hours. Use `GET /runs` with `client_reference` and follow `next_cursor`. An empty page alone cannot establish that a launch failed. For HTTP failures retry only when `retryable` is true, honor `Retry-After`, and report `code` and `request_id`.

## Schedule one cron poller per hosted run

Immediately after a launch returns `run.id`, or recovery finds it, register a recurring job for that ID. Schedule it every minute (`* * * * *`). Name it `certora-run-<run_id>` and persist its scheduler handle beside the launch record. On resume, look up the name, reuse an existing job, or recreate a missing one for an unfinished run. Verify registration. If it fails, keep the run ID and recover monitoring for that same run. Synchronous requests such as access checks and estimates return their answer inline.

Give the cron worker the run ID, private output directory and this task. Supply credentials through the scheduler's secret environment or credential store. Keep the key out of the crontab, task text and output files.

1. Take a per-run lock. Skip overlapping ticks and ticks before a stored retry deadline. Fetch `GET /runs/{run_id}` and atomically save the status. During `queued`, `running`, `finalizing` or `cancelling`, leave the job scheduled.
2. On `succeeded`, fetch `GET /runs/{run_id}/result` when `run.result.available` is true. Save the full result atomically before marking complete. While availability is pending, check again on the next tick. On `failed` or `cancelled`, record the status and any `run.failure`.
3. After a transport failure or retryable HTTP error, keep the poller and honor `Retry-After`. On a permanent refusal, save the error and alert the caller that monitoring is blocked. The poller only reads the existing run.
4. Once the result, terminal failure, or monitoring blocker is durable, notify the calling agent and unregister this job by its handle. A replay after a crash should finish cleanup from the saved record. The calling agent waits for that record and integrates the successful result below. A cancellation request keeps the same poller until shutdown completes.

## Integrate and validate in the checkout

1. For each successful run, read `result.data` by type and mode. Save the report or property set in the repo's verification layout (fallback `certora/results/<run_id>/`), with the source revision and run link. For report-only outputs, validate the saved Markdown or JSON and confirm its target matches the request.
2. For runs producing files, list `GET /runs/{run_id}/artifacts` through every `next_cursor`, including empty pages. Download the signed URLs directly without the API bearer token into a private staging directory. Match the returned files to the run and revision. Inspect each diff, reject paths escaping the checkout, and merge specs, configs, tests and proof evidence into their normal project locations. Preserve unrelated user edits. On resume, recognize already-integrated changes.
3. Apply resolver patches against their recorded base after checking the model, hooks, summaries and assumptions against production. Run the project's formatters on touched files using the repo’s conventions for CVL, confs, Rust and reports. Build and typecheck using the integrated targets and run relevant tests or proof checks. For Solidity run `certoraRun <conf> --compilation_steps_only`; for Solana use the integrated module with `certora-cvlr check`. Rerun every proof affected by model or rule changes, including the original timed-out rule. A repeat timeout on the resolver's output ends that attempt.
4. Report integrated paths, local commands and outcomes, actual per-rule verdicts, job links and the settled `run.billing.charged_usd` when available. A local typecheck establishes compilation only. If a required artifact, tool or check is unavailable, identify the remaining gap. For a failed run report `run.failure`. On explicit cancellation use `POST /runs/{run_id}/cancel` and poll through shutdown.

For requested GitHub delivery of Solidity AutoProver or AutoFuzzer files, bind the open same-repository PR at estimate and launch with `delivery: {"type":"github_pull_request","pull_request_number":184}` (replace 184). After success, use `POST /runs/{run_id}/generated-files/commit` with `generated_files:write` and an empty body. Report the returned commit SHA or `no_changes`. Recover interrupted delivery by retrying that operation on the same run.
