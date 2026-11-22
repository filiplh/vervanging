#!/bin/sh
# worktree-setup.sh: prepare a fresh git worktree by reusing the main checkout's dependencies when that is safe,
# and run the project's install command only for what could not be reused.
#
#   sh worktree-setup.sh [--dry-run] [-- <install command> ...]
#
# Point commands.setup in factory.yaml at it, with the project's own install command after "--", for example
#   commands:
#     setup: sh .factory/bin/worktree-setup.sh -- <your install command>
# The install command runs only when a dependency folder could not be reused, or when no known kind of dependency
# folder was found at all (then the project's command is the only way). It must be safe to run twice.
#
# For each kind of dependency folder it knows (see kinds() below), in the main checkout and, for monorepos, up to
# three levels down, it reuses the main checkout's folder only when all of these hold:
#   - this is a linked worktree, not the main checkout (on a CI runner it just runs the install command);
#   - the folder is missing here, exists in the main checkout, and git ignores it in both;
#   - every lockfile of that kind is byte for byte the same here and in the main checkout, and there is at least one;
#   - the main checkout's folder is not older than its lockfile (it was installed after the last lockfile change);
#   - the file system can clone files copy-on-write: APFS (cp -c) or reflink (cp --reflink=always, btrfs, XFS).
#     A clone shares disk blocks until either side changes a file, so it costs almost no space. Without copy-on-write
#     it does not copy: the install command runs instead. Package managers with a shared content store (pnpm, bun,
#     yarn berry, uv) already keep that install small, because they link from one store per machine.
# It never symlinks or hard-links the main checkout's folder: a change in one worktree would then change all of them.
# A clone is made under a temporary name and renamed into place, so an interrupted run leaves no half-made folder.
#
# A folder that is already here is checked against the lockfiles it sits next to. A folder this script prepared (a
# clone, or one the install command made) holds a stamp, .worktree-setup-stamp, with the checksums of those lockfiles.
# A missing stamp or one that does not match the lockfiles always means the install command runs; a stamp is never
# removed, so a failed or skipped install leaves the folder marked out of date until an install succeeds. After the
# install command succeeds, the folders it was run for get a new stamp. A clone gets its stamp before it is renamed
# into place, so a folder never sits at its name without one.
#
# Everything it writes goes through a walk from the worktree root, one real folder at a time (no symlink, and the
# kernel's path of each folder must be the expected one), so nothing is written or removed outside the worktree.
#
# Needs: a POSIX shell, git, cp, find. Exit codes: 0 ready, 1 something could not be prepared, 2 bad usage.
set -eu
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

prog=worktree-setup

STAMP=.worktree-setup-stamp

# kinds: one per line, "<folder>|<lockfiles>|<marker files inside the folder that an install rewrites>". Each kind is
# detected by its lockfile names; none is required. Only kinds whose folders stay valid when moved to another path:
# Python virtual environments are not here, they record their own absolute path.
kinds() {
  echo 'node_modules|package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb|.package-lock.json .modules.yaml .yarn-state.yml .yarn-integrity' # neutrality-allow: package-lock.json the standard lockfile name of one package manager, used only to detect it
  echo 'vendor|composer.lock|composer/installed.json'
  echo 'deps|mix.lock|'
}

DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --) shift; break ;;
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "$prog: unknown option $1 (put the install command after --)" >&2; exit 2 ;;
  esac
  shift
done
# "$@" is now the install command, possibly empty.

say() { echo "$prog: $*"; }

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "$prog: not inside a git worktree" >&2; exit 1; }
cd -P "$top" || exit 1
top=$(/bin/pwd -P) # the physical root: walks compare the kernel's paths against it
main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main" ] && [ -d "$main" ] || main=$top

run_install() {
  if [ $# -eq 0 ]; then return 1; fi
  if [ "$DRY" = 1 ]; then say "would run: $*"; return 0; fi
  say "running: $*"
  "$@"
}

if [ "$main" -ef "$top" ]; then
  say "main checkout or a single clone: nothing to reuse"
  if [ $# -gt 0 ]; then run_install "$@"; fi
  exit 0
fi

# Clone method: "c" (cp -c, APFS) or "reflink" (cp --reflink=always), or empty when neither really clones.
same_fs() { [ "$(df -P "$1" | awk 'NR == 2 { print $1 }')" = "$(df -P "$2" | awk 'NR == 2 { print $1 }')" ]; }
clone_method() {
  same_fs "$main" "$top" 2>/dev/null || return 0
  probe=$(mktemp "./.worktree-setup-probe.XXXXXX" 2>/dev/null) || return 0 # in the root, the current folder
  if cp --reflink=always "$probe" "$probe.clone" 2>/dev/null; then
    echo reflink
  elif [ "$(uname -s)" = Darwin ]; then
    # macOS cp -c silently falls back to a full copy when it cannot clone, so check the file system itself.
    mp=$(df -P "$main" | awk 'NR == 2 { print $NF }')
    if mount | grep -F " on $mp (" | grep -q '(apfs'; then echo c; fi
  fi
  rm -f "$probe" "$probe.clone"
}
METHOD=${WORKTREE_SETUP_METHOD-$(clone_method)} # the override is for tests: none, c or reflink
[ "$METHOD" != none ] || METHOD=

# walk_to <folder relative to the root>: cd from the root into it, one real folder at a time: no symlink, and the
# kernel's path of each folder must be the expected one. Fails on any doubt. Call it in a subshell.
walk_to() {
  cd -P "$top" 2> /dev/null && [ "$(/bin/pwd -P)" = "$top" ] || return 1
  _w_at=$top; _w_rest=$1
  while :; do case $_w_rest in ./*) _w_rest=${_w_rest#./} ;; *) break ;; esac; done
  [ "$_w_rest" != . ] || _w_rest=
  while [ -n "$_w_rest" ]; do
    case $_w_rest in
      */*) _w_c=${_w_rest%%/*}; _w_rest=${_w_rest#*/} ;;
      *) _w_c=$_w_rest; _w_rest= ;;
    esac
    case $_w_c in '' | . | ..) return 1 ;; esac
    { [ -d "./$_w_c" ] && [ ! -L "./$_w_c" ]; } || return 1
    cd -P "./$_w_c" 2> /dev/null || return 1
    _w_at="$_w_at/$_w_c"
    [ "$(/bin/pwd -P 2> /dev/null)" = "$_w_at" ] || return 1
  done
}
parent_of() { case $1 in */*) echo "${1%/*}" ;; *) echo . ;; esac; }

# put_stamp <text>: write the stamp in the current folder without writing through a name that is already there. The
# old name is removed as a name (a symlink is removed, never followed), and the new file is created with noclobber,
# which fails rather than follow or overwrite. A stamp that is missing for a moment only means "install".
put_stamp() {
  rm -f "./$STAMP" 2> /dev/null
  (set -C; printf '%s\n' "$1" > "./$STAMP") 2> /dev/null
}

# clone <dep dir> <lockfile folder>: copy-on-write from the main checkout, under a temporary name inside the walked
# parent folder, stamped, then renamed into place. Exit 3: the parent is not a real folder inside this worktree.
clone() {
  _c_st=$(stamp_now "$2") || return 1
  (walk_to "$(parent_of "$1")" || exit 3
    _c_n=${1##*/}
    _c_tmp=".$_c_n.worktree-setup-tmp.$$"
    { [ ! -e "./$_c_n" ] && [ ! -L "./$_c_n" ] && [ ! -e "./$_c_tmp" ] && [ ! -L "./$_c_tmp" ]; } || exit 1
    if case $METHOD in
      c) cp -c -R -p "$main/$1" "./$_c_tmp" ;;
      reflink) cp -R -p --reflink=always "$main/$1" "./$_c_tmp" ;;
      *) false ;;
    esac && [ -d "./$_c_tmp" ] && [ ! -L "./$_c_tmp" ] && (cd -P "./$_c_tmp" && put_stamp "$_c_st") \
      && [ ! -e "./$_c_n" ] && mv "./$_c_tmp" "./$_c_n"; then
      exit 0
    fi
    rm -rf "./$_c_tmp" # one name in the walked folder, made by this run
    exit 1)
}

ignored_in() { git -C "$1" check-ignore -q -- "$2/" 2>/dev/null; } # trailing /: it is a folder, even if missing

# lock_state <folder>: "same", "differs" or "none" for the kind's lockfiles in <folder> here and in main.
lock_state() {
  found=0
  for l in $LOCKS; do
    if [ -f "$main/$1/$l" ] || [ -f "$1/$l" ]; then
      found=1
      cmp -s "$main/$1/$l" "$1/$l" 2>/dev/null || { echo differs; return; }
    fi
  done
  if [ "$found" = 1 ]; then echo same; else echo none; fi
}

# newer_than_install <lockfile folder> <dep dir>: no lockfile in the first is newer than the dependency folder's
# install marker (or, without a marker, than the folder itself). Paths are used as given.
newer_than_install() {
  ref=
  for m in $MARKERS; do
    if [ -f "$2/$m" ]; then ref="$2/$m"; break; fi
  done
  [ -n "$ref" ] || ref=$2
  for l in $LOCKS; do
    [ ! -f "$1/$l" ] || [ -z "$(find "$1/$l" -newer "$ref" 2>/dev/null)" ] || return 1
  done
}

# fresh <folder> <dep dir>: main's dependency folder was written after its lockfiles changed.
fresh() { newer_than_install "$main/$1" "$main/$2"; }

# stamp_of <folder>: the checksums of the kind's lockfiles in <folder> of this worktree.
stamp_of() {
  for l in $LOCKS; do
    if [ -f "$1/$l" ]; then printf '%s %s\n' "$l" "$(cksum < "$1/$l")"; fi
  done
}
# stamp_now <lockfile folder>: the stamp its lockfiles give now, read inside the walked folder.
stamp_now() { (walk_to "$1" && stamp_of .); }

# write_stamp <lockfile folder> <dep dir>: inside the walked dependency folder.
write_stamp() {
  _st=$(stamp_now "$1") || return 1
  (walk_to "$2" && put_stamp "$_st")
}

# present_state <lockfile folder> <dep dir>: "ok", or why a dependency folder that is already here cannot be trusted.
# Only a stamp that matches the lockfiles now counts; a missing one never does.
present_state() {
  if ! (walk_to "$2") 2> /dev/null; then echo "it is not a real folder inside this worktree"; return; fi
  # The stamp and the lockfiles are read inside their walked folders, not through a path resolved again.
  if ! _ps_have=$( (walk_to "$2" && [ -f "./$STAMP" ] && [ ! -L "./$STAMP" ] && cat "./$STAMP") 2> /dev/null); then
    echo "it has no stamp from a completed setup"; return
  fi
  if _ps_want=$(stamp_now "$1") && [ "$_ps_want" = "$_ps_have" ]; then
    echo ok
  else
    echo "its lockfile changed since it was prepared"
  fi
}

# targets <folder>: the dependency folders of this kind in the main checkout at <folder> and below it (real
# directories, not inside another one, and not below a deeper folder with its own lockfile), relative to the root.
targets() {
  [ -d "$main/$1" ] || return 0
  (cd "$main/$1" && find . -maxdepth 4 -name .git -prune -o -type d -name "$DIR" -prune -print 2>/dev/null) \
    | while IFS= read -r t; do
        case $t in *[[:cntrl:]]*) continue ;; esac
        parent=${t%/*}
        if [ "$parent" != . ]; then
          own=0
          for l in $LOCKS; do [ ! -f "$main/$1/$parent/$l" ] || own=1; done
          [ "$own" = 0 ] || continue
        fi
        [ ! -L "$main/$1/$t" ] || continue
        printf '%s\n' "$1/${t#./}" | sed 's|^\./||'
      done
}

# fresh_all <folder>: every dependency folder in $TMP/targets is fresh against <folder>'s lockfiles.
fresh_all() {
  while IFS= read -r t; do fresh "$1" "$t" || return 1; done < "$TMP/targets"
}

# lock_places <lockfiles...>: the folders, relative to the worktree root ("." for the root), that hold one of the
# lockfiles here or in the main checkout, down to three levels. Dependency folders and .git are not searched.
lock_places() {
  n=$#
  for l in "$@"; do set -- "$@" -o -name "$l"; done
  shift "$n"
  shift
  { find . "$main" -maxdepth 4 \( -name node_modules -o -name .git -o -name "$DIR" \) -prune -o -type f \( "$@" \) \
    -print 2>/dev/null || true; } \
    | MAIN=$main awk 'BEGIN { m = ENVIRON["MAIN"] "/" }
        index($0, m) == 1 { $0 = "./" substr($0, length(m) + 1) }
        { sub(/\/[^\/]*$/, ""); print }' \
    | sort -u
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-setup.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
kinds > "$TMP/kinds"
: > "$TMP/restamp" # "<dep dir>|<folder>|<lockfiles>" for each folder the install command is run for
need_install=0
known=0
reused=0
while IFS='|' read -r DIR LOCKS MARKERS; do
  [ -n "$DIR" ] || continue
  # shellcheck disable=SC2086 # LOCKS is a list of plain file names
  lock_places $LOCKS > "$TMP/places"
  [ -s "$TMP/places" ] || continue
  known=1
  while IFS= read -r place; do
    case $place in .) where=. ;; ./*) where=${place#./} ;; *) continue ;; esac
    [ -d "$where" ] || continue # this package is not in this worktree
    targets "$where" > "$TMP/targets"
    # One decision per lockfile folder, for its own dependency folder and the nested ones (workspace packages).
    why=
    if [ -z "$METHOD" ]; then why="no copy-on-write clone on this file system"
    elif [ ! -s "$TMP/targets" ]; then why="not installed in the main checkout"
    else
      case $(lock_state "$where") in
        same) fresh_all "$where" || why="the main checkout's copy is older than its lockfile" ;;
        differs) why="lockfile differs from the main checkout" ;;
        *) why="no lockfile" ;;
      esac
    fi
    [ -s "$TMP/targets" ] || echo "$where/$DIR" | sed 's|^\./||' > "$TMP/targets"
    while IFS= read -r rel; do
      if [ -e "$rel" ]; then
        state=$(present_state "$where" "$rel")
        if [ "$state" = ok ]; then say "$rel: present and matches its lockfile"; continue; fi
        say "$rel: present, but $state"; need_install=1
        printf '%s|%s|%s\n' "$rel" "$where" "$LOCKS" >> "$TMP/restamp"
        continue # its stamp stays as it is, so a failed install leaves it out of date
      fi
      { [ -e "$(parent_of "$rel")" ] || [ -L "$(parent_of "$rel")" ]; } || continue # its package is not in this worktree
      if ! (walk_to "$(parent_of "$rel")") 2> /dev/null; then
        say "$rel: its folder is not a real folder inside this worktree (a symlink?); left to the install command"
        need_install=1; continue
      fi
      if [ -z "$why" ] && { ! ignored_in "$main" "$rel" || ! ignored_in "$top" "$rel"; }; then
        say "$rel: git does not ignore it, left to the install command"; need_install=1
        printf '%s|%s|%s\n' "$rel" "$where" "$LOCKS" >> "$TMP/restamp"; continue
      fi
      if [ -n "$why" ]; then
        say "$rel: $why"; need_install=1
        printf '%s|%s|%s\n' "$rel" "$where" "$LOCKS" >> "$TMP/restamp"; continue
      fi
      if [ "$DRY" = 1 ]; then say "$rel: would clone from the main checkout ($METHOD)"; reused=$((reused + 1)); continue; fi
      if clone "$rel" "$where"; then
        say "$rel: cloned from the main checkout (copy-on-write)"; reused=$((reused + 1))
      else
        say "$rel: clone failed"; need_install=1
        printf '%s|%s|%s\n' "$rel" "$where" "$LOCKS" >> "$TMP/restamp"
      fi
    done < "$TMP/targets"
  done < "$TMP/places"
done < "$TMP/kinds"

if [ "$known" = 0 ]; then
  if [ $# -gt 0 ]; then run_install "$@"; exit $?; fi
  say "no known dependency folder to reuse and no install command given; nothing to do"
  exit 0
fi
if [ "$need_install" = 1 ]; then
  run_install "$@" || { echo "$prog: some dependencies are not ready; pass the install command after --" >&2; exit 1; }
  if [ "$DRY" = 0 ]; then
    # The install command succeeded with the lockfiles as they are now: stamp the folders it was run for.
    while IFS='|' read -r rel where LOCKS; do
      if [ -d "$rel" ] && [ ! -L "$rel" ]; then
        write_stamp "$where" "$rel" || say "$rel: could not write its stamp; the next run installs again"
      fi
    done < "$TMP/restamp"
  fi
fi
say "ready ($reused reused)"
