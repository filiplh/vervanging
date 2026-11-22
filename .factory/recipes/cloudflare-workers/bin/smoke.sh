#!/usr/bin/env bash
# Smoke check after a deploy or a rollback: every path must answer with a 2xx status (redirects followed).
# Usage: smoke.sh <base URL> [<JSON list of paths>]     e.g. smoke.sh https://app.example.com '["/", "/health"]'
# Env: SMOKE_ATTEMPTS (default 6) and SMOKE_DELAY in seconds (default 5): the edge needs a few seconds to switch.
set -euo pipefail

base=${1:?usage: smoke.sh <base URL> [<JSON list of paths>]}
base=${base%/}
case $base in http://* | https://*) ;; *) base="https://$base" ;; esac
paths_json=${2:-'["/"]'}
attempts=${SMOKE_ATTEMPTS:-6}
delay=${SMOKE_DELAY:-5}

paths=()
while IFS= read -r path; do
  [ -n "$path" ] && paths+=("$path")
done < <(jq -r '.[]' <<<"$paths_json")
[ ${#paths[@]} -gt 0 ] || paths=(/)

failed=0
for path in "${paths[@]}"; do
  case $path in /*) ;; *) path="/$path" ;; esac
  url="$base$path"
  code=000
  for ((i = 1; i <= attempts; i++)); do
    code=$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 15 -H 'Cache-Control: no-cache' "$url" 2>/dev/null || true)
    code=${code:-000}
    case $code in 2??) break ;; esac
    [ "$i" -lt "$attempts" ] && sleep "$delay"
  done
  case $code in
    2??) echo "ok   $code $url" ;;
    *)
      echo "FAIL $code $url (after $attempts attempts)"
      failed=1
      ;;
  esac
done
exit "$failed"
