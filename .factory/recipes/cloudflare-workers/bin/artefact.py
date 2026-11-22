#!/usr/bin/env python3
"""The deploy artefact: what the build job (no secrets) hands to the job that holds the secrets.

    artefact.py pack   --bundle DIR --assets REL --target T --sha SHA --run-id ID --out FILE
    artefact.py unpack --from DIR --digest HEX --target T --sha SHA --run-id ID --into EMPTY_DIR
                       --config REL [--main-stem STEM] [--assets REL]

`pack` runs in the build job, after the project's setup and build: it puts the bundled Worker (wrangler's
`deploy --dry-run --outdir`) under worker/, the built assets directory under assets/ and a manifest naming the target,
the commit and the workflow run into one gzipped tar, and prints `file=` and `digest=` (its sha256) for the job's
outputs.

`unpack` runs in a job that holds the secrets, so it treats the artefact as untrusted data: the build job ran
third-party code, which could have written anything into it. It
- takes the one file the download left in DIR, refuses it unless its sha256 is the digest the build job gave, and
  refuses a manifest that names another target, commit or run (the download reads only this run's artefacts);
- reads every member before writing any: only regular files and folders, only under worker/ and assets/ (plus the
  manifest), plain relative names without `..`, no links or devices, no duplicates, within size limits;
- writes them itself into EMPTY_DIR/artefact/, outside the checkout, never with tarfile's extract, never following a
  link, without any executable or set-id bit;
- builds the release tree, EMPTY_DIR/tree/, the only folder wrangler deploys from: a copy of the trusted config
  (--config, from the checkout, made before anything else is written) at its path, and, with --assets (from that
  config, checked by wrangler-config.py), the artefact's assets at theirs. Nothing else is in it;
- prints `entry=` (with --main-stem: the bundled entry, artefact/worker/<stem>.js or .mjs, uploaded as it is with
  --no-bundle), `config=` (the copy) and `tree=`.
The checkout is never written to, so every script, tool and setting the later steps run from it (the recipe's bin/,
the core's checker, the workflow's own files) stays the gated commit's. Nothing in the artefact is ever run: wrangler
runs in the release tree, with the copied config, where the artefact can only add assets.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import sys
import tarfile

MANIFEST = "factory-artefact.json"
NAME = re.compile(r"(worker|assets)(/[A-Za-z0-9._@+~=,%() -]+)*")
MAX_MEMBERS = 100_000
MAX_BYTES = 2 * 1024 ** 3


class Refuse(Exception):
    pass


def manifest(target, sha, run_id):
    return {"format": 1, "target": target, "sha": sha, "run_id": run_id}


def add_tree(tar, source, prefix):
    """Adds a folder as prefix/..., regular files and folders only (a link would be refused on the other side)."""
    for root, dirs, files in os.walk(source, followlinks=False):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, source).replace(os.sep, "/")
            mode = os.lstat(path).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise Refuse(f"{prefix}/{rel} is not a regular file or folder")
            info = tar.gettarinfo(path, arcname=f"{prefix}/{rel}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            info.mode = 0o755 if info.isdir() else 0o644
            if info.isreg():
                with open(path, "rb") as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)


def pack(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with tarfile.open(args.out, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        data = json.dumps(manifest(args.target, args.sha, args.run_id), sort_keys=True).encode()
        info = tarfile.TarInfo(MANIFEST)
        info.size, info.mode = len(data), 0o644
        tar.addfile(info, io.BytesIO(data))
        if args.bundle and os.path.isdir(args.bundle):
            add_tree(tar, args.bundle, "worker")
        if args.assets:
            if not os.path.isdir(args.assets) or os.path.islink(args.assets):
                raise Refuse(f"the assets directory {args.assets} does not exist after the build")
            add_tree(tar, args.assets, "assets")
    with open(args.out, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    print(f"file={os.path.basename(args.out)}\ndigest={digest}")


def downloaded(folder):
    entries = os.listdir(folder) if os.path.isdir(folder) else []
    if len(entries) != 1:
        raise Refuse(f"the download holds {len(entries)} files, not the one artefact")
    path = os.path.join(folder, entries[0])
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise Refuse("the downloaded artefact is not a regular file")
    return path


def unpack(args):
    if not re.fullmatch(r"[0-9a-f]{64}", args.digest):
        raise Refuse("the build job gave no sha256 digest")
    path = downloaded(args.source)
    with open(path, "rb") as f:
        blob = f.read()
    if hashlib.sha256(blob).hexdigest() != args.digest:
        raise Refuse("the artefact's sha256 is not the digest the build job gave")
    if os.path.lexists(args.into) and (not os.path.isdir(args.into) or os.listdir(args.into)):
        raise Refuse(f"{args.into} is not an empty folder")

    members, seen, total, found = [], set(), 0, None
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for info in tar:
            name = info.name
            if len(seen) >= MAX_MEMBERS:
                raise Refuse("the artefact has too many members")
            if name in seen:
                raise Refuse(f"the artefact names {name!r} twice")
            seen.add(name)
            if name == MANIFEST and info.isreg():
                if info.size > 4096:
                    raise Refuse("the manifest is too large")
                try:
                    found = json.loads(tar.extractfile(info).read().decode())
                except ValueError:
                    raise Refuse("the manifest is not JSON")
                continue
            parts = name.split("/")
            if not NAME.fullmatch(name) or any(p in ("", ".", "..") for p in parts):
                raise Refuse(f"the artefact holds a name outside worker/ and assets/: {name!r}")
            if info.isreg():
                total += info.size
                if total > MAX_BYTES:
                    raise Refuse("the artefact is too large")
                members.append((name, info, tar.extractfile(info).read()))
            elif info.isdir():
                members.append((name, info, None))
            else:
                raise Refuse(f"{name!r} is not a regular file or folder (links and devices are refused)")
    if found != manifest(args.target, args.sha, args.run_id):
        raise Refuse(f"the manifest {found!r} is not this run's artefact of {args.target} at {args.sha}")

    config_source = trusted_config(args.config)
    os.makedirs(args.into, exist_ok=True)
    base = os.path.realpath(args.into)
    root = os.path.join(base, "artefact")
    tree = os.path.join(base, "tree")
    os.makedirs(root)
    os.makedirs(tree)
    # The config first, before any byte of the artefact is written.
    config_copy = os.path.join(tree, *args.config.split("/"))
    os.makedirs(os.path.dirname(config_copy), exist_ok=True)
    shutil.copyfile(config_source, config_copy)
    for name, info, data in members:
        target = os.path.join(root, *name.split("/"))
        parent = os.path.dirname(target)
        os.makedirs(parent, mode=0o755, exist_ok=True)
        if os.path.realpath(parent) != parent or not (parent == root or parent.startswith(root + os.sep)):
            raise Refuse(f"{name!r} would be written outside the artefact folder")
        if data is None:
            os.makedirs(target, mode=0o755, exist_ok=True)
            continue
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
        with os.fdopen(fd, "wb") as f:
            f.write(data)

    entry = ""
    if args.main_stem:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", args.main_stem):
            raise Refuse("the entry's name is not plain")
        candidates = [os.path.join(root, "worker", args.main_stem + ext) for ext in (".js", ".mjs")]
        candidates = [c for c in candidates if os.path.isfile(c)]
        if len(candidates) != 1:
            raise Refuse(f"the bundle has {len(candidates)} entries named {args.main_stem}.js or .mjs, not one")
        entry = candidates[0]
    if args.assets:
        place_assets(os.path.join(root, "assets"), args.assets, args.config, tree)
    print(f"entry={entry}\nconfig={config_copy}\ntree={tree}")


def plain_relative(rel, what):
    parts = rel.split("/")
    if not rel or os.path.isabs(rel) or any(p in ("", ".", "..") for p in parts) or "\\" in rel:
        raise Refuse(f"{what} {rel!r} is not a plain path inside the checkout")
    return parts


def trusted_config(rel):
    """The checkout's config file (the current folder is the checkout): a regular file, reached without a link."""
    parts = plain_relative(rel, "the config")
    checkout = os.path.realpath(".")
    path = os.path.join(checkout, *parts)
    if os.path.realpath(path) != path or not stat.S_ISREG(os.lstat(path).st_mode):
        raise Refuse(f"the config {rel} is not a regular file of the checkout")
    return path


def place_assets(source, rel, config_rel, tree):
    """Moves the built assets to `rel` inside the release tree, never into the checkout. The assets may not hold the
    config copy or sit above it, so they cannot replace or sit beside it (wrangler-config.py check refuses that too)."""
    if not os.path.isdir(source):
        raise Refuse("the config has an assets directory, but the artefact holds no assets")
    parts = plain_relative(rel, "the assets directory")
    config_dir = config_rel.split("/")[:-1]
    if config_dir[:len(parts)] == parts or config_rel.split("/") == parts:
        raise Refuse(f"the assets directory {rel} would hold the config")
    target = os.path.join(tree, *parts)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.lexists(target):
        raise Refuse(f"the release tree already has {rel}")
    shutil.move(source, target)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pack")
    p.add_argument("--bundle", default="")
    p.add_argument("--assets", default="")
    p.add_argument("--out", required=True)
    u = sub.add_parser("unpack")
    u.add_argument("--from", dest="source", required=True)
    u.add_argument("--digest", required=True)
    u.add_argument("--into", required=True)
    u.add_argument("--config", required=True)
    u.add_argument("--main-stem", default="")
    u.add_argument("--assets", default="")
    for q in (p, u):
        q.add_argument("--target", required=True)
        q.add_argument("--sha", required=True)
        q.add_argument("--run-id", required=True)
    args = parser.parse_args()
    try:
        pack(args) if args.command == "pack" else unpack(args)
    except Refuse as e:
        print(f"::error title=Artefact::{e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
