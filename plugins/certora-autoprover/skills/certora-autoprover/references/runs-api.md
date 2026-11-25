# Hosted verification

Use `https://app.certora.com/v2` for hosted runs. Authenticate API requests with `Authorization: Bearer <organization key>`. Use `CERTORAKEY` for a shared prover/REST key or `CERTORA_API_KEY` for a dedicated REST key. Keep credentials out of logs and saved requests. Every plan includes the API. Check `GET /access` for `key.scopes` and `billing.balance_usd`. Launch and read require `runs:create` and `runs:read`. Downloading artifacts requires `artifacts:read`. Only cancellation requires `runs:cancel`.

## Pick the route

Paths below are relative to the v2 base. Both engines read an immutable GitHub commit. Check that the requested source, specs, configs and design documents match that commit, including local changes. Use the local prover for inputs the service cannot see or express.

| Request | POST route | Fields |
| --- | --- | --- |
| Solidity contract verification | `/auto-prover-runs` | `contract: {path, name}`. Set `run_mode` to `prioritized` for the top-ranked cluster, `comprehensive` for every candidate, or `evaluate` for existing repository specs and confs. |
| Solidity property suggestions | `/auto-prover-runs` | Set `run_mode: "property_generation"`. Returns `result.data.property_set` and runs no proofs. |
| Solana program verification | `/auto-prover-solana-runs` | `program: {path, name}`. Path is the crate's `src/lib.rs`; name is optional. Modes: `prioritized`, `comprehensive`. |
| Resolve a timed-out rule | `/timeout-resolver-runs` | Send `run_url`, `rule`, `property: {title, description, sort}`, and optionally `contract` and `method`. Use the finished same-environment prover run owned by the organization. |

An English rule has no dedicated input field on the contract/program routes. Author and review the exact rule locally. For Solidity, hosted `evaluate` can run it once the reviewed spec and conf are present at the requested commit. Require evidence identifying that rule and its verdict.

## Estimate and launch

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

1. For either AutoProver engine, POST the body as JSON to its route plus `/estimate`. Skip this step for Timeout Resolver. Estimates are free. Read `estimated_cost_usd`, `minimum_balance_required_usd` and `can_launch` from `estimate`. Respect the user's budget. Solidity's `limits.max_budget_usd` caps the balance hold; runtime is billed on top.
2. POST the identical JSON to the launch route with `Idempotency-Key`. For Solidity add `Estimate-Quote-Id: <estimate.estimate_quote_id>` within 15 minutes. On a rejected quote, re-estimate the same body and replace the quote header. Solana uses flat pricing without a quote header. The resolver has a fixed hold and no estimate route.
3. Save the accepted `run.id`, `run.dashboard_url` and actual `run.billing.reserved_usd`. After an ambiguous launch replay only with the same endpoint, credential, key and body. Accepted, reservation-backed and unresolved launches have no time-based expiry. Only completed pre-dispatch client failures with no run or reservation may expire after 24 hours. Recover by `GET /runs?client_reference=...`, following `next_cursor`. An empty page alone cannot establish that launch failed. Retry an HTTP failure only when `retryable` is true. Honor `Retry-After`; report `code` and `request_id`.

## Finish

Poll `GET /runs/{id}` at intervals of at least 15 seconds until `succeeded`, `failed` or `cancelled`. Fetch `GET /runs/{id}/result` on success with `run.result.available == true`. Inspect `result.run_type`, mode where applicable, and `result.data` for actual per-rule outcomes. Report `run.failure` on failure and the settled `run.billing.charged_usd` when available.

Retrieve generated specs, configs or resolver evidence from `GET /runs/{id}/artifacts`; follow every `next_cursor`, including on empty pages. Download signed URLs directly without the API bearer token. Review resolver patches and proof assumptions against the production model, then rerun the affected specs. On explicit cancellation use `POST /runs/{id}/cancel` and poll through shutdown.
