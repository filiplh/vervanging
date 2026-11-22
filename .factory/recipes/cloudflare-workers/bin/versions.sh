#!/usr/bin/env bash
# Reads a Worker's versions from Cloudflare and prints key=value lines for $GITHUB_OUTPUT.
#   versions.sh live <worker>       exists=true|false, split=true|false, version_id, tag, commit of the live version
#   versions.sh previous <worker>   version_id, tag, commit of the newest earlier deployment that ran another
#                                   version: what a rollback without a version id restores
#   versions.sh tag <worker> <id>   tag, commit of that version
# An empty value means unknown, and unknown always holds. `commit` is a full SHA, given only when the version's
# message is exactly the factory's (`factory <target> production <40-hex SHA>`) and its tag is the first 12
# characters of that SHA: a 12-character tag alone could be matched by another commit. While traffic is split
# between versions (a gradual rollout), `split=true` and the live commit is unknown. Every value is checked against
# a strict character set before it is printed, so nothing Cloudflare returns can add a line to $GITHUB_OUTPUT.
# Env: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (only ever from CI secrets), WRANGLER (the pinned command).
set -euo pipefail

command=${1:?usage: versions.sh live|previous|tag <worker> [<version id>]}
worker=${2:?worker name missing}
: "${WRANGLER:?WRANGLER must hold the pinned wrangler command}"

info_of() {
  # "<tag><TAB><commit>" of one version.
  # shellcheck disable=SC2086 # WRANGLER is a command line on purpose
  $WRANGLER versions view "$1" --name "$worker" --json | jq -r '
    def safe(re): if type == "string" and test(re) then . else "" end;
    (.annotations["workers/tag"] | safe("\\A[0-9A-Za-z._-]{1,64}\\z")) as $tag
    | ((.annotations["workers/message"] | safe("\\Afactory [0-9A-Za-z._-]+ production [0-9a-f]{40}\\z"))
       | (capture("(?<sha>[0-9a-f]{40})\\z").sha // "")) as $sha
    | [$tag, (if $sha != "" and $tag == $sha[0:12] then $sha else "" end)] | @tsv'
}

print_version() {
  local id=$1 info="" tag="" commit=""
  if [ -n "$id" ]; then
    # Read first, split after: a temporary IFS on `read ... < <(info_of ...)` reaches the process substitution, and
    # $WRANGLER (`<interpreter> <script>`) would then run as one command name.
    info=$(info_of "$id") || info=""
    IFS=$'\t' read -r tag commit <<<"$info" || true
  fi
  printf 'version_id=%s\ntag=%s\ncommit=%s\n' "$id" "$tag" "$commit"
}

version_ids() {
  # The version id with the most traffic of each deployment given on stdin, only if it is a well-formed id.
  jq -r 'def safe: if type == "string" and test("\\A[0-9a-f-]{1,64}\\z") then . else "" end;
         (.versions // []) | (max_by(.percentage) // {}) | (.version_id | safe)'
}

case $command in
  live)
    # An explicit template: a bare mktemp ignores TMPDIR on macOS. The file goes away on every way out of the script.
    body=
    trap '[ -z "$body" ] || rm -f -- "$body"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    body=$(mktemp "${TMPDIR:-/tmp}/factory-versions.XXXXXX")
    status=$(curl -sS -o "$body" -w '%{http_code}' \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/services/$worker")
    case $status in
      404)
        printf 'exists=false\nsplit=false\nversion_id=\ntag=\ncommit=\n'
        exit 0
        ;;
      200) ;;
      *)
        echo "::error title=Cloudflare::Could not read Worker $worker (HTTP $status): $(jq -c '.errors' "$body" 2>/dev/null)" >&2
        exit 1
        ;;
    esac
    echo exists=true
    # shellcheck disable=SC2086
    if ! deployment=$($WRANGLER deployments status --name "$worker" --json); then
      echo "::warning title=Cloudflare::Worker $worker exists but has no readable deployment." >&2
      printf 'split=false\nversion_id=\ntag=\ncommit=\n'
      exit 0
    fi
    if [ "$(jq '(.versions // []) | length' <<<"$deployment")" -gt 1 ]; then
      echo split=true
      printf 'version_id=%s\ntag=\ncommit=\n' "$(version_ids <<<"$deployment")"
      exit 0
    fi
    echo split=false
    print_version "$(version_ids <<<"$deployment")"
    ;;
  previous)
    # shellcheck disable=SC2086
    deployments=$($WRANGLER deployments list --name "$worker" --json)
    id=$(jq -r '
      def safe: if type == "string" and test("\\A[0-9a-f-]{1,64}\\z") then . else "" end;
      [ sort_by(.created_on) | reverse | .[] | (.versions // []) | (max_by(.percentage) // {}) | (.version_id | safe) ]
      | .[0] as $live | map(select(. != $live and . != "")) | .[0] // ""' <<<"$deployments")
    print_version "$id"
    ;;
  tag)
    id=${3:?version id missing}
    if ! [[ $id =~ ^[0-9a-f-]{1,64}$ ]]; then
      printf 'version_id=\ntag=\ncommit=\n'
      exit 0
    fi
    print_version "$id"
    ;;
  *)
    echo "versions.sh: unknown command $command" >&2
    exit 64
    ;;
esac
