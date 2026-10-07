#!/usr/bin/env python3
"""verify_gates.py - the origin-verification gates as plain, testable functions.

verify.py used to hold these as regex constants. A regex that cuts a "statement"
out of C text by looking for the next `;` is wrong in both directions: a `;`
inside a string literal flips the quote pairing (the forged output after it is
no longer seen), and a char literal `'"'` does the same. With nested quantifiers
it also backtracks exponentially on input that has no terminator. Gate 1 is the
check where a false negative IS a forgery that passed, so it is a lexer here:

  strip comments -> tokenize (strings, chars, identifiers, numbers, punctuation)
  -> classify calls by NAME with balanced parentheses -> collect literals

Each file is read once, in linear time, with a deadline; a scan that runs out of
time FAILS the gate ("not checked" is not "passed").

What the three gates look at (all of it takes the GUEST console):

  1. source negative   no literal the machine emits appears on the console
                       (plus: one UART TX path, no write into the protected
                       pstore range)
  2. output origin     the console's fixed strings exist inside the firmware
  3. input origin      the machine never types into its own UART receive path

The guest console is the UART console plus the merged memory-dump kernel log.
Lines the QEMU process itself wrote (`qemu-system-aarch64: info: ...`) are host
diagnostics and are never guest evidence.

Also here: the bypass-ledger parser (shared with check_change.sh) and the
verification-bypass report (reported, not a gate). Two ledger-side facts are read
from STATIC.md and never from the machine: the hardware-hash precondition row
(hash_engine_state, a ledger check, not a fourth gate) and the "address windows"
table (address_windows_report, a reference indicator, never a gate).

CLI (used by check_change.sh):
  verify_gates.py ledger <workdir> [--ledger FILE] [--baseline FILE]
                                                     -> JSON, exit 1 on issues
  verify_gates.py scan --console FILE SRC...         -> gate 1 JSON
"""
import argparse
import collections
import glob
import json
import mmap
import os
import re
import sys
import time
import zlib

SCAN_BUDGET = 120.0          # seconds for lexing + comparing one gate-1 scan
SHAPE_BUDGET = 120.0         # seconds for the line-shape comparison (gate 2)


class ScanTimeout(Exception):
    """The scan did not finish inside its budget. That is a FAIL, not a pass."""


def _check(deadline):
    if deadline is not None and time.monotonic() > deadline:
        raise ScanTimeout()


# =============================================================================
# C lexer
# =============================================================================
_WS = re.compile(r"[ \t\r\f\v]+")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUMBER = re.compile(r"(?:0[xX]|\.?[0-9])(?:[eEpP][+-]|[0-9A-Za-z_'.])*")
# Disjoint alternatives (a run of ordinary characters, or one escape pair), so
# matching is linear whatever the input looks like.
_STR_BODY = re.compile(r'(?:[^"\\\n]+|\\[\s\S])*')
_CHR_BODY = re.compile(r"(?:[^'\\\n]+|\\[\s\S])*")
_DIRECTIVE = re.compile(r"#[ \t]*([A-Za-z_]\w*)")
_SKIP_DIRECTIVES = frozenset(("include", "include_next", "import", "pragma",
                              "error", "warning", "line", "ident", "sccs"))
_STR_PREFIX = frozenset(("L", "u", "U", "u8"))
_DIGITS = frozenset("0123456789")
_OPS3 = frozenset(("<<=", ">>=", "..."))
_OPS2 = frozenset(("==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=",
                   "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "->", "##"))
_ASSIGN_OPS = frozenset(("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
                         "<<=", ">>="))
_ESC = re.compile(r"\\(?:(\r?\n)|x([0-9A-Fa-f]+)|([0-7]{1,3})|u([0-9A-Fa-f]{4})|"
                  r"U([0-9A-Fa-f]{8})|([\s\S]))")
_SIMPLE_ESC = {"n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11,
               "\\": 92, "'": 39, '"': 34, "?": 63, "e": 27}


def decode_c(body):
    """Interpret C escapes. `body` is source text read as latin-1, so the result
    is the bytes the compiler would emit (a literal ending in backslash-n really
    ends in a newline and can match a console line)."""
    out = bytearray()
    pos = 0
    for m in _ESC.finditer(body):
        out += body[pos:m.start()].encode("latin-1", "replace")
        pos = m.end()
        cont, hx, octal, u4, u8, other = m.groups()
        if cont is not None:
            continue                            # backslash-newline: line continuation
        if hx is not None:
            out.append(int(hx[-2:], 16))        # greedy hex, value truncated to a byte
        elif octal is not None:
            out.append(int(octal, 8) & 0xFF)
        elif u4 is not None or u8 is not None:
            try:
                out += chr(int(u4 or u8, 16)).encode("utf-8")
            except (ValueError, OverflowError):
                out.append(63)
        else:
            out.append(_SIMPLE_ESC.get(other, ord(other) & 0xFF))
    out += body[pos:].encode("latin-1", "replace")
    return bytes(out)


def _parse_int(text):
    t = text.replace("'", "")
    if len(t) > 40:
        return None                              # never feed a huge digit run to int()
    t = t.rstrip("uUlL")
    try:
        if t[:2] in ("0x", "0X"):
            return int(t[2:], 16)
        if t[:2] in ("0b", "0B"):
            return int(t[2:], 2)
        if len(t) > 1 and t[0] == "0" and t.isdigit():
            return int(t, 8)
        if t.isdigit():
            return int(t)
    except ValueError:
        return None
    return None


def _lex_quoted(src, i):
    """Lex a string or char literal starting at the quote at src[i].

    Returns (kind, value, end, newlines) or None when this quote is stray text
    (an apostrophe in dead prose)."""
    q = src[i]
    body_re = _STR_BODY if q == '"' else _CHR_BODY
    m = body_re.match(src, i + 1)
    j = m.end()
    closed = src.startswith(q, j)
    body = src[i + 1:j]
    nl = body.count("\n")
    if closed:
        j += 1
    elif q == "'":
        return None                              # unterminated char: not a literal
    value = decode_c(body)
    if q == '"':
        return "str", value, j, nl
    if len(value) == 1:
        return "chr", value[0], j, nl
    if not value:
        return "chr", 0, j, nl
    return "str", value, j, nl                   # multi-char constant: treat as text


def tokenize(src, deadline=None):
    """C source text (latin-1) -> list of (kind, text, value, line, in_pp).

    kind: id | num | str | chr | op | pp (directive start) | nl (end of a
    preprocessor line). Comments vanish. `#include`-like lines are skipped whole:
    their <...> and "..." are paths, not output. Every other directive keeps its
    tokens, because a `#define` can carry text that later reaches the console.
    """
    toks = []
    n = len(src)
    i, line = 0, 1
    bol, in_pp = True, False
    tick = 0
    while i < n:
        tick += 1
        if (tick & 2047) == 0:
            _check(deadline)
        c = src[i]
        if c == "\n":
            if in_pp:
                toks.append(("nl", "\n", None, line, True))
                in_pp = False
            line += 1
            i += 1
            bol = True
            continue
        if c in " \t\r\f\v":
            i = _WS.match(src, i).end()
            continue
        if c == "\\":
            if src.startswith("\n", i + 1):
                i += 2
                line += 1
                continue
            if src.startswith("\r\n", i + 1):
                i += 3
                line += 1
                continue
        if c == "/":
            nxt = src[i + 1:i + 2]
            if nxt == "*":
                j = src.find("*/", i + 2)
                j = n if j < 0 else j + 2
                line += src.count("\n", i, j)
                i = j
                continue
            if nxt == "/":
                j = i + 2
                while True:
                    k = src.find("\n", j)
                    if k < 0:
                        j = n
                        break
                    if k - 1 >= i + 2 and (src[k - 1] == "\\" or
                                          (src[k - 1] == "\r" and k - 2 >= i + 2
                                           and src[k - 2] == "\\")):
                        line += 1
                        j = k + 1
                        continue
                    j = k
                    break
                i = j
                continue
        if c == "#" and bol:
            m = _DIRECTIVE.match(src, i)
            name = m.group(1) if m else ""
            if name in _SKIP_DIRECTIVES:
                j = i
                while True:
                    k = src.find("\n", j)
                    if k < 0:
                        j = n
                        break
                    if k > i and (src[k - 1] == "\\" or
                                  (src[k - 1] == "\r" and k - 2 >= i and src[k - 2] == "\\")):
                        line += 1
                        j = k + 1
                        continue
                    j = k
                    break
                i = j
                continue
            toks.append(("pp", "#", name, line, True))
            in_pp = True
            i = m.end() if m else i + 1
            bol = False
            continue
        bol = False
        if c == '"' or c == "'":
            lit = _lex_quoted(src, i)
            if lit is not None:
                kind, value, j, nl = lit
                toks.append((kind, "", value, line, in_pp))
                line += nl
                i = j
                continue
            toks.append(("op", c, None, line, in_pp))
            i += 1
            continue
        if c == "_" or ("a" <= c <= "z") or ("A" <= c <= "Z"):
            m = _IDENT.match(src, i)
            word, j = m.group(), m.end()
            if word in _STR_PREFIX and j < n and src[j] in "\"'":
                lit = _lex_quoted(src, j)
                if lit is not None:
                    kind, value, j2, nl = lit
                    toks.append((kind, "", value, line, in_pp))
                    line += nl
                    i = j2
                    continue
            toks.append(("id", word, None, line, in_pp))
            i = j
            continue
        if c in _DIGITS or (c == "." and src[i + 1:i + 2] in _DIGITS):
            m = _NUMBER.match(src, i)
            text = m.group()
            toks.append(("num", text, _parse_int(text), line, in_pp))
            i = m.end()
            continue
        tri, duo = src[i:i + 3], src[i:i + 2]
        if tri in _OPS3:
            op = tri
        elif duo in _OPS2:
            op = duo
        else:
            op = c
        toks.append(("op", op, None, line, in_pp))
        i += len(op)
    return toks


# --- adjacent literal concatenation (with object-like string macros) ----------
_PRI = re.compile(r"^(?:PRI|SCN)([diouxX])(?:8|16|32|64|MAX|PTR|LEAST\d+|FAST\d+)$")


def _strpart(tok, macros):
    if tok[0] == "str":
        return True
    if tok[0] == "id":
        return tok[1] in macros or bool(_PRI.match(tok[1]))
    return False


def _partval(tok, macros):
    if tok[0] == "str":
        return tok[2]
    if tok[1] in macros:
        return macros[tok[1]]
    m = _PRI.match(tok[1])
    return b"l" + m.group(1).encode()            # PRIx64 -> the "lx" of "%" PRIx64


def _collect_macros(toks):
    """`#define NAME "text" "more"` -> {NAME: b"textmore"} so that
    `NAME "tail"` is seen as one literal instead of two fragments."""
    macros = {}
    n = len(toks)
    i = 0
    while i < n:
        t = toks[i]
        if t[0] == "pp" and t[2] == "define" and i + 1 < n and toks[i + 1][0] == "id":
            name = toks[i + 1][1]
            j = i + 2
            body = []
            while j < n and toks[j][0] != "nl":
                body.append(toks[j])
                j += 1
            if body and all(_strpart(b, macros) for b in body) and \
                    any(b[0] == "str" or b[1] in macros for b in body):
                macros[name] = b"".join(_partval(b, macros) for b in body)
            i = j
        else:
            i += 1
    return macros


def merge_strings(toks, macros):
    """Adjacent string literals are one literal to the compiler; so they are one
    here. `"Linux " "version 4.14"` must be matched as "Linux version 4.14"."""
    out = []
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if _strpart(t, macros) and not (out and out[-1][0] == "pp"):
            j = i
            while j < n and _strpart(toks[j], macros) and toks[j][4] == t[4]:
                j += 1
            run = toks[i:j]
            if any(r[0] == "str" for r in run):
                out.append(("str", "", b"".join(_partval(r, macros) for r in run),
                            run[0][3], t[4]))
            else:
                out.extend(run)
            i = j
        else:
            out.append(t)
            i += 1
    return out


# =============================================================================
# Structure: frames, calls, literals, lists, functions
# =============================================================================
# Output that stays on QEMU's own stderr: never the guest UART.
HOST_DIAG = frozenset(("error_report", "info_report", "warn_report", "qemu_log",
                       "qemu_log_mask", "error_report_once", "warn_report_once",
                       "info_report_once"))
# Names of QEMU objects (MemoryRegion labels, properties, the machine type). A
# region called "itmon" is the device being modelled, not the machine printing it.
_NAMING = re.compile(
    r"^(?:memory_region_init\w*|object_property_\w+|object_initialize\w*|object_new|"
    r"qdev_\w+|sysbus_\w+|type_register\w*|MACHINE_TYPE_NAME|blk_by_name|"
    r"qemu_chr_new|qemu_chr_fe_init|machine_class_\w+)$")
_DESC_NAMES = frozenset(("desc", "name", "fw_name"))
_KEYWORDS = frozenset(("if", "while", "switch", "return", "sizeof", "_Alignof",
                       "alignof", "__attribute__", "defined", "typeof", "__typeof__",
                       "_Static_assert", "static_assert", "else", "do", "case",
                       "goto"))
# The machine may receive input only through the chardev callback. These names
# are the self-injection helpers an earlier gate already looked for.
RX_SEED_NAMES = frozenset(("rx_seed", "seed_rx", "rx_inject", "inject_rx", "feed_rx"))
_RX_BUF = re.compile(r"(?i)^(?:\w*_)?(?:rx|rcv|recv|receive|rbr)"
                     r"(?:_?(?:buf|buffer|fifo|queue|data|byte|char|ring|chr))?$")
_RX_REG = re.compile(r"(?i)^(?:\w*_)?(?:rbr|rx_?(?:data|byte|char|reg|val))$")
_TIMER = re.compile(r"^(?:timer_new\w*|timer_init\w*|qemu_new_timer\w*|aio_timer_new\w*)$")
_COPY_CALLS = frozenset(("memcpy", "memmove", "memset", "strcpy", "strncpy", "strlcpy",
                         "fifo8_push", "fifo8_push_all", "fifo32_push", "fifo32_push_all"))
_STDOUT_STREAM_CALLS = frozenset(("fprintf", "fputs", "fputc", "putc", "fwrite", "vfprintf"))


class _Frame(object):
    __slots__ = ("kind", "name", "exempt", "start", "pending", "func")

    def __init__(self, kind, name, exempt, start):
        self.kind = kind          # call | group | for | brace
        self.name = name
        self.exempt = exempt      # host_diag | qemu_naming | None
        self.start = start
        self.pending = []         # literals held back until the call closes
        self.func = None


class _Run(object):
    """A comma-separated run of char/int constants inside an initializer."""
    __slots__ = ("items", "has_chr", "hexy", "line")

    def __init__(self):
        self.items = []
        self.has_chr = False
        self.hexy = False         # written as 0x.. : a byte table, not a list of codes
        self.line = 0

    def add(self, kind, value, line, text=""):
        if not self.items:
            self.line = line
        if kind == "chr":
            self.has_chr = True
            self.items.append((False, value))
            return
        if text[:2] in ("0x", "0X"):
            self.hexy = True
        if value > 0xFF:
            if value.bit_length() <= 64:
                self.items.append((True, value))
            else:
                self.items.append((False, 0xFF))   # breaks a text run
        else:
            self.items.append((False, value))


def ascii_runs(seq, minlen):
    """Runs of printable ASCII (plus tab/newline/CR) at least minlen long."""
    pat = re.compile(rb"[\x20-\x7e\t\n\r]{%d,}" % minlen)
    return [m.group() for m in pat.finditer(seq)]


def _run_candidates(run):
    items = run.items
    out, seen = [], set()
    if not any(w for (w, _v) in items):
        # {'l','o','g'} and {104,101} are text written as codes: two characters
        # already read as a word. A table of 0x.. bytes needs four in a row to
        # read as one (a register table is full of printable pairs).
        seq = bytes(v & 0xFF for (_w, v) in items)
        kind = "byte_array" if run.hexy and not run.has_chr else "char_list"
        for s in ascii_runs(seq, 4 if (run.hexy and not run.has_chr) else 2):
            if s not in seen:
                seen.add(s)
                out.append((kind, s))
        return out
    for order in ("little", "big"):
        parts = []
        for (wide, v) in items:
            if wide:
                parts.append(v.to_bytes(4 if v < (1 << 32) else 8, order))
            else:
                parts.append(bytes((v & 0xFF,)))
        for s in ascii_runs(b"".join(parts), 4):
            if s not in seen:
                seen.add(s)
                out.append(("wide_const", s))
    return out


def _const_strings(value):
    """A 32/64-bit constant that reads as ASCII ("NoGZ" = 0x4e6f475a)."""
    if value < 0x20202020 or value.bit_length() > 64:
        return []
    width = 4 if value < (1 << 32) else 8
    out, seen = [], set()
    for order in ("big", "little"):
        for s in ascii_runs(value.to_bytes(width, order), 4):
            if s not in seen:
                seen.add(s)
                out.append(s)
    return out


def _split_args(toks, a, b):
    args, depth, s = [], 0, a
    for k in range(a, b):
        t = toks[k]
        if t[0] == "op":
            if t[1] in ("(", "[", "{"):
                depth += 1
            elif t[1] in (")", "]", "}"):
                depth -= 1
            elif t[1] == "," and depth == 0:
                args.append((s, k))
                s = k + 1
    args.append((s, b))
    return args


def _skip_subscripts(toks, j):
    """Past `[..]` chains and `.field`/`->field` that follow them."""
    n = len(toks)
    while j < n:
        if toks[j][0] == "op" and toks[j][1] == "[":
            depth = 0
            while j < n:
                if toks[j][0] == "op" and toks[j][1] == "[":
                    depth += 1
                elif toks[j][0] == "op" and toks[j][1] == "]":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            continue
        if toks[j][0] == "op" and toks[j][1] in (".", "->") and j + 1 < n \
                and toks[j + 1][0] == "id":
            j += 2
            continue
        break
    return j


class Facts(object):
    """Everything the gates need from one source file."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.literals = []         # {"kind","value","line"} that could reach the console
        self.exempt = collections.Counter()
        self.calls = []            # (callee, line, caller or None)
        self.funcs = []            # (name, first token, last token)
        self.bare_ids = set()      # identifiers used without a call: address taken
        self.registered = []       # (position, function, line) of set_handlers
        self.timer_ids = []
        self.rx_writes = []        # (line, caller, what)
        self.macro_rx = {}         # macro name -> (line, what): an rx write in its body
        self.rx_seed = []          # (line, name)
        self.be_writes = []        # (line, caller)
        self.tx_sites = []         # (line, name)
        self.stdout_writers = []   # (line, name)
        self.int_consts = []       # (value, line)
        self.unbalanced = 0


def analyze(src_tokens, path, deadline=None):
    macros = _collect_macros(src_tokens)
    toks = merge_strings(src_tokens, macros)
    n = len(toks)
    f = Facts(path)
    stack, saved = [], []
    closed = None                  # (name, kind, index) of the last ')'
    cur_func = None
    macro = {"name": None, "next": False}      # the #define whose line is being read
    run = _Run()

    def release(frames):
        for fr in frames:
            if fr.pending:
                f.literals.extend(fr.pending)
                fr.pending = []
            if fr.kind != "brace":
                f.unbalanced += 1

    def emit(kind, value, line, skip_brace=False, exempt=None):
        if exempt:
            f.exempt[exempt] += 1
            return
        item = {"kind": kind, "value": value, "line": line}
        owner = None
        skipped = not skip_brace
        for fr in reversed(stack):
            if fr.kind == "call":
                owner = fr
                break
            if fr.kind == "brace":
                if not skipped:
                    skipped = True
                    continue
                break
        if owner is not None and owner.exempt:
            owner.pending.append(item)
        else:
            f.literals.append(item)

    def flush():
        for kind, s in _run_candidates(run):
            emit(kind, s, run.line, skip_brace=True)
        run.items = []
        run.has_chr = False
        run.hexy = False

    def _rx_write(line, what):
        """A write into an rx buffer. In a function-like macro body it is held
        under the macro's name and charged to each function that uses the macro."""
        if cur_func is None and macro["name"]:
            f.macro_rx[macro["name"]] = (line, what)
        else:
            f.rx_writes.append((line, cur_func, what))

    def on_call_close(fr, idx, line):
        name = fr.name
        if name.startswith("qemu_chr_fe_set_handlers"):
            args = _split_args(toks, fr.start + 1, idx)
            for pos in (1, 2, 3):
                if pos < len(args):
                    a, b = args[pos]
                    # the handler is the last identifier: `(IOReadHandler *)uart_receive`
                    ids = [toks[k][1] for k in range(a, b) if toks[k][0] == "id"]
                    if ids and ids[-1] != "NULL":
                        f.registered.append((pos, ids[-1], line))
        elif _TIMER.match(name):
            for k in range(fr.start + 1, idx):
                if toks[k][0] == "id":
                    f.timer_ids.append(toks[k][1])
        elif name in _COPY_CALLS:
            args = _split_args(toks, fr.start + 1, idx)
            a, b = args[0]
            zeroing = (name == "memset" and len(args) > 1 and args[1][1] - args[1][0] == 1
                       and toks[args[1][0]][0] == "num" and toks[args[1][0]][2] == 0)
            if not zeroing and any(toks[k][0] == "id" and _RX_BUF.match(toks[k][1])
                                   for k in range(a, b)):
                _rx_write(line, name + "()")
        if name in _STDOUT_STREAM_CALLS:
            if any(toks[k][0] == "id" and toks[k][1] == "stdout"
                   for k in range(fr.start + 1, idx)):
                f.stdout_writers.append((line, name))
        elif name in ("write", "dprintf") and fr.start + 1 < idx \
                and toks[fr.start + 1][0] == "num" and toks[fr.start + 1][2] == 1:
            f.stdout_writers.append((line, name))

    for idx in range(n):
        if (idx & 4095) == 0:
            _check(deadline)
        kind, text, value, line, pp = toks[idx]
        top = stack[-1] if stack else None
        in_list = top is not None and top.kind == "brace"

        if kind in ("chr", "num"):
            usable = value is not None and (kind == "num" or isinstance(value, int))
            if kind == "num" and value is not None:
                f.int_consts.append((value, line))
            if in_list and usable:
                run.add(kind, value, line, text)
                continue
            if run.items:
                flush()
            if kind == "num" and value is not None:
                for s in _const_strings(value):
                    emit("wide_const", s, line)
            continue
        if in_list and run.items and kind == "op" and text == ",":
            continue
        if run.items:
            flush()

        if kind == "pp":
            saved.append((stack, closed))
            stack, closed = [], None
            macro["name"], macro["next"] = None, (value == "define")
            continue
        if kind == "nl":
            release(stack)
            stack, closed = saved.pop() if saved else ([], None)
            macro["name"], macro["next"] = None, False
            continue

        if kind == "str":
            desc = (idx >= 3 and toks[idx - 1][0] == "op" and toks[idx - 1][1] == "="
                    and toks[idx - 2][0] == "id" and toks[idx - 2][1] in _DESC_NAMES
                    and toks[idx - 3][0] == "op" and toks[idx - 3][1] == "->")
            emit("string", value, line, exempt="qemu_naming" if desc else None)
            continue

        if kind == "id":
            if macro["next"]:
                macro["name"], macro["next"] = text, False
            nxt = toks[idx + 1] if idx + 1 < n else None
            called = nxt is not None and nxt[0] == "op" and nxt[1] == "("
            if called:
                if text in RX_SEED_NAMES:
                    f.rx_seed.append((line, text))
            else:
                f.bare_ids.add(text)
            prev = toks[idx - 1] if idx else None
            if _RX_BUF.match(text) and nxt is not None and nxt[0] == "op" and nxt[1] == "[":
                j = _skip_subscripts(toks, idx + 1)
                decl = (prev is not None and prev[0] == "id"
                        and prev[1] not in ("else", "do", "return", "case"))
                zero = (j + 2 < n and toks[j][1] == "=" and toks[j + 1][0] == "num"
                        and toks[j + 1][2] == 0 and toks[j + 2][0] == "op"
                        and toks[j + 2][1] in (";", ",", ")"))     # clearing, not typing
                if j < n and toks[j][0] == "op" and toks[j][1] in _ASSIGN_OPS \
                        and not decl and not zero:
                    _rx_write(line, text + "[]")
            elif _RX_REG.match(text) and nxt is not None and nxt[0] == "op" \
                    and nxt[1] in _ASSIGN_OPS:
                decl = (prev is not None and
                        ((prev[0] == "id" and prev[1] not in ("else", "do", "return", "case"))
                         or (prev[0] == "op" and prev[1] == "*" and idx >= 2
                             and toks[idx - 2][0] == "id"
                             and toks[idx - 2][1] not in _KEYWORDS)))
                if not decl:
                    _rx_write(line, text)
            continue

        if kind != "op":
            continue

        if text == "(":
            prev = toks[idx - 1] if idx else None
            name = prev[1] if (prev is not None and prev[0] == "id") else None
            if name is None:
                fk = "group"
            elif name == "for":
                fk = "for"
            elif name in _KEYWORDS:
                fk = "group"
            else:
                fk = "call"
            exempt = None
            if fk == "call":
                if name in HOST_DIAG:
                    exempt = "host_diag"
                elif name == "fprintf" and idx + 2 < n and toks[idx + 1][1] == "stderr" \
                        and toks[idx + 2][1] == ",":
                    exempt = "host_diag"
                elif _NAMING.match(name):
                    exempt = "qemu_naming"
                if (cur_func is not None or pp) and not (pp and name == macro["name"]):
                    # A `name(` at file scope is a definition or a prototype, not a
                    # call: counting it made the receive callback "call itself". The
                    # same goes for the name a #define introduces.
                    f.calls.append((name, line, cur_func))
                if name.startswith("qemu_chr_fe_write") or \
                        name in ("qemu_chr_write", "qemu_chr_write_all"):
                    f.tx_sites.append((line, name))
                elif name.startswith("qemu_chr_be_write"):
                    f.be_writes.append((line, cur_func))
                elif name in ("printf", "vprintf", "puts", "putchar"):
                    f.stdout_writers.append((line, name))
            stack.append(_Frame(fk, name, exempt, idx))
        elif text == ")":
            if stack and stack[-1].kind in ("call", "group", "for"):
                fr = stack.pop()
                if fr.pending:
                    f.exempt[fr.exempt] += len(fr.pending)
                    fr.pending = []
                closed = (fr.name, fr.kind, idx)
                if fr.kind == "call":
                    on_call_close(fr, idx, line)
            else:
                f.unbalanced += 1
        elif text == "{":
            # A function body starts where no function and no open paren is: braces
            # left open by the other branch of an #if must not hide every function
            # after them.
            is_func = (not pp and cur_func is None and closed is not None
                       and all(x.kind == "brace" and not x.func for x in stack)
                       and closed[2] == idx - 1 and closed[1] == "call"
                       and closed[0] not in _KEYWORDS)
            fr = _Frame("brace", None, None, idx)
            if is_func:
                fr.func = closed[0]
                cur_func = closed[0]
            stack.append(fr)
        elif text == "}":
            while stack and stack[-1].kind != "brace":
                release([stack.pop()])
            if stack:
                fr = stack.pop()
                if fr.func:
                    f.funcs.append((fr.func, fr.start, idx))
                    cur_func = None
            else:
                f.unbalanced += 1
        elif text == ";":
            # A `;` inside a call's parentheses means the call was never closed
            # (it cannot compile). Held-back literals are released as collected,
            # so a truncated host-diagnostic call cannot hide what follows it.
            while stack and stack[-1].kind in ("call", "group"):
                release([stack.pop()])

    if run.items:
        flush()
    release(stack)
    for st, _c in saved:
        release(st)
    return f


def read_source(path):
    with open(path, "rb") as fh:
        return fh.read().decode("latin-1")


def analyze_file(path, deadline=None):
    return analyze(tokenize(read_source(path), deadline), path, deadline)


def analyze_files(paths, deadline=None):
    return [analyze_file(p, deadline) for p in paths]


# =============================================================================
# Which sources are the machine
# =============================================================================
_INCLUDE_LOCAL = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.M)


def read_targets(workdir):
    """Basenames sync_machine.sh recorded in qemu_targets.txt (what was built)."""
    path = os.path.join(workdir, "06_machine", "qemu_targets.txt")
    if not os.path.isfile(path):
        return None
    names = set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.split("#", 1)[0].strip()
            if raw:
                names.add(os.path.basename(raw.split("\t")[0].split()[0]))
    return names


def resolve_sources(workdir):
    """(built, skipped): the machine files that were actually compiled, and the
    stale ones next to them (named, so a reader sees what was left out).

    Without qemu_targets.txt every .c is taken, plus .h/.inc. With it, a .c is
    built only if it was synced into the QEMU tree; a header only if a built file
    includes it. A superseded v1 machine left in 06_machine/ is not evidence of
    what ran, and scanning it turned stale text into false leaks."""
    src = os.path.join(workdir, "06_machine")
    all_c = sorted(glob.glob(os.path.join(src, "*.c")))
    all_h = sorted(glob.glob(os.path.join(src, "*.h")) + glob.glob(os.path.join(src, "*.inc")))
    targets = read_targets(workdir)
    if targets is None:
        return [p for p in all_c + all_h if os.path.isfile(p)], []
    built_c = [p for p in all_c if os.path.basename(p) in targets]
    by_name = {os.path.basename(p): p for p in all_h}
    built_h, queue = set(), [p for p in built_c] + \
        [by_name[n] for n in targets if n in by_name]
    seen = set()
    while queue:
        p = queue.pop()
        if p in seen:
            continue
        seen.add(p)
        if p in by_name.values():
            built_h.add(p)
        try:
            text = read_source(p)
        except OSError:
            continue
        for inc in _INCLUDE_LOCAL.findall(text):
            q = by_name.get(os.path.basename(inc))
            if q and q not in seen:
                queue.append(q)
    built = built_c + sorted(built_h)
    skipped = [os.path.basename(p) for p in all_c + all_h if p not in built]
    return built, skipped


# =============================================================================
# Guest console
# =============================================================================
_HOST_LINE = re.compile(rb"^(?:\d+(?:\.\d+)?\s+)?qemu-system-[A-Za-z0-9_]+:\s")
_HOST_MID = re.compile(rb"(?:\d+\.\d+\s+)?qemu-system-[A-Za-z0-9_]+:\s")
_LINE_SPLIT = re.compile(rb"[\r\n]+")
_KLINE = re.compile(rb"^\s*\d+(?:\.\d+)?\s(.*)$")


def filter_host(data):
    """(guest_lines, dropped): bytes -> lines with QEMU's own diagnostics removed.
    Read as bytes: a text-mode read silently drops a guest line that carries a
    stray carriage return."""
    lines, dropped = [], 0
    for ln in _LINE_SPLIT.split(data):
        if not ln:
            continue
        if _HOST_LINE.match(ln):
            dropped += 1
            continue
        m = _HOST_MID.search(ln)
        if m:                                    # a host line glued after guest text
            dropped += 1
            ln = ln[:m.start()]
            if not ln.strip():
                continue
        lines.append(ln)
    return lines, dropped


def read_guest_console(console_path, memdump_path=None):
    """The guest console = UART lines + the merged memory-dump kernel log.

    kernel_<N>.log has one `<seconds> <text>` per line; only the text is the
    guest's. Host diagnostics are removed from both (defensively: the run script
    already writes them to host_<N>.txt)."""
    uart_raw = b""
    if console_path and os.path.isfile(console_path):
        with open(console_path, "rb") as fh:
            uart_raw = fh.read()
    uart, dropped = filter_host(uart_raw)
    mem, mem_dropped = [], 0
    if memdump_path and os.path.isfile(memdump_path):
        with open(memdump_path, "rb") as fh:
            lines, mem_dropped = filter_host(fh.read())
        for ln in lines:
            m = _KLINE.match(ln)
            mem.append(m.group(1) if m else ln)
    lines = uart + mem
    return {"lines": lines, "bytes": b"\n".join(lines) + (b"\n" if lines else b""),
            "uart_lines": len(uart), "memdump_lines": len(mem),
            "host_dropped": dropped + mem_dropped, "uart_bytes": len(uart_raw)}


class ConsoleView(object):
    """The console as the gates compare against it: unique lines only, so a
    retry loop's 100k repeats cost nothing."""

    def __init__(self, lines):
        seen, uniq = set(), []
        for ln in lines:
            if ln not in seen:
                seen.add(ln)
                uniq.append(ln)
        self.lines = lines
        self.blob = b"\n".join(uniq)
        self.lineset = {ln.strip() for ln in uniq}

    @classmethod
    def of(cls, console):
        if isinstance(console, ConsoleView):
            return console
        if isinstance(console, dict):
            return cls(console["lines"])
        return cls([ln for ln in _LINE_SPLIT.split(console) if ln])


# =============================================================================
# Gate 1: source negative
# =============================================================================
_FMT = re.compile(rb"%[-+ #0-9.*hlLzjtq]*[a-zA-Z%]")
_NL = re.compile(rb"[\r\n]+")


def literal_pieces(value):
    """What a literal can look like once printed: [(text, mode)].

    mode "sub"   a fixed run of 6+ characters, searched inside the console
    mode "line"  a short literal with no conversions, which must equal a whole
                 console line (a short fragment is everywhere, a whole line is not)
    A literal containing `%d` prints differently than it is written, so only the
    runs between conversions are compared. A literal that is several lines (an
    escaped newline in the middle) is compared line by line."""
    out = []
    for ln in _NL.split(value):
        s = ln.strip()
        if not s:
            continue
        parts = _FMT.split(ln)
        if len(parts) == 1:
            out.append((s, "sub" if len(s) >= 6 else "line"))
        else:
            for p in parts:
                p = p.strip()
                if len(p) >= 6:
                    out.append((p, "sub"))
    return out


def find_leaks(facts_list, view, deadline=None):
    leaks, seen = [], set()
    for f in facts_list:
        for it in f.literals:
            _check(deadline)
            for piece, mode in literal_pieces(it["value"]):
                key = (f.name, piece)
                if key in seen:
                    continue
                hit = (piece in view.blob) if mode == "sub" else (piece in view.lineset)
                if hit:
                    seen.add(key)
                    leaks.append({"file": f.name, "line": it["line"], "kind": it["kind"],
                                  "text": piece[:60].decode("latin-1"), "match": mode})
    return leaks


def parse_ranges(spec):
    """"0x48090000:0xe0000,0x50000000-0x50001000" -> [(base, size)]."""
    out = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            a, b = part.split(":", 1)
            base, size = int(a, 0), int(b, 0)
        elif "-" in part:
            a, b = part.split("-", 1)
            base = int(a, 0)
            size = int(b, 0) - base
        else:
            raise ValueError("범위는 BASE:SIZE 또는 BASE-END 입니다: %s" % part)
        out.append((base, size))
    return out


def plan_ranges(workdir):
    """The protected pstore region from the static-analyzer's memdump_plan.json."""
    path = os.path.join(workdir, "memdump_plan.json")
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
        base = int(str(plan["region_base"]), 0)
        size = int(str(plan["region_size"]), 0)
        return [(base, size)]
    except (OSError, ValueError, KeyError, TypeError):
        return []


# Calls through which a machine writes guest memory. The protected-range check above sees
# only integer CONSTANTS inside the range; an address computed at run time (base + offset)
# is invisible to it, so where the machine writes at all is listed for the reader. Reported,
# never a gate: a machine legitimately places its stages and initialises its vector page.
_GUEST_WRITE = re.compile(
    r"^(?:address_space_(?:write\w*|rw|st\w*)|cpu_physical_memory_(?:write|rw)|dma_memory_(?:write|rw)|"
    r"(?:stb|stw|stl|stq)_phys|memory_region_get_ram_ptr)$")


def source_negative(facts_list, console, protected=None, skipped=(), deadline=None):
    """Gate 1 over already-analysed files. Returns the full result dict."""
    view = ConsoleView.of(console)
    leaks = find_leaks(facts_list, view, deadline)
    tx = [(f.name, ln, nm) for f in facts_list for (ln, nm) in f.tx_sites]
    stdout = [(f.name, ln, nm) for f in facts_list for (ln, nm) in f.stdout_writers]
    hits = []
    for (base, size) in (protected or []):
        for f in facts_list:
            for (v, ln) in f.int_consts:
                if base <= v < base + size:
                    hits.append({"file": f.name, "line": ln, "value": hex(v),
                                 "range": "%s+%s" % (hex(base), hex(size))})
    guest_writes = []
    if protected:
        for f in facts_list:
            for (name, ln, func) in f.calls:
                if _GUEST_WRITE.match(name):
                    guest_writes.append({"file": f.name, "line": ln, "call": name, "func": func})
    exempt = collections.Counter()
    for f in facts_list:
        exempt.update(f.exempt)
    return {
        "leaks": leaks,
        "guest_writes": guest_writes,
        "tx_paths": [{"file": a, "line": b, "call": c} for (a, b, c) in tx],
        "stdout_writers": [{"file": a, "line": b, "call": c} for (a, b, c) in stdout],
        "protected_hits": hits,
        "exempt": dict(exempt),
        "unbalanced": sum(f.unbalanced for f in facts_list),
        "skipped_stale": list(skipped),
        "files": [f.name for f in facts_list],
    }


def source_negative_verdict(res, n_sources, timed_out=False):
    """(ok, evidence) in the wording the gate has always used."""
    if timed_out:
        return False, ("소스 스캔이 제한 시간(%d 초)을 넘겼습니다 — 검사하지 못한 것은 "
                       "통과가 아닙니다" % SCAN_BUDGET)
    if n_sources == 0:
        # Nothing scanned is not the same as nothing found. Passing here would
        # certify "the machine does not print console text" without having read
        # a single machine source.
        return False, ("머신 소스를 하나도 찾지 못했습니다 (06_machine/*.c) — "
                       "검사하지 못한 것은 통과가 아닙니다")
    problems = []
    if res["leaks"]:
        shown = ["%s:%s" % (lk["file"], lk["text"][:40]) for lk in res["leaks"][:10]]
        problems.append("머신이 출력하는 문자열이 콘솔에 %d 건 나타납니다: %s — "
                        "머신이 콘솔을 지어냈는지 확인하십시오" % (len(res["leaks"]), shown))
    if len(res["tx_paths"]) > 1:
        sites = ["%s:%d" % (t["file"], t["line"]) for t in res["tx_paths"][:6]]
        problems.append("게스트 UART 출력 경로가 %d 곳입니다 (1 곳이어야 합니다): %s"
                        % (len(res["tx_paths"]), sites))
    if res["stdout_writers"]:
        sites = ["%s:%d %s" % (t["file"], t["line"], t["call"]) for t in res["stdout_writers"][:6]]
        problems.append("머신이 QEMU stdout 에 씁니다 (하니스가 stdout 전체를 콘솔 파일에 "
                        "쓰므로 둘째 출력 경로입니다): %s" % sites)
    if res["protected_hits"]:
        sites = ["%s:%d %s" % (h["file"], h["line"], h["value"]) for h in res["protected_hits"][:6]]
        problems.append("머신 소스가 보호 영역(pstore)의 주소 %d 곳을 참조합니다: %s — "
                        "이 영역은 머신이 쓰면 안 됩니다" % (len(res["protected_hits"]), sites))
    if problems:
        return False, " / ".join(problems)
    ex = res["exempt"]
    note = ("머신 소스 %d 개의 어떤 출력 문자열도 콘솔에 없습니다 "
            "(주석·#include·호스트 진단·객체 이름은 출력이 아니므로 제외)" % n_sources)
    if len(res["tx_paths"]) == 1:
        note += " · UART 출력 경로 1 곳"
    elif not res["tx_paths"]:
        note += " · UART 출력 호출 없음"
    if ex:
        note += " · 제외 호스트 진단 %d, 객체 이름 %d" % (ex.get("host_diag", 0),
                                                         ex.get("qemu_naming", 0))
    if res["skipped_stale"]:
        note += " · 빌드되지 않아 제외한 파일: %s" % res["skipped_stale"]
    if res.get("guest_writes"):
        funcs = sorted({w["func"] or "(전역)" for w in res["guest_writes"]})
        note += (" · 게스트 메모리에 쓰는 호출 %d 곳 (함수 %s) — 계산된 주소는 정적으로 보지 "
                 "못하므로 이 함수들이 보호 영역(pstore)에 쓰지 않는지 소스를 읽어 확인하십시오"
                 % (len(res["guest_writes"]), ", ".join(funcs[:8])))
    if res["unbalanced"]:
        note += " · 괄호가 맞지 않는 곳 %d (건너뛴 것이 아니라 보수적으로 검사)" % res["unbalanced"]
    return True, note


def check_source_negative(sources, console_bytes, protected=None, skipped=()):
    """(ok, evidence). Leak-only: the TX-path, stdout and guest-write findings are
    reported by verify.py's gate 1, not here."""
    if not sources:
        return source_negative_verdict({}, 0)
    deadline = time.monotonic() + SCAN_BUDGET
    try:
        facts = analyze_files(sources, deadline)
        res = source_negative(facts, ConsoleView.of(console_bytes), protected, skipped, deadline)
    except ScanTimeout:
        return source_negative_verdict({}, len(sources), timed_out=True)
    res = dict(res, tx_paths=[], stdout_writers=[], protected_hits=[], guest_writes=[])
    return source_negative_verdict(res, len(sources))


# =============================================================================
# Gate 3: input origin
# =============================================================================
_MONITOR_INJECT = re.compile(
    r"\b(sendkey|send-key|chardev[-_]send[-_]break|ringbuf[-_]write|"
    r"input[-_]send[-_]event|human[-_]monitor[-_]command|chardev[-_]add|chardev[-_]change)\b")
_MONITOR_CALLS = (
    re.compile(r"""\bmon\s+["']([^"'\n]+)["']"""),
    re.compile(r"""(?:echo|printf)\s+(?:-e\s+|-n\s+)?["']([^"'\n]+)["']\s*\|\s*"""
               r"""(?:\S+\s+)*?(?:socat|nc|ncat)\b"""),
    re.compile(r'''["']execute["']\s*:\s*["']([\w-]+)["']'''),
    re.compile(r'''["']command-line["']\s*:\s*["']([^"'\n]+)["']'''),
    # a helper that runs one monitor command: hmp(sock, 'pmemsave ...'), qmp("..."),
    # monitor_cmd("...") - the command is the first word of the string argument.
    # (Lower case only: MonitorGone("monitor closed") is an exception, not a command.)
    re.compile(r"""\b(?:hmp\w*|qmp\w*|mon|\w*monitor_cmd\w*|\w*monitor_command\w*)\s*\("""
               r"""\s*(?:[^,()"'\n]+,\s*)?[rbf]?["']([A-Za-z][\w-]*[^"'\n]*)["']"""),
    # a write to something that is a monitor/QMP socket (not any file object)
    re.compile(r"""\b\w*(?:mon|sock|qmp|hmp|conn)\w*\.(?:send|sendall|write)\(\s*b?["']"""
               r"""([A-Za-z][\w-]*[^"'\n]*)["']""", re.I),
)
ALLOWED_MONITOR = frozenset(("pmemsave",))


def scan_monitor(paths):
    """Monitor commands in harness sources. The monitor may only be used to read
    guest memory back (pmemsave); anything that types, sends keys, or rewires a
    chardev is the host feeding the guest and must be on the record."""
    findings, used = [], set()
    for p in paths:
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        name = os.path.basename(p)
        # a full-line comment that says "never sendkey" is not a use of it
        text = "\n".join("" if ln.lstrip().startswith("#") else ln for ln in text.split("\n"))
        cmds = []
        for rx in _MONITOR_CALLS:
            for m in rx.finditer(text):
                # the command is the first word; a literal backslash-n in a Python
                # or shell string ends it just as whitespace does
                first = re.split(r"\\[nr]|\s", m.group(1).strip())[0]
                if first:
                    cmds.append((first, text.count("\n", 0, m.start()) + 1))
        for m in _MONITOR_INJECT.finditer(text):
            cmds.append((m.group(1), text.count("\n", 0, m.start()) + 1))
        reported = set()
        for cmd, line in cmds:
            used.add(cmd)
            if cmd not in ALLOWED_MONITOR and (line, cmd) not in reported:
                reported.add((line, cmd))
                findings.append({"file": name, "line": line, "kind": "monitor_command",
                                 "detail": "모니터 명령 '%s' (pmemsave 외)" % cmd})
    return findings, sorted(used)


def input_origin(facts_list, harness_paths=(), input_token=None):
    """Gate 3: the machine must not feed its own receive path.

    Input may only arrive through the function registered with
    qemu_chr_fe_set_handlers (and what only it calls). Everything below is a way
    of typing into the guest from inside the machine:
      - an rx_seed-style helper
      - qemu_chr_be_write (the backend side of the chardev, called by the machine)
      - a write into an rx buffer / data register outside that callback, including
        from a timer callback
      - the machine calling its own receive callback
      - a monitor command other than pmemsave in the harness
      - the command the host types (`input_token`) sitting in the machine as a
        whole literal: the machine would be supplying its own input
    """
    findings = []
    if input_token:
        tok = input_token.encode("utf-8")
        for f in facts_list:
            for it in f.literals:
                v = it["value"].strip()
                if v == tok or (tok.endswith(b":") and v.startswith(tok)):
                    findings.append({"file": f.name, "line": it["line"], "kind": "input_command",
                                     "detail": "입력 명령 '%s' 이 머신 소스에 리터럴로 있습니다 — "
                                               "머신이 명령을 지어내는 순환검증입니다" % input_token})
    for f in facts_list:
        for (line, nm) in f.rx_seed:
            findings.append({"file": f.name, "line": line, "kind": "rx_seed",
                             "detail": "%s() — 머신이 수신 버퍼를 스스로 채웁니다" % nm})
        for (line, caller) in f.be_writes:
            findings.append({"file": f.name, "line": line, "kind": "chr_be_write",
                             "detail": "qemu_chr_be_write — 머신이 chardev 의 입력 쪽을 직접 호출합니다"})

    defined = {nm for f in facts_list for (nm, _s, _e) in f.funcs}
    registered = {fn for f in facts_list for (_p, fn, _l) in f.registered}
    read_cb = {fn for f in facts_list for (p, fn, _l) in f.registered if p == 2}
    callers = collections.defaultdict(set)
    edges = collections.defaultdict(set)
    for f in facts_list:
        for (callee, _line, caller) in f.calls:
            if callee in defined:
                callers[callee].add(caller or "<file>")
                if caller:
                    edges[caller].add(callee)
    bare = set()
    for f in facts_list:
        bare |= f.bare_ids
    allowed = set(registered)
    changed = True
    while changed:
        changed = False
        for fn in defined:
            if fn in allowed or fn in bare:
                continue
            cs = callers.get(fn)
            if cs and all(c in allowed for c in cs):
                allowed.add(fn)
                changed = True
    timer_cbs = {i for f in facts_list for i in f.timer_ids} & defined
    from_timer, work = set(timer_cbs), list(timer_cbs)
    while work:
        for nxt in edges.get(work.pop(), ()):
            if nxt not in from_timer:
                from_timer.add(nxt)
                work.append(nxt)

    # A write inside a function-like macro is charged to each function that uses it.
    macro_rx = {}
    for f in facts_list:
        macro_rx.update(f.macro_rx)
    for f in facts_list:
        writes = list(f.rx_writes)
        for (callee, line, caller) in f.calls:
            if callee in macro_rx:
                writes.append((line, caller, "%s()→%s" % (callee, macro_rx[callee][1])))
        for (line, caller, what) in writes:
            if caller in allowed:
                continue
            where = "타이머 콜백 %s 에서" % caller if caller in from_timer else \
                ("%s() 에서" % caller if caller else "함수 밖(매크로)에서")
            findings.append({"file": f.name, "line": line, "kind": "rx_write",
                             "detail": "%s 수신 버퍼에 씁니다 (%s) — chardev 콜백 밖입니다"
                                       % (where, what)})
        for (callee, line, caller) in f.calls:
            if callee in read_cb and caller not in allowed:
                findings.append({"file": f.name, "line": line, "kind": "callback_call",
                                 "detail": "%s() 는 chardev 수신 콜백인데 머신 코드가 직접 "
                                           "호출합니다 (%s)" % (callee, caller or "함수 밖")})
    mon_findings, used = scan_monitor(harness_paths)
    findings += mon_findings
    return {"findings": findings, "callbacks": sorted(registered),
            "monitor_commands": used, "harness": [os.path.basename(p) for p in harness_paths]}


def input_origin_verdict(res, n_sources):
    if n_sources == 0:
        return False, "머신 소스를 찾지 못해 입력 경로를 확인할 수 없습니다"
    if res["findings"]:
        shown = ["%s:%d %s" % (x["file"], x["line"], x["kind"]) for x in res["findings"][:8]]
        return False, ("머신이 자기 수신 경로를 채웁니다 (%d 건): %s — 입력은 chardev 콜백으로만 "
                       "들어와야 합니다" % (len(res["findings"]), shown))
    note = "머신 소스 %d 개에 수신 버퍼 자가 주입이 없습니다" % n_sources
    if res["callbacks"]:
        note += " (수신 콜백: %s)" % ", ".join(res["callbacks"])
    if res["harness"]:
        note += " · 하니스 %d 개의 모니터 명령은 pmemsave 뿐" % len(res["harness"]) \
            if res["monitor_commands"] else " · 하니스 %d 개에 모니터 명령 없음" % len(res["harness"])
    return True, note


def check_input_origin(sources, harness_paths=(), input_token=None):
    """(ok, evidence) for a list of source paths."""
    if not sources:
        return input_origin_verdict({}, 0)
    deadline = time.monotonic() + SCAN_BUDGET
    try:
        res = input_origin(analyze_files(sources, deadline), harness_paths, input_token)
    except ScanTimeout:
        return False, "소스 스캔이 제한 시간을 넘겼습니다 — 검사하지 못한 것은 통과가 아닙니다"
    return input_origin_verdict(res, len(sources))


# =============================================================================
# Gate 2: output origin
# =============================================================================
# Console words that are fixed strings in the firmware, as opposed to the values
# printf assembles at runtime. "%d"/"%s" substitutions (timestamps, sizes, register
# dumps) are NOT in the image and counting them as missing made the gate fail on a
# console that was entirely genuine - 3,131 of 4,511 "missing" tokens were digits.
FIXED_WORD = re.compile(rb"[A-Za-z][A-Za-z_]{3,}")
# A console the machine invented would fail to match almost everywhere. A handful
# of unmatched words means the reference set is incomplete - the console is
# written by every firmware component that shares the UART, and an exported kit may
# not carry all of them.
ORIGIN_MIN_RATIO = 0.98

IMAGE_DIRS = ("03_bootloader", "02_unpacked", "fw", "verify_ref")
IMAGE_MAX = 128 * 1024 * 1024        # skip super.img / lu0.img sized backing stores
_MEDIUM_NAME = re.compile(r"(?i)^lu\d*(?:[_.-].*)?\.img$|negative")
GUNZIP_CAP = 512 * 1024 * 1024
_EXCLUDED_KINDS = ("synthesized", "forged")


class BlobSet(object):
    """Reference images opened read-only through mmap, so a 128 MB file costs
    address space, not memory. Close() when done."""

    def __init__(self):
        self.blobs, self.names, self.excluded = [], [], []
        self._keep = []

    def add_file(self, path, label=None):
        label = label or os.path.basename(path)
        try:
            size = os.path.getsize(path)
            if size == 0:
                return
            fh = open(path, "rb")
            try:
                blob = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
                self._keep.append((fh, blob))
            except (OSError, ValueError):
                blob = fh.read()
                fh.close()
            self.blobs.append(blob)
            self.names.append(label)
            if blob[:2] == b"\x1f\x8b":
                self._add_gunzip(path, label)
        except OSError:
            return

    def _add_gunzip(self, path, label):
        """A gzip kernel is searched as the plain Image it decompresses to."""
        out, total = [], 0
        d = zlib.decompressobj(31)
        try:
            with open(path, "rb") as fh:
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    data = d.decompress(chunk)
                    total += len(data)
                    if total > GUNZIP_CAP:
                        return
                    out.append(data)
                    if d.eof:
                        break
        except (OSError, zlib.error):
            return
        if out:
            self.blobs.append(b"".join(out))
            self.names.append(label + "(gunzip)")

    def add_bytes(self, data, label):
        if data:
            self.blobs.append(data)
            self.names.append(label)

    def close(self):
        for fh, blob in self._keep:
            try:
                blob.close()
                fh.close()
            except (OSError, ValueError):
                pass
        self._keep = []


def load_medium_kinds(workdir, provenance=None, manifest=None):
    """name -> {"kind", "source"}: what each partition of the medium really is.

    lu_provenance.json is written beside the image by build_lu.py; the manifest
    entries carry the same `kind`. Tolerates the shapes either could take."""
    kinds = {}

    def put(name, kind, source=None):
        if name:
            cur = kinds.setdefault(str(name), {"kind": None, "source": None})
            if kind:
                cur["kind"] = str(kind)
            if source:
                cur["source"] = source

    def read_json(path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    mpath = manifest or os.path.join(workdir, "lu_manifest.json")
    if os.path.isfile(mpath):
        data = read_json(mpath) or {}
        for p in (data.get("partitions") or []) if isinstance(data, dict) else []:
            if isinstance(p, dict):
                put(p.get("name"), p.get("kind"), p.get("source"))
    ppath = provenance
    if not ppath:
        for cand in (os.path.join(workdir, "fw", "lu_provenance.json"),
                     os.path.join(workdir, "lu_provenance.json")):
            if os.path.isfile(cand):
                ppath = cand
                break
    if ppath and os.path.isfile(ppath):
        data = read_json(ppath)
        if isinstance(data, dict) and isinstance(data.get("partitions"), (dict, list)):
            data = data["partitions"]
        if isinstance(data, dict):
            for name, v in data.items():
                put(name, v.get("kind") if isinstance(v, dict) else v,
                    v.get("source") if isinstance(v, dict) else None)
        elif isinstance(data, list):
            for v in data:
                if isinstance(v, dict):
                    put(v.get("name"), v.get("kind"), v.get("source"))
    return kinds


def reference_images(workdir, extra=(), provenance=None, manifest=None):
    """Firmware components whose strings the console may legitimately contain.

    The console is not produced by the bootloader container alone - the other firmware
    components that share the UART (and the DTB) print through it too, and their
    strings live in their own files. What is NOT reference: the synthesized medium image itself, and any
    partition build_lu.py made up (kind synthesized/forged) - bytes we wrote cannot
    be the evidence for output we want to prove genuine."""
    bs = BlobSet()
    kinds = load_medium_kinds(workdir, provenance, manifest)
    bad_names = {n.lower() for n, v in kinds.items() if v["kind"] in _EXCLUDED_KINDS}
    bad_paths = {os.path.realpath(os.path.join(workdir, v["source"]))
                 for v in kinds.values()
                 if v["kind"] in _EXCLUDED_KINDS and v["source"]}
    seen = set()
    for path in extra:
        if path and os.path.isfile(path):
            seen.add(os.path.realpath(path))
            bs.add_file(path)
    for sub in IMAGE_DIRS:
        for path in sorted(glob.glob(os.path.join(workdir, sub, "*"))):
            real = os.path.realpath(path)
            if real in seen or not os.path.isfile(path):
                continue
            base = os.path.basename(path)
            stem = os.path.splitext(base)[0].lower()
            if os.path.getsize(path) > IMAGE_MAX:
                continue
            if os.path.splitext(path)[1].lower() not in (".bin", ".img", ".dtb", ""):
                continue
            if _MEDIUM_NAME.search(base):
                bs.excluded.append({"file": base, "reason": "합성한 매체 이미지"})
                continue
            if real in bad_paths or stem in bad_names:
                bs.excluded.append({"file": base, "reason": "합성·위조 파티션 (lu_provenance)"})
                continue
            seen.add(real)
            bs.add_file(path)
    return bs


def _in_any(blobs, needle):
    for b in blobs:
        if b.find(needle) >= 0:
            return True
    return False


_PH = b"\x00"
# Decorations a logging layer puts in front of the message: kernel timestamps
# `[   1.234]`, caller ids `[T12]`, tick counters `[15929]`, `<6>` levels. They are
# not part of the format string in the image, so they come off before comparing.
_TAGS = re.compile(rb"^(?:\s*(?:\[\s*(?:[TC]?\d+(?:\.\d+)?)\s*\]|<\d+>))+\s*")
_EPOCH = re.compile(rb"^\d{9,}(?:\.\d+)?\s+")      # a wall-clock prefix some harnesses add
_NEG = re.compile(rb"(?<![\w\])])-(?=[0-9])")        # `= -1`: the sign belongs to the number
_HEXRUN = re.compile(rb"\b(?:(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{3,}|[fF]{4,})\b")
_NUMRUN = re.compile(rb"0[xX][0-9A-Fa-f]+|[0-9]+")
_PHRUN = re.compile(rb"\x00+")
_ALPHA = re.compile(rb"[A-Za-z]")
_IDENT_B = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_CAMEL = re.compile(rb"[a-z][A-Z]")
_PATHY = re.compile(rb"/[\w.\-]+/[\w.\-]+")
_MACADDR = re.compile(rb"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){3,}")


def line_shape(line):
    """A console line with its runtime values taken out (numbers, hex, timestamps
    and the logger's own prefix), so `[Thermal] cpu 3 temp 45` and
    `... cpu 7 temp 51` are one shape and can be compared against the format
    string in the image."""
    s = _EPOCH.sub(b"", line, count=1)
    s = _TAGS.sub(b"", s, count=1)
    s = _NEG.sub(b"", s)
    s = _HEXRUN.sub(_PH, s)
    s = _NUMRUN.sub(_PH, s)
    return _PHRUN.sub(_PH, s).strip()


def _informative(frag):
    return len(_ALPHA.findall(frag)) >= 4


def _identlike(tok):
    return len(tok) >= 4 and (b"_" in tok or bool(_CAMEL.search(tok)))


def _looks_runtime(frag):
    s = frag.replace(b" ", b"")
    if not s:
        return True
    if len(_ALPHA.findall(s)) / float(len(s)) < 0.5:
        return True
    return bool(_PATHY.search(frag) or _MACADDR.search(frag) or _HEXRUN.search(frag))


def classify_shape(frags, search):
    """None when the shape is found in the images; else (class, unmatched).

    format_plus_function  the fixed text is a format and the rest is a function
                          name the format prints (`[Thermal/TZ/CPU]%s` + __func__)
    runtime_assembled     what is left is data (paths, addresses, ids), not text
    suspicious            real-looking text found nowhere: an invented line, or a
                          line built out of words that happen to exist"""
    unmatched = [fr for fr in frags if _informative(fr) and not search(fr)]
    if not unmatched:
        return None, []
    peeled_any, peeled_ok = False, True
    for u in unmatched:
        pieces, pos = [], 0
        for m in _IDENT_B.finditer(u):
            if _identlike(m.group()):
                pieces.append(u[pos:m.start()])
                pos = m.end()
                peeled_any = True
        pieces.append(u[pos:])
        for p in pieces:
            p = p.strip()
            if _informative(p) and not search(p):
                peeled_ok = False
    if peeled_any and peeled_ok:
        return "format_plus_function", unmatched
    if all(_looks_runtime(u) for u in unmatched):
        return "runtime_assembled", unmatched
    return "suspicious", unmatched


LIST_CAP = 20000


def compare_line_shapes(lines, blobs, budget=SHAPE_BUDGET, missing_words=()):
    """Every distinct console line shape, matched against the images, with the
    unmatched ones listed and classified. Not a gate yet (open decision Q4): the
    suspicious ones are reported, prominently, and the word rule still decides.

    `missing_words` are console words the word rule already found in NO image: a
    fragment containing one cannot be found either, so it costs no scan. The rest
    are searched blob by blob, most recently hit blob first - against a few GB of
    reference images a full scan per fragment is what the time budget is spent on."""
    deadline = time.monotonic() + budget
    missing_words = set(missing_words)
    order = list(range(len(blobs)))
    counts = collections.Counter(lines)
    shapes = collections.OrderedDict()
    for ln, c in counts.items():
        sh = line_shape(ln)
        if not sh:
            continue
        ent = shapes.get(sh)
        if ent is None:
            shapes[sh] = [c, ln]
        else:
            ent[0] += c
    cache = {}

    def search(frag):
        r = cache.get(frag)
        if r is None:
            if time.monotonic() > deadline:
                raise ScanTimeout()
            r = False
            if not (missing_words and any(w in missing_words for w in FIXED_WORD.findall(frag))):
                for pos, i in enumerate(order):
                    if blobs[i].find(frag) >= 0:
                        r = True
                        if pos:
                            order.insert(0, order.pop(pos))
                        break
            cache[frag] = r
        return r

    matched = no_text = 0
    unmatched = []
    unchecked = 0
    items = list(shapes.items())
    for pos, (sh, (cnt, example)) in enumerate(items):
        frags = [x.strip() for x in sh.split(_PH)]
        if not any(_informative(x) for x in frags):
            no_text += 1
            continue
        try:
            cls, um = classify_shape(frags, search)
        except ScanTimeout:
            unchecked = len(items) - pos
            break
        if cls is None:
            matched += 1
        else:
            unmatched.append({"class": cls, "count": cnt,
                              "shape": sh.replace(_PH, b"#").decode("latin-1")[:200],
                              "example": example.decode("latin-1")[:200],
                              "unmatched": [u.decode("latin-1")[:120] for u in um[:3]]})
    order = {"suspicious": 0, "format_plus_function": 1, "runtime_assembled": 2}
    unmatched.sort(key=lambda e: (order[e["class"]], -e["count"]))
    by_class = collections.Counter(e["class"] for e in unmatched)
    listed = unmatched[:LIST_CAP]
    return {"total": len(shapes), "matched": matched, "no_fixed_text": no_text,
            "unchecked": unchecked, "unmatched_total": len(unmatched),
            "by_class": {k: by_class.get(k, 0) for k in order},
            "suspicious_lines": sum(e["count"] for e in unmatched if e["class"] == "suspicious"),
            "unmatched": listed, "list_truncated": len(unmatched) - len(listed)}


def output_origin(console, blobs, names=(), shape_budget=SHAPE_BUDGET):
    """Gate 2. The pass criterion is still the word rule (every FIXED word of the
    console exists in some image, at least ORIGIN_MIN_RATIO of them); the line-shape
    comparison rides along and is reported next to it."""
    lines = console["lines"] if isinstance(console, dict) else \
        [ln for ln in _LINE_SPLIT.split(console) if ln]
    data = console["bytes"] if isinstance(console, dict) else console
    blobs = [b for b in blobs if len(b)]
    words = set(FIXED_WORD.findall(data))
    res = {"words": {"total": len(words)}, "shapes": None,
           "reference": {"images": len(blobs), "names": list(names)[:50]}}
    if not words:
        res.update({"pass": False, "evidence":
                    "콘솔에서 고정 문자열을 찾지 못했습니다 — 대조할 것이 없습니다"})
        return res
    if not blobs:
        res.update({"pass": False, "evidence":
                    "대조할 펌웨어 이미지가 없습니다 (--container 또는 02_unpacked/)"})
        return res
    missing_b = [w for w in words if not _in_any(blobs, w)]
    missing = sorted(w.decode("latin-1") for w in missing_b)
    found = len(words) - len(missing)
    ratio = found / float(len(words))
    res["words"].update({"found": found, "missing": len(missing),
                         "missing_sample": missing[:50], "ratio": round(ratio, 4)})
    shapes = compare_line_shapes(lines, blobs, shape_budget, missing_b)
    res["shapes"] = shapes
    if not missing:
        evidence = ("고정 문자열 %d 개가 모두 펌웨어 이미지 %d 개 안에 있습니다 "
                    "(런타임 조립분은 대조 대상이 아닙니다)" % (len(words), len(blobs)))
        ok = True
    else:
        detail = ("고정 문자열 %d 개 중 %d 개 확인 (%.1f%%), %d 개 미발견: %s — 이미지 %d 개와 대조"
                  % (len(words), found, ratio * 100, len(missing), missing[:10], len(blobs)))
        if ratio >= ORIGIN_MIN_RATIO:
            evidence, ok = detail + " · %d%% 이상이라 통과" % int(ORIGIN_MIN_RATIO * 100), True
        else:
            evidence = detail + (" — 지어낸 출력이거나, 같은 UART 를 쓰는 다른 펌웨어 성분이 "
                                 "02_unpacked/ 에 없습니다")
            ok = False
    bc = shapes["by_class"]
    evidence += (" · 줄 형태 %d 개 중 미발견 %d (런타임 조립 %d · 서식+함수명 %d · 의심 %d)"
                 % (shapes["total"], shapes["unmatched_total"], bc["runtime_assembled"],
                    bc["format_plus_function"], bc["suspicious"]))
    if shapes["unchecked"]:
        evidence += " · 시간 제한으로 %d 개 형태는 대조하지 못함" % shapes["unchecked"]
    sus = [e for e in shapes["unmatched"] if e["class"] == "suspicious"]
    if sus:
        evidence += (" · ⚠ 의심 형태 %d 건(%d 줄)은 아직 판정에 반영하지 않지만 확인이 필요합니다: %s"
                     % (len(sus), shapes["suspicious_lines"],
                        ["%s (×%d)" % (e["example"][:60], e["count"]) for e in sus[:8]]))
    res.update({"pass": ok, "evidence": evidence})
    return res


def check_output_origin(console, images):
    """(ok, evidence) over already-loaded images (bytes or mmap)."""
    res = output_origin(console, list(images))
    return res["pass"], res["evidence"]


# =============================================================================
# Bypass ledger (06_machine/bypasses.md)
# =============================================================================
_FIELD_PATTERNS = (
    ("대상", re.compile(r"^[\s>\-*+]*\**\s*대상\s*\**\s*[:：]\s*(.*)$")),
    ("이유", re.compile(r"^[\s>\-*+]*\**\s*이유\s*\**\s*[:：]\s*(.*)$")),
    ("방법", re.compile(r"^[\s>\-*+]*\**\s*방법\s*\**\s*[:：]\s*(.*)$")),
    ("부작용", re.compile(r"^[\s>\-*+]*\**\s*(?:알려진\s*)?부작용\s*\**\s*[:：]\s*(.*)$")),
)
_META_RE = re.compile(r"^[\s>\-*+]*\**\s*메타\s*\**\s*[:：]\s*(.*)$")
_HEAD_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
_RULE_RE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
_ID_RE = re.compile(r"(?:^|[\s(\[])#([A-Za-z0-9][\w.\-]*)")
_BUNDLE_RE = re.compile(r"#\d+\s*(?:[~～→,]|->|–|—)\s*#?\d+|#\d+\s*-\s*#\d+")
_EMPTY_SIDE = re.compile(r"^[\(\[（【<]*\s*(?:기록\s*없음)?\s*[\)\]）】>]*$")
_TAG_RE = re.compile(r"(?:/\*|//)\s*bypass\s*:\s*#?([A-Za-z0-9][\w.\-]*)")

META_VOCAB = {
    "종류": ("M", "V", "S", "P", "I", "H"),
    "표지": ("F", "K", "L", "R", "X"),
    "출처": ("A", "B", "C", "D"),
    "도출": ("auto", "semi", "manual", "none", "n/a"),
}
LEDGER_NAMES = ("bypasses.md", "우회_패치_목록.md")

# Words in a ledger row that mean "this row changes what verified boot decides". A row's own
# words are the only evidence a script has: whether the firmware's hash is computed by hardware
# is a derived fact of one firmware, not something this file can know. Rows are written in
# Korean (the fields are shown to the user), so the Korean words matter as much as the English
# ones. ledger_issues() and bypass_report() read the same list: what the report counts as a
# verification bypass is what the gate asks to be labelled.
VERIFY_WORDS = re.compile(
    r"(?i)avb|digest|memcmp|unlock|verified\s*boot|verifiedboot|sbc"
    r"|hash|signature|\brsa\b|sha-?\d|secure\s*boot|rollback"
    r"|검증|서명|해시|다이제스트|무결성|인증|잠금\s*해제|언락|보안\s*부팅|롤백")


# The subset of VERIFY_WORDS that names a hash, digest or signature comparison - the one
# thing the hardware-hash exception (CLAUDE.md section 11) can ever apply to. memcmp, avb,
# unlock and the rest are verification words but not this claim: a status word or a lock
# value flipped under label F does not need a hash engine to explain it. Every match here is
# a match of VERIFY_WORDS too (tests/parts/verify_gates.sh holds the two together).
HASH_WORDS = re.compile(
    r"(?i)hash|digest|signature|\brsa\b|sha-?\d|해시|다이제스트|서명")


def _entry_text(entry):
    """Heading, 대상, 이유 and 방법: what an entry says it changes. 부작용 is not read: it
    says what is no longer verified, so it names verification in every honest entry."""
    parts = [entry.get("heading") or ""]
    for name in ("대상", "이유", "방법"):
        parts.extend(entry["fields"].get(name, []))
    return " ".join(parts)


def verify_touch(entry):
    """The first verification word in what an entry says it changes, or None."""
    m = VERIFY_WORDS.search(_entry_text(entry))
    return m.group(0) if m else None


def hash_touch(entry):
    """The first hash/digest/signature word in what an entry says it changes, or None."""
    m = HASH_WORDS.search(_entry_text(entry))
    return m.group(0) if m else None


def hash_engine_needed(entry):
    """The hash word when this entry needs the hardware-hash precondition, else None.

    It needs it when it is labelled 표지 F (verification forged or neutralised), speaks of a
    hash, digest or signature, and is not 종류=M. Kind M means the engine is modelled and the
    digest is really computed: that is path (a) of the ladder, honest by construction, and
    it must not be asked to prove a premise it does not use."""
    meta = entry.get("meta") or {}
    if "F" not in (meta.get("표지") or []) or meta.get("종류") == "M":
        return None
    return hash_touch(entry)


def find_ledger(workdir):
    src = os.path.join(workdir, "06_machine")
    for name in LEDGER_NAMES:
        path = os.path.join(src, name)
        if os.path.isfile(path):
            return path
    return None


def parse_meta(raw):
    """`종류=P; 표지=F,L; 출처=A; 도출=semi` -> (parsed, errors)."""
    parsed, errors = {}, []
    for part in re.split(r"[;；]", raw or ""):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            errors.append("메타 항목 '%s' 에 '=' 이 없습니다" % part)
            continue
        key, val = [x.strip() for x in part.split("=", 1)]
        if key == "근거":
            parsed[key] = val
            continue
        if key not in META_VOCAB:
            errors.append("알 수 없는 메타 항목 '%s' (종류·표지·출처·도출·근거)" % key)
            continue
        vals = [x.strip() for x in val.split(",")] if key == "표지" else [val]
        vals = [x for x in vals if x not in ("", "-")]
        bad = [x for x in vals if x not in META_VOCAB[key]]
        if bad:
            errors.append("메타 %s=%s 는 어휘에 없습니다 (허용: %s)"
                          % (key, ",".join(bad), "|".join(META_VOCAB[key])))
        parsed[key] = vals if key == "표지" else (vals[0] if vals else "")
    return parsed, errors


def parse_ledger(text):
    """The ledger as a list of entries.

    An entry starts at a heading, or at a `대상` field when the previous entry
    already has one (ledgers without headings). Field values continue onto the
    lines below them. Code fences are skipped: a `#define` in a fenced patch table
    is not a heading."""
    entries = []
    cur, last, fence = None, None, False

    def new(heading, lineno):
        ident = None
        if heading:
            m = _ID_RE.search(heading)
            ident = m.group(1) if m else None
        return {"heading": heading, "id": ident, "line": lineno, "fields": {},
                "meta_raw": None, "meta_line": None}

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if line.lstrip().startswith("```"):
            fence = not fence
            last = None
            continue
        if fence:
            continue
        mh = _HEAD_RE.match(line)
        if mh:
            if cur is not None and cur["fields"]:
                entries.append(cur)
            cur = new(mh.group(1).strip(), lineno)
            last = None
            continue
        field = None
        for name, rx in _FIELD_PATTERNS:
            m = rx.match(line)
            if m:
                field = (name, m.group(1))
                break
        if field:
            name, val = field
            if cur is None or (name == "대상" and "대상" in cur["fields"]):
                if cur is not None and cur["fields"]:
                    entries.append(cur)
                cur = new(None, lineno)
            cur["fields"][name] = [val.strip().strip("*_` ").strip()]
            last = name
            continue
        mm = _META_RE.match(line)
        if mm and cur is not None:
            cur["meta_raw"] = mm.group(1).strip()
            cur["meta_line"] = lineno
            last = None
            continue
        if _RULE_RE.match(line):
            last = None
            continue
        if cur is not None and last and line.strip():
            cur["fields"][last].append(line.strip().lstrip("-*+> ").strip())
    if cur is not None and cur["fields"]:
        entries.append(cur)
    for e in entries:
        e["meta"], e["meta_errors"] = parse_meta(e["meta_raw"]) if e["meta_raw"] is not None \
            else ({}, [])
    return entries


def side_effect_empty(entry):
    if "부작용" not in entry["fields"]:
        return False
    value = " ".join(entry["fields"]["부작용"]).strip().strip("*_` ").strip()
    return bool(_EMPTY_SIDE.match(value))


def scan_tags(paths):
    """`/* bypass:<id> */` tags on patch-table rows in the machine sources."""
    tags = []
    for p in paths:
        try:
            text = read_source(p)
        except OSError:
            continue
        for m in _TAG_RE.finditer(text):
            tags.append((m.group(1), os.path.basename(p), text.count("\n", 0, m.start()) + 1))
    return tags


def entry_signature(e):
    return (e.get("id"), e.get("heading"),
            tuple(sorted((k, tuple(v)) for k, v in e["fields"].items())), e.get("meta_raw"))


def ledger_issues(entries, tags=(), baseline=None, hash_engine=None):
    """What is wrong with the ledger as a record (not whether the bypass is wise).

    side_effect_empty   부작용 is empty or "(기록 없음)": the field the run reads
                        FIRST when it stalls, so an empty one is worse than none
    meta_vocab          the optional 메타 line uses words outside the vocabulary
    verify_unlabelled   대상/이유/방법 touch verification (verify_touch) but the entry has
                        no 표지=F and is not 종류=M. A verification bypass must carry the
                        label, and an entry with no 메타 line cannot carry one. 종류=M
                        (the engine is modelled and the digest really computed) is the
                        honest path (a) of the hardware-hash ladder and must not be forced
                        to claim a forgery; bypass_report() still counts such a row, so the
                        exemption hides nothing. The script cannot tell whether the
                        hash really is hardware-computed: that premise is the
                        static-analyzer's to derive, and this check does not read it
    hash_engine_row_missing
                        the entry is a labelled (표지 F) change to a hash, digest or signature
                        comparison (hash_engine_needed) and STATIC.md carries no row saying the
                        digest is computed by a hardware engine (hash_engine_state). That row is
                        the precondition of the hardware-hash exception (CLAUDE.md section 11) and
                        only the static-analyzer writes it. A ledger check, not a fourth gate.
                        Skipped when `hash_engine` (the state dict) is not passed. The script
                        still cannot tell who wrote the row, or whether (a) was really infeasible:
                        the row is a necessary condition, never a proof, and the verifier reads
                        the entry's 이유
    bundled_ids         one heading covering several numbers (`#42~#44`)
    dup_id              two entries with the same number
    tag_no_entry / dup_tag / entry_no_tag
                        patch-table rows tagged /* bypass:<id> */ must map one to
                        one onto entries (checked only when any tag exists)

    `baseline` (the ledger as it stood before this round's change) limits the
    per-entry checks to entries that are new or edited: a fixer cannot repair the
    history it inherited, and blocking every round on an old entry would end the
    run. The kit's 22 "(기록 없음)" entries are reported by verify.py's record
    item instead, which reads the whole ledger.

    The checks are per round, so they hold only if a rejected entry never BECOMES baseline:
    `check_change.sh restore` puts the ledger back to the snapshot (not just the sources) when
    it rejects a round. Without that, the next snapshot would copy the rejected entry as
    history and the identical patch retried one round later would pass every per-entry check
    above (side_effect_empty, verify_unlabelled, hash_engine_row_missing)."""
    issues = []
    old = {entry_signature(e) for e in (baseline or [])}

    def label(e):
        return "#%s" % e["id"] if e.get("id") else (e.get("heading") or "줄 %d" % e["line"])

    ids = collections.Counter(e["id"] for e in entries if e.get("id"))
    for e in entries:
        if baseline is not None and entry_signature(e) in old:
            continue
        if side_effect_empty(e):
            issues.append({"kind": "side_effect_empty", "id": e.get("id"), "line": e["line"],
                           "message": "%s: 부작용이 비어 있거나 '(기록 없음)' 입니다 — 이후 정체 시 "
                                      "가장 먼저 참조되는 항목입니다" % label(e)})
        for err in e.get("meta_errors", []):
            issues.append({"kind": "meta_vocab", "id": e.get("id"), "line": e["line"],
                           "message": "%s: %s" % (label(e), err)})
        word = verify_touch(e)
        if word and "F" not in (e["meta"].get("표지") or []) and e["meta"].get("종류") != "M":
            issues.append({"kind": "verify_unlabelled", "id": e.get("id"), "line": e["line"],
                           "message": "%s: 대상·이유·방법이 검증 경로('%s')를 건드리는데 표지 F 가 없습니다 — "
                                      "검증 결과를 바꾸거나 무력화했다면 '- 메타: 종류=P; 표지=F; ...' 를 "
                                      "달고, 엔진을 모델링해 값이 실제로 계산되는 것이면 종류=M 으로 적습니다 "
                                      "(라벨 없는 검증 우회는 허용하지 않습니다)%s"
                                      % (label(e), word, HASH_ROW_HINT if hash_touch(e) else "")})
        hword = hash_engine_needed(e)
        if hword and hash_engine is not None and hash_engine.get("status") != "hardware":
            issues.append({"kind": "hash_engine_row_missing", "id": e.get("id"),
                           "line": e["line"], "static_status": hash_engine.get("status"),
                           "message": "%s: 대상·이유·방법이 해시·서명 비교('%s')를 바꾸는 검증 우회(표지 F)인데 "
                                      "%s. 하드웨어 해시 예외(CLAUDE.md 11절)는 STATIC.md 에 static-analyzer 가 쓴 "
                                      "행 '%s' 가 있을 때만 열립니다 (fixer 는 이 행을 쓰지 못합니다). 행이 없으면 "
                                      "소프트웨어 해시로 보고 무패치로 통과시켜야 합니다 — 엔진을 모델링해 digest 가 "
                                      "실제로 계산되는 변경이면 종류=M 으로 적습니다"
                                      % (label(e), hword, hash_engine_reason(hash_engine),
                                         HASH_ROW_SHAPE)})
        if e.get("heading") and _BUNDLE_RE.search(e["heading"]):
            issues.append({"kind": "bundled_ids", "id": e.get("id"), "line": e["line"],
                           "message": "%s: 한 제목이 여러 번호를 묶었습니다 — 표 1행 = 우회 1건입니다"
                                      % label(e)})
    for ident, c in ids.items():
        if c > 1:
            issues.append({"kind": "dup_id", "id": ident, "line": None,
                           "message": "#%s 번호가 %d 개 기록에 겹칩니다" % (ident, c)})
    if tags:
        tag_count = collections.Counter(t[0] for t in tags)
        for ident, c in tag_count.items():
            where = ["%s:%d" % (t[1], t[2]) for t in tags if t[0] == ident][:3]
            if ident not in ids:
                issues.append({"kind": "tag_no_entry", "id": ident, "line": None,
                               "message": "표 행 태그 bypass:%s (%s) 에 대응하는 기록(#%s)이 없습니다"
                                          % (ident, ", ".join(where), ident)})
            if c > 1:
                issues.append({"kind": "dup_tag", "id": ident, "line": None,
                               "message": "bypass:%s 태그가 표 %d 행에 쓰였습니다 (%s) — "
                                          "표 1행 = 우회 1건입니다" % (ident, c, ", ".join(where))})
        for e in entries:
            if e.get("id") and e["meta"].get("종류") == "P" and e["id"] not in tag_count:
                issues.append({"kind": "entry_no_tag", "id": e["id"], "line": e["line"],
                               "message": "#%s 는 종류=P(패치)인데 대응하는 표 행(/* bypass:%s */)이 "
                                          "없습니다" % (e["id"], e["id"])})
    return issues


# =============================================================================
# STATIC.md facts the ledger and the report depend on
# =============================================================================
STATIC_NAME = "STATIC.md"

# The row the static-analyzer writes when it has derived where the firmware's digest is
# computed. Canon (CLAUDE.md section 11): a table row whose first cell is `hash_engine` and
# second cell `hardware` (or `software`), the third cell naming the point where the hash path
# leaves the bootloader - a function address or an SMC id. A one-line form is read too, because
# the record is prose-adjacent and a row that is there but in another shape must not read as
# absent:  hash_engine: hardware (evidence: ...)
HASH_ROW_SHAPE = "| hash_engine | hardware | <근거: 함수 주소·SMC id (0x…)> |"
HASH_ROW_HINT = (" (해시·서명 비교면 표지 F 와 함께 STATIC.md 의 hash_engine 행도 필요합니다: %s)"
                 % HASH_ROW_SHAPE)
HASH_ENGINE_VALUES = ("hardware", "software")
_HASH_ENGINE_LINE = re.compile(
    r"^[\s>\-*+]*[`*_]*hash[_ -]engine[`*_]*\s*[:：=]\s*[`*_]*(\w+)[`*_]*(.*)$", re.I)
_FENCE_RE = re.compile(r"^\s*(?:```|~~~)")
# A cell that says "nothing derived": empty, or it STARTS with a placeholder word. The English
# words end at a word edge ((?![A-Za-z0-9_])): `nand_hash_fn 0x1234`, `native crypto SMC id`,
# `tbdigest 0x5555` and `unknown_cmd 0x40` are evidence that merely begin with the letters of a
# placeholder, and dropping them rejected a good row. 미확정 is Korean and takes endings
# (미확정임, 미확정 — …), so it stays a prefix match.
_NO_EVIDENCE = re.compile(
    r"^[\W_]*$"
    r"|^[\W_]*(?:미확정|(?:unconfirmed|unknown|n/?a|tbd|todo)(?![A-Za-z0-9_]))", re.I)
# Text that says the value is a guess. A row that is hedged is not a derived fact
# (CLAUDE.md section 7 rule 4: an undetermined value is written as undetermined, and then it
# is not a row). A question mark anywhere, a hedge word at a word edge, or a Korean hedge.
_HEDGE = re.compile(
    r"[?？]"
    r"|(?<![A-Za-z0-9_])(?:maybe|perhaps|probably|possibly|likely|unsure|unclear|undetermined|"
    r"undecided|unverified|unconfirmed|guess(?:ed)?|presumably|assumed|tentative(?:ly)?)"
    r"(?![A-Za-z0-9_])"
    r"|미확정|미정|추정|추측|아마|불확실|불명|확인\s*필요|가정", re.I)
_HEX_LITERAL = re.compile(r"0[xX][0-9A-Fa-f]+")


def _unresolved(text):
    """True when a cell or evidence text says nothing was derived (placeholder) or only
    guesses (hedged)."""
    return bool(_NO_EVIDENCE.search(text) or _HEDGE.search(text))


def _clean_cell(cell):
    return re.sub(r"^[\s`*_]+|[\s`*_]+$", "", cell)


def _table_cells(line):
    """The cells of a markdown table row, or None when the line is not one."""
    line = line.strip()
    if not line.startswith("|"):
        return None
    return [_clean_cell(c) for c in line.strip("|").split("|")]


def _is_separator(cells):
    return bool(cells) and all(re.fullmatch(r":?-{1,}:?", c.replace(" ", "")) for c in cells if c) \
        and any(cells)


def parse_hash_engine_rows(text):
    """Every `hash_engine` row in STATIC.md text (table row or one-line form), in file order.

    A row is `ok` when its value is hardware or software and its evidence is not a
    placeholder, is not hedged (a question mark, "maybe", 추정 ...) and carries a hex literal
    (a function address or an SMC id). Rows inside a code fence are skipped: a quoted example is
    not a derived fact."""
    rows, fence = [], False
    for lineno, raw in enumerate(text.splitlines(), 1):
        if _FENCE_RE.match(raw):
            fence = not fence
            continue
        if fence:
            continue
        value = evidence = None
        cells = _table_cells(raw)
        if cells is not None:
            if len(cells) < 2 or re.sub(r"[\s-]+", "_", cells[0].lower()) != "hash_engine":
                continue
            value = cells[1].lower()
            evidence = " | ".join(c for c in cells[2:] if c)
            hedged = bool(_HEDGE.search(cells[1]) or _HEDGE.search(evidence))
            form = "table"
        else:
            m = _HASH_ENGINE_LINE.match(raw.strip())
            if not m:
                continue
            value = m.group(1).lower()
            hedged = bool(_HEDGE.search(m.group(2)))
            evidence = re.sub(r"^[\s(（\[,;:—–\-]*", "", m.group(2).strip())
            evidence = re.sub(r"^(?:evidence|근거)\s*[:：=]?\s*", "", evidence, flags=re.I)
            evidence = evidence.rstrip(") ）]").strip()
            form = "line"
        has_value = value in HASH_ENGINE_VALUES
        has_evidence = bool(evidence) and not _NO_EVIDENCE.search(evidence) \
            and bool(_HEX_LITERAL.search(evidence)) and not hedged
        rows.append({"line": lineno, "form": form, "value": value, "evidence": evidence,
                     "ok": has_value and has_evidence,
                     "has_value": has_value, "has_evidence": has_evidence,
                     "hedged": hedged})
    return rows


def hash_engine_state(workdir):
    """What STATIC.md says about where the firmware's digest is computed.

    status  hardware     a usable row says so: the precondition of the hardware-hash exception
            software     a usable row says the digest is computed in software (no exception)
            unevidenced  a hash_engine row exists but names no function address or SMC id
                         (or says neither hardware nor software): it is not a derived fact
            absent       STATIC.md has no hash_engine row
            no_static    there is no STATIC.md at all
    The last usable row wins: STATIC.md is append-only, so a later derivation corrects an
    earlier one (`conflict` says both answers were written). Nothing here knows who wrote the
    row; the canon says the static-analyzer does and a fixer does not."""
    path = os.path.join(workdir, STATIC_NAME)
    st = {"path": path, "exists": False, "status": "no_static", "value": None,
          "evidence": None, "line": None, "rows": 0, "conflict": False, "ignored": []}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return st
    st["exists"] = True
    rows = parse_hash_engine_rows(text)
    st["rows"] = len(rows)
    usable = [r for r in rows if r["ok"]]
    if usable:
        last = usable[-1]
        st.update(status=last["value"], value=last["value"], evidence=last["evidence"],
                  line=last["line"], conflict=len({r["value"] for r in usable}) > 1)
    elif rows:
        st["status"] = "unevidenced"
    else:
        st["status"] = "absent"
    st["ignored"] = [{"line": r["line"], "value": r["value"], "has_evidence": r["has_evidence"],
                      "hedged": r["hedged"]}
                     for r in rows if not r["ok"]]
    return st


def hash_engine_reason(state):
    """Why the precondition does not hold, in one clause of Korean."""
    status = (state or {}).get("status")
    if status == "no_static":
        return "STATIC.md 가 없습니다"
    if status == "software":
        return ("STATIC.md 의 hash_engine 행(줄 %s)은 software 입니다 — 해시를 소프트웨어가 계산하면 "
                "예외는 열리지 않습니다" % state.get("line"))
    if status == "unevidenced":
        bad = state.get("ignored") or [{}]
        if bad[-1].get("hedged"):
            return ("STATIC.md 의 hash_engine 행(줄 %s)은 물음표·추정·미확정·maybe 같은 어림으로 "
                    "적혀 있어 도출된 사실로 세지 않습니다 (근거 칸의 함수 주소·SMC id(0x…)를 "
                    "단정형으로 다시 도출해 적어야 합니다)" % bad[-1].get("line"))
        return ("STATIC.md 의 hash_engine 행(줄 %s)은 근거 칸에 함수 주소·SMC id(0x…)가 없거나 값이 "
                "hardware·software 가 아니라서 도출된 사실로 세지 않습니다" % bad[-1].get("line"))
    return "STATIC.md 에 해시가 하드웨어 엔진에서 계산된다는 행이 없습니다"


_HEADING_ANY = re.compile(r"^\s{0,3}(#{1,6})\s+(.*)$")
_WINDOW_LABEL = re.compile(r"(?i)address[\s_-]*windows?|주소[\s_]*창")
ADDRESS_WINDOW_COLUMNS = ("base", "size", "name", "source", "model", "phase", "kind",
                          "evidence", "bypass", "security_effect")
_MIXED_MARKER = "handoff_tick"


def _col_name(cell):
    return re.sub(r"[\s-]+", "_", _clean_cell(cell).lower())


def is_mixed_arch(paths):
    """True when a machine source carries the mixed-architecture template's handoff tick.

    The same marker run_full.sh and make_export.sh use to pick single-threaded TCG."""
    for p in paths or ():
        try:
            if _MIXED_MARKER in read_source(p):
                return True
        except OSError:
            continue
    return False


def address_window_tables(text):
    """(tables, in_section_count): the tables of STATIC.md that are address-window tables.

    A table counts when it sits under a heading or a short label that names the table
    ("address windows" or 주소 창), or when its header has base, size and one more of the
    template's columns (a table written without the heading must not read as missing).
    Rows inside a code fence are not read."""
    tables, fence, open_section = [], False, False
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        if _FENCE_RE.match(raw):
            fence = not fence
            i += 1
            continue
        if fence:
            i += 1
            continue
        cells = _table_cells(raw)
        if cells is None:
            if _HEADING_ANY.match(raw):
                open_section = bool(_WINDOW_LABEL.search(raw))
            elif raw.strip() and len(raw.strip()) <= 80 and _WINDOW_LABEL.search(raw):
                open_section = True
            i += 1
            continue
        # a table starts here: header, separator, rows
        nxt = _table_cells(lines[i + 1]) if i + 1 < len(lines) else None
        if nxt is None or not _is_separator(nxt):
            i += 1
            continue
        header = [_col_name(c) for c in cells]
        rows = []
        j = i + 2
        while j < len(lines):
            rc = _table_cells(lines[j])
            if rc is None:
                break
            if any(rc):
                rows.append(rc)
            j += 1
        by_columns = "base" in header and "size" in header and \
            any(c in header for c in ("source", "model", "security_effect", "phase", "kind"))
        if open_section or by_columns:
            tables.append({"line": i + 1, "header": header, "rows": rows,
                           "by_heading": bool(open_section)})
        i = j
    return tables


def address_windows_report(workdir, sources=()):
    """The STATIC.md "address windows" table as a REFERENCE indicator (never a gate).

    The machine template (templates/machine_mixed_arch.c.tmpl, Conventions) makes every window
    it opens, every read override and every assumed value one row of this table, because the
    classifier and the fixers read STATIC.md and not the machine source: a window recorded only
    in the source reaches nobody. This reports whether the record is there:

      status  present            every table found has all ten columns
              columns_incomplete a table is there but lacks some of the columns
              missing            no such table in STATIC.md
      windows                    rows across the tables
      security_effect_empty      rows whose security_effect cell says nothing: blank, a dash, or
                                 a placeholder or guess (미확정, unknown, tbd, n/a, "true?"). Nobody
                                 said whether the firmware reads that value on a signature
                                 verification path. Rows of a table without the column count.
      security_effect_undetermined
                                 the part of security_effect_empty that was written as a placeholder
                                 or guess rather than left blank
      security_effect_true       rows that say true

    Machines that are not mixed-architecture (no handoff tick in the built sources) are not
    held to it: the report says so in `note` and nothing else is measured."""
    if not is_mixed_arch(sources):
        return {"applicable": False, "status": None, "windows": None,
                "note": "혼합 아키텍처 머신이 아니라서 주소 창 표를 보지 않았습니다 "
                        "(머신 소스에 %s 없음)" % _MIXED_MARKER}
    out = {"applicable": True, "status": "missing", "tables": 0, "windows": 0,
           "missing_columns": [], "security_effect_empty": 0, "security_effect_undetermined": 0,
           "security_effect_true": 0, "note": None}
    path = os.path.join(workdir, STATIC_NAME)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        out["note"] = "STATIC.md 가 없습니다"
        return out
    tables = address_window_tables(text)
    out["tables"] = len(tables)
    if not tables:
        out["note"] = ("STATIC.md 에 주소 창(address windows) 표가 없습니다 — 머신이 연 창·덮어쓴 값·"
                       "가정한 값의 기록이 분류기와 fixer 에게 닿지 않습니다")
        return out
    missing = []
    for t in tables:
        for col in ADDRESS_WINDOW_COLUMNS:
            if col not in t["header"] and col not in missing:
                missing.append(col)
        idx = t["header"].index("security_effect") if "security_effect" in t["header"] else None
        for r in t["rows"]:
            out["windows"] += 1
            cell = r[idx] if idx is not None and idx < len(r) else ""
            if not cell or re.fullmatch(r"[\W_]*", cell):
                out["security_effect_empty"] += 1
            elif _unresolved(cell):
                # 미확정 / unknown / tbd / "true?" ...: the analyst is told to write 미확정 in
                # exactly the cells it cannot derive. Nobody has said whether the firmware reads
                # that value, so the row is as open as a blank one - counted there, and named
                # separately so the report can say how many were written as undetermined.
                out["security_effect_empty"] += 1
                out["security_effect_undetermined"] += 1
            elif cell.lower() in ("true", "yes", "y", "예", "참"):
                out["security_effect_true"] += 1
    out["missing_columns"] = missing
    out["status"] = "columns_incomplete" if missing else "present"
    if missing:
        out["note"] = "열이 모자랍니다: %s" % ", ".join(missing)
    return out


# =============================================================================
# Verification-bypass report (a report, not a gate)
# =============================================================================
# The firmware's own status lines are a report, never a gate, and WHICH strings they are is
# a fact about one firmware: static-analyzer derives them into <workdir>/status_tokens.txt
# (one token per line, '#' comments allowed; text after a TAB is a note), and --status-token
# adds more. No vendor string lives in this script (CLAUDE.md section 3).
STATUS_TOKENS_FILE = "status_tokens.txt"
FIRMWARE_STATUS_TOKENS = ()


def read_status_tokens(workdir):
    """The tokens the static-analyzer derived for this firmware (empty when it has not)."""
    path = os.path.join(workdir, STATUS_TOKENS_FILE)
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                tok = raw.rstrip("\r\n").split("\t", 1)[0].strip()
                if tok and not tok.startswith("#") and tok not in out:
                    out.append(tok)
    except OSError:
        pass
    return out
FAIL_MARKER = re.compile(rb"(?i)fail|error|invalid|mismatch|corrupt|reject|denied|panic")


def gpt_partitions(image_path):
    """name -> (start_byte, size_bytes) read from the GPT of a medium image."""
    import struct
    out = {}
    try:
        with open(image_path, "rb") as fh:
            for bs in (512, 4096):
                fh.seek(bs)
                hdr = fh.read(92)
                if hdr[:8] != b"EFI PART":
                    continue
                entries_lba, count, esize = struct.unpack_from("<QII", hdr, 72)
                fh.seek(entries_lba * bs)
                raw = fh.read(min(count, 1024) * esize)
                for i in range(min(count, 1024)):
                    e = raw[i * esize:(i + 1) * esize]
                    if len(e) < 128 or e[:16] == b"\0" * 16:
                        continue
                    start, end = struct.unpack_from("<QQ", e, 32)
                    name = e[56:128].decode("utf-16-le", "replace").split("\0")[0]
                    out[name] = {"start": start * bs, "size": (end - start + 1) * bs,
                                 "block_size": bs}
                return out
    except (OSError, struct.error):
        return out
    return out


def _avb_footer(image_path, part):
    try:
        with open(image_path, "rb") as fh:
            tail = min(part["size"], 1 << 20)
            fh.seek(part["start"] + part["size"] - tail)
            return b"AVBf" in fh.read(tail)
    except OSError:
        return False


def negative_result(pos_lines, neg_lines):
    """Did the firmware reject the corrupted image? The only honest evidence is a
    failure line the corrupted run printed and the intact run did not: a stubbed
    verifier says "equal" to everything and the two consoles show the same
    verdicts."""
    pos_shapes = {line_shape(ln) for ln in pos_lines}
    new = []
    for ln in neg_lines:
        if FAIL_MARKER.search(ln) and line_shape(ln) not in pos_shapes:
            new.append(ln.decode("latin-1")[:160])
            if len(new) >= 20:
                break
    return {"performed": True, "rejected": bool(new), "new_failure_lines": new[:5]}


def bypass_report(workdir, entries, console, neg_lines=None, medium_image=None,
                  provenance=None, manifest=None, status_tokens=(), hash_state=None):
    """verify_bypass {count, signals, status, hash_engine}. Signals (a)-(e) of verification.md §7.

    count is the number of individual findings (a ledger row, a forged or modified
    partition, a firmware status token seen, a corruption that was not rejected),
    so the label can say "검증 우회 N건" without double counting one bypass.

    `hash_engine` is not a signal and adds nothing to count. It answers the question the
    hardware-hash exception hangs on: does STATIC.md carry the row saying the digest is computed
    by a hardware engine (status, value, evidence, line), and which ledger rows (`needed_by`,
    the labelled hash/digest/signature changes that are not kind M) lean on it. `unbacked` is
    the ids among them that have no such row: the verifier says so next to the count."""
    signals = []

    flagged = []
    for e in entries:
        meta = e.get("meta") or {}
        why = None
        if "F" in (meta.get("표지") or []):
            why = "표지 F"
        else:
            word = verify_touch(e)
            if word:
                why = "제목·대상·이유·방법에 '%s'" % word
        if why:
            flagged.append({"id": e.get("id"), "heading": (e.get("heading") or "")[:80],
                            "why": why})
    signals.append({"id": "ledger", "label": "우회 장부의 검증 우회 행 (표지 F, 또는 제목·대상·이유·방법에 "
                    "avb·digest·memcmp·unlock·verifiedboot·sbc·hash·signature·해시·서명·검증 등)", "count": len(flagged),
                    "items": flagged[:50]})

    kinds = load_medium_kinds(workdir, provenance, manifest)
    image = medium_image or os.path.join(workdir, "fw", "lu0.img")
    parts = gpt_partitions(image) if os.path.isfile(image) else {}
    forged = []
    for name, v in sorted(kinds.items()):
        if v["kind"] == "forged":
            ent = {"partition": name}
            if name in parts:
                ent["avb_footer"] = _avb_footer(image, parts[name])
            forged.append(ent)
    signals.append({"id": "forged_media", "label": "매체의 위조 파티션 (kind=forged, AVB 푸터)",
                    "count": len(forged), "items": forged})

    mods = [{"partition": n} for n, v in sorted(kinds.items()) if v["kind"] == "modified"]
    signals.append({"id": "modified_images", "label": "이미지 수정(I) — 서명된 이미지의 바이트 변경",
                    "count": len(mods), "items": mods})

    text = console["bytes"] if isinstance(console, dict) else console
    seen = []
    tokens = []
    for tok in tuple(FIRMWARE_STATUS_TOKENS) + tuple(read_status_tokens(workdir)) + tuple(status_tokens):
        if tok and tok not in tokens:
            tokens.append(tok)
    for tok in tokens:
        b = tok.encode("utf-8")
        at = text.find(b)
        if at >= 0:
            ln = text.rfind(b"\n", 0, at) + 1
            end = text.find(b"\n", at)
            seen.append({"token": tok, "line": text[ln:end if end >= 0 else None]
                         .decode("latin-1")[:160]})
    signals.append({"id": "firmware_status",
                    "label": "펌웨어 자신의 상태 로그 (게스트 콘솔)" +
                             ("" if tokens else " — 도출된 토큰이 없어 찾지 않았습니다 (status_tokens.txt)"),
                    "count": len(seen), "items": seen})

    if neg_lines is None:
        neg = {"performed": False, "rejected": None, "new_failure_lines": []}
        signals.append({"id": "negative_test", "label": "음성 시험 (훼손 이미지) — 미실시: "
                        "펌웨어의 검증이 실제로 도는지 증명되지 않았습니다", "count": 0,
                        "items": []})
    else:
        pos = console["lines"] if isinstance(console, dict) else \
            [ln for ln in _LINE_SPLIT.split(console) if ln]
        neg = negative_result(pos, neg_lines)
        signals.append({"id": "negative_test",
                        "label": "음성 시험 (훼손 이미지)" +
                                 (" — 펌웨어가 훼손을 거부했습니다" if neg["rejected"]
                                  else " — 훼손해도 실패가 나오지 않았습니다 (검증이 우회된 증거)"),
                        "count": 0 if neg["rejected"] else 1,
                        "items": [] if neg["rejected"] else [{"detail": "새 실패 줄 없음"}]})
    count = sum(s["count"] for s in signals)
    hstate = hash_state if hash_state is not None else hash_engine_state(workdir)
    needed = [{"id": e.get("id"), "heading": (e.get("heading") or "")[:80], "word": w}
              for e in entries for w in [hash_engine_needed(e)] if w]
    hash_engine = {"row": hstate["status"] == "hardware", "status": hstate["status"],
                   "value": hstate["value"], "evidence": hstate["evidence"],
                   "line": hstate["line"], "conflict": hstate["conflict"],
                   "static": hstate["path"] if hstate["exists"] else None,
                   "needed_by": needed,
                   "unbacked": [n["id"] or n["heading"] for n in needed
                                if hstate["status"] != "hardware"]}
    return {"count": count, "status": "present" if count else "none",
            "signals": signals, "negative_test": neg,
            "unproven": neg_lines is None, "hash_engine": hash_engine}


def verdict_label(gate_ok, bypass_count):
    if gate_ok:
        if bypass_count:
            return ("VERIFIED (출처 검증 통과) · 검증 우회 %d건 · verify_ok: reached_bypassed"
                    % bypass_count)
        return "출처 검증 통과"
    if bypass_count:
        return "UNVERIFIED (출처 검증 실패) · 검증 우회 %d건" % bypass_count
    return "출처 검증 실패"


# =============================================================================
# CLI
# =============================================================================
def _cmd_ledger(args):
    path = args.ledger or find_ledger(args.workdir)
    if not path:
        print(json.dumps({"ledger": None, "entries": 0, "issues": [], "ok": True},
                         ensure_ascii=False))
        return 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        entries = parse_ledger(fh.read())
    baseline = None
    if args.baseline and os.path.isfile(args.baseline):
        with open(args.baseline, encoding="utf-8", errors="replace") as fh:
            baseline = parse_ledger(fh.read())
    built, _skipped = resolve_sources(args.workdir)
    hstate = hash_engine_state(args.workdir)
    issues = ledger_issues(entries, scan_tags(built), baseline, hash_engine=hstate)
    print(json.dumps({"ledger": path, "entries": len(entries), "issues": issues,
                      "ok": not issues,
                      "hash_engine": {"status": hstate["status"], "line": hstate["line"]}},
                     ensure_ascii=False))
    return 0 if not issues else 1


def _cmd_scan(args):
    cons = read_guest_console(args.console, args.memdump_log)
    deadline = time.monotonic() + SCAN_BUDGET
    try:
        facts = analyze_files(args.sources, deadline)
        res = source_negative(facts, cons, parse_ranges(args.protected_ranges),
                              deadline=deadline)
    except ScanTimeout:
        print(json.dumps({"ok": False, "timeout": True}, ensure_ascii=False))
        return 1
    ok, evidence = source_negative_verdict(res, len(args.sources))
    print(json.dumps({"ok": ok, "evidence": evidence, **res}, ensure_ascii=False, indent=2))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("ledger")
    p.add_argument("workdir")
    p.add_argument("--ledger", default=None)
    p.add_argument("--baseline", default=None,
                   help="the ledger before this round; only new or edited entries are checked")
    p.set_defaults(fn=_cmd_ledger)
    p = sub.add_parser("scan")
    p.add_argument("--console", required=True)
    p.add_argument("--memdump-log", default=None)
    p.add_argument("--protected-ranges", default=None)
    p.add_argument("sources", nargs="+")
    p.set_defaults(fn=_cmd_scan)
    args = ap.parse_args(argv)
    if not getattr(args, "fn", None):
        ap.print_help()
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
