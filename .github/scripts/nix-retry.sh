#!/usr/bin/env bash
# Retry only explicit transient Nix download failures, not build/evaluation errors.
set -euo pipefail

if (( $# == 0 )); then
  echo 'Usage: nix-retry.sh <command> [args...]' >&2
  exit 2
fi

log=$(mktemp)
trap 'rm -f -- "$log"' EXIT
export NO_COLOR=1

# Match errors, not warnings: Nix may recover from a warning itself.
network_error='^[[:space:]]*error:.*(unable to download|failed to download|unable to fetch|failed to fetch|cannot download|could not download).*(HTTP (error|status( code)?) (408|416|429|5[0-9]{2})([^0-9]|$)|connection (reset|refused|timed out|closed)|timed out|timeout|temporary failure in name resolution|could not resolve (host|proxy)|failed (sending data|to connect)|failure when receiving data|unexpected end of file)'
permanent_error='^[[:space:]]*(error:.*(hash mismatch|syntax error|assertion.*failed|undefined variable|attribute .*missing|option .*does not exist|infinite recursion|No space left on device|permission denied|builder .*failed with exit code)|Reason:.*(builder|build process).*(failed|exit code))'

for attempt in 1 2 3; do
  echo "Nix attempt ${attempt}/3: $*"
  if "$@" 2>&1 | tee "$log"; then
    exit 0
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  status=${statuses[0]}
  if (( statuses[1] != 0 )); then
    echo 'Unable to capture Nix output; not retrying.' >&2
    exit "${statuses[1]}"
  fi

  if (( attempt == 3 )) || ! grep -Eiq "$network_error" "$log" || grep -Eiq "$permanent_error" "$log"; then
    exit "$status"
  fi

  delay=$((attempt * 30))
  echo "::warning::Transient Nix download failure (attempt ${attempt}/3); retrying in ${delay}s."
  sleep "$delay"
done
