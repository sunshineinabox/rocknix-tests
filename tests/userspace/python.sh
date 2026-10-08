# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PY_KNOWN=${TESTS}/userspace/python.known
PY_DIRS="/usr/bin /usr/sbin /usr/lib /usr/lib32 /usr/libexec /usr/share /usr/config /usr/local /etc"
PY_CHECK=$(cat <<'EOF'
import ast
import contextlib
import importlib
import io
import os
import py_compile
import re
import shutil
import sys
import tempfile
from importlib.machinery import FrozenImporter, PathFinder

STDLIB = re.compile(r"^/usr/lib(32)?/python3\.\d+(/|$)")
PROGRAM_DIRS = ("/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/rocknix/", "/usr/lib/autostart/")
GUARDS = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}


def sources(roots):
    for top in roots:
        for dirpath, dirs, names in os.walk(top):
            if STDLIB.match(dirpath):
                dirs[:] = []
                continue
            dirs.sort()
            for name in sorted(names):
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                with open(path, "rb") as f:
                    first = f.readline(512)
                if first.startswith(b"#!") and b"python" in first:
                    yield path, first[2:].decode(errors="replace").strip()
                elif name.endswith(".py"):
                    yield path, None


def guarded(node):
    for handler in node.handlers:
        types = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
        if any(t is None or getattr(t, "id", getattr(t, "attr", None)) in GUARDS for t in types):
            return True
    return False


def imports(body):
    for node in body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name, []
        elif isinstance(node, ast.ImportFrom):
            if not node.level and node.module:
                yield node.module, [alias.name for alias in node.names if alias.name != "*"]
        elif isinstance(node, (ast.Try, ast.TryStar)):
            yield from imports(([] if guarded(node) else node.body) + node.orelse + node.finalbody)
        elif isinstance(node, ast.If):
            if "TYPE_CHECKING" not in ast.unparse(node.test):
                yield from imports(node.body)
            yield from imports(node.orelse)
        elif isinstance(node, (ast.With, ast.For, ast.While, ast.ClassDef)):
            yield from imports(node.body + getattr(node, "orelse", []))


def locate(name, base):
    parts = name.split(".")
    if parts[0] in sys.builtin_module_names or FrozenImporter.find_spec(parts[0]):
        return "builtin"
    spec = PathFinder.find_spec(parts[0], [base] + sys.path[1:])
    for part in parts[1:]:
        if spec is None or not spec.submodule_search_locations:
            break
        spec = PathFinder.find_spec(part, list(spec.submodule_search_locations))
    if spec is None:
        return None
    return "local" if (spec.origin or "").startswith(base + "/") else "system"


def unresolved(path, tree):
    base = os.path.dirname(os.path.realpath(path))
    for module, names in imports(tree.body):
        where = locate(module, base)
        if where is None:
            top = module.split(".")[0]
            yield module if locate(top, base) else top
        elif where != "local" and names:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    loaded = importlib.import_module(module)
            except (Exception, SystemExit):
                yield module
                continue
            package = getattr(loaded, "__path__", None)
            for name in names:
                if not hasattr(loaded, name) and not (package and PathFinder.find_spec(name, list(package))):
                    yield f"{module}.{name}"


def main():
    mode, roots = sys.argv[1], sys.argv[2:]
    tmp = tempfile.mkdtemp()
    for path, shebang in sources(roots):
        if mode == "compile":
            try:
                py_compile.compile(path, cfile=os.path.join(tmp, "check.pyc"), doraise=True)
            except py_compile.PyCompileError as e:
                print(f"{path}: {str(e).strip().splitlines()[-1]}")
        elif mode == "shebang" and shebang and os.access(path, os.X_OK):
            interpreter, _, arg = shebang.partition(" ")
            arg = arg.strip()
            if os.path.basename(interpreter) == "env":
                command = (arg[2:].split() or [""])[0] if arg.startswith("-S") else arg
            else:
                command = interpreter
            if not shutil.which(command):
                print(f"{path}: {shebang}")
        elif mode == "imports" and (shebang is not None or path.startswith(PROGRAM_DIRS)):
            try:
                with open(path, "rb") as f:
                    tree = ast.parse(f.read(), path)
            except (SyntaxError, ValueError):
                continue
            for missing in dict.fromkeys(unresolved(path, tree)):
                print(f"{path} {missing}")
    shutil.rmtree(tmp, ignore_errors=True)


main()
EOF
)

py_check() {
  cd / && python3 -c "${PY_CHECK}" "$@"
}

test_python_programs_compile() {
  local out
  out=$(py_check compile ${PY_DIRS}) || fail "compile check failed"
  out=$(echo "${out}" | grep -vxF -f "${PY_KNOWN}")
  [ -z "${out}" ] || fail "Python $(python3 -V | cut -d' ' -f2) cannot compile:"$'\n'"${out}"
}

test_python_shebangs_resolve() {
  local out file rest failures=""
  out=$(py_check shebang ${PY_DIRS}) || fail "shebang check failed"
  while read -r file rest; do
    [ -z "${file}" ] || known_failure "${PY_KNOWN}" "${file%:}" || failures="${failures}${file} ${rest}"$'\n'
  done <<<"${out}"
  [ -z "${failures}" ] || fail "Python shebang interpreter not in the image:"$'\n'"${failures}"
}

test_python_program_imports_resolve() {
  local out
  out=$(py_check imports ${PY_DIRS}) || fail "import check failed"
  out=$(echo "${out}" | grep -vxF -f "${PY_KNOWN}")
  [ -z "${out}" ] || fail "top-level imports that importlib cannot find (program module[.name]):"$'\n'"${out}"
}

test_site_packages_import() {
  local dir module out failures=""
  for dir in $(python3 -c 'import site; print(" ".join(site.getsitepackages()))'); do
    for module in $(python3 -c 'import pkgutil, sys; print(*(m.name for m in pkgutil.iter_modules(sys.argv[1:])))' \
      "${dir}"); do
      known_failure "${PY_KNOWN}" "import ${module}" && continue
      out=$(cd / && timeout 60 python3 -c "import ${module}" 2>&1) ||
        failures="${failures}${module}: $(echo "${out}" | tail -n 1)"$'\n'
    done
  done
  [ -z "${failures}" ] || fail "site-packages modules fail to import:"$'\n'"${failures}"
}

test_stdlib_extension_modules_import() {
  local file module out failures=""
  for file in "$(python3 -c 'import sysconfig; print(sysconfig.get_path("platstdlib"))')"/lib-dynload/*.so; do
    module=$(basename "${file}")
    module=${module%%.*}
    known_failure "${PY_KNOWN}" "import ${module}" && continue
    out=$(cd / && timeout 60 python3 -c "import ${module}" 2>&1) ||
      failures="${failures}${module}: $(echo "${out}" | tail -n 1)"$'\n'
  done
  [ -z "${failures}" ] || fail "lib-dynload extension modules fail to import:"$'\n'"${failures}"
}

test_bluetooth_agent_dbus_bindings() {
  local out
  [ -x /usr/bin/rocknix-bluetooth-agent ] || skip "no rocknix-bluetooth-agent in this image"
  out=$(cd / && python3 -c 'import asyncio, dbussy, ravel; ravel.system_bus_async; dbussy.Connection' 2>&1) ||
    fail "dbussy/ravel as used by rocknix-bluetooth-agent: ${out}"
}
