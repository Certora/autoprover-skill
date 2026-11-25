# Solidity · author and run CVL

Use the project's existing spec, deployment configuration and prover command when they cover the requested claim. Run from the project root with Java 19+, the project's Solidity compiler(s) and `CERTORAKEY` for cloud submissions.

## Build the scene

Identify the concrete main contract, its production entry point and the dependency graph it actually calls. Match the deployed revision, compiler, optimizer, via-IR, EVM version, library links, constructor/initializer arguments and proxy implementation/storage as relevant to the claim. A verified implementation in isolation can still say nothing about the initialized proxy. Distinguish the current deployment from all configurations reachable through upgrades or admin setters.

If a matching setup is missing, use the pinned AutoProver tools. Set `SKILL_DIR` to the installed skill directory. If installation is needed, explain it and obtain approval first.

```bash
ref=$(cat "$SKILL_DIR/AUTOPROVER_REF.txt")
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_0='git@github.com:' \
  uv tool install --python 3.12 --with-executables-from certora-cli \
  "ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@$ref"
```

For Foundry use `forge compiler resolve --json -vv`. For Hardhat inspect the resolved build info, including per-file overrides. Match binaries and settings to the production build. Provide versioned compiler executables on this run's PATH (e.g. `solc8.17` for 0.8.17). If AutoSetup cannot express a required override, use a validated project configuration or resolve the discrepancy before submitting.

Example for a Vault that calls Escrow. Substitute the actual contracts and use one group ID across related jobs. AutoSetup submits cloud jobs. Add `--proxy-mapping Proxy=Implementation` when supported by deployment evidence. Use `--clear-cache` when changing the contract set or setup flags.

```bash
group_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
ANTHROPIC_API_KEY=skip-llm-placeholder certora-autosetup \
  --main-contract src/Vault.sol:Vault src/Vault.sol:Vault src/Escrow.sol:Escrow \
  --no-strip-contracts --skip-llm --extra-args "--group_id $group_id"
```

Check the generated `certora/confs/<Main>.conf`, sanity report and actual call resolution. Copy the sanity spec's imports into the authored spec, including base summaries and call resolution. Confirm each relevant external call reaches an allowed implementation or a justified model covering its state changes, callbacks, return values and failures. Scope dispatch to all production possibilities. An unconstrained return alone cannot model a stateful transfer.

## Write and prove the user's claim

1. Identify the actors, inputs, starting state, action, expected state and revert behavior in the user's words. Use a CVL rule for a transition, an inductive invariant for a state predicate across all writers, and `satisfy` for an existence claim. Keep units, actors, rounding and quantifiers explicit. Consult the relevant [CVL rules](https://docs.certora.com/en/latest/docs/cvl/rules.html) and [statements](https://docs.certora.com/en/latest/docs/cvl/statements.html).
2. Use symbolic inputs and `env` for the caller, value and block context. Read the pre-state, call the real entry point, then assert the expected result. For required success or failure use `@withrevert` and capture `lastReverted` immediately. An ordinary call discards reverting paths. Ground each `require` in the claim, deployment evidence or a separately proven invariant. Check reachability of the case and both branches where relevant. Leave the code and effects under test executable.
3. Put the spec under `certora/specs/`. Copy the validated conf, set `verify` to `Main:certora/specs/<name>.spec`, enable `rule_sanity: "basic"`, and check rule/method filters. Examine optimistic bounds and imported summaries for effects on this claim. Complete the three production reviews in the main skill before submitting the proof.

For example, if the requirement is “only the owner may set the fee,” the ABI exposes `owner()` and `setFee(uint256)`, and the production target has no other authorized role, the rule body can be:

```cvl
rule onlyOwnerMaySetFee(env e, uint256 fee) {
    address ownerBefore = owner(e);
    require e.msg.sender != ownerBefore;
    setFee@withrevert(e, fee);
    assert lastReverted, "a non-owner must be rejected";
}
```

For this example, check that a non-owner can reach the call and separately witness a valid owner's successful call. A contract that rejects everyone satisfies the rejection rule. If the claim instead covers every way the fee can change, include all production writers.

```bash
certoraRun "$conf" --compilation_steps_only
# Once the typecheck succeeds:
certoraRun "$conf" --group_id "$group_id" --wait_for_results all
```

Use a fresh group ID for an existing setup if none exists. Wait through completion. Inspect leaf verdicts, vacuity checks, call resolution and failing traces in the linked report. With the pinned tooling, `"$(uv tool dir)"/ai-composer/bin/prover-cli --job-url "$report_url" --verdicts` prints verdicts and counterexamples. Record the exact spec, conf, revision and job URL. Rerun affected rules after edits to code, spec, dependencies or modeling.
