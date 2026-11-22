#!/usr/bin/env python3
"""Reads the Wrangler config the way the deploy needs it, and refuses what would run a command next to the secrets.

    wrangler-config.py show  [--config PATH]   in the build job, which holds no secret
    wrangler-config.py check [--config PATH]   in every job that holds the Cloudflare secrets, before wrangler runs

Both run in the checkout's root and print key=value lines for $GITHUB_OUTPUT:
    config=<path of the config file, relative>   every wrangler call passes it as --config
    main_stem=<file name of `main` without its extension, empty without `main`>
    assets=<the assets directory, relative to the checkout, empty without `assets`>
Without --config, the file is found as wrangler finds it: wrangler.json, wrangler.jsonc or wrangler.toml, in that
order, in the checkout's root.

`check` also refuses, because wrangler would act on it inside the deploy step:
- a `build` section with a command (custom build): wrangler runs it before every deploy, even with --no-bundle, so it
  would run project and third-party code next to the secrets. The recipe's `with.build` setting replaces it;
- a redirected config (.wrangler/deploy/config.json), which would make wrangler read another file than this one;
- `site` (Workers Sites), whose bucket the build job does not hand over: use `assets`;
- `containers`: wrangler builds a container image from the project's Dockerfile during the deploy, which would run
  project code next to the secrets;
- an assets directory that is the checkout itself, the config's own folder or one above it, or inside .git,
  .github, .factory, .wrangler or node_modules. The deploy job puts the build's (untrusted) assets in a separate
  release tree, never in the checkout (artefact.py), so this is a second line: the assets folder must be one that
  wrangler reads only as content, apart from the config and from anything a later step runs.
Every printed value is checked against a plain character set, so nothing in the config can add an output line.
Python 3 standard library only (TOML needs Python 3.11 or later, as on GitHub's runners).
"""

import argparse
import json
import os
import posixpath
import re
import sys

LOOKUP = ("wrangler.json", "wrangler.jsonc", "wrangler.toml")
PLAIN = re.compile(r"[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*")


class Refuse(Exception):
    pass


def strip_jsonc(text):
    """JSON with comments and trailing commas (as wrangler reads it) to plain JSON. Strings are kept as they are."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise Refuse("an unterminated /* comment")
            i = j + 2
        else:
            out.append(c)
            i += 1
    plain = "".join(out)
    # A comma followed only by blanks and a closing bracket, outside strings.
    result, i, n = [], 0, len(plain)
    while i < n:
        c = plain[i]
        if c == '"':
            j = i + 1
            while j < n and plain[j] != '"':
                j += 2 if plain[j] == "\\" else 1
            result.append(plain[i:j + 1])
            i = j + 1
            continue
        if c == ",":
            j = i + 1
            while j < n and plain[j] in " \t\r\n":
                j += 1
            if j < n and plain[j] in "]}":
                i += 1
                continue
        result.append(c)
        i += 1
    return "".join(result)


def load(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if path.endswith(".toml"):
        try:
            import tomllib
        except ImportError:
            raise Refuse("reading a TOML config needs Python 3.11 or later")
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError as e:
            raise Refuse(f"{path} is not valid TOML ({e})")
    else:
        try:
            data = json.loads(strip_jsonc(text))
        except ValueError as e:
            raise Refuse(f"{path} is not valid JSON or JSONC ({e})")
    if not isinstance(data, dict):
        raise Refuse(f"{path} does not hold a table of settings")
    return data


def relative(path, what):
    """A normalised path relative to the checkout, in plain characters, never leaving it."""
    norm = posixpath.normpath(path)
    if norm.startswith("/") or norm == ".." or norm.startswith("../") or not PLAIN.fullmatch(norm):
        raise Refuse(f"{what} {path!r} is not a plain path inside the checkout")
    return norm


def find_config(given):
    if given:
        path = relative(given, "the config")
        if not os.path.isfile(path):
            raise Refuse(f"no Wrangler config at {path}")
        return path
    for name in LOOKUP:
        if os.path.isfile(name):
            return name
    raise Refuse("no Wrangler config (wrangler.json, wrangler.jsonc or wrangler.toml) in the checkout's root")


def inside(path, root):
    return path == root or path.startswith(root + os.sep)


def read(given, check):
    config = find_config(given)
    real_root = os.path.realpath(".")
    if not inside(os.path.realpath(config), real_root):
        raise Refuse(f"the config {config} resolves outside the checkout")
    data = load(config)
    folder = posixpath.dirname(config)
    main = data.get("main")
    stem = ""
    if main is not None:
        if not isinstance(main, str):
            raise Refuse("`main` is not a path")
        stem = posixpath.splitext(posixpath.basename(relative(posixpath.join(folder, main), "main")))[0]
        if not re.fullmatch(r"[A-Za-z0-9._-]+", stem):
            raise Refuse(f"the file name of `main` ({main!r}) is not plain")
    assets = ""
    section = data.get("assets")
    if section is not None:
        directory = section.get("directory") if isinstance(section, dict) else None
        if not isinstance(directory, str) or not directory:
            raise Refuse("`assets` has no directory")
        assets = relative(posixpath.join(folder, directory), "the assets directory")
    if check:
        build = data.get("build")
        if isinstance(build, dict) and build.get("command"):
            raise Refuse(f"{config} has a custom build (build.command): wrangler would run it inside the deploy step, "
                         "next to the secrets. Move the command to the target's `with.build` setting.")
        if os.path.lexists(os.path.join(".wrangler", "deploy", "config.json")):
            raise Refuse(".wrangler/deploy/config.json would redirect wrangler to another config than the one checked")
        if "site" in data:
            raise Refuse(f"{config} uses Workers Sites (`site`), which this recipe does not deploy: use `assets`")
        if "containers" in data:
            raise Refuse(f"{config} has `containers`: wrangler would build their image, project code, inside the "
                         "deploy step, next to the secrets. This recipe does not deploy containers.")
        if assets:
            parts = assets.split("/")
            if assets == "." or (folder and inside(folder, assets)):
                raise Refuse(f"the assets directory {assets} holds the config: the build's files would sit beside it")
            if parts[0] in (".git", ".github", ".factory", ".wrangler", "node_modules") or "node_modules" in parts:
                raise Refuse(f"the assets directory {assets} is inside {parts[0]}")
            parent = os.path.realpath(posixpath.dirname(assets) or ".")
            if not inside(parent, real_root):
                raise Refuse(f"the assets directory {assets} resolves outside the checkout")
            if os.path.islink(assets):
                raise Refuse(f"the assets directory {assets} is a symbolic link")
    return config, stem, assets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("show", "check"))
    parser.add_argument("--config", default="")
    args = parser.parse_args()
    try:
        config, stem, assets = read(args.config, args.command == "check")
    except Refuse as e:
        print(f"::error title=Wrangler config::{e}")
        return 1
    print(f"config={config}\nmain_stem={stem}\nassets={assets}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
