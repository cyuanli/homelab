#!/usr/bin/env bash
# Sends one message to Hermes over peer dm and prints its reply (the hermes-inbox run's only tool).
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 '<message>'" >&2
    exit 2
fi

out="$(kubectl -n ai exec -i deploy/hermes -c hermes -- hermes peer dm --json local \
    <<< "Message from Claude Code (scheduled inbox run): $1" 2> /dev/null)"
jq -er '.reply' <<< "$out"
