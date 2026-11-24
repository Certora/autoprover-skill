# Generating the properties with the hosted property generator

The hosted property generator is AutoProver's own property formulation, run as a service. Give it a repository, a commit and a main contract. It analyzes the contract, groups it into components, formulates invariants, safety properties and attack vectors, reviews them, and ranks them across the contract. It writes no specs and runs no prover jobs.

You drive it through the Certora Runs API. `runs-api.md` holds what every Runs API service shares: the key, how the API answers, starting a run exactly once, waiting, reading the result, and cost. This page says what is the generator's own.

When the project qualifies, it is the default source of Phase 4's properties. When it cannot run, Phase 4 drafts the properties itself. Neither path blocks the flow.

## When the project qualifies

The service clones the project from GitHub, so it sees a commit, not your working tree. Use it only when all of these hold:

- The project root is inside a git repository whose `origin` remote is on `github.com`. Write `<repo>` for its `https://github.com/<owner>/<name>` form, without `.git`.
- Write `<sha>` for the full `git rev-parse HEAD`. Whether GitHub has that commit is for the estimate to say (*Estimate*), since a shallow clone cannot tell.
- `git status --porcelain` lists no change to a `.sol` file. Changes elsewhere do not matter.
- The key in `CERTORAKEY` holds `runs:create` and `runs:read` (`runs-api.md`, *The key*). `runs:cancel` is useful, not needed.

## When something blocks it

A failed check above, a refused estimate (*Estimate*) and a refused launch (*Launching*) each name a cause the user can usually fix: commit and push the `.sol` changes, push the commit, create a key with the permissions, install the organization's Certora GitHub app on the repository, or top up the balance. Tell the user which one it is, and what would fix it. Then ask whether they want to fix it before you continue. When they have, run the checks and the estimate again. When they decline, or the request said to work without asking, draft the properties locally and continue. Do not push, commit or stash yourself.

## Estimate

The estimate is free and holds nothing. `POST <base>/v2/auto-prover-runs/estimate`, as JSON, with the bearer token:

```json
{
  "source": {
    "repository_url": "<repo>",
    "commit_sha": "<sha>",
    "authentication": { "type": "public" }
  },
  "contract": { "path": "<relative/path/File.sol>", "name": "<ContractName>" },
  "run_mode": "property_generation",
  "client_reference": "<key>"
}
```

`contract.path` is relative to the repository root, which is not always the project root. Add `"documents": { "design": "<path>" }` when Phase 1 found a design document that is committed at `<sha>`; the path is relative to the repository root and must be a Markdown (`.md`, `.markdown`) or PDF file. `<key>` is the idempotency key from *Launching*.

Choose `authentication.type` before the first estimate, and send one estimate. Ask GitHub without credentials, `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/<owner>/<name>`: `200` means the repository is public, so the type is `public`; any other answer means `organization_github_app`, which reads a private repository through the organization's Certora GitHub app. A token the user saved in the web app does not reach the API. For a private repository, check `capabilities.github_app_connected` from `GET <base>/v2/access` first. If it is false, the app is not connected, which blocks the run (*When something blocks it*), and an estimate would be refused anyway.

The reply holds `estimate.estimated_cost_usd`, `estimate.balance_usd`, `estimate.can_launch` and `estimate.estimate_quote_id`. The launch holds about twice the estimate on the organization's balance and refunds what the run does not use. If `can_launch` is true, launch without asking the user, and tell them in one line that the generator was launched, with the estimate, its `run.dashboard_url`, and that it runs while Phases 2 and 3 continue. A small contract takes minutes; a large one takes longer.

Two answers block it (*When something blocks it*). `can_launch` false means the balance cannot cover the hold. A `422` with code `source_revision_not_found` means the service cannot read that commit with that type: the commit is not pushed, or the organization's Certora GitHub app is not installed on the repository. Do not retry with the other type. A `422` with code `contract_not_found` means `contract.path` or `contract.name` does not match that commit: fix the path relative to the repository root, and estimate again. These refusals create no quote and hold nothing.

## Launching

Launch exactly once, as `runs-api.md` (*Starting a run exactly once*) describes. Build the idempotency key from the input: `propgen-<name>-<sha>-<ContractName>`, where `<name>` is the repository name. It is at most 200 characters; shorten `<name>`, never `<sha>`. The same string is `client_reference`. Record the key and the exact body in `certora/propgen/keys.json` before the first send.

`POST <base>/v2/auto-prover-runs`, as JSON, with the bearer token, the header `Idempotency-Key: <key>`, the header `Estimate-Quote-Id: <estimate_quote_id>`, and the body of the estimate.

The quote is good for 15 minutes, and only for this key, engine, repository, commit and contract, so launch right after the estimate. The quote travels in a header, not in the body, so a new quote never changes the stored body. A `409 estimate_quote_invalid` means the quote has expired or does not match the launch, and a `503 estimate_quote_unavailable` means the service could not read it. Neither one starts a run or holds anything. After either, estimate again and send the launch again with the new quote, under the same idempotency key and with the stored body. A `400 estimate_quote_invalid` means the header is not a UUID or comes from another endpoint's estimate: fix the header. A resume that replays a launch that already returned a run needs no new estimate.

The reply is `202` with a `run` object. Write `run.id` to `certora/propgen/run.json`. A `402 insufficient_balance` blocks it (*When something blocks it*). A `409 idempotency_conflict` means an earlier skill run launched the generator on the same commit and contract with another body, a different design document for one: list the runs for that `client_reference`, and use the run that exists. To find a run that exists, read `GET <base>/v2/runs?run_type=auto_prover&client_reference=<key>`.

Launch right after Phase 1, so the run overlaps Phases 2 and 3. Do not wait for it there.

## Waiting

When Phase 4 starts, wait for the run in the foreground, as `runs-api.md` (*Waiting*) describes. Phases 2 and 3 usually cover most of the wait.

A `failed` or `cancelled` run has no property set. Quote `run.failure.code` and `run.failure.detail`, and draft locally. Do not launch a second run.

## Reading the property set

Read the result as `runs-api.md` (*Reading the result*) describes. Check that `result.run_type` is `auto_prover` and `result.run_mode` is `property_generation`. Save `result.data.property_set` to `certora/propgen/property_set.json`.

```json
{
  "contract_name": "<ContractName>",
  "components": [
    {
      "name": "<component name>",
      "properties": [
        { "title": "<snake_case>", "sort": "invariant|safety_property|attack_vector", "description": "<text>", "rank": 1 }
      ]
    }
  ]
}
```

`rank` orders the properties across the whole contract by importance, `1` first. It is `null` when the run did not rank them.

A run that ends without a property set (`409 result_unavailable`) leaves Phase 4 to draft locally.

## Using it in Phase 4

The generator's components are its own. Phases 4-6 work on the Phase 2 components, so assign each generated property to the Phase 2 component of the main contract whose entry points and state it is about. A property that spans two components goes to the one it constrains, the same choice you make for a property you draft. Copy `title`, `sort` and `description` verbatim. Never reword a generated property to make it easier to prove; if one is out of scope by Phase 4's hard rules (event emission, off-chain events, what the type system already guarantees), drop it and record why.

Then run one round of your own per component, working `property-classes.md` against the generated list as the record of what was considered, and add what it missed. The structural invariants batch (slug `invariants`) is still yours: those invariants exist to rule out infeasible starting states, which is not what the generator formulates.

Record the provenance in `certora/propgen/assignment.json`, one entry per generated property, with `component` null and `dropped` set when it was dropped:

```json
[{"title": "<title>", "rank": 1, "generator_component": "<its component>", "component": "<Phase 2 component>", "dropped": null}]
```

Write `<slug>.properties.json` in its usual shape, `[{title, sort, description}]`; the provenance stays in `assignment.json`. When the prover budget is short in Phase 6, spend it on the properties with the smallest rank numbers first. Phase 7 states which properties came from the generator and which from the local round.

## Cost

The run is charged as `runs-api.md` (*Cost*) describes. Phase 7 reports `run.billing.charged_usd`. One run per skill run: a resume reads the stored run, never a new one.
