#!/usr/bin/env python3
"""factory-settings' resolver and output: every setting in use and where its value comes from.

    python3 -I factory-settings.py repo --target DIR --defaults FILE
    python3 -I factory-settings.py show --target DIR --defaults FILE --machine FILE --mode MODE --stop STOP
                                        [--prefix KEY] [--changed] [--json]

`repo` prints factory.yaml › project.repo when factory.yaml is valid, else nothing; the shell script needs it for the
emergency-stop query. `show` prints the report. Exit codes of `show`: 0 shown; 3 factory.yaml is missing or not
valid (nothing printed); 4 no setting matches --prefix (nothing printed); 64 bad arguments; 70 internal error.

Shared with factory-doctor, not copied: this file loads factory-doctor.py (next to it) as a module and uses its YAML
subset reader (load_yaml), its validation of factory.yaml and the machine file (check_factory_yaml, check_machine),
its merge rule (merge: maps merge per key, lists and scalars replace) and its redaction (redact, deep_redact). A
factory.yaml the doctor fails is never resolved: no value is guessed from a file the doctor would refuse.

Standard library only; runs on Python 3.8 and later. It reads files and never changes one, never runs a command and
never reads a credential. Every printed string, keys and the target included, passes the doctor's redact() first, in
text and JSON alike.
"""

import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Read-only includes the folder this runs from: importing factory-doctor.py must not leave a bytecode cache there.
sys.dont_write_bytecode = True


def load_doctor():
    spec = importlib.util.spec_from_file_location("factory_doctor", os.path.join(HERE, "factory-doctor.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    doc_mod = load_doctor()
    redact, deep_redact, merge, load_yaml, Refused = (doc_mod.redact, doc_mod.deep_redact, doc_mod.merge,
                                                      doc_mod.load_yaml, doc_mod.Refused)
except BaseException:  # noqa: B036 (reported by guarded() as one fixed line)
    doc_mod = None


# --- what the code knows besides core/defaults.yaml ----------------------------------------------------------------
# Every default is read from core/defaults.yaml (the one source, as docs/factory-yaml.md says); there is no table of
# defaults here. A key with no default is written "<required>" there: it shows no "default" and is never guessed.
# The per-entry defaults (a check, a role, a deploy target or environment, serve) come from its `entry_defaults`
# section: entry path (with `<name>` for any one name) to the keys that entry gets when it leaves them out.

REQUIRED = object()   # a key with no default: factory.yaml must set it
REQUIRED_MARK = "<required>"


def marked(node):
    """The parsed defaults with every "<required>" replaced by REQUIRED."""
    if isinstance(node, dict):
        return {k: marked(v) for k, v in node.items()}
    if isinstance(node, list):
        return [marked(v) for v in node]
    return REQUIRED if node == REQUIRED_MARK else node

# Sections of core/defaults.yaml that are not factory.yaml keys: the machine settings (shown as machine.<key>) and the
# per-entry defaults.
NOT_KEYS = ("machine", "entry_defaults")
# Maps shown as one value: they belong to a recipe, which validates its own keys.
OPAQUE = re.compile(r"deploy\.[^.]+\.with")
# How "no value" reads in text, per key; JSON gives null.
NONE_TEXT = ((re.compile(r"commands\.checks\.[^.]+\.when"), "every change"),)


def none_text(key):
    for rx, text in NONE_TEXT:
        if rx.fullmatch(key):
            return text
    return "none"


# --- reading the inputs ---------------------------------------------------------------------------------------------

def read_lock(target):
    """(version, upstream) from .factory/core.lock, each None unless exactly one well-formed line holds it."""
    path = os.path.join(target, ".factory", "core.lock")
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return None, None
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return None, None

    def one(prefix, rx):
        vals = [ln[len(prefix):] for ln in lines if ln.startswith(prefix)]
        return vals[0] if len(vals) == 1 and rx.fullmatch(vals[0]) else None

    return one("version: ", doc_mod.SEMVER), one("upstream: ", doc_mod.REPO)


def read_defaults(path):
    """The parsed core defaults, or None when the file is missing or cannot be read."""
    if not path or not os.path.isfile(path):
        return None
    try:
        d = load_yaml(path)
    except (Refused, OSError, UnicodeDecodeError):
        return None
    return d if isinstance(d, dict) else None


def failed(check):
    return any(line.startswith("R\t%s\tfail\t" % check) for line in doc_mod.OUT)


def valid_factory_yaml(target, defaults):
    """The parsed factory.yaml when the doctor's check passes it (ok or warn), else None."""
    del doc_mod.OUT[:]
    doc = doc_mod.check_factory_yaml(target, defaults)
    ok = isinstance(doc, dict) and not failed("factory.yaml")
    del doc_mod.OUT[:]
    return doc if ok else None


def read_machine(path):
    """("missing" | "invalid" | "ok", parsed machine file or {}), validated by the doctor's machine check."""
    if not os.path.lexists(path):
        return "missing", {}
    del doc_mod.OUT[:]
    m = doc_mod.check_machine(path)
    bad = m is None or failed("machine")
    del doc_mod.OUT[:]
    return ("invalid", {}) if bad else ("ok", m)


# --- resolving ------------------------------------------------------------------------------------------------------

MISSING = object()


def entry_patterns(defaults):
    """(regex, defaults of that entry) per `entry_defaults` item of the core defaults, `<name>` read as any one name."""
    table = (defaults or {}).get("entry_defaults")
    out = []
    for path, own in (marked(table).items() if isinstance(table, dict) else ()):
        if isinstance(own, dict):
            out.append((re.compile(r"\.".join("[^.]+" if re.fullmatch(r"<[^<>.]+>", seg) else re.escape(seg)
                                              for seg in path.split("."))), own))
    return out


def entry_defaults(key, patterns):
    for rx, own in patterns:
        if rx.fullmatch(key):
            return own
    return None


def flatten(eff, core, project, path, src_project, src_core, rows, patterns):
    """One row per leaf of the merged settings. A map descends (its entries merge per key); a list or a scalar is
    one value. A leaf's source is the project file when that file sets it, else the core."""
    key = ".".join(path)
    own = entry_defaults(key, patterns)
    if own is not None and (isinstance(eff, dict) or (eff is None and project is not MISSING)):
        # An entry of a map the project fills (a check, a role, ...): its own defaults first, merged per key.
        eff = merge(own, eff or {})
        core = merge(own, core if isinstance(core, dict) else {})
    if isinstance(eff, dict) and eff and not OPAQUE.fullmatch(key):
        for k, v in eff.items():
            core_v = core.get(k, MISSING) if isinstance(core, dict) else MISSING
            sub_p = project.get(k, MISSING) if isinstance(project, dict) else MISSING
            flatten(v, core_v, sub_p, path + [k], src_project, src_core, rows, patterns)
        return
    rows.append(row(path, eff, src_project if project is not MISSING else src_core, core))


def row(path, value, source, default):
    r = {"key": ".".join(str(p) for p in path), "value": value, "source": source}
    if default is not MISSING and default is not REQUIRED:
        r["default"] = default
    return r


def resolve(doc, defaults, machine_state, machine, lock_version):
    core_src = "core default %s" % lock_version if lock_version else "core default"
    d = marked(defaults or {})
    # The sections of the core defaults that are not factory.yaml keys stay out of the project's settings.
    core = {k: v for k, v in d.items() if k not in NOT_KEYS}
    patterns = entry_patterns(d)
    repo = doc.get("project", {}).get("repo", "")
    core["project"] = dict(core.get("project") or {}, name=repo.split("/", 1)[1] if "/" in repo else None)
    rows = []
    for top in list(core) + [k for k in doc if k not in core]:
        c, p = core.get(top, MISSING), doc.get(top, MISSING)
        if c is MISSING and p is MISSING:
            continue
        eff = p if c is MISSING else (c if p is MISSING else merge(c, p))
        flatten(eff, c, p, [top], "factory.yaml", core_src, rows, patterns)
    for r in rows:
        if r["value"] is REQUIRED:   # cannot happen for a file the doctor passed; never a guess either way
            r["value"], r["source"] = "unknown", "factory.yaml"

    mcore = d.get("machine") if isinstance(d.get("machine"), dict) else None
    mrows = []
    if machine_state == "invalid":
        for r in leaf_keys(mcore or {}, ["machine"]):
            mrows.append({"key": r, "value": "unknown", "source": "machine.yaml (not valid: run factory-doctor)"})
        if not mrows:
            mrows.append({"key": "machine", "value": "unknown", "source": "machine.yaml (not valid: run factory-doctor)"})
    elif mcore is None:
        flatten(machine or {}, {}, machine or {}, ["machine"], "machine.yaml", "machine default", mrows, [])
        mrows = [r for r in mrows if r["key"] != "machine"]
        mrows.insert(0, {"key": "machine", "value": "unknown",
                         "source": "machine default (core defaults.yaml has no machine section here)"})
    else:
        flatten(merge(mcore, machine or {}), mcore, machine or {}, ["machine"], "machine.yaml", "machine default", mrows,
                [])
    return rows + mrows


def leaf_keys(node, path):
    if isinstance(node, dict) and node:
        out = []
        for k, v in node.items():
            out += leaf_keys(v, path + [k])
        return out
    return [".".join(path)]


# --- output ---------------------------------------------------------------------------------------------------------

def text_value(key, v):
    if v is None:
        s = none_text(key)
    elif isinstance(v, bool):
        s = "true" if v else "false"
    elif isinstance(v, (list, dict)):
        s = json.dumps(v, ensure_ascii=False)
    else:
        s = str(v)
    return redact(re.sub(r"[\x00-\x1f\x7f]", " ", s))


def differs(r):
    return r["source"] in ("factory.yaml", "machine.yaml") and ("default" not in r or r["value"] != r["default"])


def matches(key, prefix):
    return prefix is None or key == prefix or key.startswith(prefix + ".")


def show(opts):
    target = opts["--target"]
    defaults = read_defaults(opts["--defaults"])
    doc = valid_factory_yaml(target, defaults)
    if doc is None:
        return 3
    machine_state, machine = read_machine(opts["--machine"])
    version, upstream = read_lock(target)
    settings = resolve(doc, defaults, machine_state, machine, version)
    mode = opts["--mode"]
    state = [
        {"key": "state.core_version", "value": version or "unknown", "source": ".factory/core.lock"},
        {"key": "state.upstream", "value": upstream or "unknown", "source": ".factory/core.lock"},
        {"key": "state.emergency_stop", "value": {"on": "on (paused)", "off": "off"}.get(opts["--stop"], "unknown"),
         "source": "factory-pause status"},
        {"key": "state.agent_token_mode",
         "value": {"off": "off", "staged": "staged", "on": "on"}.get(mode, "unknown"),   # no broker: unknown
         "source": "factory-github mode"},
    ]
    prefix = opts["--prefix"]
    settings = [r for r in settings if matches(r["key"], prefix)]
    state = [r for r in state if matches(r["key"], prefix)]
    if not settings and not state:
        return 4   # the prefix names no key at all (with --changed, "nothing differs" is a normal answer)
    if opts["--changed"]:
        settings, state = [r for r in settings if differs(r)], []
    if opts["--json"]:
        def out_row(r):
            o = {"key": redact(r["key"]), "value": deep_redact(r["value"]), "source": redact(r["source"])}
            if "default" in r:
                o["default"] = deep_redact(r["default"])
            return o
        report = {"target": redact(target), "changed_only": bool(opts["--changed"]),
                  "settings": [out_row(r) for r in settings], "state": [out_row(r) for r in state]}
        sys.stdout.write(json.dumps(report, ensure_ascii=False, indent=1) + "\n")
        return 0
    rows = settings + state
    kw = max([len("key")] + [len(redact(r["key"])) for r in rows])
    sw = max([len("source")] + [len(redact(r["source"])) for r in rows])
    lines = ["factory-settings: %s%s" % (text_value("", target), " (only what differs from the defaults)"
                                          if opts["--changed"] else ""),
             "%-*s  %-*s  %s" % (kw, "key", sw, "source", "value")]
    for r in rows:
        line = "%-*s  %-*s  %s" % (kw, redact(r["key"]), sw, redact(r["source"]), text_value(r["key"], r["value"]))
        if opts["--changed"] and "default" in r:
            line += "  (default: %s)" % text_value(r["key"], r["default"])
        lines.append(line.rstrip())
    if not rows:
        lines.append("(nothing differs from the defaults)")
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


def main(argv):
    if doc_mod is None:
        sys.stderr.write("factory-settings.py: factory-doctor.py is missing or broken next to it\n")
        return 70
    if argv[:1] == ["repo"] and len(argv) == 5 and argv[1] == "--target" and argv[3] == "--defaults":
        doc = valid_factory_yaml(argv[2], read_defaults(argv[4]))
        repo = (doc or {}).get("project", {}).get("repo")
        if isinstance(repo, str) and doc_mod.REPO.fullmatch(repo) and redact(repo) == repo:
            sys.stdout.write(repo + "\n")
        return 0
    if argv[:1] != ["show"]:
        sys.stderr.write("factory-settings.py: bad arguments (not shown)\n")
        return 64
    opts = {"--target": None, "--defaults": "", "--machine": "", "--mode": "", "--stop": "", "--prefix": None}
    flags = {"--changed": False, "--json": False}
    args = argv[1:]
    while args:
        if args[0] in flags:
            flags[args[0]] = True
            args = args[1:]
        elif args[0] in opts and len(args) >= 2:
            opts[args[0]] = args[1]
            args = args[2:]
        else:
            sys.stderr.write("factory-settings.py: bad argument (not shown)\n")
            return 64
    if not opts["--target"]:
        sys.stderr.write("factory-settings.py: --target is required\n")
        return 64
    opts.update(flags)
    return show(opts)


def guarded(argv):
    """main() behind one fixed line, as in factory-doctor.py: an uncaught error never prints a traceback, a path or
    a value."""
    try:
        code = main(argv)
        sys.stdout.flush()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 70
    except BaseException:  # noqa: B036 (KeyboardInterrupt and BrokenPipeError included, on purpose)
        code = 70
        try:
            sys.stderr.write("factory-settings.py: internal error (details not shown)\n")
            sys.stderr.flush()
        except BaseException:
            pass
    os._exit(code if isinstance(code, int) else 70)


if __name__ == "__main__":
    guarded(sys.argv[1:])
