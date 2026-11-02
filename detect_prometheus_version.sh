#!/usr/bin/env bash
set -euo pipefail

REPO_API="https://api.github.com/repos/prometheus/prometheus/releases"

LATEST_VERSION=$(
  curl -s "${REPO_API}" \
    | jq -r '
        .[]
        | select(.prerelease == false)
        | .tag_name
      ' \
    | sed 's/^v//' \
    | grep -vE '(dev|test|debug|rc|beta|alpha)' \
    | sort -V \
    | tail -n1
)

if [[ -z "${LATEST_VERSION}" ]]; then
    echo "ERROR: Could not detect a stable Prometheus version" >&2
    exit 5
fi

echo "${LATEST_VERSION}"


# from https://github.com/prometheus/prometheus I only detect the release candidates for version 3.16.0
