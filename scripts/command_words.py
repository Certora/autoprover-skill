#!/usr/bin/env python3
"""Print the multi-word function names a shell script calls, one per line.

install.sh's self-test feeds these to `command -v`: a word that resolves to no
function, builtin or program is a call whose definition went away. `set -e` does
not catch that inside a function invoked under `||`, so the step reports success
and silently skips its work.

Comments, heredoc bodies and quoted strings are prose or another language's
source (the awk programs are both), never this script's commands, so they are
dropped before the scan.

Only words carrying an underscore are reported. That is the shape of every
function this script defines beyond a handful of one-word helpers, and it is
what keeps the output free of the words a shell uses in command position for
other reasons: `case` pattern labels (agents, cursor, gemini) and the field
verbs of an embedded awk program (print, next, skip) carry none.
"""

import re
import sys

WORD = re.compile(r"[a-z_][a-z0-9_]*")
HEREDOC = re.compile(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?")
KEYWORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "in", "function", "select", "time", "coproc",
}


def strip_quotes(line: str, open_quote: str) -> tuple[str, str]:
    """Return the line with quoted spans and any comment blanked, and the quote left open.

    The comment has to be cut here rather than before: an apostrophe in prose
    ("solc-select's store") would otherwise open a quote that never closes, and
    every line after it would read as quoted and be skipped.
    """
    out = []
    quote = open_quote
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            # A double-quoted string takes backslash escapes, so \" does not end
            # it; a single-quoted one takes none, and ends at the first quote.
            if quote == '"' and ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch == "\\" and i + 1 < len(line):
            out.append(" ")
            i += 2
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        # A `#` opens a comment only at the start of a word, which is what keeps
        # `${name##*/}` and `$#` intact.
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch)
        i += 1
    return "".join(out), quote


def command_words(text: str) -> list[str]:
    words: set[str] = set()
    quote = ""
    terminator = ""
    for raw in text.splitlines():
        if terminator:
            if raw.strip() == terminator:
                terminator = ""
            continue
        stripped, quote_after = strip_quotes(raw, quote)
        if not quote:
            here = HEREDOC.search(raw)
            if here:
                terminator = here.group(1)
        # A line that began inside a quote carries no command of its own.
        started_quoted = bool(quote)
        quote = quote_after
        if started_quoted:
            continue
        code = stripped.split("#", 1)[0]
        for part in re.split(r"[;&|]{1,2}|\$\(|`|\{|\}|\(|\)", code):
            head = part.lstrip()
            match = WORD.match(head)
            if not match:
                continue
            word = match.group(0)
            rest = head[match.end():]
            # `name=value` is an assignment and `name()` a definition, not a call.
            if rest[:1] in ("=", "(") or word in KEYWORDS:
                continue
            if "_" not in word:
                continue
            words.add(word)
    return sorted(words)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: command_words.py <script>", file=sys.stderr)
        raise SystemExit(2)
    with open(sys.argv[1], encoding="utf-8") as handle:
        for word in command_words(handle.read()):
            print(word)


main()
