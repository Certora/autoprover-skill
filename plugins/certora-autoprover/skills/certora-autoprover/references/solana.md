# Solana · author and run CVLR

Follow the project's existing CVLR harness when it models the deployed program. Otherwise use the pinned `certora-cvlr` for Anchor, Pinocchio, jiminy or solana-program. Set `SKILL_DIR` to the installed skill directory. For new tool installations, explain the changes and obtain approval first. Use `CERTORAKEY` for cloud jobs.

```bash
solana_ref=$(cat "$SKILL_DIR/SOLANA_AUTOPROVER_REF.txt")
cvlr() {
  env -u CERTORA GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' \
    GIT_CONFIG_VALUE_0='git@github.com:' uvx --python 3.12 \
    --from "ai-composer[certora-cli] @ git+https://github.com/Certora/AutoProver@$solana_ref" \
    certora-cvlr "$@"
}
cvlr toolchain
```

Install missing prerequisites from the toolchain diagnostic. In the project root, run `cvlr setup . --component <module>` with every existing component you intend to keep and the new one. Supply `--package <name>` consistently for multi-program workspaces. Inspect scaffold and dependency changes against the deployed lockfile, features, program ID and instruction ABI. Explain material differences and resolve them before claiming production coverage. Read the generated reference's `cvlr.md` and the framework-specific instructions in `author.md` for these crate versions. [Certora Solana reference](https://docs.certora.com/en/latest/docs/solana/index.html)

Write the `#[rule]` in the scaffolded `src/certora/specs/<module>.rs`. Start with nondeterministic arguments and accounts. Invoke the production instruction path, including validation, handler and account writeback when relevant. A direct Anchor handler call can bypass signer, owner, PDA, alias and serialization checks. For authorization claims exercise invalid accounts as well as valid ones. Model writable flags, token authority and CPI effects when the claim depends on them. A stubbed CPI that leaves balances unchanged cannot establish token conservation. Check success/error paths explicitly with `cvlr_assert!` and justify every `cvlr_assume!`. For a reachable-state invariant, prove initialization and preservation at every writer, including close and reinitialize paths. Verify that summaries and feature gates preserve every effect under test.

After the three production reviews in the main skill, run the exact authored module. For a multi-program workspace append the package option to check and prove.

```bash
cvlr check . --component "$module"
# After a successful check:
cvlr prove . --component "$module"
# Use the returned job link and repeat while RUNNING:
cvlr wait "$report_url" --for 20
```

Match submitted rule names and per-instance verdicts against the intended properties. For a violation use `cvlr cex "$report_url" --rule "$rule"`. For vacuity, rerun that rule with `--unsat-core` and read `cvlr vacuity "$new_report_url" --rule "$rule"`. Inspect external-call and loop warnings. Record unmodeled CPI effects, any optimistic loop bounds and deployment assumptions with the verdict.
