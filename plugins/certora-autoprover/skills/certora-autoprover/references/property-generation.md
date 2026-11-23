# Generating the properties with the hosted property generator

The hosted property generator is AutoProver's own property formulation, run as a service. Give it a repository, a commit and a main contract. It analyzes the contract, groups it into components, formulates invariants, safety properties and attack vectors, reviews them, and ranks them across the contract. It writes no specs and runs no prover jobs.

You drive it through the Certora Runs API, the same API as the Timeout Resolver (`timeout-resolver.md`). Its sections *How the API answers*, *Waiting* and the idempotency rules of *Starting a run* apply here unchanged. This page says only what differs.

When the project qualifies, it is the default source of Phase 4's properties. When it does not, or the organization's balance cannot cover the run, or the run ends without a property set, Phase 4 drafts the properties itself. Neither path blocks the flow.

## When the project qualifies

The service clones the project from GitHub, so it sees a commit, not your working tree. Use it only when all of these hold:

- The project root is inside a git repository whose `origin` remote is on `github.com`. Write `<repo>` for its `https://github.com/<owner>/<name>` form, without `.git`.
- Write `<sha>` for the full `git rev-parse HEAD`. Whether GitHub has that commit is for the estimate to say (*Estimate*), since a shallow clone cannot tell.
- `git status --porcelain` lists no change to a `.sol` file. Changes elsewhere do not matter.
- The key in `CERTORAKEY` holds `runs:create` and `runs:read`, read from `GET <base>/v2/access` (`key.scopes`). `runs:cancel` is useful, not needed.

If one fails, say which, and draft the properties locally. Do not push, commit or stash for the user to make a project qualify.

`<base>` is `https://app.certora.com`.

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

`contract.path` is relative to the repository root, which is not always the project root. Add `"documents": { "design": "<path>" }` when Phase 1 found a design document that is committed at `<sha>`; the path is relative to the repository root and must be a Markdown (`.md`, `.markdown`) or PDF file. `<key>` is the idempotency key from the next section.

Choose `authentication.type` before the first estimate, and send one estimate. Ask GitHub without credentials, `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/<owner>/<name>`: `200` means the repository is public, so the type is `public`; any other answer means `organization_github_app`, which reads a private repository through the organization's Certora GitHub app. A `422` with code `source_revision_not_found` means the service cannot read that commit with that type: draft locally, and tell the user why it may be: the commit is not pushed, or the organization's Certora GitHub app is not installed on the repository. Do not retry with the other type. A token the user saved in the web app does not reach the API.

The reply holds `estimate.estimated_cost_usd`, `estimate.balance_usd`, `estimate.can_launch` and `estimate.estimate_quote_id`. The launch holds about twice the estimate on the organization's balance and refunds what the run does not use. If `can_launch` is true, launch without asking the user. If it is false, say why in one line and draft locally. Tell the user in one line that the generator was launched, with the estimate, and that it runs while Phases 2 and 3 continue. A small contract takes minutes; a large one takes longer.

## Launching

Build the idempotency key from the input: `propgen-<name>-<sha>-<ContractName>`, where `<name>` is the repository name. It is at most 200 characters; shorten `<name>`, never `<sha>`. The same string is `client_reference`. Record the key and the exact body in `certora/propgen/keys.json` before the first send, and on a retry or a resume send the stored body under the stored key, as `timeout-resolver.md` (*Starting a run*) explains. A new key is a new paid run.

`POST <base>/v2/auto-prover-runs`, as JSON, with the bearer token, the header `Idempotency-Key: <key>`, the header `Estimate-Quote-Id: <estimate_quote_id>`, and the body of the estimate.

A `402 insufficient_balance` means the balance cannot cover the hold: draft locally. The reply is otherwise `202` with a `run` object. Write `run.id` to `certora/propgen/run.json`. A `503 launch_outcome_unknown` is handled as in `timeout-resolver.md`: retry under the same key and body, never under a new one. To find a run that exists, read `GET <base>/v2/runs?run_type=auto_prover&client_reference=<key>`.

Launch right after Phase 1, so the run overlaps Phases 2 and 3. Do not wait for it there.

## Waiting

When Phase 4 starts, wait for the run in the foreground, as `timeout-resolver.md` (*Waiting*) describes: poll `GET <base>/v2/runs/<run_id>` and stop at `succeeded`, `failed` or `cancelled`. Phases 2 and 3 usually cover most of the wait.

A `failed` or `cancelled` run has no property set. Quote `run.failure.code` and `run.failure.detail`, and draft locally. Do not launch a second run.

## Reading the property set

`GET <base>/v2/runs/<run_id>/result`. The reply body is `{request_id, result}`. Check that `result.run_type` is `auto_prover` and `result.run_mode` is `property_generation`. Save `result.data.property_set` to `certora/propgen/property_set.json`.

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

`409 result_not_ready` means the set is still being finalized: poll a few more times. `409 result_unavailable` means the run ended without one: draft locally.

## Using it in Phase 4

The generator's components are its own. Phases 4-6 work on the Phase 2 components, so assign each generated property to the Phase 2 component of the main contract whose entry points and state it is about. A property that spans two components goes to the one it constrains, the same choice you make for a property you draft. Copy `title`, `sort` and `description` verbatim. Never reword a generated property to make it easier to prove; if one is out of scope by Phase 4's hard rules (event emission, off-chain events, what the type system already guarantees), drop it and record why.

Then run one round of your own per component, working `property-classes.md` against the generated list as the record of what was considered, and add what it missed. The structural invariants batch (slug `invariants`) is still yours: those invariants exist to rule out infeasible starting states, which is not what the generator formulates.

Record the provenance in `certora/propgen/assignment.json`, one entry per generated property, with `component` null and `dropped` set when it was dropped:

```json
[{"title": "<title>", "rank": 1, "generator_component": "<its component>", "component": "<Phase 2 component>", "dropped": null}]
```

Write `<slug>.properties.json` in its usual shape, `[{title, sort, description}]`; the provenance stays in `assignment.json`. When the prover budget is short in Phase 6, spend it on the properties with the smallest rank numbers first. Phase 7 states which properties came from the generator and which from the local round.

## Cost

`run.billing.reserved_usd` is the hold, and `run.billing.charged_usd` the settled charge, which `GET <base>/v2/runs/<run_id>` shows once the run settles. Phase 7 reports the charge. One run per skill run: a resume reads the stored run, never a new one.
