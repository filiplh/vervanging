#!/usr/bin/env bash
# One issue per marker, opened and closed by the deploy workflows, so a deploy that is held night after night, or a
# commit that fails twice, updates one issue instead of opening many.
#   issue.sh open <marker> <title> <body file> [<label>,<label>...]   opens or updates; prints the issue URL
#   issue.sh close <marker> <comment>                                 closes the open issue with that marker, if any
#   issue.sh note <marker> <body file>                                comments on the open issue with that marker, if any
# Env: GH_TOKEN (the workflow's own token, issues: write) and REPO (owner/name).
set -euo pipefail

command=${1:?usage: issue.sh open|close <marker> ...}
marker="<!-- ${2:?marker missing} -->"
: "${REPO:?REPO missing}"

find_open() {
  gh issue list --repo "$REPO" --state open --author 'app/github-actions' --limit 200 --json number,body \
    | jq -r --arg m "$marker" '[.[] | select(.body | startswith($m))][0].number // ""'
}

case $command in
  open)
    title=${3:?title missing}
    body_file=${4:?body file missing}
    labels=${5:-}
    # An explicit template: a bare mktemp ignores TMPDIR on macOS. The file goes away on every way out of the script.
    full=
    trap '[ -z "$full" ] || rm -f -- "$full"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    full=$(mktemp "${TMPDIR:-/tmp}/factory-issue.XXXXXX")
    { echo "$marker"; cat "$body_file"; } >"$full"
    number=$(find_open)
    if [ -n "$number" ]; then
      gh issue edit "$number" --repo "$REPO" --title "$title" --body-file "$full" >/dev/null
      gh issue view "$number" --repo "$REPO" --json url --jq .url
    elif [ -n "$labels" ] && url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$full" --label "$labels"); then
      echo "$url"
    else
      [ -n "$labels" ] && echo "::warning::Could not add labels $labels (missing from the repo?); opening the issue without them." >&2
      gh issue create --repo "$REPO" --title "$title" --body-file "$full"
    fi
    ;;
  close)
    comment=${3:?comment missing}
    number=$(find_open)
    if [ -n "$number" ]; then
      gh issue close "$number" --repo "$REPO" --comment "$comment" >/dev/null
      echo "closed #$number"
    fi
    ;;
  note)
    body_file=${3:?body file missing}
    number=$(find_open)
    if [ -n "$number" ]; then
      gh issue comment "$number" --repo "$REPO" --body-file "$body_file" >/dev/null
      echo "noted on #$number"
    fi
    ;;
  *)
    echo "issue.sh: unknown command $command" >&2
    exit 64
    ;;
esac
