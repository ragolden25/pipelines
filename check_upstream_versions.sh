#!/usr/bin/env bash
# =====================================================================
# check_upstream_versions.sh -- independently verify that the packages in
# the Trixie repo are the latest upstream releases.
#
# Run it daily (it is separate from the weekly build scripts, so the
# dashboard shows a fresh "checked" time even when no build ran).
#
# For each package it
#   1. asks the project's own page for the newest release
#        nginx    nginx.org/download/            highest 1.x.y   (same rule as auto-build-nginx.sh)
#        openssl  GitHub releases of openssl     highest 3.5.x   (same rule as auto-build-openssl.sh)
#   2. reads what the Nucleus repo actually publishes, from the signed-index
#      source file dists/trixie/main/binary-amd64/Packages
#   3. compares the two upstream-style version numbers.
#
# Metrics (node_exporter textfile collector, one atomic file):
#   repo_version_current{package,published,upstream}   1 = repo has the latest
#                                                      0 = repo is behind / ahead
#                                                     -1 = could not be determined
#   upstream_check_timestamp_seconds{package}          when the check ran
#
# Also reports one job event (type "check") so the job-freshness table shows it.
# Never fails the cron job because a website was unreachable: that is reported
# as -1, not as a script error.
#
# Install:  /usr/local/bin/check_upstream_versions.sh   (mode 0755, runs as root)
# Cron:     30 6 * * * /usr/local/bin/check_upstream_versions.sh
# =====================================================================
set -u
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
REPO="${REPO:-/var/www/html/repos/nucleus}"
PACKAGES_FILE="${PACKAGES_FILE:-${REPO}/dists/trixie/main/binary-amd64/Packages}"
CURL=(curl -fsS --max-time 30 --retry 2)

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }

# ---- upstream lookups (print the version, or nothing on failure) -----------
upstream_nginx() {
  "${CURL[@]}" https://nginx.org/download/ 2>/dev/null \
    | grep -oP 'href="nginx-\K1\.[0-9]+\.[0-9]+(?=\.tar\.gz")' \
    | sort -V | tail -n 1
}
upstream_openssl() {
  "${CURL[@]}" https://api.github.com/repos/openssl/openssl/releases 2>/dev/null \
    | grep -oP '"tag_name":\s*"openssl-3\.5\.\d+"' \
    | grep -oP '3\.5\.\d+' \
    | sort -V | tail -n 1
}

# ---- what the repo publishes: upstream part of the highest version ---------
# "1.29.3+nucleus1" or "1:3.5.4-1+nucleus1" -> "1.29.3" / "3.5.4"
published_version() {
  local pkg="$1"
  [[ -r "$PACKAGES_FILE" ]] || return 0
  awk -v p="$pkg" '
    /^Package: / { cur = $2 }
    /^Version: / && cur == p { print $2 }' "$PACKAGES_FILE" \
    | sed -E 's/^[0-9]+://; s/[-+~].*$//' \
    | sort -V | tail -n 1
}

PACKAGES=(nginx openssl)
now="$(date +%s)"
bad=0
body=""

for pkg in "${PACKAGES[@]}"; do
  up="$(upstream_"$pkg" || true)"
  pub="$(published_version "$pkg" || true)"
  if [[ -z "$up" || -z "$pub" ]]; then
    val=-1; bad=1
  elif [[ "$up" == "$pub" ]]; then
    val=1
  else
    val=0
  fi
  echo "${pkg}: published=${pub:-?} upstream=${up:-?} -> ${val}"
  body+="repo_version_current{package=\"$(esc "$pkg")\",published=\"$(esc "${pub:-unknown}")\",upstream=\"$(esc "${up:-unknown}")\"} ${val}"$'\n'
  body+="upstream_check_timestamp_seconds{package=\"$(esc "$pkg")\"} ${now}"$'\n'
done

mkdir -p "$TEXTFILE_DIR" 2>/dev/null
out="${TEXTFILE_DIR}/repo_upstream_check.prom"
tmp="$(mktemp "${TEXTFILE_DIR}/.repo_upstream_check.XXXXXX")" || { echo "cannot write metrics" >&2; exit 1; }
{
  echo "# HELP repo_version_current 1 if the Nucleus repo publishes the newest upstream release, 0 if not, -1 if unknown."
  echo "# TYPE repo_version_current gauge"
  grep '^repo_version_current' <<<"$body"
  echo "# HELP upstream_check_timestamp_seconds Unix time the upstream check ran."
  echo "# TYPE upstream_check_timestamp_seconds gauge"
  grep '^upstream_check_timestamp_seconds' <<<"$body"
} > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$out"

# Job-freshness entry (daily). A website that could not be reached counts as a failed check.
/usr/local/bin/emit_event.sh check upstream-versions "$([[ $bad -eq 0 ]] && echo success || echo fail)" "" 86400 2>/dev/null || true
exit 0
