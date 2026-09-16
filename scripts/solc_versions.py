#!/usr/bin/env python3
"""Print the concrete solc versions a Solidity project needs, one per line.

Run by install.sh --project <path>, using the interpreter of the installed
ai-composer tool venv. It deliberately reuses autosetup's own pragma parser
(certora_autosetup.utils.solc_version_resolver) rather than matching pragmas
with a regex here: the parser is SpecifierSet-based and already agrees with
what autosetup will later demand of PATH, so a second implementation could
only disagree with it.

Two details that are easy to get wrong and are load-bearing here:

* `resolve_pragma_to_version` is NOT used. It biases towards versions whose
  binary is already installed, which makes it circular when the question is
  "what should I download". We match the pragma against the raw upstream
  release list instead and take the highest release that satisfies it.
* foundry.toml can pin a compiler that no source file's pragma names, so the
  pinned versions are unioned in even when no pragma asks for them.
"""

import sys
import tomllib
from pathlib import Path

try:
    from packaging.version import Version
    from certora_autosetup.utils.solc_version_resolver import (
        extract_pragma_spec,
        parse_pragma_constraint,
        fetch_available_solc_versions,
    )
except ImportError as exc:  # pragma: no cover - environment problem, not logic
    sys.exit(
        f"solc_versions.py: cannot import autosetup's pragma parser ({exc}).\n"
        "Run this with the interpreter of the ai-composer tool venv, e.g.\n"
        '  "$(uv tool dir)"/ai-composer/bin/python scripts/solc_versions.py <project>'
    )

# Vendored dependencies and build output carry pragmas of their own; including
# them would install compilers for code the verification never compiles.
SKIP_DIRS = {"lib", "node_modules", "out", "cache", ".git", "artifacts", "test", "tests"}

# foundry.toml spellings autosetup itself accepts (build_systems/foundry.py).
FOUNDRY_SOLC_KEYS = ("solc", "solc_version", "solc-version")


def pinned_from_foundry(root: Path) -> set[str]:
    """Compiler versions pinned in foundry.toml, across all profiles."""
    out: set[str] = set()
    config = root / "foundry.toml"
    if not config.is_file():
        return out
    try:
        data = tomllib.loads(config.read_text(errors="ignore"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        print(f"warning: could not read {config}: {exc}", file=sys.stderr)
        return out
    for profile in (data.get("profile") or {}).values():
        if not isinstance(profile, dict):
            continue
        for key in FOUNDRY_SOLC_KEYS:
            value = profile.get(key)
            if isinstance(value, str):
                out.add(value.lstrip("v"))
    return out


def versions_from_pragmas(root: Path, available: list[Version]) -> set[str]:
    """Highest released version satisfying each distinct pragma in the tree."""
    specs: set[str] = set()
    for path in root.rglob("*.sol"):
        if SKIP_DIRS & set(path.relative_to(root).parts[:-1]):
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            # Broken symlinks under lib/ are common in checked-out corpora.
            continue
        spec = extract_pragma_spec(text)
        if spec:
            specs.add(spec)

    out: set[str] = set()
    for spec in specs:
        constraint = parse_pragma_constraint(spec)
        if constraint is None:
            print(f"warning: unparseable pragma {spec!r}", file=sys.stderr)
            continue
        pick = next((v for v in available if v in constraint), None)
        if pick is None:
            print(f"warning: no released solc satisfies {spec!r}", file=sys.stderr)
            continue
        out.add(str(pick))
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: solc_versions.py <project-root>", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if not root.is_dir():
        print(f"solc_versions.py: not a directory: {root}", file=sys.stderr)
        return 2

    try:
        available = sorted(
            (Version(v) for v in fetch_available_solc_versions()), reverse=True
        )
    except Exception as exc:  # network or upstream-format failure
        print(
            f"solc_versions.py: could not fetch the solc release list ({exc})",
            file=sys.stderr,
        )
        return 1

    needed = versions_from_pragmas(root, available) | pinned_from_foundry(root)
    if not needed:
        print(f"solc_versions.py: no pragmas or pins found under {root}", file=sys.stderr)
        return 1

    for version in sorted(needed, key=Version):
        print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
