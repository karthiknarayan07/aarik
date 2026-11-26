#!/usr/bin/env python3
"""Text checks over Swift string literals, run by scripts/verify.sh.

  text-lint.py ellipsis DIR...      fail on three dots ("...") inside a string literal; the text uses the ellipsis
                                    character (U+2026), as the system does. Ranges such as 1... are code, not text.
  text-lint.py tools FILELIST ALLOW fail when a string literal in an app-level screen (the files named in FILELIST,
                                    one path per line) names a tool or a tool-specific noun ("Convert", "Shrink",
                                    "compress"). ALLOW lists the legitimate literals, one per line, as
                                    `path :: literal text`; blank lines and lines starting with # are ignored.

The scanner understands comments, plain, raw (#"..."#) and multi-line (\"\"\") literals and skips the code inside
`\\( )` interpolations, so identifiers such as `shell.convert` never count.
"""
import os
import re
import sys

TOOL_NOUNS = re.compile(r"convert|shrink|compress", re.IGNORECASE)


def literals(source):
    """Yields (line, text) for each string literal; `text` excludes interpolated code."""
    i, n, line = 0, len(source), 1
    out = []

    def scan_string(start, hashes, multiline):
        # `start` is just past the opening quote(s). Returns (index after literal, text, lines consumed).
        j, parts, consumed = start, [], 0
        close = '"' * (3 if multiline else 1) + "#" * hashes
        escape = "\\" + "#" * hashes
        while j < n:
            if source.startswith(close, j):
                return j + len(close), "".join(parts), consumed
            if source.startswith(escape, j):
                nxt = j + len(escape)
                if nxt < n and source[nxt] == "(":
                    depth, k = 1, nxt + 1
                    while k < n and depth:
                        c = source[k]
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                        elif c == "\n":
                            consumed += 1
                        k += 1
                    parts.append("\\(…)")
                    j = k
                    continue
                parts.append(source[j : nxt + 1])
                j = nxt + 1
                continue
            if source[j] == "\n":
                consumed += 1
            parts.append(source[j])
            j += 1
        return n, "".join(parts), consumed

    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if source[i] == "\n":
                        line += 1
                    i += 1
        elif c in '#"':
            m = re.match(r'(#*)("""|")', source[i:])
            if not m:
                i += 1
                continue
            hashes, quotes = len(m.group(1)), m.group(2)
            start = i + len(m.group(0))
            end, text, consumed = scan_string(start, hashes, quotes == '"""')
            out.append((line, text))
            line += consumed
            i = end
        else:
            i += 1
    return out


def swift_files(roots):
    for root in roots:
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in (".build", "checkouts", "Tests")]
            for name in files:
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def ellipsis(roots):
    bad = []
    for path in swift_files(roots):
        for line, text in literals(open(path, encoding="utf-8").read()):
            if "..." in text:
                bad.append(f"{path}:{line}: \"{text.strip()[:80]}\" uses three dots; use the ellipsis character")
    return bad


def tools(filelist, allowfile):
    allowed = set()
    for raw in open(allowfile, encoding="utf-8"):
        raw = raw.rstrip("\n")
        if raw.strip() and not raw.lstrip().startswith("#"):
            path, _, text = raw.partition(" :: ")
            allowed.add((path.strip(), text))
    screens = [p.strip() for p in open(filelist, encoding="utf-8") if p.strip() and not p.startswith("#")]
    bad = []
    for path in screens:
        if not os.path.isfile(path):
            bad.append(f"{path}: listed as an app-level screen but missing")
            continue
        for line, text in literals(open(path, encoding="utf-8").read()):
            if TOOL_NOUNS.search(text) and (path, text) not in allowed:
                bad.append(f"{path}:{line}: app-level text names a tool: \"{text.strip()[:80]}\"")
    return bad


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "ellipsis" and len(argv) > 2:
        bad = ellipsis(argv[2:])
    elif mode == "tools" and len(argv) == 4:
        bad = tools(argv[2], argv[3])
    else:
        print(__doc__)
        return 2
    for message in bad:
        print(message)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
