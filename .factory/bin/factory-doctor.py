#!/usr/bin/env python3
"""factory-doctor's local checks: factory.yaml, commands.verify, hooks and settings, the machine file.

    python3 -I factory-doctor.py checks --target DIR --defaults FILE --machine FILE [--labels FILE]
    python3 -I factory-doctor.py yaml FILE      # parse one file with the reader below; print it as JSON
    python3 -I factory-doctor.py render RECORDS "<check> ..." TARGET EXIT [--json]   # the doctor's output

`checks` prints one record per line, fields separated by a tab:
    R <check> <ok|warn|fail|n/a> <message> <fix>    the result of a check
    D <check> <text>                                 a detail line under that result
    F <name> <value>                                 a fact for the shell script (repo, version, min_free_gb, and
                                                     min_free_gb_why when no minimum could be read)
    L <label>                                        a label the project should have

Standard library only; runs on Python 3.8 and later. It reads files and never changes one, and never runs a project
command.

Credentials: the shapes are listed once (SHAPES). An input value that holds one makes its file fail, named by key
path. A diagnostic shows an input value only through shown(), which gives "<redacted: looks like a credential>" for
any value that holds a shape or a fragment of one, and every record and every field of the final output (text and
JSON alike, from `render`) passes redact() as well, so text from other tools (gh, the broker) is covered too.

The YAML reader accepts a strict, documented subset and refuses everything else, with the line number:
    - block mappings with plain keys (letters, digits, _ . -) or quoted keys; block sequences, also of mappings;
    - flow sequences and mappings, also across lines, with comments between entries;
    - single-quoted and double-quoted scalars on one line; literal and folded block scalars (| > with - or +);
    - plain scalars on one line, or, as a block mapping value or a block sequence entry, continued on the lines below
      that are indented more than the line the value starts on: the lines are joined by single spaces (YAML line
      folding), each stripped of its indentation;
    - comments; one leading `---`.
    Refused: anchors, aliases, tags, directives, `?` keys, explicit block indentation, tabs in indentation, duplicate
    keys, quoted scalars across lines, plain scalars across lines inside [ ] or { }, and plain values whose type
    differs between YAML 1.1 and 1.2 (yes, no, on, off, octal-looking numbers, dates): quote those. A line that
    continues a plain value is refused when it holds `: ` or ends with `:`, holds ` #`, starts with an indicator
    (- ? : # [ ] { } , & * ! | > ' " % @ `), or follows a blank line (a paragraph break folds to a line break, which
    this subset does not read); a value with a comment on its first line, or on a comment line, ends there.
"""

import json
import os
import re
import shlex
import shutil
import sys
import warnings

warnings.simplefilter("ignore")   # a warning would print a source line and a path; nothing is printed unasked


# --- credentials: detected in one place, never shown ----------------------------------------------------------------

REDACTED = "<redacted: looks like a credential>"
WORD_START = r"(?<![A-Za-z0-9_])"
# (kind, full shape, fragment). A full shape in an input value makes that value a credential: factory.yaml and the
# machine file fail on it. A fragment (a shape's prefix with enough characters after it) is enough to blank text in a
# diagnostic, so a value cut short or quoted is still blanked.
SHAPES = (
    ("GitHub token", r"gh[pousr]_[A-Za-z0-9]{20,}", r"gh[pousr]_[A-Za-z0-9]{6,}"),
    ("GitHub fine-grained token", r"github_pat_[A-Za-z0-9_]{20,}", r"github_pat_[A-Za-z0-9_]{6,}"),
    ("GitLab token", r"glpat-[A-Za-z0-9_\-]{20,}", r"glpat-[A-Za-z0-9_\-]{6,}"),
    ("secret API key", r"sk-[A-Za-z0-9_\-]{20,}", r"sk-[A-Za-z0-9_\-]{10,}"),
    ("payment API key", r"[rs]k_(?:live|test)_[A-Za-z0-9]{16,}", r"[rs]k_(?:live|test)_[A-Za-z0-9]{6,}"),
    ("Slack token", r"xox[abposr]-[A-Za-z0-9\-]{10,}", r"xox[abposr]-[A-Za-z0-9\-]{6,}"),
    ("AWS access key", r"(?:AKIA|ASIA)[0-9A-Z]{16}", r"(?:AKIA|ASIA)[0-9A-Z]{8,}"),
    ("Google API key", r"AIza[0-9A-Za-z_\-]{35}", r"AIza[0-9A-Za-z_\-]{8,}"),
    ("npm token", r"npm_[A-Za-z0-9]{36}", r"npm_[A-Za-z0-9]{12,}"),
    ("JSON web token", r"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}", r"eyJ[A-Za-z0-9_\-]{12,}"),
    ("private key", r"-----BEGIN [A-Z ]*PRIVATE KEY", r"-----BEGIN [A-Z ]*PRIVATE KEY.*"),
    ("URL with a password", r"[A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@]+:[^/\s@]+@", r"[A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@]+:[^/\s@]+@\S*"),
)
# Detection in an input value (is_secret, which fails factory.yaml) keeps a word boundary on the left, so ordinary
# words such as "risk-..." are not called credentials. Redaction of output has no left boundary: a shape glued to a
# prefix ("proj_ghp_...", an escaped "\\n" before it) is still blanked. Blanking a little too much is the safe side.
SECRET = re.compile("|".join(WORD_START + "(?:" + full + ")" for _, full, _ in SHAPES))
FRAGMENT = re.compile("|".join(WORD_START + "(?:" + frag + ")" for _, _, frag in SHAPES))
# One exception: the bare "sk-" shape is common inside ordinary words ("risk-", "task-"), so it keeps a boundary
# against letters and digits, but not against "_" or punctuation.
LOOSE = {"secret API key": r"(?<![A-Za-z0-9])"}
ANY_SECRET = re.compile("|".join(LOOSE.get(kind, "") + "(?:" + full + ")" for kind, full, _ in SHAPES))
ANY_FRAGMENT = re.compile("|".join(LOOSE.get(kind, "") + "(?:" + frag + ")" for kind, _, frag in SHAPES))


def is_secret(value):
    """True when an input value holds a full credential shape."""
    return isinstance(value, str) and SECRET.search(value) is not None


def redact(text):
    """Text with every credential shape and fragment blanked: the one redaction every output passes through."""
    return ANY_FRAGMENT.sub(REDACTED, ANY_SECRET.sub(REDACTED, str(text)))


def shown(value, quote=True, limit=60):
    """An input value as a diagnostic may show it: the placeholder when it holds a credential shape or fragment,
    else its repr (or the plain text with quote=False), shortened. Detection runs on the whole value, before any
    shortening, so a cut can never turn a credential into something that passes."""
    text = value if isinstance(value, str) else repr(value)
    if ANY_SECRET.search(text) or ANY_FRAGMENT.search(text):
        return REDACTED
    out = repr(value) if quote else text
    return out if len(out) <= limit else out[:limit - 3] + "..."


def key(k):
    """A key as part of a key path in a diagnostic."""
    return shown(str(k), quote=False)


# --- the YAML subset reader -----------------------------------------------------------------------------------------

class Refused(Exception):
    pass


PLAIN_KEY = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.\-]*")
KEY_LINE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.\-]*):(?= |$)")
ESCAPES = {"\\": "\\", '"': '"', "/": "/", "n": "\n", "t": "\t", "r": "\r", "0": "\0", "a": "\a", "b": "\b",
           "e": "\x1b", "f": "\f", "v": "\v", " ": " ", "\t": "\t", "N": "\x85", "_": "\xa0", "L": "\u2028",
           "P": "\u2029"}


def resolve_plain(v, where):
    """The value of a plain scalar, refusing spellings that YAML 1.1 and 1.2 readers disagree on."""
    if v in ("true", "True", "TRUE"):
        return True
    if v in ("false", "False", "FALSE"):
        return False
    if v in ("null", "Null", "NULL", "~", ""):
        return None
    if v.lower() in ("yes", "no", "on", "off", "y", "n"):
        raise Refused("%s: %s is true or false to some YAML readers and a string to others; quote it" % (where, shown(v)))
    if re.fullmatch(r"[-+]?0[0-9]+", v) or re.fullmatch(r"[-+]?0[xob][0-9A-Fa-f_]+", v):
        raise Refused("%s: %s is a number in another base to some YAML readers; quote it" % (where, shown(v)))
    if re.fullmatch(r"[-+]?[0-9]+", v):
        return int(v)
    if re.fullmatch(r"[-+]?(\.[0-9]+|[0-9]+\.[0-9]*)([eE][-+]?[0-9]+)?", v) or re.fullmatch(r"[-+]?[0-9]+[eE][-+]?[0-9]+", v):
        return float(v)
    if v.lower() in (".inf", "+.inf", "-.inf", ".nan") or re.fullmatch(r"[0-9_]+(:[0-9_]+)+(\.[0-9]*)?", v) \
            or re.fullmatch(r"[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt ].*)?", v) or re.fullmatch(r"[-+]?[0-9][0-9_]*_[0-9_]*", v):
        raise Refused("%s: %s has a special meaning to some YAML readers; quote it" % (where, shown(v)))
    return v


def quoted(s, p, where):
    """A single- or double-quoted scalar starting at s[p], ending on the same line. Returns (value, end)."""
    q = s[p]
    p += 1
    out = []
    while True:
        if p >= len(s) or s[p] == "\n":
            raise Refused("%s: a quoted value that does not end on its line" % where)
        c = s[p]
        if q == "'":
            if c == "'":
                if p + 1 < len(s) and s[p + 1] == "'":
                    out.append("'")
                    p += 2
                    continue
                return "".join(out), p + 1
            out.append(c)
            p += 1
            continue
        if c == '"':
            return "".join(out), p + 1
        if c == "\\":
            e = s[p + 1] if p + 1 < len(s) else ""
            if e in ESCAPES:
                out.append(ESCAPES[e])
                p += 2
                continue
            n = {"x": 2, "u": 4, "U": 8}.get(e)
            h = s[p + 2:p + 2 + n] if n else ""
            if n and re.fullmatch("[0-9A-Fa-f]{%d}" % n, h) and int(h, 16) <= 0x10FFFF:
                out.append(chr(int(h, 16)))
                p += 2 + n
                continue
            raise Refused("%s: an escape this reader does not know (\\%s)" % (where, e))
        out.append(c)
        p += 1


def fold(lines):
    """Folded block scalar content (the indentation already removed), without its final line break."""
    out, prev, empties = "", None, 0
    for line in lines:
        if line == "":
            empties += 1
            continue
        more = line[0] in " \t"
        if prev is None:
            out += "\n" * empties
        else:
            kept = more or prev[0] in " \t"
            out += ("\n" if kept else " ") if empties == 0 else "\n" * (empties + (1 if kept else 0))
        out += line
        prev, empties = line, 0
    return out


class Reader:
    def __init__(self, text):
        if text.startswith("﻿"):
            text = text[1:]
        self.lines = []
        for n, line in enumerate(text.split("\n"), 1):
            if line.endswith("\r"):
                line = line[:-1]
            if "\r" in line:
                raise Refused("line %d: a carriage return inside a line" % n)
            self.lines.append(line)
        self.n = len(self.lines)

    def refuse(self, msg, i):
        raise Refused("line %d: %s" % (i + 1, msg))

    def meaningful(self, i):
        s = self.lines[i].strip(" \t")
        return s != "" and not s.startswith("#")

    def next_meaningful(self, i):
        while i < self.n and not self.meaningful(i):
            i += 1
        return i

    def indent(self, i):
        line = self.lines[i]
        s = len(line) - len(line.lstrip(" "))
        if line[s:s + 1] == "\t" and self.meaningful(i):
            self.refuse("a tab in the indentation", i)
        return s

    def parse(self):
        i = self.next_meaningful(0)
        if i < self.n and self.lines[i].lstrip().startswith("%"):
            self.refuse("a directive (not supported)", i)
        if i < self.n and re.fullmatch(r"---(\s+#.*)?\s*", self.lines[i]):
            i = self.next_meaningful(i + 1)
        if i >= self.n:
            return None
        if self.indent(i) != 0:
            self.refuse("the document does not start at the left margin", i)
        value, i = self.block(i, 0)
        i = self.next_meaningful(i)
        if i < self.n:
            self.refuse("unexpected content (a second document, or a line out of place)", i)
        return value

    def is_item(self, i, ind):
        c = self.lines[i][ind:]
        if c.startswith("-\t"):
            self.refuse("a tab after a dash", i)
        return c == "-" or c.startswith("- ")

    def block(self, i, ind):
        if self.is_item(i, ind):
            return self.sequence(i, ind)
        return self.mapping(i, ind)

    def key_at(self, content, i):
        """(key, rest) when content starts with `key:` followed by a space or the end, else None."""
        if content[:1] in ("'", '"'):
            k, p = quoted(content, 0, "line %d" % (i + 1))
            if content[p:p + 1] == ":" and content[p + 1:p + 2] in ("", " "):
                return k, content[p + 1:]
            return None
        m = KEY_LINE.match(content)
        return (m.group(1), content[m.end():]) if m else None

    def mapping(self, i, ind):
        out = {}
        while True:
            i = self.next_meaningful(i)
            if i >= self.n or self.indent(i) < ind:
                return out, i
            if self.indent(i) > ind:
                self.refuse("unexpected indentation (a value across lines is not supported; quote it or use | or >)", i)
            if self.is_item(i, ind):
                self.refuse("a list item where a key was expected", i)
            content = self.lines[i][ind:]
            kv = self.key_at(content, i)
            if kv is None:
                self.refuse("not a `key: value` line (keys are letters, digits, _ . - or quoted)", i)
            k, rest = kv
            if k in out:
                self.refuse("the key %s appears twice" % shown(k), i)
            out[k], i = self.value(rest, i, ind)

    def value(self, rest, i, ind):
        """The value after `key:` (or after a dash) on line i, in a block at indentation ind."""
        r = rest.strip(" ")
        if r == "" or r.startswith("#"):
            j = self.next_meaningful(i + 1)
            if j < self.n:
                lj = self.indent(j)
                if lj > ind:
                    return self.block(j, lj)
                if lj == ind and self.is_item(j, ind):
                    return self.sequence(j, ind)
            return None, i + 1
        if r[0] in "|>":
            return self.block_scalar(r, i, ind)
        return self.inline(r, i, ind)

    def tail_ok(self, tail, i):
        if tail.strip(" \t") and not re.match(r"[ \t]+#", tail):
            self.refuse("unexpected text after a value: %s" % shown(tail.strip()), i)

    def inline(self, r, i, ind):
        where = "line %d" % (i + 1)
        if r[0] in "[{":
            text = r + "\n" + "\n".join(self.lines[i + 1:])
            flow = Flow(text, i)
            v, p = flow.node(0)
            end = i + text.count("\n", 0, p)
            eol = text.find("\n", p)
            self.tail_ok(text[p:eol if eol >= 0 else len(text)], end)
            for k in range(i + 1, end + 1):
                if self.meaningful(k) and self.indent(k) <= ind:
                    self.refuse("a flow collection continues on a line that is not indented more than its key", k)
            return v, end + 1
        if r[0] in "'\"":
            v, p = quoted(r, 0, where)
            self.tail_ok(r[p:], i)
            return v, i + 1
        if r[0] in "&*!%@`?,[]{}" or r == "-" or r.startswith("- "):
            self.refuse("anchors, aliases, tags and values starting with %r are not supported; quote the value" % r[0], i)
        m = re.search(r"[ \t]#", r)
        v = (r[:m.start()] if m else r).rstrip(" \t")
        if re.search(r":([ \t]|$)", v):   # a tab separates as a space does (review of #145)
            self.refuse("a `: ` inside a plain value; quote it", i)
        if m:   # a comment ends the value; a more-indented line after it is refused by the caller
            return resolve_plain(v, where), i + 1
        parts, j = self.continuation(i, ind)
        return resolve_plain(" ".join([v] + parts), where), j

    def continuation(self, i, ind):
        """The lines that continue a plain value started on line i (YAML line folding: joined by single spaces).

        A continuation line is indented more than ind and is refused when real YAML could read it differently: a
        `: ` or a trailing `:`, a ` #`, a first character that is an indicator, or a blank line before it (a
        paragraph break, which folds to a line break). A comment line ends the value. Returns (parts, next line)."""
        parts, j = [], i + 1
        while j < self.n:
            line = self.lines[j]
            s = line.strip(" \t")
            if s == "":
                k = j
                while k < self.n and self.lines[k].strip(" \t") == "":
                    k += 1
                if k < self.n and not self.lines[k].strip(" \t").startswith("#") and self.indent(k) > ind:
                    self.refuse("a plain value continues after a blank line (a line break in the value is not "
                                "supported; use | or >)", k)
                break
            if s.startswith("#") or self.indent(j) <= ind:
                break
            if s[0] in "-?:#[]{},&*!|>'\"%@`":
                self.refuse("a line that continues a plain value starts with %r; quote the value or use >" % s[0], j)
            if re.search(r":([ \t]|$)", s):
                self.refuse("a `: ` in a line that continues a plain value; quote the value or use >", j)
            if re.search(r"[ \t]#", s):
                self.refuse("a ` #` in a line that continues a plain value; quote the value or use >", j)
            parts.append(s)
            j += 1
        return parts, j

    def sequence(self, i, ind):
        out = []
        while True:
            i = self.next_meaningful(i)
            if i >= self.n or self.indent(i) < ind:
                return out, i
            if self.indent(i) > ind:
                self.refuse("unexpected indentation (a value across lines is not supported; quote it or use | or >)", i)
            if not self.is_item(i, ind):
                return out, i
            content = self.lines[i][ind + 1:]
            stripped = content.lstrip(" ")
            off = ind + 1 + len(content) - len(stripped)
            if stripped == "" or stripped.startswith("#"):
                v, i = self.value("", i, ind)
            elif stripped == "-" or stripped.startswith("- ") or self.key_at(stripped, i) is not None:
                self.lines[i] = " " * off + stripped   # the item's content as a block at its own column
                v, i = self.block(i, off)
            elif stripped[0] in "|>":
                v, i = self.block_scalar(stripped, i, ind)
            else:
                v, i = self.inline(stripped, i, ind)
            out.append(v)

    def block_scalar(self, header, i, ind):
        m = re.fullmatch(r"([|>])([-+]?)([ \t]+#.*)?[ \t]*", header)
        if not m:
            self.refuse("a block scalar header this reader does not support (explicit indentation?)", i)
        style, chomp = m.group(1), m.group(2)
        k = i + 1
        while k < self.n and self.lines[k].strip(" \t") == "":
            k += 1
        if k >= self.n or self.indent(k) <= ind:
            return ("\n" if chomp == "+" else ""), k
        ci = self.indent(k)
        body, j = [], i + 1
        while j < self.n:
            line = self.lines[j]
            if line.strip(" \t") == "":
                body.append("")
            elif len(line) - len(line.lstrip(" ")) < ci:
                break
            else:
                body.append(line[ci:])
            j += 1
        trailing = 0
        while body and body[-1] == "":
            body.pop()
            trailing += 1
        text = "\n".join(body) if style == "|" else fold(body)
        if chomp == "-":
            return text, j
        return text + "\n" + ("\n" * trailing if chomp == "+" else ""), j


class Flow:
    """Flow collections over a text that may span lines; `line0` is the line the text starts on."""

    def __init__(self, text, line0):
        self.t, self.line0 = text, line0

    def where(self, p):
        return "line %d" % (self.line0 + 1 + self.t.count("\n", 0, p))

    def refuse(self, msg, p):
        raise Refused("%s: %s" % (self.where(p), msg))

    def ws(self, p):
        t = self.t
        while p < len(t):
            if t[p] in " \t\n":
                p += 1
            elif t[p] == "#" and (p == 0 or t[p - 1] in " \t\n"):
                eol = t.find("\n", p)
                p = len(t) if eol < 0 else eol
            else:
                break
        return p

    def at(self, p):
        return self.t[p] if p < len(self.t) else ""

    def node(self, p):
        p = self.ws(p)
        c = self.at(p)
        if c == "[":
            return self.seq(p + 1)
        if c == "{":
            return self.map(p + 1)
        if c in ("'", '"'):
            return quoted(self.t, p, self.where(p))
        return self.plain(p)

    def seq(self, p):
        out = []
        while True:
            p = self.ws(p)
            if p >= len(self.t):
                self.refuse("a [ that is never closed", p)
            if self.at(p) == "]":
                return out, p + 1
            v, p = self.node(p)
            p = self.ws(p)
            if self.at(p) == ":":
                self.refuse("a `key: value` pair inside [ ] is not supported", p)
            out.append(v)
            if self.at(p) == ",":
                p += 1
            elif self.at(p) == "]":
                return out, p + 1
            else:
                self.refuse("expected , or ]", p)

    def map(self, p):
        out = {}
        while True:
            p = self.ws(p)
            if p >= len(self.t):
                self.refuse("a { that is never closed", p)
            if self.at(p) == "}":
                return out, p + 1
            if self.at(p) in ("'", '"'):
                k, p = quoted(self.t, p, self.where(p))
            else:
                m = PLAIN_KEY.match(self.t, p)
                if not m:
                    self.refuse("a key that is not letters, digits, _ . - or quoted", p)
                k, p = m.group(0), m.end()
            if self.at(p) != ":" or self.at(p + 1) not in (" ", "\t", "\n", ",", "}"):
                self.refuse("expected `: ` after the key %s" % shown(k), p)
            if k in out:
                self.refuse("the key %s appears twice" % shown(k), p)
            p = self.ws(p + 1)
            if self.at(p) in (",", "}"):
                v = None
            else:
                v, p = self.node(p)
            out[k] = v
            p = self.ws(p)
            if self.at(p) == ",":
                p += 1
            elif self.at(p) == "}":
                return out, p + 1
            else:
                self.refuse("expected , or }", p)

    def plain(self, p):
        t = self.t
        c = self.at(p)
        if c == "" or c in ",]}&*!%@`?|>" or (c == "-" and self.at(p + 1) in ("", " ", "\t", "\n", ",", "]", "}")):
            self.refuse("an empty value, or one starting with %r; quote it" % c, p)
        q = p
        while q < len(t):
            ch = t[q]
            if ch in ",]}\n" or (ch == ":" and self.at(q + 1) in ("", " ", "\t", "\n", ",", "]", "}")):
                break
            if ch in "[{":
                self.refuse("a [ or { inside a plain value; quote it", q)
            if ch == "#" and t[q - 1] in " \t":
                break
            q += 1
        v = t[p:q].rstrip(" \t")
        r = self.ws(q)
        if r > q and self.at(r) not in ("", ",", "]", "}", ":"):
            self.refuse("a plain value across lines; quote it", r)
        return resolve_plain(v, self.where(p)), q


def load_yaml(path):
    with open(path, encoding="utf-8") as f:
        return Reader(f.read()).parse()


# --- the checks -----------------------------------------------------------------------------------------------------

OUT = []


def clean(s):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(s))


def result(check, status, message, fix=""):
    OUT.append("R\t%s\t%s\t%s\t%s" % (check, status, redact(clean(message)), redact(clean(fix))))


def detail(check, text):
    OUT.append("D\t%s\t%s" % (check, redact(clean(text))))


def fact(name, value):
    OUT.append("F\t%s\t%s" % (name, redact(clean(value))))


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_str(v, empty=False):
    return isinstance(v, str) and (empty or v.strip() != "")


def str_list(v, empty=True):
    return isinstance(v, list) and all(is_str(x) for x in v) and (empty or len(v) > 0)


TOP_KEYS = {"factory", "project", "mode", "commands", "work_kinds", "roles", "models", "ci", "licences", "human_gates",
            "deploy", "packs", "demo"}
TIERS = ("deep", "standard", "light")
TOP_EFFORTS = {"xhigh", "max", "ultra", "ultrathink"}
TOP_MODELS = {"claude-fable-5-2"}
CROSS_PROVIDER_TIERS = ("deep", "standard")   # a first review of this work runs on another provider than the builder
REVIEW_LISTS = ("re_review", "docs_only")     # models.reviews keys that hold a list of candidate specs
EFFORT_RANK = {"minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6, "ultrathink": 6}
SPEC = re.compile(r"([a-z0-9][a-z0-9-]*)/([A-Za-z0-9][A-Za-z0-9._-]*)(?:/([a-z]+))?")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]*")
CHECK_NAME = re.compile(r"[a-z][a-z0-9_]*")
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
LANG = re.compile(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*")


def walk_secrets(node, path, found):
    if isinstance(node, dict):
        for k, v in node.items():
            p = "%s.%s" % (path, key(k)) if path else key(k)
            if is_secret(str(k)):
                found.append(path or "(top level)")
            walk_secrets(v, p, found)
    elif isinstance(node, list):
        for n, v in enumerate(node):
            walk_secrets(v, "%s[%d]" % (path, n), found)
    elif is_secret(node):
        found.append(path)


def merge(base, over):
    """Maps merge per key; lists and scalars replace."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merge(base.get(k), v) if k in base else v
        return out
    return over


def unknown(node, allowed, path, errs):
    for k in node:
        if k not in allowed:
            errs.append("%s: unknown key %s" % (path, shown(k)))


def check_models(project_models, defaults, errs, warns):
    core = (defaults or {}).get("models") or {}
    if project_models is not None and not isinstance(project_models, dict):
        errs.append("models: must be a map")
        return
    pm = project_models or {}
    unknown(pm, {"tiers", "agents", "helpers", "reviews", "escalation"}, "models", errs)
    for part in ("tiers", "agents", "helpers", "reviews"):
        if part in pm and not isinstance(pm[part], dict):
            errs.append("models.%s: must be a map" % part)
            return
    for part in ("agents", "helpers", "reviews"):
        if core.get(part):
            unknown(pm.get(part) or {}, set(core[part]), "models." + part, errs)
    unknown(pm.get("tiers") or {}, set(TIERS), "models.tiers", errs)
    for tier, v in (pm.get("tiers") or {}).items():
        if not isinstance(v, dict):
            errs.append("models.tiers.%s: must be a map of build and review" % tier)
            return
        unknown(v, {"build", "review"}, "models.tiers." + tier, errs)
    for k, v in (pm.get("reviews") or {}).items():
        if k in REVIEW_LISTS and not str_list(v, empty=False):
            errs.append("models.reviews.%s: must be a non-empty list of model specs" % key(k))
            return
    if "escalation" in pm and not str_list(pm["escalation"], empty=False):
        errs.append("models.escalation: must be a non-empty list of model specs")
        return
    m = merge(core, pm)

    def origin(path):
        node = pm
        for part in path.split("[")[0].split(".")[1:]:
            if not isinstance(node, dict) or part not in node:
                return "the core defaults"
            node = node[part]
        return "factory.yaml"

    def spec(path, v):
        mm = SPEC.fullmatch(v) if isinstance(v, str) else None
        if not mm:
            errs.append("%s: %s is not <provider>/<model>[/<effort>]" % (path, shown(v)))
        return mm

    defaults_list = []
    for tier in TIERS:
        t = (m.get("tiers") or {}).get(tier)
        if not isinstance(t, dict) or "build" not in t or "review" not in t:
            errs.append("models.tiers.%s: needs build and review" % tier)
            continue
        b, r = spec("models.tiers.%s.build" % tier, t["build"]), spec("models.tiers.%s.review" % tier, t["review"])
        defaults_list += [("models.tiers.%s.build" % tier, b), ("models.tiers.%s.review" % tier, r)]
        if b and r and tier in CROSS_PROVIDER_TIERS and b.group(1) == r.group(1):
            errs.append("models.tiers.%s: build and review use the same provider (%s); a first review of %s work runs"
                        " on another" % (tier, shown(b.group(1), quote=False), tier))
        elif b and r and (b.group(1), b.group(2)) == (r.group(1), r.group(2)):
            errs.append("models.tiers.%s: build and review use the same model (%s); the reviewer must use another"
                        % (tier, shown("%s/%s" % (b.group(1), b.group(2)), quote=False)))
    for part in ("agents", "helpers", "reviews"):
        for k, v in (m.get(part) or {}).items():
            p = "models.%s.%s" % (part, key(k))
            if part == "reviews" and k in REVIEW_LISTS:
                if not str_list(v, empty=False):
                    errs.append("%s: must be a non-empty list of model specs" % p)
                    continue
                defaults_list += [("%s[%d]" % (p, n), spec("%s[%d]" % (p, n), x)) for n, x in enumerate(v)]
            else:
                defaults_list.append((p, spec(p, v)))
    # Each review list must hold, for every model whose work it may review (each tier's builder and the lead, who fixes
    # findings itself), a candidate on another model. A different effort never makes a candidate independent.
    def ident(v):
        mm = SPEC.fullmatch(v) if isinstance(v, str) else None
        return (mm.group(1), mm.group(2)) if mm else None
    authors = []
    for tier in TIERS:
        t = (m.get("tiers") or {}).get(tier)
        if isinstance(t, dict) and ident(t.get("build")):
            authors.append(("models.tiers.%s.build" % tier, ident(t["build"])))
    if ident((m.get("agents") or {}).get("lead")):
        authors.append(("models.agents.lead", ident(m["agents"]["lead"])))
    for k in REVIEW_LISTS:
        v = (m.get("reviews") or {}).get(k)
        cands = [ident(x) for x in v] if str_list(v, empty=False) else []
        if not cands or None in cands:
            continue   # a missing list or a bad spec is reported above
        seen = set()
        for path, who in authors:
            if who in seen or any(c != who for c in cands):
                continue
            seen.add(who)
            errs.append("models.reviews.%s: no entry can review work by %s (%s): every candidate is that model; add one"
                        " on another model (set in %s)" % (key(k), shown("%s/%s" % who, quote=False), path,
                                                           origin("models.reviews." + k)))
    for path, mm in defaults_list:
        if mm and (mm.group(3) in TOP_EFFORTS or mm.group(2) in TOP_MODELS):
            errs.append("%s: %s is a top setting, for escalation only, never a default (set in %s)"
                        % (path, shown(mm.group(0), quote=False), origin(path)))
    ladder = m.get("escalation") or []
    specs = [spec("models.escalation[%d]" % n, v) for n, v in enumerate(ladder)]
    order = []
    for v in (core.get("escalation") or []):
        mm = SPEC.fullmatch(v) if isinstance(v, str) else None
        if mm and (mm.group(1), mm.group(2)) not in order:
            order.append((mm.group(1), mm.group(2)))
    where = origin("models.escalation")
    for n in range(1, len(specs)):
        a, b = specs[n - 1], specs[n]
        if not a or not b:
            continue
        ma, mb = (a.group(1), a.group(2)), (b.group(1), b.group(2))
        ea, eb = EFFORT_RANK.get(a.group(3) or ""), EFFORT_RANK.get(b.group(3) or "")
        step = "models.escalation: %s -> %s" % (shown(a.group(0), quote=False), shown(b.group(0), quote=False))
        if ma == mb:
            if ea is None or eb is None:
                warns.append("%s: cannot tell whether this steps up (an effort is missing or unknown)" % step)
            elif eb <= ea:
                errs.append("%s steps down or stays level; the ladder only steps up (set in %s)" % (step, where))
        elif ma in order and mb in order:
            if order.index(mb) < order.index(ma):
                errs.append("%s steps down to a weaker model; the ladder only steps up (set in %s)" % (step, where))
        else:
            warns.append("%s: cannot tell whether this steps up (a model the core ladder does not rank)" % step)


def own_workflows(target, limit=5):
    """The project's own workflow files (.github/workflows, top level, not factory-*), as a shown, comma-joined list
    capped at `limit` names; "" when there are none or the folder cannot be read."""
    github = os.path.join(target, ".github")
    folder = os.path.join(github, "workflows")
    try:
        # Every part below the repo root must be a real folder: a link could lead outside the repo.
        if os.path.islink(github) or os.path.islink(folder) or not os.path.isdir(folder):
            return ""
        names = sorted(n for n in os.listdir(folder)
                       if n.endswith((".yml", ".yaml")) and not n.startswith("factory-")
                       and os.path.isfile(os.path.join(folder, n)) and not os.path.islink(os.path.join(folder, n)))
    except OSError:
        return ""
    more = len(names) - limit
    out = ", ".join(shown(n, quote=False) for n in names[:limit])
    return out + (" and %d more" % more if more > 0 else "")


def check_factory_yaml(target, defaults):
    """Returns the parsed document (or None) after reporting the factory.yaml result."""
    path = os.path.join(target, "factory.yaml")
    name = "factory.yaml"
    if not os.path.isfile(path):
        result(name, "fail", "no factory.yaml at the repo root", "install the factory with /factory-init, which writes it")
        return None
    try:
        doc = load_yaml(path)
    except Refused as e:
        result(name, "fail", "cannot be read: %s" % e, "fix that line; quote values the reader names and keep to the "
               "subset in the factory-doctor skill")
        return None
    except (OSError, UnicodeDecodeError) as e:
        result(name, "fail", "cannot be read: %s" % e.__class__.__name__, "make factory.yaml a readable UTF-8 file")
        return None
    if not isinstance(doc, dict):
        result(name, "fail", "is not a map of keys", "start from the core template (factory-init writes it)")
        return None
    errs, warns = [], []
    found = []
    walk_secrets(doc, "", found)
    for p in found:
        errs.append("%s: looks like a credential (value not shown); no secrets in factory.yaml, ever" % p)
    unknown(doc, TOP_KEYS, "(top level)", errs)

    if not is_str(doc.get("factory")) or not SEMVER.fullmatch(doc["factory"]):
        errs.append("factory: required, the core version as a semver string such as 0.1.0")
    project = doc.get("project")
    if not isinstance(project, dict):
        errs.append("project: required, a map with repo and languages")
        project = {}
    unknown(project, {"repo", "name", "languages"}, "project", errs)
    if not is_str(project.get("repo")) or not REPO.fullmatch(project["repo"]):
        errs.append("project.repo: required, owner/name")
    if "name" in project and not is_str(project["name"]):
        errs.append("project.name: must be a string")
    langs = project.get("languages")
    if not str_list(langs, empty=False) or not all(LANG.fullmatch(x) for x in langs):
        errs.append("project.languages: required, a non-empty list of BCP 47 language tags")
    mode = doc.get("mode", "solo")
    if mode not in ("solo", "team"):
        errs.append("mode: solo or team")

    commands = doc.get("commands")
    checks = {}
    if not isinstance(commands, dict):
        errs.append("commands: required, a map with at least verify")
        commands = {}
    unknown(commands, {"setup", "verify", "serve", "checks"}, "commands", errs)
    if "setup" in commands and not is_str(commands["setup"]):
        errs.append("commands.setup: must be a command")
    if not is_str(commands.get("verify")):
        errs.append("commands.verify: required, the one command every change must pass")
    serve = commands.get("serve")
    if serve is None:
        warns.append("commands.serve: not set, so hunters and the validator can only run tests")
    elif not isinstance(serve, dict) or not is_str(serve.get("run")):
        errs.append("commands.serve: a map with run (required) and ready")
    else:
        unknown(serve, {"run", "ready"}, "commands.serve", errs)
        if "ready" in serve and not (is_str(serve["ready"]) and serve["ready"].startswith("/")):
            errs.append("commands.serve.ready: a URL path starting with /")
    if "checks" in commands:
        checks = commands["checks"]
        if not isinstance(checks, dict):
            errs.append("commands.checks: a map of name to check")
            checks = {}
        for cn, c in checks.items():
            p = "commands.checks.%s" % key(cn)
            if not CHECK_NAME.fullmatch(str(cn)) or cn == "verify":
                errs.append("%s: names are lower case with _, and verify is reserved" % p)
            if not isinstance(c, dict) or not is_str(c.get("run")):
                errs.append("%s: a map with run (required), setup, when, heavy, gate" % p)
                continue
            unknown(c, {"run", "setup", "when", "heavy", "gate"}, p, errs)
            if "setup" in c and not is_str(c["setup"]):
                errs.append("%s.setup: must be a command, like run" % p)
            if "when" in c and not str_list(c["when"], empty=False):
                errs.append("%s.when: a non-empty glob list" % p)
            for b in ("heavy", "gate"):
                if b in c and not isinstance(c[b], bool):
                    errs.append("%s.%s: true or false" % (p, b))

    wk = doc.get("work_kinds", {})
    if not isinstance(wk, dict):
        errs.append("work_kinds: a map of kind to tier")
    else:
        for k, v in wk.items():
            if not SLUG.fullmatch(str(k)):
                errs.append("work_kinds.%s: kinds are lower case with -" % key(k))
            if v not in TIERS:
                errs.append("work_kinds.%s: %s is not a tier (deep, standard, light)" % (key(k), shown(v)))

    roles = doc.get("roles", {})
    if not isinstance(roles, dict):
        errs.append("roles: a map of name to role")
        roles = {}
    for rn, r in roles.items():
        p = "roles.%s" % key(rn)
        if not SLUG.fullmatch(str(rn)):
            errs.append("%s: role names are lower case with -" % p)
        if not isinstance(r, dict) or not str_list(r.get("owns"), empty=False):
            errs.append("%s.owns: required, a non-empty glob list" % p)
            continue
        unknown(r, {"owns", "skills"}, p, errs)
        if "skills" in r and not str_list(r["skills"]):
            errs.append("%s.skills: a list of skill names" % p)
    if mode == "team" and not roles:
        errs.append("roles: team mode needs at least one role")

    check_models(doc.get("models"), defaults, errs, warns)

    ci = doc.get("ci", {})
    nightly = []
    if not isinstance(ci, dict):
        errs.append("ci: a map with pr, nightly, skip_paths, external")
    else:
        unknown(ci, {"pr", "nightly", "skip_paths", "external"}, "ci", errs)
        for lk in ("pr", "nightly"):
            v = ci.get(lk, [] if lk == "nightly" else ["verify"])
            if not str_list(v):
                errs.append("ci.%s: a list of check names" % lk)
                continue
            for cn in v:
                if cn != "verify" and cn not in checks:
                    errs.append("ci.%s: %s is neither verify nor a key of commands.checks" % (lk, shown(cn)))
            if lk == "nightly":
                nightly = v
        if "skip_paths" in ci and not str_list(ci["skip_paths"]):
            errs.append("ci.skip_paths: a glob list")
        ext = ci.get("external", [])
        if not isinstance(ext, list):
            errs.append("ci.external: a list of entries, each with workflow and jobs")
        else:
            for i, e in enumerate(ext):
                pe = "ci.external[%d]" % i
                if not isinstance(e, dict):
                    errs.append("%s: a map with workflow and jobs" % pe)
                    continue
                unknown(e, {"workflow", "jobs", "covered_by"}, pe, errs)
                if not is_str(e.get("workflow")):
                    errs.append("%s.workflow: a workflow name" % pe)
                if not str_list(e.get("jobs"), empty=False):
                    errs.append("%s.jobs: a non-empty list of job names" % pe)
                cover = e.get("covered_by", [])
                if "covered_by" in e and not str_list(cover, empty=False):
                    errs.append("%s.covered_by: a non-empty list of check names" % pe)
                    cover = []
                for cn in cover:
                    if cn != "verify" and cn not in checks:
                        errs.append("%s.covered_by: %s is neither verify nor a key of commands.checks" % (pe, shown(cn)))
            if not ext:
                own = own_workflows(target)
                if own:
                    warns.append(
                        "ci.external is empty, but this repo has its own workflows (%s): their checks are not "
                        "factory.yaml checks, so the merge gate may refuse PRs; list their jobs in ci.external "
                        "(docs/factory-yaml.md > ci.external)" % own)

    lic = doc.get("licences", {})
    if not isinstance(lic, dict):
        errs.append("licences: a map with allow and dev_only")
    else:
        unknown(lic, {"allow", "dev_only"}, "licences", errs)
        for lk in ("allow", "dev_only"):
            if lk in lic and not str_list(lic[lk]):
                errs.append("licences.%s: a list of SPDX ids" % lk)
    if "human_gates" in doc and not str_list(doc["human_gates"]):
        errs.append("human_gates: a list of sentences")
    if "packs" in doc and not (str_list(doc["packs"]) and all(SLUG.fullmatch(x) for x in doc["packs"])):
        errs.append("packs: a list of pack names")

    demo = doc.get("demo", {})
    if not isinstance(demo, dict):
        errs.append("demo: a map with flows")
    else:
        unknown(demo, {"flows"}, "demo", errs)
        flows = demo.get("flows", [])
        if not isinstance(flows, list):
            errs.append("demo.flows: a list of flows, each with name, surface and steps")
        else:
            names = set()
            for i, f in enumerate(flows):
                pf = "demo.flows[%d]" % i
                if not isinstance(f, dict):
                    errs.append("%s: a map with name, surface and steps" % pf)
                    continue
                unknown(f, {"name", "surface", "steps"}, pf, errs)
                if not is_str(f.get("name")):
                    errs.append("%s.name: a flow name" % pf)
                elif f["name"] in names:
                    errs.append("%s.name: %s is used by an earlier flow" % (pf, shown(f["name"])))
                else:
                    names.add(f["name"])
                if f.get("surface") not in ("ui", "http", "command"):
                    errs.append("%s.surface: ui, http or command" % pf)
                if not str_list(f.get("steps"), empty=False):
                    errs.append("%s.steps: a non-empty list of steps" % pf)

    deploy = doc.get("deploy", {})
    if not isinstance(deploy, dict):
        errs.append("deploy: a map of target to target settings")
        deploy = {}
    for tn, t in deploy.items():
        p = "deploy.%s" % key(tn)
        if not isinstance(t, dict) or not is_str(t.get("recipe")):
            errs.append("%s.recipe: required" % p)
            continue
        unknown(t, {"recipe", "with", "environments"}, p, errs)
        if "with" in t and not isinstance(t["with"], dict):
            errs.append("%s.with: a map" % p)
        envs = t.get("environments")
        if not isinstance(envs, dict) or not envs:
            errs.append("%s.environments: required, at least one of preview, staging, production" % p)
            continue
        for env_name, e in envs.items():
            pe = "%s.environments.%s" % (p, key(env_name))
            if env_name not in ("preview", "staging", "production"):
                errs.append("%s: environments are preview, staging or production" % pe)
            e = {} if e is None else e
            if not isinstance(e, dict):
                errs.append("%s: a map with when, approve, url" % pe)
                continue
            unknown(e, {"when", "approve", "url"}, pe, errs)
            w = e.get("when", "manual")
            if not (w in ("manual", "merge", "nightly") or (is_str(w) and re.fullmatch(r"pr-label:[A-Za-z0-9][A-Za-z0-9:_.-]*", w))):
                errs.append("%s.when: manual, merge, nightly or pr-label:<label>" % pe)
            if w == "nightly" and not nightly:
                errs.append("%s.when: nightly needs a non-empty ci.nightly" % pe)
            if e.get("approve", "first") not in ("first", "always"):
                errs.append("%s.approve: first or always" % pe)
            if "url" in e and not (is_str(e["url"]) and re.match(r"https?://", e["url"])):
                errs.append("%s.url: an http(s) URL" % pe)

    if errs:
        result(name, "fail", "%d problem(s): %s" % (len(errs), errs[0]),
               "fix each line below in a PR (changing factory.yaml is a human gate); every key is in the factory "
               "repo's docs/factory-yaml.md")
        for e in errs:
            detail(name, e)
        for w in warns:
            detail(name, "warning: " + w)
    elif warns:
        result(name, "warn", warns[0] if len(warns) == 1 else "%d warnings: %s" % (len(warns), warns[0]),
               "every key is in the factory repo's docs/factory-yaml.md")
        for w in (warns if len(warns) > 1 else []):
            detail(name, w)
    else:
        result(name, "ok", "valid: core %s, %s mode, %d role(s), %d check(s)" % (doc["factory"], mode, len(roles), len(checks)))
    return doc


SHELL_WORDS = {"(", ")", "{", "}", "!", "if", "for", "while", "until", "case", "cd", "export", ".", "source", "exec",
               "eval", "set", "command", "env", "time", "nice", "nohup", "test", "[", "true", "false", "builtin"}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}


def check_verify(target, doc):
    name = "verify"
    if doc is None:
        result(name, "warn", "not checked: factory.yaml could not be read", "fix factory.yaml first")
        return
    commands = doc.get("commands") if isinstance(doc.get("commands"), dict) else {}
    cmd = commands.get("verify")
    if not is_str(cmd):
        result(name, "fail", "commands.verify is not set", "set commands.verify in factory.yaml: the one command every "
               "change must pass")
        return
    try:
        words = shlex.split(cmd, comments=True, posix=True)
    except ValueError as e:
        result(name, "fail", "commands.verify is not a valid shell line (%s)" % e, "fix the quoting in commands.verify")
        return
    while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]):
        words.pop(0)
    if not words:
        result(name, "fail", "commands.verify runs no program", "make commands.verify run the project's checks")
        return
    exe = words[0]
    if exe in SHELL_WORDS or re.search(r"[$`*?(){};&|<>]", exe):
        result(name, "warn", "cannot tell which program commands.verify runs (it starts with %s)" % shown(exe),
               "start commands.verify with the program it runs, or a script that runs the rest")
        return
    setup = is_str(commands.get("setup"))

    def missing(what):
        if setup:
            result(name, "warn", "%s is not there yet" % shown(what, quote=False),
                   "run commands.setup first (it should create it); if it does not, fix commands.verify")
        else:
            result(name, "fail", "%s does not exist" % shown(what, quote=False), "fix commands.verify, or add a commands.setup that creates it")

    if "/" in exe:
        path = exe if os.path.isabs(exe) else os.path.join(target, exe)
        if not os.path.isfile(path):
            missing(exe)
            return
        if not os.access(path, os.X_OK):
            result(name, "fail", "%s is not executable" % shown(exe, quote=False), "chmod +x it, or run it through its interpreter")
            return
        found = exe
    else:
        found = shutil.which(exe)
        if not found:
            result(name, "fail", "%s is not on PATH" % shown(exe, quote=False), "install %s, or fix commands.verify" % shown(exe, quote=False))
            return
    if os.path.basename(exe) in SHELLS and len(words) > 1 and not words[1].startswith("-") and "/" in words[1]:
        script = words[1] if os.path.isabs(words[1]) else os.path.join(target, words[1])
        if not os.path.isfile(script):
            missing(words[1])
            return
    runs = " ".join(words[:2]) if os.path.basename(exe) in SHELLS and len(words) > 1 else exe
    result(name, "ok", "defined; starts %s (not run by the doctor)" % shown(runs, quote=False))


def lock_entries(target):
    path = os.path.join(target, ".factory", "core.lock")
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.fullmatch(r"[0-9a-f]{64}  (\S+)\n?", line)
                if m:
                    out.append(m.group(1))
    except (OSError, UnicodeDecodeError):
        return None
    return out


def no_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError("the key %s appears twice" % shown(k))
        out[k] = v
    return out


# The hook events of Claude Code settings. An entry under another name runs nothing, so it never counts as wired.
HOOK_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification",
               "UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "SessionStart", "SessionEnd"}


def hook_forms(rel):
    """The exact commands that run a core hook: the forms the core's hook settings write. Nothing else counts, not
    an echo, a comment, a wrapper or extra words, because none of those is known to run the guard."""
    return {'sh "$CLAUDE_PROJECT_DIR"/%s' % rel, '"$CLAUDE_PROJECT_DIR"/%s' % rel}


# The events the core's settings template (core/templates/claude-settings.json) wires each core hook for, and for each
# event the tools its matcher lists (None: the event has no tool matcher, so none is checked). A project is checked
# against this table because the template itself is not installed into a project; the doctor's tests compare the
# table with the template, as sets, so the two cannot drift apart. A hook that is not in the table counts as wired
# under any known event, for any tool.
CORE_HOOK_EVENTS = {".factory/hooks/factory-hook": {
    "PreToolUse": ("Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Grep"),
    "PostToolUse": ("Bash",),
    "Stop": None,
    "SubagentStop": None}}

TOOL_LIST = re.compile(r"[A-Za-z0-9_]+(\|[A-Za-z0-9_]+)*")


def matcher_tools(matcher):
    """What a matcher string selects, read strictly: "all" (absent, empty, `*` or `.*`), the set of tool names of a
    plain `|`-list of names, or None when it is any other regular expression and the doctor cannot tell."""
    if matcher in ("", "*", ".*"):
        return "all"
    if TOOL_LIST.fullmatch(matcher):
        return set(matcher.split("|"))
    return None


def uncovered_tools(matchers, wanted):
    """(missing tools, matchers it cannot read) for the matchers of the groups that run a hook, against the tools the
    template's matcher lists. Several groups together may cover the tools. A matcher that is not a plain list of
    names and not a match-all form never counts as covering anything: when tools are left over, they are missing
    only if every matcher was read; otherwise the doctor cannot tell."""
    covered, unread = set(), []
    for matcher in matchers:
        got = matcher_tools(matcher)
        if got == "all":
            return [], []
        if got is None:
            unread.append(matcher)
        else:
            covered |= got
    left = [t for t in wanted if t not in covered]
    return ([], unread) if left and unread else (left, [])


def wired_commands(settings, notes):
    """The hook entries in parsed settings that Claude Code runs, by event, as (matcher, command) pairs: entries of a
    known event, in the documented shape (a group of matcher and hooks; a hook of type, command and timeout). An
    entry with any other shape or key (such as a "disabled" flag) is not counted, and a note says so."""
    out = {}
    hk = settings.get("hooks")
    if hk is None:
        return out
    if not isinstance(hk, dict):
        notes.append("hooks in .claude/settings.json is not an object; nothing in it counts")
        return out
    for event, groups in hk.items():
        if event not in HOOK_EVENTS:
            notes.append("hooks event %s is not a Claude Code event; its entries do not count" % shown(event))
            continue
        if not isinstance(groups, list):
            notes.append("hooks.%s is not a list; nothing in it counts" % event)
            continue
        for g in groups:
            if not isinstance(g, dict) or set(g) - {"matcher", "hooks"} or not isinstance(g.get("hooks"), list) \
                    or not isinstance(g.get("matcher", ""), str):
                notes.append("hooks.%s has a group that is not {matcher, hooks}; it does not count" % event)
                continue
            for h in g["hooks"]:
                ok = (isinstance(h, dict) and not set(h) - {"type", "command", "timeout"} and h.get("type") == "command"
                      and isinstance(h.get("command"), str)
                      and (is_int(h.get("timeout", 1)) and h.get("timeout", 1) > 0))
                if ok:
                    out.setdefault(event, []).append((g.get("matcher", ""), h["command"]))
                else:
                    notes.append("hooks.%s has an entry that is not {type: command, command, timeout}; it does not "
                                 "count" % event)
    return out

def check_hooks(target):
    name = "hooks"
    entries = lock_entries(target)
    if entries is not None:
        hooks = [p for p in entries if p.startswith(".factory/hooks/") and not p.endswith(".md")]
    else:
        hooks = []
        base = os.path.join(target, ".factory", "hooks")
        for root, _dirs, files in os.walk(base):
            for fn in files:
                rel = os.path.relpath(os.path.join(root, fn), target).replace(os.sep, "/")
                if not rel.endswith(".md"):
                    hooks.append(rel)
    problems, notes, settings = [], [], {}
    for rel in (".claude/settings.json", ".claude/settings.local.json"):
        p = os.path.join(target, rel)
        if not os.path.exists(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f, object_pairs_hook=no_dupes)
        except (OSError, ValueError) as e:
            problems.append("%s is not valid JSON (%s)" % (rel, str(e).split(":")[0]))
            continue
        if not isinstance(data, dict):
            problems.append("%s is not a JSON object" % rel)
            continue
        settings[rel] = data
        if data.get("disableAllHooks") is True:
            problems.append("%s sets disableAllHooks: every hook is off" % rel)
    toml = os.path.join(target, ".codex", "config.toml")
    if os.path.exists(toml):
        try:
            import tomllib  # Python 3.11+
        except ImportError:
            notes.append(".codex/config.toml not parsed: this Python has no tomllib (3.11+)")
        else:
            try:
                with open(toml, "rb") as f:
                    tomllib.load(f)
            except (OSError, ValueError) as e:
                problems.append(".codex/config.toml is not valid TOML (%s)" % str(e).split("(")[0].strip())
    if not hooks:
        if problems:
            result(name, "fail", problems[0], "fix the file so it parses; factory-init merges these files")
        else:
            result(name, "n/a", "not applicable: this core version installs no hooks yet; the settings files that exist parse")
        for p in problems:
            detail(name, p)
        for n in notes:
            detail(name, n)
        return
    main = settings.get(".claude/settings.json")
    if main is None and not any(p.startswith(".claude/settings.json") for p in problems):
        problems.append(".claude/settings.json is missing; the core's hooks are wired there")
    by_event = wired_commands(main or {}, notes)
    commands = {c for pairs in by_event.values() for _m, c in pairs}
    unwired = []   # (hook, event) the template wires and the project does not
    short = []     # (hook, event, tools) wired under a matcher that leaves out tools the template's matcher lists
    unsure = []    # a matcher the doctor cannot read, where tools are left over
    for rel in hooks:
        if not os.path.isfile(os.path.join(target, rel)):
            problems.append("%s is missing" % rel)
        if not hook_forms(rel) & commands:
            problems.append("%s is not wired in .claude/settings.json (no entry runs it in an accepted form)" % rel)
            continue
        base = os.path.basename(rel)
        for event, tools in CORE_HOOK_EVENTS.get(rel, {}).items():
            matchers = [m for m, c in by_event.get(event, []) if c in hook_forms(rel)]
            if not matchers:
                problems.append("%s is not wired for %s in .claude/settings.json" % (base, event))
                unwired.append((base, event))
                continue
            if tools is None:
                continue
            missing, unread = uncovered_tools(matchers, tools)
            if missing:
                problems.append("%s is wired for %s, but its matcher %s leaves out %s, which the core's settings "
                                "template matches" % (base, event, " and ".join(shown(m) for m in matchers),
                                                      ", ".join(missing)))
                short.append((base, event, missing))
            elif unread:
                unsure.append("cannot tell whether the %s matcher %s of %s covers %s: only a plain list of tool names "
                              "(or a match-all form) is read" % (event, " and ".join(shown(m) for m in unread), base,
                                                                 ", ".join(tools)))
    if problems:
        fix = ("apply the settings merge that factory-update left as a proposal in its PR (factory-update never writes "
               ".claude/settings.json), or re-run /factory-init from a source at the repo's core version to merge the "
               "core's hook settings")
        if short:
            fix = "widen the matcher in .claude/settings.json to cover %s; then %s" % (
                ", ".join("%s for %s" % (", ".join(t), e) for _h, e, t in short), fix)
        if unwired:
            fix = "wire %s in .claude/settings.json (the core's settings template does); then %s" % (
                ", ".join("%s for %s" % u for u in unwired), fix)
        result(name, "fail", "%d problem(s): %s" % (len(problems), problems[0]), fix)
    elif unsure:
        result(name, "warn", unsure[0], "write the matcher as the core's settings template does (a plain list of tool "
               "names joined with |), or leave the matcher out")
    else:
        result(name, "ok", "%d core hook(s) present and wired in .claude/settings.json" % len(hooks))
    for p in problems + unsure:
        detail(name, p)
    for n in notes:
        detail(name, n)


MACHINE_LIMITS = {"builders": (1, 6), "reviewers": (1, 4), "heavy": (1, 2), "test_workers": (1, 8)}
# The usage section (allowance pacing): every map is keyed by provider, except weights.effort (by effort) and
# weights.model (by model id). factory-usage validates the merged machine settings with the same function.
USAGE_KEYS = {"reserve_pct", "week_units", "week_reset", "weights"}
RESERVE_PCT = (0, 90)
WEEK_RESET = re.compile(r"(mon|tue|wed|thu|fri|sat|sun) ([01][0-9]|2[0-3]):[0-5][0-9]")
MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def is_positive_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 and v == v and v != float("inf")


def usage_errors(usage, errs, where="usage"):
    """Problems of the machine settings' usage section (a map, or None when absent) appended to errs."""
    if usage is None:
        return
    if not isinstance(usage, dict):
        errs.append("%s: must be a map" % where)
        return
    unknown(usage, USAGE_KEYS, where, errs)

    def entries(k, key_re, what):
        v = usage.get(k)
        if v is None:
            return {}
        if not isinstance(v, dict):
            errs.append("%s.%s: must be a map of %s" % (where, k, what))
            return {}
        out = {}
        for name, x in v.items():
            if not isinstance(name, str) or not key_re.fullmatch(name):
                errs.append("%s.%s: %s is not a %s name" % (where, k, shown(name), what[:-1]))
            else:
                out[name] = x
        return out

    for name, x in entries("reserve_pct", SLUG, "providers").items():
        lo, hi = RESERVE_PCT
        if not is_int(x) or x < lo or x > hi:
            errs.append("%s.reserve_pct.%s: an integer from %d to %d" % (where, name, lo, hi))
    for name, x in entries("week_units", SLUG, "providers").items():
        if not is_positive_number(x):
            errs.append("%s.week_units.%s: a number above 0" % (where, name))
    for name, x in entries("week_reset", SLUG, "providers").items():
        if x is not None and not (isinstance(x, str) and WEEK_RESET.fullmatch(x)):
            errs.append("%s.week_reset.%s: \"<mon|tue|...|sun> HH:MM\" in UTC, or null" % (where, name))
    w = usage.get("weights")
    if w is None:
        return
    if not isinstance(w, dict):
        errs.append("%s.weights: must be a map" % where)
        return
    unknown(w, {"effort", "model"}, where + ".weights", errs)
    for part, key_re, what in (("effort", re.compile("|".join(EFFORT_RANK)), "efforts"), ("model", MODEL_ID, "models")):
        v = w.get(part)
        if v is None:
            continue
        if not isinstance(v, dict):
            errs.append("%s.weights.%s: must be a map of %s" % (where, part, what))
            continue
        for name, x in v.items():
            if not isinstance(name, str) or not key_re.fullmatch(name):
                errs.append("%s.weights.%s: %s is not a known %s name" % (where, part, shown(name), what[:-1]))
            elif not is_positive_number(x):
                errs.append("%s.weights.%s.%s: a number above 0" % (where, part, name))


# The shifts section: time windows in the machine's local time, each "HH:MM-HH:MM" (24-hour; the end may be earlier
# than the start, which crosses midnight). No two windows may share a minute; one that ends where another starts is fine.
SHIFT_KEYS = ("night", "quiet", "busy")
SHIFT_WINDOW = re.compile(r"(([01][0-9]|2[0-3]):([0-5][0-9]))-(([01][0-9]|2[0-3]):([0-5][0-9]))")


def shift_minutes(window):
    """(start, end) of a valid window as minutes after midnight."""
    m = SHIFT_WINDOW.fullmatch(window)
    return int(m.group(2)) * 60 + int(m.group(3)), int(m.group(5)) * 60 + int(m.group(6))


def shift_spans(start, end):
    """The minutes of the day a window covers, as half-open spans; one that crosses midnight is two."""
    return [(start, end)] if start < end else [(start, 1440), (0, end)]


def shifts_errors(shifts, errs, where="shifts"):
    """Problems of the machine settings' shifts section (a map, or None when absent) appended to errs."""
    if shifts is None:
        return
    if not isinstance(shifts, dict):
        errs.append("%s: must be a map of windows (%s)" % (where, ", ".join(SHIFT_KEYS)))
        return
    unknown(shifts, set(SHIFT_KEYS), where, errs)
    good = {}
    for k in SHIFT_KEYS:
        if k not in shifts:
            continue
        v = shifts[k]
        if not (isinstance(v, str) and SHIFT_WINDOW.fullmatch(v)):
            errs.append("%s.%s: \"HH:MM-HH:MM\" in 24-hour local time (00:00 to 23:59; the end may be earlier than the "
                        "start to cross midnight)" % (where, k))
            continue
        start, end = shift_minutes(v)
        if start == end:
            errs.append("%s.%s: an empty window (the start and the end are the same time)" % (where, k))
        else:
            good[k] = shift_spans(start, end)
    names = list(good)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if any(s1 < e2 and s2 < e1 for s1, e1 in good[a] for s2, e2 in good[b]):
                errs.append("%s.%s and %s.%s: the windows overlap" % (where, a, where, b))


def machine_doc_errors(doc):
    """The problems of a parsed machine file (a map); factory-usage validates the text it read safely with it."""
    errs = []
    found = []
    walk_secrets(doc, "", found)
    errs += ["%s: looks like a credential (value not shown); no secrets in this file" % p for p in found]
    unknown(doc, {"limits", "ci", "doctor", "usage", "shifts"}, "(top level)", errs)
    usage_errors(doc.get("usage"), errs)
    shifts_errors(doc.get("shifts"), errs)
    sections = {"limits": set(MACHINE_LIMITS), "ci": {"minutes_per_month"}, "doctor": {"min_free_gb"}}
    for sec, keys in sections.items():
        v = doc.get(sec, {})
        if v is None:
            v = {}
        if not isinstance(v, dict):
            errs.append("%s: must be a map" % sec)
            continue
        unknown(v, keys, sec, errs)
        for k in keys & set(v):
            lo, hi = MACHINE_LIMITS.get(k, (0, None)) if sec == "limits" else ((1, None) if sec == "doctor" else (0, None))
            x = v[k]
            if not is_int(x) or x < lo or (hi is not None and x > hi):
                errs.append("%s.%s: an integer %s" % (sec, k, "from %d to %d" % (lo, hi) if hi else "of at least %d" % lo))
    return errs


def read_machine_fd(fd):
    """The whole text of an open file, from its start (UTF-8), with CRLF and lone CR line ends turned into LF, as
    load_yaml's text-mode read does, so both readers see the same text."""
    chunks, size = [], 0
    while True:
        b = os.pread(fd, 1 << 20, size)
        if not b:
            return b"".join(chunks).decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        chunks.append(b)
        size += len(b)


def check_machine(path, fd=None):
    """The machine file's check; returns the parsed file when it passes. With fd, the file is read from that open
    descriptor (the caller opened and checked it) and path only names it."""
    name = "machine"
    if fd is None and not os.path.lexists(path):
        result(name, "n/a", "no ~/.factory/machine.yaml; the core defaults apply until a factory command writes it")
        return None
    try:
        doc = load_yaml(path) if fd is None else Reader(read_machine_fd(fd)).parse()
    except Refused as e:
        result(name, "fail", "~/.factory/machine.yaml cannot be read: %s" % e, "fix that line; you edit this file by hand")
        return None
    except (OSError, UnicodeDecodeError) as e:
        result(name, "fail", "~/.factory/machine.yaml cannot be read: %s" % e.__class__.__name__, "make it a readable UTF-8 file")
        return None
    errs = []
    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        result(name, "fail", "~/.factory/machine.yaml is not a map", "start from the example in the factory repo's docs")
        return None
    errs += machine_doc_errors(doc)
    if errs:
        result(name, "fail", "%d problem(s): %s" % (len(errs), errs[0]),
               "edit ~/.factory/machine.yaml by hand; keys and ranges are under Machine settings in docs/factory-yaml.md")
        for e in errs:
            detail(name, e)
        return None
    lim = doc.get("limits") or {}
    result(name, "ok", "caps valid: " + ", ".join("%s %s" % (k, lim[k]) for k in MACHINE_LIMITS if k in lim)
           if lim else "valid; no caps set, so the core defaults apply")
    return doc


def wanted_labels(labels_path, doc, target):
    """Emits L records; returns a reason string when the list cannot be made."""
    if not labels_path or not os.path.isfile(labels_path):
        return "the core's label template (labels.yaml) is not in this checkout"
    try:
        spec = load_yaml(labels_path)
    except (Refused, OSError, UnicodeDecodeError) as e:
        return "the label template cannot be read (%s)" % (e if isinstance(e, Refused) else e.__class__.__name__)
    roles = sorted((doc or {}).get("roles") or {}) if isinstance((doc or {}).get("roles"), dict) else []
    hunters = os.path.join(target, ".factory", "hunters.md")
    if os.path.isfile(hunters):
        areas = []
        try:
            with open(hunters, encoding="utf-8", errors="replace") as f:
                hunter_lines = f.readlines()
        except OSError:
            hunter_lines = []
            detail("labels", ".factory/hunters.md cannot be read, so its areas were not used")
        for line in hunter_lines:
            m = re.fullmatch(r"## +(\S+)\s*", line)
            if m and m.group(1).lower() != "priorities":
                if SLUG.fullmatch(m.group(1)):
                    areas.append(m.group(1))
                else:
                    detail("labels", "skipped a heading in .factory/hunters.md that is not an area slug")
    else:
        areas = roles
    previews = []
    for t in ((doc or {}).get("deploy") or {}).values() if isinstance((doc or {}).get("deploy"), dict) else []:
        envs = t.get("environments") if isinstance(t, dict) else None
        for e in (envs or {}).values() if isinstance(envs, dict) else []:
            w = e.get("when") if isinstance(e, dict) else None
            if is_str(w) and w.startswith("pr-label:") and w[9:] != "preview":
                previews.append(w[9:])
    plan = (("labels", None, [None]), ("per_role", "__FACTORY_ROLE__", roles),
            ("per_hunter_area", "__FACTORY_HUNTER_AREA__", [a for a in areas if a != "process"]),
            ("per_preview_label", "__FACTORY_PREVIEW_LABEL__", previews))
    seen = set()
    for section, ph, items in plan:
        for entry in (spec or {}).get(section) or []:
            n = entry.get("name") if isinstance(entry, dict) else None
            if not is_str(n):
                return "the label template has an entry without a name in %s" % section
            for it in items:
                label = n if ph is None else n.replace(ph, it)
                if label.lower() not in seen:
                    seen.add(label.lower())
                    OUT.append("L\t%s" % redact(clean(label)))
    return None


CHECK_NAMES = ("factory.yaml", "core.lock", "labels", "status-issue", "hooks", "verify", "auth", "disk", "machine")
STATUSES = ("ok", "warn", "fail", "n/a")


def deep_redact(v):
    """A parsed value with every string, keys included, passed through redact() before it is serialized."""
    if isinstance(v, str):
        return redact(v)
    if isinstance(v, list):
        return [deep_redact(x) for x in v]
    if isinstance(v, dict):
        return {redact(str(k)): deep_redact(x) for k, x in v.items()}
    return v


def render(records, order, target, rc, as_json):
    """Text or JSON from the shell's records. Every field passes redact() first, the same for both outputs, and is
    shortened only after that."""
    def field(s):
        s = redact(clean(s))
        return s if len(s) <= 400 else s[:397] + "..."

    st, msg, fix, det = {}, {}, {}, {}
    with open(records, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2 or parts[1] not in CHECK_NAMES:
                continue   # only the fixed check names are ever printed
            if parts[0] == "R" and len(parts) >= 5 and parts[1] not in st:
                if parts[2] in STATUSES:
                    st[parts[1]], msg[parts[1]], fix[parts[1]] = parts[2], field(parts[3]), field(parts[4])
                else:
                    st[parts[1]], msg[parts[1]], fix[parts[1]] = "fail", "unexpected status in the records (not shown)", ""
            elif parts[0] == "D" and len(parts) >= 3:
                det.setdefault(parts[1], []).append(field(parts[2]))
    count = {s: sum(1 for c in order if st.get(c) == s) for s in ("ok", "warn", "fail", "n/a")}
    if as_json:
        doc = {"target": field(target), "exit": rc, "summary": count,
               "checks": [{"check": c, "status": st.get(c, ""), "message": msg.get(c, ""), "fix": fix.get(c, ""),
                           "details": det.get(c, [])} for c in order]}
        sys.stdout.write(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
        return
    lines = ["factory-doctor: %s" % field(target)]
    for c in order:
        lines.append("%-5s %-13s %s" % (st.get(c, ""), c, msg.get(c, "")))
        lines += ["%-19s - %s" % ("", d) for d in det.get(c, [])]
        if st.get(c) in ("warn", "fail"):
            lines.append("%-19s fix: %s" % ("", fix.get(c, "")))
    lines.append("summary: %d ok, %d n/a, %d warn, %d fail" % (count["ok"], count["n/a"], count["warn"], count["fail"]))
    sys.stdout.write("\n".join(lines) + "\n")


def min_free_gb_fact(machine, defaults, dnote):
    """The free-space minimum for the shell script: machine.yaml's doctor.min_free_gb, else the machine default in the
    core's defaults.yaml (the one source of it). When neither gives a whole number of at least 1 (no machine value
    and a missing, unreadable or incomplete defaults file), no value is given and min_free_gb_why says why."""
    for src in (machine, (defaults or {}).get("machine") if isinstance(defaults, dict) else None):
        doc = src.get("doctor") if isinstance(src, dict) else None
        if isinstance(doc, dict) and is_int(doc.get("min_free_gb")) and doc["min_free_gb"] >= 1:
            fact("min_free_gb", doc["min_free_gb"])
            return
    fact("min_free_gb_why", "%s, so the core's default of machine.doctor.min_free_gb could not be read"
         % (dnote or "the core defaults hold no machine.doctor.min_free_gb of at least 1"))


def main(argv):
    if argv[:1] == ["render"] and len(argv) in (5, 6):
        order = argv[2].split()
        if not order or any(c not in CHECK_NAMES for c in order):
            sys.stderr.write("factory-doctor.py: bad check order (not shown)\n")
            return 64
        render(argv[1], order, argv[3], int(argv[4]), argv[5:] == ["--json"])
        return 0
    if len(argv) == 2 and argv[0] == "yaml":
        # The reader on one file, for the tests of its subset. Its output passes redact() like every other output.
        try:
            parsed = load_yaml(argv[1])
        except Refused as e:
            sys.stdout.write(redact("refused: %s" % e) + "\n")
            return 1
        except (OSError, UnicodeDecodeError):
            sys.stderr.write("factory-doctor.py: cannot read the file (details not shown)\n")
            return 1
        sys.stdout.write(redact(json.dumps(deep_redact(parsed), sort_keys=True)) + "\n")
        return 0
    if not argv or argv[0] != "checks":
        sys.stderr.write(__doc__)
        return 64
    opts = {"--target": None, "--defaults": "", "--machine": "", "--labels": ""}
    args = argv[1:]
    while args:
        if args[0] not in opts or len(args) < 2:
            sys.stderr.write("factory-doctor.py: bad argument (not shown)\n")
            return 64
        opts[args[0]] = args[1]
        args = args[2:]
    target = opts["--target"]
    defaults, dnote = None, None
    if opts["--defaults"] and os.path.isfile(opts["--defaults"]):
        try:
            defaults = load_yaml(opts["--defaults"])
        except (Refused, OSError, UnicodeDecodeError) as e:
            dnote = "the core defaults cannot be read (%s)" % (e if isinstance(e, Refused) else e.__class__.__name__)
    else:
        dnote = "no core defaults.yaml found, so the core model tables were not checked"
    doc = check_factory_yaml(target, defaults)
    if dnote:
        detail("factory.yaml", dnote)
    if isinstance(doc, dict):
        project = doc.get("project") if isinstance(doc.get("project"), dict) else {}
        if is_str(project.get("repo")) and REPO.fullmatch(project["repo"]) and not shown(project["repo"]) == REDACTED:
            fact("repo", project["repo"])
        if is_str(doc.get("factory")) and SEMVER.fullmatch(doc["factory"]):
            fact("version", doc["factory"])
    check_verify(target, doc)
    check_hooks(target)
    machine = check_machine(opts["--machine"])
    min_free_gb_fact(machine, defaults, dnote)
    reason = wanted_labels(opts["--labels"], doc, target)
    if reason:
        fact("labels_unknown", reason)
    sys.stdout.write("".join(line + "\n" for line in OUT))
    return 0


def guarded(argv):
    """main() behind one fixed line: an uncaught error never prints a traceback, a path or a value."""
    try:
        code = main(argv)
        sys.stdout.flush()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 70
    except BaseException:  # noqa: B036 (KeyboardInterrupt and BrokenPipeError included, on purpose)
        code = 70
        try:
            sys.stderr.write("factory-doctor.py: internal error (details not shown)\n")
            sys.stderr.flush()
        except BaseException:
            pass
    # os._exit: no interpreter shutdown, so nothing can print after this (an unflushable stdout included).
    os._exit(code if isinstance(code, int) else 70)


if __name__ == "__main__":
    guarded(sys.argv[1:])
