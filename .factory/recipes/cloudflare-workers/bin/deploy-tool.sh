#!/usr/bin/env bash
# Installs the recipe's deploy tool (wrangler) in an empty folder, checking every byte before anything of it runs.
#   deploy-tool.sh install <empty folder>
# The jobs that hold the Cloudflare secrets run wrangler only through this script, never through npx:
# 1. deploy-tool/manifest.json and deploy-tool/lockfile.json (next to bin/) must have the sha256 sums the workflow
#    pins (DEPLOY_TOOL_PACKAGE_SHA256, DEPLOY_TOOL_LOCK_SHA256). They are npm's manifest and lockfile, kept under
#    neutral names and copied under npm's own names into the empty folder;
# 2. the manifest must ask for exactly DEPLOY_TOOL (wrangler@<x.y.z>) and nothing else, with no scripts, and the
#    lockfile must resolve it to that version and give every package a registry.npmjs.org tarball with a sha512
#    integrity (npm skips the check for an entry without one, so such a lockfile is refused);
# 3. `npm ci --ignore-scripts` installs exactly that tree in the empty folder, with a clean environment (no secret,
#    no npm_config_* variable), its own empty cache and two different empty npmrc files (user and global): npm
#    checks each tarball against its sha512 and runs no lifecycle script, so nothing it downloads runs during the
#    install;
# 4. the installed wrangler must be that version.
# Then WRANGLER, the command the other scripts run, goes to $GITHUB_ENV (to stdout without one). It is defined nowhere
# else, so a step that runs wrangler before this one fails instead of fetching an unchecked copy.
set -euo pipefail

command=${1:?usage: deploy-tool.sh install <empty folder>}
dir=${2:?folder missing}
[ "$command" = install ] || { echo "deploy-tool.sh: unknown command $command" >&2; exit 64; }
: "${DEPLOY_TOOL:?DEPLOY_TOOL must name the pinned tool, wrangler@<x.y.z>}"
: "${DEPLOY_TOOL_PACKAGE_SHA256:?DEPLOY_TOOL_PACKAGE_SHA256 must pin deploy-tool/manifest.json}"
: "${DEPLOY_TOOL_LOCK_SHA256:?DEPLOY_TOOL_LOCK_SHA256 must pin deploy-tool/lockfile.json}"
# The folder goes into WRANGLER, which callers split on spaces: plain characters only.
[[ $dir =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "::error title=Deploy tool::The tool folder must be an absolute plain path." >&2; exit 1; }
if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
  echo "::error title=Deploy tool::$dir is not empty: the tool is installed only into an empty folder." >&2
  exit 1
fi
src=$(cd "$(dirname "$0")/../deploy-tool" && pwd)
# npm reads only its own names; this is the one line that spells them.
manifest=$dir/package.json lock=$dir/package-lock.json installed=$dir/node_modules/wrangler/package.json # neutrality-allow: package.json npm's own manifest name, for the recipe's pinned deploy tool, not a project's file neutrality-allow: package-lock.json npm's own lockfile name, for the recipe's pinned deploy tool, not a project's file
mkdir -p "$dir"
cp "$src/manifest.json" "$manifest"
cp "$src/lockfile.json" "$lock"

python3 - "$manifest" "$lock" <<'PY'
import hashlib, json, os, re, sys
manifest_path, lock_path = sys.argv[1:3]
tool = os.environ["DEPLOY_TOOL"]
problems = []
for path, label, var in ((manifest_path, "deploy-tool/manifest.json", "DEPLOY_TOOL_PACKAGE_SHA256"),
                         (lock_path, "deploy-tool/lockfile.json", "DEPLOY_TOOL_LOCK_SHA256")):
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != os.environ[var].strip().lower():
        problems.append(f"{label} has sha256 {digest}, the workflow pins {os.environ[var]}")
match = re.fullmatch(r"(wrangler)@([0-9]+\.[0-9]+\.[0-9]+)", tool)
if not match:
    problems.append(f"DEPLOY_TOOL must be wrangler@<x.y.z>, not {tool!r}")
else:
    name, version = match.groups()
    with open(manifest_path) as f:
        package = json.load(f)
    with open(lock_path) as f:
        lock = json.load(f)
    if package.get("dependencies") != {name: version}:
        problems.append(f"the manifest must depend on exactly {name} {version}")
    for key in ("devDependencies", "optionalDependencies", "peerDependencies", "overrides", "scripts", "workspaces"):
        if key in package:
            problems.append(f"the manifest must not have {key}")
    packages = lock.get("packages")
    if lock.get("lockfileVersion") != 3 or not isinstance(packages, dict):
        problems.append("the lockfile must be lockfile version 3")
        packages = {}
    root = packages.get("", {})
    if root.get("dependencies") != {name: version}:
        problems.append(f"the lockfile's root must depend on exactly {name} {version}")
    if packages.get(f"node_modules/{name}", {}).get("version") != version:
        problems.append(f"the lockfile must resolve {name} to {version}")
    for path, entry in packages.items():
        if path == "":
            continue
        if not path.startswith("node_modules/") or entry.get("link") or entry.get("inBundle"):
            problems.append(f"{path}: only registry packages are allowed")
        elif not re.fullmatch(r"https://registry\.npmjs\.org/[^\s?#]+\.tgz", str(entry.get("resolved", ""))):
            problems.append(f"{path}: its tarball is not on registry.npmjs.org")
        elif not re.fullmatch(r"sha512-[A-Za-z0-9+/]{86}==", str(entry.get("integrity", ""))):
            problems.append(f"{path}: no sha512 integrity")
if problems:
    for problem in problems:
        print(f"::error title=Deploy tool::{problem}")
    sys.exit(1)
PY

# A clean environment: npm sees no secret, no npm_config_* variable, no user or global npmrc and no shared cache.
# The user and the global config each get their own empty file: npm 10.9 refuses to load one file as both.
: > "$dir/.npmrc-empty"
: > "$dir/.npmrc-global"
mkdir -p "$dir/.home"
(cd "$dir" && env -i PATH="$PATH" HOME="$dir/.home" npm ci --ignore-scripts --no-audit --no-fund \
  --no-update-notifier --registry=https://registry.npmjs.org/ --userconfig "$dir/.npmrc-empty" \
  --globalconfig "$dir/.npmrc-global" --cache "$dir/.npm-cache" --loglevel=warn)

version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$installed")
if [ "wrangler@$version" != "$DEPLOY_TOOL" ]; then
  echo "::error title=Deploy tool::npm installed wrangler $version, not $DEPLOY_TOOL." >&2
  exit 1
fi
line="WRANGLER=node $dir/node_modules/wrangler/bin/wrangler.js"
if [ -n "${GITHUB_ENV:-}" ]; then echo "$line" >> "$GITHUB_ENV"; else echo "$line"; fi
echo "Deploy tool: $DEPLOY_TOOL, every package checked against the pinned lockfile."
