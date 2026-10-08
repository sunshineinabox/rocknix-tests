#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import os
import re
import shlex
import sys

SKIP_EXT = {".mk", ".patch", ".diff", ".py", ".c", ".h", ".cpp", ".json", ".xml", ".ini", ".cfg", ".conf",
            ".txt", ".md", ".dts", ".dtsi", ".service", ".socket", ".timer", ".mount", ".path", ".target",
            ".slice", ".rules", ".hwdb", ".png", ".jpg", ".svg", ".ttf", ".bin", ".yml", ".yaml", ".lua",
            ".js", ".qml", ".glsl", ".toml", ".opt", ".desktop", ".kl", ".rmp", ".cmake", ".in", ".pem"}
SHELL_DIRS = ("/profile.d/", "/quirks/", "/autostart/", "/sleep.d/")
COMMAND_KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "time", "exec", "nohup",
                    "command", "env", "sudo", "function", "done", "fi", "esac", "in"}
WRAPPERS = {"nice", "nohup", "setsid", "timeout", "xargs", "env", "flock", "ionice", "chroot", "time",
            "watch", "taskset", "chrt", "su", "sudo", "stdbuf", "unshare", "nsenter"}
OPERATORS = {";", ";;", "&", "&&", "|", "||", "(", ")", "`", "|&", ";&", ";;&"}
LABEL_WORD = r"""(?:"[^"]*"|'[^']*'|[^()\s;|"'])+"""
CASE_LABEL = re.compile(r"^\s*\(?(?:" + LABEL_WORD + r"\s*\|\s*)*" + LABEL_WORD + r"\)(?=\s|$)")
ARRAY_OPEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\+?=\(")
ARITHMETIC = re.compile(r"\$?\(\((?:[^()]|\([^()]*\))*\)\)")
FUNCTION_DEF = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.-]*)\s*(?:\(\)|\s+\{)", re.M)


def is_shell(path):
    base = os.path.basename(path)
    if base == "package.mk" or os.path.splitext(base)[1] in SKIP_EXT:
        return False
    try:
        with open(path, "rb") as f:
            head = f.read(256)
    except OSError:
        return False
    if b"\0" in head:
        return False
    if head.startswith(b"#!"):
        return re.search(rb"\b(sh|bash|ash)\b", head.split(b"\n", 1)[0]) is not None
    if base.endswith(".sh"):
        return True
    if base.startswith("README") or "." in base:
        return False
    return "/profile.d/" in path or (any(d in path for d in SHELL_DIRS) and os.access(path, os.X_OK))


def tokenize(line):
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>`")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def statements(text):
    lines = text.split("\n")
    heredoc = None
    i = 0
    while i < len(lines):
        number, line = i + 1, lines[i]
        i += 1
        if heredoc:
            if line.strip() == heredoc:
                heredoc = None
            continue
        while line.rstrip().endswith("\\") and i < len(lines):
            line = line.rstrip()[:-1] + " " + lines[i]
            i += 1
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m:
            heredoc = m.group(1)
        line = ARITHMETIC.sub("0", line)
        line = CASE_LABEL.sub(" ", line)
        if ARRAY_OPEN.search(line):
            while line.count("(") > line.count(")") and i < len(lines):
                line += " " + lines[i]
                i += 1
        joined = 0
        while True:
            try:
                tokens = tokenize(line)
                break
            except ValueError:
                if joined >= 40 or i >= len(lines):
                    tokens = None
                    break
                line += "\n" + lines[i]
                i += 1
                joined += 1
        if tokens:
            yield number, tokens


def commands(tokens):
    cmd, args, expect_command, skip_next = None, [], True, False
    depth = 0
    for index, tok in enumerate(tokens):
        if depth == -1:
            depth = 1
            continue
        if depth > 0:
            depth += {"(": 1, ")": -1}.get(tok, 0)
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\+?=", tok) and index + 1 < len(tokens) and tokens[index + 1] == "(":
            depth = -1
            continue
        if skip_next:
            skip_next = False
            continue
        if cmd == "[[":
            if tok == "]]":
                cmd = "]]"
            continue
        if tok in OPERATORS:
            if cmd and not (tok == ")" and not args):
                yield cmd, args
            cmd, args, expect_command = None, [], True
            continue
        if re.fullmatch(r"\d*(?:[<>]+|&>>?|>&|<&)", tok):
            skip_next = True
            continue
        if expect_command:
            if tok in COMMAND_KEYWORDS or tok == "$" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=", tok):
                continue
            cmd, expect_command = tok, False
            continue
        args.append(tok)
    if cmd:
        yield cmd, args


def shell_files(paths):
    for top in paths:
        if os.path.isfile(top):
            yield top
            continue
        for dirpath, _, files in os.walk(top):
            for name in files:
                path = os.path.join(dirpath, name)
                if not os.path.islink(path) and is_shell(path):
                    yield path


def main():
    args = sys.argv[1:]
    owned = None
    if args[0] == "--owned":
        owned = {name for _, _, files in os.walk(os.path.join(args[1], "projects/ROCKNIX")) for name in files}
        args = args[2:]
    mode, base, paths = args[0], args[1], args[2:]
    files = sorted(set(shell_files(os.path.join(base, p) for p in paths)))
    if owned is not None:
        files = [f for f in files if os.path.basename(f) in owned]
    texts = {}
    for path in files:
        with open(path, errors="replace") as f:
            texts[path] = f.read()
    functions = set()
    for top in [os.path.join(base, p) for p in paths] + [os.path.join(base, "etc/profile")]:
        walk = [(os.path.dirname(top), [], [os.path.basename(top)])] if os.path.isfile(top) else os.walk(top)
        for dirpath, _, names in walk:
            for name in names:
                try:
                    with open(os.path.join(dirpath, name), "rb") as f:
                        data = f.read(1 << 20)
                except OSError:
                    continue
                if b"\0" not in data[:512]:
                    functions.update(FUNCTION_DEF.findall(data.decode(errors="replace")))
    seen = set()
    for path in files:
        rel = os.path.relpath(path, base)
        for number, tokens in statements(texts[path]):
            for cmd, args in commands(tokens):
                name = os.path.basename(cmd)
                if mode == "commands":
                    if "/" in cmd or name in functions or name in seen or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9._+-]*", name):
                        continue
                    seen.add(name)
                    print(f"{name}\t{rel}:{number}")
                    continue
                for position, arg in enumerate(args):
                    if position and re.fullmatch(r"-\d+", arg):
                        continue
                    if name == "find" and arg in ("-exec", "-execdir", "-ok", "-okdir"):
                        break
                    if not arg.startswith("-"):
                        if name in WRAPPERS:
                            break
                        continue
                    if arg in ("-", "--") or "$" in arg or "`" in arg:
                        continue
                    if name == "find" and not re.match(r"^-[a-z]", arg):
                        continue
                    if (name, arg) not in seen:
                        seen.add((name, arg))
                        print(f"{name}\t{arg}\t{rel}:{number}")


if __name__ == "__main__":
    main()
