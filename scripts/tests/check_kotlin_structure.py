#!/usr/bin/env python3
"""Structural sanity check for edited Kotlin sources.

This is NOT a compiler. It is a lexer that answers one question: did an edit
break the *shape* of a file in a way a compiler would reject immediately —
an unterminated raw string, an unbalanced brace, a mangled string template?

That was the real risk of a large comment/string sweep: raw-string blocks and `$`
interpolation are exactly where a careless text replacement destroys syntax
without changing anything a text diff would show as suspicious.

Getting this right took three passes, because a naive lexer cries wolf on valid
Kotlin and a checker that false-positives is worse than no checker:

  1. Backtick identifiers may contain apostrophes — `` `task's comm` `` is a
     legal (and common) test name, not an unterminated char literal.
  2. A run of four quotes at the end of a raw string is content plus delimiter:
     `\"\"\"echo "a && b"\"\"\"` is a complete raw string. Kotlin terminates on the
     last three of a run, not the first three.
  3. Inside `"${\u2026}"` the expression is ordinary code, so it may contain
     newlines, nested strings and nested templates. Treating the enclosing string
     as single-line reports valid files as broken.

Hence the recursive scanner below: `scan_code` recurses into `${…}` and into
nested strings, exactly mirroring the grammar instead of approximating it.

Run: python3 scripts/tests/check_kotlin_structure.py <file.kt> [...]
Exit status is 1 if any file looks structurally broken.
"""
import sys


class Scanner:
    def __init__(self, src, path):
        self.src = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.path = path
        self.errors = []

    # -- helpers -------------------------------------------------------------

    def peek(self, offset=0):
        j = self.i + offset
        return self.src[j] if j < self.n else ""

    def advance(self, count=1):
        for _ in range(count):
            if self.i < self.n:
                if self.src[self.i] == "\n":
                    self.line += 1
                self.i += 1

    def error(self, message, line=None):
        self.errors.append(f"{message} (line {line or self.line})")

    # -- scanners ------------------------------------------------------------

    def skip_line_comment(self):
        while self.i < self.n and self.src[self.i] != "\n":
            self.advance()

    def skip_block_comment(self):
        start = self.line
        self.advance(2)
        while self.i < self.n:
            if self.src[self.i] == "*" and self.peek(1) == "/":
                self.advance(2)
                return
            self.advance()
        self.error("unterminated block comment", start)

    def scan_backtick(self):
        start = self.line
        self.advance()
        while self.i < self.n:
            if self.src[self.i] == "`":
                self.advance()
                return
            if self.src[self.i] == "\n":
                self.error("unterminated backtick identifier", start)
                return
            self.advance()
        self.error("unterminated backtick identifier", start)

    def scan_char(self):
        start = self.line
        self.advance()
        while self.i < self.n:
            c = self.src[self.i]
            if c == "\\":
                self.advance(2)
                continue
            if c == "'":
                self.advance()
                return
            if c == "\n":
                self.error("unterminated char literal", start)
                return
            self.advance()
        self.error("unterminated char literal", start)

    def scan_raw(self):
        start = self.line
        self.advance(3)
        while self.i < self.n:
            if self.src[self.i] == '"':
                run = 0
                while self.peek(run) == '"':
                    run += 1
                if run >= 3:
                    # The LAST three quotes close the string; the rest are content.
                    self.advance(run)
                    return
                self.advance(run)
                continue
            self.advance()
        self.error("unterminated raw string", start)

    def scan_string(self):
        start = self.line
        self.advance()
        while self.i < self.n:
            c = self.src[self.i]
            if c == "\\":
                self.advance(2)
                continue
            if c == "$" and self.peek(1) == "{":
                self.i += 1                      # consume '$'
                self.advance()                   # consume '{'
                if not self.scan_code(stop_at_brace=True):
                    self.error("unterminated string template", start)
                    return
                continue
            if c == '"':
                self.advance()
                return
            if c == "\n":
                # Legal only inside a template, which is handled above.
                self.error("unterminated string", start)
                return
            self.advance()
        self.error("unterminated string", start)

    def scan_code(self, stop_at_brace=False, opened_at=None):
        """Lex code. Returns True when the stop condition was reached."""
        while self.i < self.n:
            c = self.src[self.i]

            if c == "}":
                if stop_at_brace:
                    self.advance()
                    return True
                self.error("unmatched '}'")

            if c == "{":
                # A brace block; recurse so its own `}` is matched, and report a
                # missing one with the line the block started on. Note this must
                # NOT be gated on stop_at_brace: a nested block inside a template
                # or inside another block needs the same treatment, and skipping
                # it here would make its `}` close the OUTER frame instead.
                line = self.line
                self.advance()
                if not self.scan_code(stop_at_brace=True, opened_at=line):
                    self.error("unclosed '{'", line)
                continue

            if c in "([":
                closer = {"(": ")", "[": "]"}[c]
                self.scan_bracket(closer)
                continue

            if c in ")]":
                self.error(f"unmatched '{c}'")

            if c == "/" and self.peek(1) == "/":
                self.skip_line_comment()
                continue
            if c == "/" and self.peek(1) == "*":
                self.skip_block_comment()
                continue
            if self.src.startswith('"""', self.i):
                self.scan_raw()
                continue
            if c == '"':
                self.scan_string()
                continue
            if c == "`":
                self.scan_backtick()
                continue
            if c == "'":
                self.scan_char()
                continue

            self.advance()

        return False if stop_at_brace else True

    def scan_bracket(self, closer):
        start = self.line
        self.advance()
        while self.i < self.n:
            c = self.src[self.i]
            if c == closer:
                self.advance()
                return
            if c in ")]" and c != closer:
                self.error(f"'{closer}' expected but '{c}' found, opened", start)
                return
            if c == "{" or (c == "}" and closer == "}"):
                # Shouldn't happen: `}` inside a bracket is legal only as a
                # block brace, so hand control back to scan_code for it.
                line = self.line
                self.advance()
                if not self.scan_code(stop_at_brace=True, opened_at=line):
                    self.error("unclosed '{'", line)
                continue
            if c == "(":
                self.scan_bracket(")")
                continue
            if c == "[":
                self.scan_bracket("]")
                continue
            if c == "/" and self.peek(1) == "/":
                self.skip_line_comment()
                continue
            if c == "/" and self.peek(1) == "*":
                self.skip_block_comment()
                continue
            if self.src.startswith('"""', self.i):
                self.scan_raw()
                continue
            if c == '"':
                self.scan_string()
                continue
            if c == "`":
                self.scan_backtick()
                continue
            if c == "'":
                self.scan_char()
                continue
            self.advance()
        self.error(f"unclosed '{closer}' counterpart, opened", start)


def check(path):
    src = open(path, encoding="utf-8").read()
    scanner = Scanner(src, path)
    scanner.scan_code()
    if src.count('"""') % 2:
        scanner.errors.append(f'odd number of raw-string delimiters ({src.count(chr(34) * 3)})')
    return scanner.errors


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    failed = 0
    for path in sys.argv[1:]:
        try:
            errors = check(path)
        except (OSError, UnicodeDecodeError) as exc:
            print(f"[ERROR] {path}: {exc}")
            failed += 1
            continue
        if errors:
            failed += 1
            print(f"[FAIL] {path}")
            for error in errors:
                print(f"        {error}")
        else:
            print(f"[ok]   {path}")

    print()
    if failed:
        print(f"{failed} file(s) look structurally broken")
        return 1
    print(f"{len(sys.argv) - 1} file(s) structurally OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
