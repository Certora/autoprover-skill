# autoprover-skill

The `certora-verify` Claude Code skill: end-to-end formal verification of a Solidity
contract with the Certora Prover. Given a Foundry or Hardhat project and a main contract,
it models the system's components, runs `certora-autosetup` to get a working prover
configuration and summaries, formulates security properties per component, formalizes them
in CVL, and iterates `certoraRun` until every rule is verified, flagged as a suspected bug,
or retired with a reason. The last phase writes a verification report.

## Layout

```
skills/certora-verify/
  SKILL.md              the skill itself: phases 0-7
  references/
    autosetup.md        certora-autosetup invocation, outputs, failure modes
    cvl-writing.md      docs map, writing guidelines, judge checklist
    cvl-pitfalls.md     traps that aren't on any single docs page
    prover-loop.md      building confs, running certoraRun, reading results
  evals/evals.json      dev-time eval set for skill authoring
```

## Using it

Symlink the skill directory into a workspace's skills directory:

```sh
ln -s /path/to/autoprover-skill/skills/certora-verify .claude/skills/certora-verify
```

The skill is standalone, but the environment it runs in needs:

- `certoraRun` on PATH (`pip install certora-cli`)
- `certora-autosetup` on PATH. This is a separate Certora tool and is not bundled with
  certora-cli.
- `CERTORAKEY` for the cloud prover, and `ANTHROPIC_API_KEY` for autosetup's internal LLM
  calls
- the `solcX.Y` binaries the target project's pragmas require

Phase 0 of the skill checks all of these and stops with a specific message if one is missing.

## Evals

`skills/certora-verify/evals/evals.json` describes its fixtures by shape rather than by
path, so a runner supplies its own equivalent projects. Evals 1 and 2 submit real cloud
prover jobs, so expect long wall-clock and real cost. Eval 3 is offline and cheap.
