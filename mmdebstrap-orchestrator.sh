#!/bin/bash
set -euo pipefail

# mmdebstrap-orchestrator.sh
#
# Modular image builds. Runs one build script per image, logs the result,
# and reports each image's success/failure (with its digest) to Prometheus
# via emit_event.sh so the pipeline dashboard shows every image.
#
# Cron (0500 daily) - no IMAGES override, so the default list below is used:
#   0 5 * * * /root/bin/mmdebstrap-orchestrator.sh
# To build a subset by hand:
#   IMAGES="go node20" /root/bin/mmdebstrap-orchestrator.sh

# ---------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------
LOG="${LOG:-/root/bin/daily-build.log}"
IMAGES="${IMAGES:-base go node20 node22 node24 postgres18}"
BUILD_DIR="${BUILD_DIR:-/root/bin}"
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
DIGEST_BASE_URL="${DIGEST_BASE_URL:-http://localhost/images}"

# ---------------------------------------------------------------------
# 2. Status reporting (best-effort: can never fail or stop the build loop)
# ---------------------------------------------------------------------
emit_status() { "$EMIT" "$@" >> "$LOG" 2>&1 || true; }

# ---------------------------------------------------------------------
# 3. Build loop
# ---------------------------------------------------------------------
echo "=== $(date -Iseconds) : Starting daily build ===" >> "$LOG"

for img in $IMAGES; do
    echo "--- $(date -Iseconds) : Building $img ---" >> "$LOG"

    # Run the build script WITHOUT strict mode
    if "${BUILD_DIR}/mmdebstrap-build-${img}.sh" >> "$LOG" 2>&1; then
        echo "--- $(date -Iseconds) : $img build succeeded ---" >> "$LOG"
        DIGEST="$(curl -fsS "${DIGEST_BASE_URL}/debian13-${img}/digest-latest.txt" 2>/dev/null | cut -c1-12 || true)"
        emit_status build "debian13-${img}" success "${DIGEST}" 86400
    else
        echo "--- $(date -Iseconds) : $img build FAILED ---" >> "$LOG"
        emit_status build "debian13-${img}" fail "" 86400
        # Continue to next image - blast-radius protection
    fi
done

echo "=== $(date -Iseconds) : Daily build complete ===" >> "$LOG"
