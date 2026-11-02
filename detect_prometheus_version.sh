#!/usr/bin/env bash
# Prints the newest Prometheus version that is safe to stage:
#   - a published release (not a draft, not marked pre-release on GitHub)
#   - a plain X.Y.Z version (no -rc/-beta/-alpha/dev/test/debug suffix)
#   - whose linux-amd64 tarball is actually attached to the release
# The asset check covers the window right after upstream publishes a release but before
# their CI has uploaded the binaries: that release is skipped until the tarball exists,
# and the previous version (e.g. 3.15.1) is used instead.
set -euo pipefail

REPO_API="https://api.github.com/repos/prometheus/prometheus/releases?per_page=100"
ARCH="${PROM_ARCH:-linux-amd64}"

json=$(curl -sfL "${REPO_API}") || {
    echo "ERROR: GitHub API request failed (network or rate limit)" >&2
    exit 5
}

LATEST_VERSION=$(
  jq -r --arg arch "$ARCH" '
      .[]
      | select(.draft == false and .prerelease == false)
      | (.tag_name | ltrimstr("v")) as $v
      | select($v | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | select(any(.assets[]?; .name == ("prometheus-" + $v + "." + $arch + ".tar.gz")))
      | $v
    ' <<<"$json" \
    | sort -V \
    | tail -n1
)

if [[ -z "${LATEST_VERSION}" ]]; then
    echo "ERROR: Could not detect a stable Prometheus version" >&2
    exit 5
fi

echo "${LATEST_VERSION}"
