#!/usr/bin/env bash
set -euo pipefail

missing=()
for command_name in git node npm gh awk sed grep head wc sort tail tr; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing+=("$command_name")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::runner is missing required commands: ${missing[*]}"
  exit 1
fi
