"""Deterministic Lua 5.1 AST Parser, Static Linter, and Execution Engine for WoW Addon Testing."""

from __future__ import annotations

from dataclasses import dataclass
import math
import re
from typing import Any, Callable


class LuaSyntaxError(Exception):
    pass


class LuaRuntimeError(Exception):
    pass


class _BreakSignal(Exception):
    pass


class _ReturnSignal(Exception):
    def __init__(self, values: tuple[Any, ...]) -> None:
        super().__init__()
        self.values = values


@dataclass
class Token:
    kind: str
    value: Any
    line: int


KEYWORDS = frozenset(
    {
        "and",
        "break",
        "do",
        "else",
        "elseif",
        "end",
        "false",
        "for",
        "function",
        "if",
        "in",
        "local",
        "nil",
        "not",
        "or",
        "repeat",
        "return",
        "then",
        "true",
        "until",
        "while",
    }
)


def tokenize_lua51(source: str, filename: str = "<chunk>") -> list[Token]:
    if "\bgoto\b" in source:
        pass
    tokens: list[Token] = []
    i = 0
    n = len(source)
    line = 1

    while i < n:
        ch = source[i]
        if ch in " \t\r":
            i += 1
            continue
        if ch == "\n":
            line += 1
            i += 1
            continue

        # Comments
        if ch == "-" and i + 1 < n and source[i + 1] == "-":
            i += 2
            if i + 1 < n and source[i] == "[" and source[i + 1] == "[":
                i += 2
                end_idx = source.find("]]", i)
                if end_idx == -1:
                    raise LuaSyntaxError(f"{filename}:{line}: Unclosed block comment")
                line += source[i:end_idx].count("\n")
                i = end_idx + 2
            else:
                while i < n and source[i] != "\n":
                    i += 1
            continue

        # Lua 5.2+ floor division '//' check -> reject strictly in Lua 5.1
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            raise LuaSyntaxError(f"{filename}:{line}: Lua 5.2+ '//' operator is forbidden in Lua 5.1")

        # Lua 5.3+ bitwise operators check -> reject strictly in Lua 5.1
        if ch in "&|":
            raise LuaSyntaxError(f"{filename}:{line}: Lua 5.3+ bitwise operator '{ch}' is forbidden in Lua 5.1")

        # Multi-char operators
        if source.startswith("...", i):
            tokens.append(Token("DOTS", "...", line))
            i += 3
            continue
        two = source[i : i + 2]
        if two in ("==", "~=", "<=", ">=", ".."):
            tokens.append(Token("OP", two, line))
            i += 2
            continue

        # Long bracket string [[ ... ]]
        if two == "[[":
            i += 2
            end_idx = source.find("]]", i)
            if end_idx == -1:
                raise LuaSyntaxError(f"{filename}:{line}: Unclosed [[ string")
            val = source[i:end_idx]
            line += val.count("\n")
            tokens.append(Token("STRING", val, line))
            i = end_idx + 2
            continue

        # Quoted strings
        if ch in ('"', "'"):
            quote = ch
            i += 1
            buf: list[str] = []
            while i < n and source[i] != quote:
                if source[i] == "\n":
                    raise LuaSyntaxError(f"{filename}:{line}: Unfinished string")
                if source[i] == "\\":
                    i += 1
                    if i >= n:
                        raise LuaSyntaxError(f"{filename}:{line}: Trailing escape")
                    esc = source[i]
                    esc_map = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'"}
                    if esc in esc_map:
                        buf.append(esc_map[esc])
                        i += 1
                    elif esc.isdigit():
                        digits = esc
                        i += 1
                        while len(digits) < 3 and i < n and source[i].isdigit():
                            digits += source[i]
                            i += 1
                        buf.append(chr(int(digits)))
                    else:
                        buf.append(esc)
                        i += 1
                else:
                    buf.append(source[i])
                    i += 1
            if i >= n:
                raise LuaSyntaxError(f"{filename}:{line}: Unclosed string")
            i += 1
            tokens.append(Token("STRING", "".join(buf), line))
            continue

        # Numbers
        if ch.isdigit() or (ch == "." and i + 1 < n and source[i + 1].isdigit()):
            start = i
            if source[i : i + 2] in ("0x", "0X"):
                i += 2
                while i < n and source[i] in "0123456789abcdefABCDEF":
                    i += 1
                num_val: int | float = int(source[start:i], 16)
            else:
                has_dot = False
                while i < n and (source[i].isdigit() or (source[i] == "." and not has_dot)):
                    if source[i] == ".":
                        if i + 1 < n and source[i + 1] == ".":
                            break
                        has_dot = True
                    i += 1
                if i < n and source[i] in ("e", "E"):
                    has_dot = True
                    i += 1
                    if i < n and source[i] in ("+", "-"):
                        i += 1
                    while i < n and source[i].isdigit():
                        i += 1
                raw_num = source[start:i]
                num_val = float(raw_num) if has_dot else int(raw_num)
            tokens.append(Token("NUMBER", num_val, line))
            continue

        # Identifiers / keywords
        if ch.isalpha() or ch == "_":
            start = i
            while i < n and (source[i].isalnum() or source[i] == "_"):
                i += 1
            word = source[start:i]
            if word == "goto":
                raise LuaSyntaxError(f"{filename}:{line}: Lua 5.2+ 'goto' is forbidden in Lua 5.1")
            if word in KEYWORDS:
                tokens.append(Token("KW", word, line))
            else:
                tokens.append(Token("NAME", word, line))
            continue

        # Single-char punctuation / operators
        if ch in "+-*/%^#<>()[]{}=;:, .":
            if ch in "+-*/%^#<>":
                tokens.append(Token("OP", ch, line))
            else:
                tokens.append(Token(ch, ch, line))
            i += 1
            continue

        raise LuaSyntaxError(f"{filename}:{line}: Unexpected character {ch!r}")

    tokens.append(Token("EOF", None, line))
    return tokens


class Parser:
    def __init__(self, tokens: list[Token], filename: str = "<chunk>") -> None:
        self.tokens = tokens
        self.pos = 0
        self.filename = filename

    def peek(self, offset: int = 0) -> Token:
        idx = min(self.pos + offset, len(self.tokens) - 1)
        return self.tokens[idx]

    def advance(self) -> Token:
        tok = self.tokens[self.pos]
        if self.pos < len(self.tokens) - 1:
            self.pos += 1
        return tok

    def match_kw(self, kw: str) -> bool:
        tok = self.peek()
        if tok.kind == "KW" and tok.value == kw:
            self.advance()
            return True
        return False

    def expect_kw(self, kw: str) -> Token:
        tok = self.peek()
        if tok.kind == "KW" and tok.value == kw:
            return self.advance()
        raise LuaSyntaxError(f"{self.filename}:{tok.line}: Expected '{kw}', got {tok.value!r}")

    def match_punct(self, kind: str) -> bool:
        if self.peek().kind == kind:
            self.advance()
            return True
        return False

    def expect_punct(self, kind: str) -> Token:
        tok = self.peek()
        if tok.kind == kind:
            return self.advance()
        raise LuaSyntaxError(f"{self.filename}:{tok.line}: Expected '{kind}', got {tok.value!r}")

    def expect_name(self) -> str:
        tok = self.peek()
        if tok.kind == "NAME":
            return self.advance().value
        raise LuaSyntaxError(f"{self.filename}:{tok.line}: Expected identifier, got {tok.value!r}")

    def parse_chunk(self) -> tuple:
        stmts = self.parse_block(stop_kws=frozenset())
        self.expect_punct("EOF")
        return ("block", stmts)

    def parse_block(self, stop_kws: frozenset[str]) -> list[tuple]:
        stmts: list[tuple] = []
        while True:
            tok = self.peek()
            if tok.kind == "EOF":
                break
            if tok.kind == "KW" and tok.value in stop_kws:
                break
            if self.match_punct(";"):
                continue
            if tok.kind == "KW" and tok.value == "return":
                self.advance()
                exprs: list[tuple] = []
                nxt = self.peek()
                if nxt.kind != "EOF" and nxt.kind != ";" and not (nxt.kind == "KW" and nxt.value in stop_kws):
                    exprs = self.parse_explist()
                self.match_punct(";")
                stmts.append(("return", exprs))
                break
            if tok.kind == "KW" and tok.value == "break":
                self.advance()
                self.match_punct(";")
                stmts.append(("break",))
                break
            stmts.append(self.parse_stat())
        return stmts

    def parse_stat(self) -> tuple:
        tok = self.peek()
        if self.match_kw("do"):
            body = self.parse_block(frozenset({"end"}))
            self.expect_kw("end")
            return ("do", body)

        if self.match_kw("while"):
            cond = self.parse_expr()
            self.expect_kw("do")
            body = self.parse_block(frozenset({"end"}))
            self.expect_kw("end")
            return ("while", cond, body)

        if self.match_kw("repeat"):
            body = self.parse_block(frozenset({"until"}))
            self.expect_kw("until")
            cond = self.parse_expr()
            return ("repeat", body, cond)

        if self.match_kw("if"):
            branches: list[tuple[tuple, list[tuple]]] = []
            cond = self.parse_expr()
            self.expect_kw("then")
            body = self.parse_block(frozenset({"elseif", "else", "end"}))
            branches.append((cond, body))
            while self.match_kw("elseif"):
                ec = self.parse_expr()
                self.expect_kw("then")
                eb = self.parse_block(frozenset({"elseif", "else", "end"}))
                branches.append((ec, eb))
            else_body: list[tuple] | None = None
            if self.match_kw("else"):
                else_body = self.parse_block(frozenset({"end"}))
            self.expect_kw("end")
            return ("if", branches, else_body)

        if self.match_kw("for"):
            first_name = self.expect_name()
            if self.match_punct("="):
                start_e = self.parse_expr()
                self.expect_punct(",")
                stop_e = self.parse_expr()
                step_e = ("lit", 1)
                if self.match_punct(","):
                    step_e = self.parse_expr()
                self.expect_kw("do")
                body = self.parse_block(frozenset({"end"}))
                self.expect_kw("end")
                return ("for_num", first_name, start_e, stop_e, step_e, body)
            names = [first_name]
            while self.match_punct(","):
                names.append(self.expect_name())
            self.expect_kw("in")
            iter_exprs = self.parse_explist()
            self.expect_kw("do")
            body = self.parse_block(frozenset({"end"}))
            self.expect_kw("end")
            return ("for_in", names, iter_exprs, body)

        if self.match_kw("function"):
            base_name = self.expect_name()
            path = [base_name]
            while self.match_punct("."):
                path.append(self.expect_name())
            method_name: str | None = None
            if self.match_punct(":"):
                method_name = self.expect_name()
            params, has_vararg, body = self.parse_funcbody()
            if method_name is not None:
                params = ["self"] + params
                path.append(method_name)
            fn_node = ("func", params, has_vararg, body)
            if len(path) == 1:
                lhs: tuple = ("var", path[0])
            else:
                lhs = ("var", path[0])
                for seg in path[1:]:
                    lhs = ("index", lhs, ("lit", seg))
            return ("assign", [lhs], [fn_node])

        if self.match_kw("local"):
            if self.match_kw("function"):
                fname = self.expect_name()
                params, has_vararg, body = self.parse_funcbody()
                return ("local_func", fname, ("func", params, has_vararg, body))
            names = [self.expect_name()]
            while self.match_punct(","):
                names.append(self.expect_name())
            exprs: list[tuple] = []
            if self.match_punct("="):
                exprs = self.parse_explist()
            return ("local", names, exprs)

        # Prefix statement: assignment or function call
        first_p = self.parse_prefixexp()
        if self.peek().kind in (",", "="):
            targets = [first_p]
            while self.match_punct(","):
                targets.append(self.parse_prefixexp())
            self.expect_punct("=")
            rhs = self.parse_explist()
            return ("assign", targets, rhs)
        if first_p[0] in ("call", "mcall"):
            return ("expr_stat", first_p)
        raise LuaSyntaxError(f"{self.filename}:{tok.line}: Expected assignment or call statement")

    def parse_funcbody(self) -> tuple[list[str], bool, list[tuple]]:
        self.expect_punct("(")
        params: list[str] = []
        has_vararg = False
        if self.peek().kind != ")":
            while True:
                if self.peek().kind == "DOTS":
                    self.advance()
                    has_vararg = True
                    break
                params.append(self.expect_name())
                if not self.match_punct(","):
                    break
        self.expect_punct(")")
        body = self.parse_block(frozenset({"end"}))
        self.expect_kw("end")
        return params, has_vararg, body

    def parse_explist(self) -> list[tuple]:
        exprs = [self.parse_expr()]
        while self.match_punct(","):
            exprs.append(self.parse_expr())
        return exprs

    def parse_expr(self) -> tuple:
        return self.parse_or()

    def parse_or(self) -> tuple:
        left = self.parse_and()
        while self.peek().kind == "KW" and self.peek().value == "or":
            self.advance()
            left = ("or", left, self.parse_and())
        return left

    def parse_and(self) -> tuple:
        left = self.parse_cmp()
        while self.peek().kind == "KW" and self.peek().value == "and":
            self.advance()
            left = ("and", left, self.parse_cmp())
        return left

    def parse_cmp(self) -> tuple:
        left = self.parse_concat()
        while self.peek().kind == "OP" and self.peek().value in ("<", ">", "<=", ">=", "~=", "=="):
            op = self.advance().value
            left = ("binop", op, left, self.parse_concat())
        return left

    def parse_concat(self) -> tuple:
        left = self.parse_add()
        if self.peek().kind == "OP" and self.peek().value == "..":
            self.advance()
            return ("binop", "..", left, self.parse_concat())
        return left

    def parse_add(self) -> tuple:
        left = self.parse_mul()
        while self.peek().kind == "OP" and self.peek().value in ("+", "-"):
            op = self.advance().value
            left = ("binop", op, left, self.parse_mul())
        return left

    def parse_mul(self) -> tuple:
        left = self.parse_unary()
        while self.peek().kind == "OP" and self.peek().value in ("*", "/", "%"):
            op = self.advance().value
            left = ("binop", op, left, self.parse_unary())
        return left

    def parse_unary(self) -> tuple:
        tok = self.peek()
        if tok.kind == "KW" and tok.value == "not":
            self.advance()
            return ("unop", "not", self.parse_unary())
        if tok.kind == "OP" and tok.value in ("-", "#"):
            self.advance()
            return ("unop", tok.value, self.parse_unary())
        return self.parse_pow()

    def parse_pow(self) -> tuple:
        left = self.parse_primary()
        if self.peek().kind == "OP" and self.peek().value == "^":
            self.advance()
            return ("binop", "^", left, self.parse_unary())
        return left

    def parse_primary(self) -> tuple:
        tok = self.peek()
        if tok.kind == "KW":
            if tok.value == "nil":
                self.advance()
                return ("lit", None)
            if tok.value == "true":
                self.advance()
                return ("lit", True)
            if tok.value == "false":
                self.advance()
                return ("lit", False)
            if tok.value == "function":
                self.advance()
                params, has_vararg, body = self.parse_funcbody()
                return ("func", params, has_vararg, body)
        if tok.kind in ("NUMBER", "STRING"):
            self.advance()
            return ("lit", tok.value)
        if tok.kind == "DOTS":
            self.advance()
            return ("vararg",)
        if tok.kind == "{":
            return self.parse_table()
        return self.parse_prefixexp()

    def parse_prefixexp(self) -> tuple:
        tok = self.peek()
        if self.match_punct("("):
            inner = self.parse_expr()
            self.expect_punct(")")
            node: tuple = ("paren", inner)
        elif tok.kind == "NAME":
            node = ("var", self.advance().value)
        else:
            raise LuaSyntaxError(f"{self.filename}:{tok.line}: Unexpected token {tok.value!r}")

        while True:
            nxt = self.peek()
            if self.match_punct("."):
                field = self.expect_name()
                node = ("index", node, ("lit", field))
            elif self.match_punct("["):
                key_e = self.parse_expr()
                self.expect_punct("]")
                node = ("index", node, key_e)
            elif self.match_punct(":"):
                mname = self.expect_name()
                args = self.parse_call_args()
                node = ("mcall", node, mname, args)
            elif nxt.kind in ("(", "{", "STRING"):
                args = self.parse_call_args()
                node = ("call", node, args)
            else:
                break
        return node

    def parse_call_args(self) -> list[tuple]:
        tok = self.peek()
        if self.match_punct("("):
            args: list[tuple] = []
            if self.peek().kind != ")":
                args = self.parse_explist()
            self.expect_punct(")")
            return args
        if tok.kind == "{":
            return [self.parse_table()]
        if tok.kind == "STRING":
            return [("lit", self.advance().value)]
        raise LuaSyntaxError(f"{self.filename}:{tok.line}: Expected call arguments")

    def parse_table(self) -> tuple:
        self.expect_punct("{")
        fields: list[tuple] = []
        while self.peek().kind != "}":
            if self.match_punct("["):
                k = self.parse_expr()
                self.expect_punct("]")
                self.expect_punct("=")
                v = self.parse_expr()
                fields.append(("kv", k, v))
            elif self.peek().kind == "NAME" and self.peek(1).kind == "=":
                kname = self.advance().value
                self.advance()  # '='
                v = self.parse_expr()
                fields.append(("kv", ("lit", kname), v))
            else:
                fields.append(("arr", self.parse_expr()))
            if not (self.match_punct(",") or self.match_punct(";")):
                break
        self.expect_punct("}")
        return ("table", fields)


def parse_lua51(source: str, filename: str = "<chunk>") -> tuple:
    return Parser(tokenize_lua51(source, filename), filename).parse_chunk()


class LuaTable:
    """Lua 5.1 table supporting 1-based array length '#', nil deletion, and dict-like Python access."""

    def __init__(self, initial: dict[Any, Any] | list[Any] | None = None) -> None:
        self._data: dict[Any, Any] = {}
        if isinstance(initial, dict):
            for k, v in initial.items():
                if v is not None:
                    self._data[k] = v
        elif isinstance(initial, list):
            for idx, v in enumerate(initial, start=1):
                if v is not None:
                    self._data[idx] = v

    def get(self, key: Any) -> Any:
        if key is None:
            return None
        return self._data.get(key, None)

    def set(self, key: Any, value: Any) -> None:
        if key is None:
            raise LuaRuntimeError("table index is nil")
        if isinstance(key, float) and key.is_integer():
            key = int(key)
        if value is None:
            self._data.pop(key, None)
        else:
            self._data[key] = value

    def __getitem__(self, key: Any) -> Any:
        return self.get(key)

    def __setitem__(self, key: Any, value: Any) -> None:
        self.set(key, value)

    def __contains__(self, key: Any) -> bool:
        return key in self._data

    def lua_len(self) -> int:
        n = 0
        while (n + 1) in self._data:
            n += 1
        return n

    def items(self):
        return list(self._data.items())

    def keys(self):
        return list(self._data.keys())


@dataclass
class Cell:
    value: Any = None


class Env:
    def __init__(self, parent: Env | None = None, varargs: tuple[Any, ...] | None = None) -> None:
        self.parent = parent
        self.cells: dict[str, Cell] = {}
        self.varargs = varargs

    def define_local(self, name: str, value: Any) -> Cell:
        cell = Cell(value)
        self.cells[name] = cell
        return cell

    def resolve_cell(self, name: str) -> Cell | None:
        cur: Env | None = self
        while cur is not None:
            if name in cur.cells:
                return cur.cells[name]
            cur = cur.parent
        return None

    def resolve_varargs(self) -> tuple[Any, ...]:
        cur: Env | None = self
        while cur is not None:
            if cur.varargs is not None:
                return cur.varargs
            cur = cur.parent
        return ()


def lua_truthy(val: Any) -> bool:
    return val is not None and val is not False


def lua_to_string(val: Any) -> str:
    if val is None:
        return "nil"
    if val is True:
        return "true"
    if val is False:
        return "false"
    if isinstance(val, float) and val.is_integer():
        return str(int(val))
    return str(val)


def _translate_lua_pattern(pat: str) -> str:
    """Translate Lua 5.1 string pattern syntax to Python regex."""
    class_map = {
        "d": r"\d",
        "D": r"\D",
        "s": r"\s",
        "S": r"\S",
        "a": r"[A-Za-z]",
        "A": r"[^A-Za-z]",
        "w": r"[A-Za-z0-9]",
        "W": r"[^A-Za-z0-9]",
        "l": r"[a-z]",
        "u": r"[A-Z]",
    }
    out: list[str] = []
    i = 0
    n = len(pat)
    in_bracket = False
    while i < n:
        ch = pat[i]
        if ch == "%":
            i += 1
            if i >= n:
                out.append(r"\%")
                break
            nxt = pat[i]
            if nxt in class_map:
                mapped = class_map[nxt]
                if in_bracket and mapped.startswith("[") and mapped.endswith("]"):
                    out.append(mapped[1:-1])
                else:
                    out.append(mapped)
            else:
                out.append(re.escape(nxt))
            i += 1
            continue
        if ch == "[" and not in_bracket:
            in_bracket = True
            out.append("[")
            i += 1
            if i < n and pat[i] == "^":
                out.append("^")
                i += 1
            if i < n and pat[i] == "]":
                out.append(r"\]")
                i += 1
            continue
        if ch == "]" and in_bracket:
            in_bracket = False
            out.append("]")
            i += 1
            continue
        if not in_bracket and ch == "-":
            # Non-greedy quantifier '.-' in Lua == '*?' in Python regex
            out.append("*?")
            i += 1
            continue
        if not in_bracket and ch in r"\^$.|?*+(){}":
            if ch in "^$*+?().":
                out.append(ch)
            else:
                out.append(re.escape(ch))
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


class MultiReturn(tuple):
    """Signals multiple return values from a Python host callback into Lua."""


def _wrap_py_return(res: Any) -> tuple[Any, ...]:
    if isinstance(res, MultiReturn):
        return tuple(res)
    return (res,)


class Lua51VM:
    def __init__(self) -> None:
        self.G = LuaTable()
        self.G["_G"] = self.G
        self._install_stdlib()

    def _install_stdlib(self) -> None:
        G = self.G

        def lua_type(v: Any = None) -> str:
            if v is None:
                return "nil"
            custom_t = getattr(v, "_lua_type", None)
            if isinstance(custom_t, str):
                return custom_t
            if isinstance(v, bool):
                return "boolean"
            if isinstance(v, (int, float)):
                return "number"
            if isinstance(v, str):
                return "string"
            if isinstance(v, LuaTable):
                return "table"
            if callable(v):
                return "function"
            return "userdata"

        def lua_tonumber(v: Any = None, base: int = 10) -> int | float | None:
            if isinstance(v, bool) or v is None:
                return None
            if isinstance(v, (int, float)):
                return v
            if isinstance(v, str):
                s = v.strip()
                if not s:
                    return None
                try:
                    if int(base) != 10:
                        return int(s, int(base))
                    return float(s) if ("." in s or "e" in s.lower()) else int(s)
                except ValueError:
                    return None
            return None

        def lua_select(index: Any, *args: Any) -> Any:
            if index == "#":
                return len(args)
            idx = int(index)
            if idx < 0:
                idx = len(args) + idx + 1
            return MultiReturn(args[max(0, idx - 1) :])

        def lua_unpack(tbl: LuaTable, i: int = 1, j: int | None = None) -> Any:
            end = tbl.lua_len() if j is None else int(j)
            return MultiReturn(tuple(tbl.get(k) for k in range(int(i), end + 1)))

        def lua_next(tbl: LuaTable, key: Any = None) -> Any:
            keys = tbl.keys()
            if not keys:
                return MultiReturn((None,))
            if key is None:
                k0 = keys[0]
                return MultiReturn((k0, tbl.get(k0)))
            try:
                idx = keys.index(key)
            except ValueError:
                return MultiReturn((None,))
            if idx + 1 < len(keys):
                kn = keys[idx + 1]
                return MultiReturn((kn, tbl.get(kn)))
            return MultiReturn((None,))

        def lua_pairs(tbl: LuaTable) -> Any:
            return MultiReturn((lua_next, tbl, None))

        def _ipairs_iter(tbl: LuaTable, i: int) -> Any:
            nxt = int(i) + 1
            v = tbl.get(nxt)
            if v is None:
                return MultiReturn((None,))
            return MultiReturn((nxt, v))

        def lua_ipairs(tbl: LuaTable) -> Any:
            return MultiReturn((_ipairs_iter, tbl, 0))

        def lua_pcall(fn: Callable[..., Any], *args: Any) -> Any:
            if not callable(fn):
                return MultiReturn((False, f"attempt to call a {lua_type(fn)} value"))
            try:
                vals = self._invoke_callable(fn, args)
                return MultiReturn((True, *vals))
            except Exception as exc:
                return MultiReturn((False, str(exc)))

        # Strict Lua 5.1 xpcall(fn, errHandler): does NOT forward extra arguments to fn!
        def lua_xpcall(fn: Callable[..., Any], err_handler: Callable[..., Any], *_ignored: Any) -> Any:
            if not callable(fn):
                err_res = self._invoke_callable(err_handler, (f"attempt to call a {lua_type(fn)} value",))
                return MultiReturn((False, err_res[0] if err_res else None))
            try:
                vals = self._invoke_callable(fn, ())
                return MultiReturn((True, *vals))
            except Exception as exc:
                try:
                    eh_vals = self._invoke_callable(err_handler, (str(exc),))
                    msg = eh_vals[0] if eh_vals else str(exc)
                except Exception as eh_exc:
                    msg = str(eh_exc)
                return MultiReturn((False, msg))

        def lua_error(msg: Any = "error", _level: Any = 1) -> None:
            raise LuaRuntimeError(lua_to_string(msg))

        def lua_wipe(tbl: LuaTable) -> LuaTable:
            if isinstance(tbl, LuaTable):
                tbl._data.clear()
            return tbl

        G["type"] = lua_type
        G["tostring"] = lambda v=None: lua_to_string(v)
        G["tonumber"] = lua_tonumber
        G["select"] = lua_select
        G["unpack"] = lua_unpack
        G["next"] = lua_next
        G["pairs"] = lua_pairs
        G["ipairs"] = lua_ipairs
        G["pcall"] = lua_pcall
        G["xpcall"] = lua_xpcall
        G["error"] = lua_error
        G["wipe"] = lua_wipe

        math_tbl = LuaTable(
            {
                "floor": lambda x: int(math.floor(float(x))),
                "ceil": lambda x: int(math.ceil(float(x))),
                "abs": lambda x: abs(x),
                "min": lambda *xs: min(xs),
                "max": lambda *xs: max(xs),
            }
        )
        G["math"] = math_tbl

        def str_find(s: str, pat: str, init: int = 1, plain: bool = False) -> Any:
            s_str = lua_to_string(s)
            p_str = lua_to_string(pat)
            pos = max(0, int(init) - 1) if int(init) >= 0 else max(0, len(s_str) + int(init))
            if lua_truthy(plain):
                idx = s_str.find(p_str, pos)
                if idx == -1:
                    return MultiReturn((None,))
                return MultiReturn((idx + 1, idx + len(p_str)))
            rx = _translate_lua_pattern(p_str)
            m = re.search(rx, s_str[pos:], flags=re.DOTALL)
            if not m:
                return MultiReturn((None,))
            return MultiReturn((pos + m.start() + 1, pos + m.end(), *m.groups()))

        def str_match(s: str, pat: str, init: int = 1) -> Any:
            s_str = lua_to_string(s)
            p_str = lua_to_string(pat)
            pos = max(0, int(init) - 1)
            rx = _translate_lua_pattern(p_str)
            m = re.search(rx, s_str[pos:], flags=re.DOTALL)
            if not m:
                return MultiReturn((None,))
            if m.groups():
                return MultiReturn(m.groups())
            return MultiReturn((m.group(0),))

        def str_format(fmt: str, *args: Any) -> str:
            conv_args = []
            for a in args:
                if isinstance(a, bool):
                    conv_args.append(str(a).lower())
                else:
                    conv_args.append(a)
            return str(fmt) % tuple(conv_args)

        def str_gsub(s: str, pat: str, repl: str, n: int | None = None) -> Any:
            s_str = lua_to_string(s)
            p_str = lua_to_string(pat)
            r_str = lua_to_string(repl)
            rx = _translate_lua_pattern(p_str)
            count = 0 if n is None else int(n)
            new_s, num_subs = re.subn(rx, lambda _m: r_str, s_str, count=count, flags=re.DOTALL)
            return MultiReturn((new_s, num_subs))

        def str_sub(s: str, i: int, j: int | None = None) -> str:
            s_str = lua_to_string(s)
            length = len(s_str)
            start = int(i)
            end = length if j is None else int(j)
            start_idx = max(0, start - 1) if start > 0 else max(0, length + start) if start < 0 else 0
            end_idx = min(length, end) if end >= 0 else max(0, length + end + 1)
            return s_str[start_idx:end_idx]

        G["string"] = LuaTable(
            {
                "format": str_format,
                "lower": lambda s: lua_to_string(s).lower(),
                "upper": lambda s: lua_to_string(s).upper(),
                "find": str_find,
                "match": str_match,
                "gsub": str_gsub,
                "sub": str_sub,
                "len": lambda s: len(lua_to_string(s)),
            }
        )
        def tbl_insert(t: LuaTable, *a: Any) -> None:
            length = t.lua_len()
            if len(a) == 1:
                t.set(length + 1, a[0])
            elif len(a) >= 2:
                pos = int(a[0])
                val = a[1]
                for idx in range(length, pos - 1, -1):
                    t.set(idx + 1, t.get(idx))
                t.set(pos, val)

        def tbl_remove(t: LuaTable, pos: int | None = None) -> Any:
            length = t.lua_len()
            if length == 0:
                return None
            idx = length if pos is None else int(pos)
            if idx < 1 or idx > length:
                return None
            removed = t.get(idx)
            for k in range(idx, length):
                t.set(k, t.get(k + 1))
            t.set(length, None)
            return removed

        G["table"] = LuaTable(
            {
                "insert": tbl_insert,
                "remove": tbl_remove,
            }
        )

    def _invoke_callable(self, fn: Callable[..., Any], args: tuple[Any, ...]) -> tuple[Any, ...]:
        if getattr(fn, "_is_lua_fn", False):
            return fn(*args)
        res = fn(*args)
        return _wrap_py_return(res)

    def eval_explist(self, exprs: list[tuple], env: Env) -> list[Any]:
        if not exprs:
            return []
        out: list[Any] = []
        for idx, e in enumerate(exprs):
            vals = self.eval_expr_multi(e, env)
            if idx < len(exprs) - 1:
                out.append(vals[0] if vals else None)
            else:
                out.extend(vals)
        return out

    def eval_expr(self, node: tuple, env: Env) -> Any:
        vals = self.eval_expr_multi(node, env)
        return vals[0] if vals else None

    def eval_expr_multi(self, node: tuple, env: Env) -> tuple[Any, ...]:
        tag = node[0]
        if tag == "lit":
            return (node[1],)
        if tag == "paren":
            return (self.eval_expr(node[1], env),)
        if tag == "vararg":
            return env.resolve_varargs()
        if tag == "var":
            name = node[1]
            cell = env.resolve_cell(name)
            if cell is not None:
                return (cell.value,)
            return (self.G.get(name),)
        if tag == "index":
            obj = self.eval_expr(node[1], env)
            key = self.eval_expr(node[2], env)
            if not isinstance(obj, LuaTable):
                raise LuaRuntimeError(f"attempt to index a {type(obj).__name__} value (key={key!r})")
            return (obj.get(key),)
        if tag == "table":
            tbl = LuaTable()
            arr_idx = 1
            fields = node[1]
            for f_idx, field in enumerate(fields):
                if field[0] == "kv":
                    k = self.eval_expr(field[1], env)
                    v = self.eval_expr(field[2], env)
                    tbl.set(k, v)
                else:
                    vals = self.eval_expr_multi(field[1], env)
                    if f_idx == len(fields) - 1:
                        for v in vals:
                            tbl.set(arr_idx, v)
                            arr_idx += 1
                    else:
                        tbl.set(arr_idx, vals[0] if vals else None)
                        arr_idx += 1
            return (tbl,)
        if tag == "func":
            params, has_vararg, body = node[1], node[2], node[3]

            def closure(*call_args: Any) -> tuple[Any, ...]:
                extra = call_args[len(params) :] if has_vararg else ()
                fn_env = Env(parent=env, varargs=extra if has_vararg else None)
                for p_i, p_name in enumerate(params):
                    fn_env.define_local(p_name, call_args[p_i] if p_i < len(call_args) else None)
                try:
                    self.exec_block(body, fn_env)
                except _ReturnSignal as ret:
                    return ret.values
                return ()

            closure._is_lua_fn = True  # type: ignore[attr-defined]
            return (closure,)
        if tag == "and":
            lv = self.eval_expr(node[1], env)
            if not lua_truthy(lv):
                return (lv,)
            return (self.eval_expr(node[2], env),)
        if tag == "or":
            lv = self.eval_expr(node[1], env)
            if lua_truthy(lv):
                return (lv,)
            return (self.eval_expr(node[2], env),)
        if tag == "unop":
            op, rhs_node = node[1], node[2]
            v = self.eval_expr(rhs_node, env)
            if op == "not":
                return (not lua_truthy(v),)
            if op == "-":
                return (-v,)
            if op == "#":
                if isinstance(v, LuaTable):
                    return (v.lua_len(),)
                if isinstance(v, str):
                    return (len(v),)
                raise LuaRuntimeError(f"attempt to get length of {type(v).__name__}")
        if tag == "binop":
            op = node[1]
            lv = self.eval_expr(node[2], env)
            rv = self.eval_expr(node[3], env)
            if op == "==":
                if type(lv) is not type(rv) and not (isinstance(lv, (int, float)) and isinstance(rv, (int, float)) and not isinstance(lv, bool) and not isinstance(rv, bool)):
                    return (False,)
                return (lv == rv,)
            if op == "~=":
                if type(lv) is not type(rv) and not (isinstance(lv, (int, float)) and isinstance(rv, (int, float)) and not isinstance(lv, bool) and not isinstance(rv, bool)):
                    return (True,)
                return (lv != rv,)
            if op == "..":
                if hasattr(lv, "_secret_guard"):
                    lv._secret_guard("concat")
                if hasattr(rv, "_secret_guard"):
                    rv._secret_guard("concat")
                return (lua_to_string(lv) + lua_to_string(rv),)
            if op == "<":
                return (lv < rv,)
            if op == "<=":
                return (lv <= rv,)
            if op == ">":
                return (lv > rv,)
            if op == ">=":
                return (lv >= rv,)
            if op == "+":
                return (lv + rv,)
            if op == "-":
                return (lv - rv,)
            if op == "*":
                return (lv * rv,)
            if op == "/":
                return (lv / rv,)
            if op == "%":
                return (lv % rv,)
            if op == "^":
                return (lv**rv,)
        if tag == "call":
            fn = self.eval_expr(node[1], env)
            if not callable(fn):
                raise LuaRuntimeError(f"attempt to call non-callable value ({fn!r})")
            args = tuple(self.eval_explist(node[2], env))
            return self._invoke_callable(fn, args)
        if tag == "mcall":
            obj = self.eval_expr(node[1], env)
            if not isinstance(obj, LuaTable):
                raise LuaRuntimeError(f"attempt to call method {node[2]!r} on non-table ({obj!r})")
            fn = obj.get(node[2])
            if not callable(fn):
                raise LuaRuntimeError(f"attempt to call nil method {node[2]!r}")
            args = (obj, *self.eval_explist(node[3], env))
            return self._invoke_callable(fn, args)
        raise LuaRuntimeError(f"Unsupported AST expr tag: {tag}")

    def exec_block(self, stmts: list[tuple], env: Env) -> None:
        block_env = Env(parent=env)
        for st in stmts:
            self.exec_stat(st, block_env)

    def exec_stat(self, node: tuple, env: Env) -> None:
        tag = node[0]
        if tag == "expr_stat":
            self.eval_expr_multi(node[1], env)
            return
        if tag == "local":
            names, exprs = node[1], node[2]
            vals = self.eval_explist(exprs, env)
            for idx, name in enumerate(names):
                env.define_local(name, vals[idx] if idx < len(vals) else None)
            return
        if tag == "local_func":
            fname, fn_node = node[1], node[2]
            cell = env.define_local(fname, None)
            cell.value = self.eval_expr(fn_node, env)
            return
        if tag == "assign":
            targets, exprs = node[1], node[2]
            resolved_targets: list[tuple] = []
            for t in targets:
                if t[0] == "var":
                    resolved_targets.append(("var", t[1]))
                elif t[0] == "index":
                    obj = self.eval_expr(t[1], env)
                    key = self.eval_expr(t[2], env)
                    resolved_targets.append(("index", obj, key))
                else:
                    raise LuaRuntimeError(f"Invalid assignment target: {t[0]}")
            vals = self.eval_explist(exprs, env)
            for idx, rt in enumerate(resolved_targets):
                val = vals[idx] if idx < len(vals) else None
                if rt[0] == "var":
                    cell = env.resolve_cell(rt[1])
                    if cell is not None:
                        cell.value = val
                    else:
                        self.G.set(rt[1], val)
                else:
                    obj, key = rt[1], rt[2]
                    if not isinstance(obj, LuaTable):
                        raise LuaRuntimeError(f"attempt to index non-table in assignment ({obj!r})")
                    obj.set(key, val)
            return
        if tag == "do":
            self.exec_block(node[1], env)
            return
        if tag == "if":
            for cond, body in node[1]:
                if lua_truthy(self.eval_expr(cond, env)):
                    self.exec_block(body, env)
                    return
            if node[2] is not None:
                self.exec_block(node[2], env)
            return
        if tag == "while":
            while lua_truthy(self.eval_expr(node[1], env)):
                try:
                    self.exec_block(node[2], env)
                except _BreakSignal:
                    break
            return
        if tag == "repeat":
            while True:
                loop_env = Env(parent=env)
                try:
                    for st in node[1]:
                        self.exec_stat(st, loop_env)
                    if lua_truthy(self.eval_expr(node[2], loop_env)):
                        break
                except _BreakSignal:
                    break
            return
        if tag == "for_num":
            var_name, start_e, stop_e, step_e, body = node[1], node[2], node[3], node[4], node[5]
            cur = self.eval_expr(start_e, env)
            stop = self.eval_expr(stop_e, env)
            step = self.eval_expr(step_e, env)
            if step == 0:
                raise LuaRuntimeError("'for' step is zero")
            while (step > 0 and cur <= stop) or (step < 0 and cur >= stop):
                iter_env = Env(parent=env)
                iter_env.define_local(var_name, cur)
                try:
                    self.exec_block(body, iter_env)
                except _BreakSignal:
                    break
                cur = cur + step
            return
        if tag == "for_in":
            names, iter_exprs, body = node[1], node[2], node[3]
            init_vals = self.eval_explist(iter_exprs, env)
            iter_fn = init_vals[0] if len(init_vals) > 0 else None
            state = init_vals[1] if len(init_vals) > 1 else None
            ctrl = init_vals[2] if len(init_vals) > 2 else None
            while True:
                res = self._invoke_callable(iter_fn, (state, ctrl))
                v1 = res[0] if res else None
                if v1 is None:
                    break
                ctrl = v1
                iter_env = Env(parent=env)
                for idx, nm in enumerate(names):
                    iter_env.define_local(nm, res[idx] if idx < len(res) else None)
                try:
                    self.exec_block(body, iter_env)
                except _BreakSignal:
                    break
            return
        if tag == "return":
            vals = tuple(self.eval_explist(node[1], env))
            raise _ReturnSignal(vals)
        if tag == "break":
            raise _BreakSignal()
        raise LuaRuntimeError(f"Unsupported AST statement tag: {tag}")

    def run_chunk(self, source: str, filename: str = "<chunk>", chunk_args: tuple[Any, ...] = ()) -> tuple[Any, ...]:
        ast = parse_lua51(source, filename)
        root_env = Env(parent=None, varargs=chunk_args)
        try:
            self.exec_block(ast[1], root_env)
        except _ReturnSignal as ret:
            return ret.values
        return ()
