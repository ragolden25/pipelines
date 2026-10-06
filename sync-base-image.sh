#!/bin/bash

set -euo pipefail
umask 022

SERVER_BASE_URL=http://container-forge/images
WORKDIR="/opt/ansible/tmp"

# Status reporting to Prometheus (via emit_event.sh). CURRENT names the step in
# progress; if the script dies, the EXIT trap reports that step as failed.
# emit_status can never fail the sync, even if emit_event.sh is missing.
emit_status() { /usr/local/bin/emit_event.sh "$@" || true; }
CURRENT="setup"
trap 'rc=$?; if [[ $rc -ne 0 && -n "$CURRENT" ]]; then emit_status sync "$CURRENT" fail "" 86400; fi; exit $rc' EXIT

# Ensure temp workspace exists
mkdir -p "$WORKDIR"

# Determine current quarter
QUARTER_INFO=$(/opt/ansible/files/common/scripts/determine_quarters.sh)
CURRENT_QUARTER=$(echo "$QUARTER_INFO" | grep '^quarter=' | cut -d= -f2)

IMG_DIR="/opt/ansible/files/avocado/${CURRENT_QUARTER}/images"
IMG2_DIR="/opt/ansible/files/grafana/${CURRENT_QUARTER}/images"
PROV_DIR="/opt/ansible/files/avocado/${CURRENT_QUARTER}/provenance"
GRAF_DIR="/opt/ansible/files/grafana/${CURRENT_QUARTER}/provenance"

DF_AVO_DIR="/opt/ansible/files/avocado/${CURRENT_QUARTER}/dockerfiles"
DF_GRAF_DIR="/opt/ansible/files/grafana/${CURRENT_QUARTER}/dockerfiles"

mkdir -p "$IMG_DIR" "$IMG2_DIR" \
         "$PROV_DIR/container-forge" "$GRAF_DIR/container-forge" \
         "$DF_AVO_DIR" "$DF_GRAF_DIR"

echo "[$(date)] Determined current quarter: ${CURRENT_QUARTER}"
echo "[$(date)] Image directory: ${IMG_DIR}"
echo "[$(date)] Provenance directory: ${PROV_DIR}"
echo "[$(date)] Workspace directory: ${WORKDIR}"

# Ensure container-forge GPG public key is present and current
echo "[$(date)] Ensuring container-forge GPG public key is present..."

KEY_URL="${SERVER_BASE_URL}/debian13-base/container-forge.pub"
KEY_TMP="${WORKDIR}/container-forge.pub"

wget -q -O "$KEY_TMP" "$KEY_URL"

gpg --batch --yes --import "$KEY_TMP"

if ! gpg --list-keys "container-forge" >/dev/null 2>&1; then
    echo "[ERROR] Failed to import container-forge public key."
    exit 1
fi

echo "[$(date)] container-forge GPG key imported and verified."
emit_status sync setup success "" 86400

# Format: SUBDIR|TAR_PREFIX|DOCKERFILE_NAME|IMAGE_NAME|DEST
# DEST: "both" copies to avocado + grafana (existing behavior).
#       "avocado" or "grafana" copies to only that stack's directories.
TARGETS=(
    "debian13-base|debian13-base-latest|Dockerfile.debian13.slim|container-forge/debian13-slim|both"
    "debian13-go|debian13-go-latest|Dockerfile.debian13.go|container-forge/debian13-go|both"
    "debian13-node22|debian13-node22-latest|Dockerfile.debian13.node22|container-forge/debian13-node22|both"
    "debian13-node24|debian13-node24-latest|Dockerfile.debian13.node24|container-forge/debian13-node24|grafana"
    "debian13-postgres18|debian13-postgres18-latest|Dockerfile.debian13.postgres18|container-forge/debian13-postgres18|avocado"
)

for TARGET in "${TARGETS[@]}"; do
    IFS="|" read -r SUBDIR TAR_PREFIX DF_NAME IMG_NAME DEST <<< "$TARGET"
    CURRENT="$SUBDIR"

    echo "========================================================="
    echo "[$(date)] Processing target image: ${SUBDIR} (dest: ${DEST})"
    echo "========================================================="

    BASE_URL="${SERVER_BASE_URL}/${SUBDIR}"

    IMAGE_URL="${BASE_URL}/${TAR_PREFIX}.tar.gz"
    TAR_SIG_URL="${BASE_URL}/${TAR_PREFIX}.tar.gz.asc"
    DIGEST_SIG_URL="${BASE_URL}/digest-latest.digest.asc"

    if ! wget -q --spider "${DIGEST_SIG_URL}"; then
        DIGEST_SIG_URL="${BASE_URL}/${SUBDIR}-latest.digest.asc"
        [[ "$SUBDIR" == "debian13-go" ]] && DIGEST_SIG_URL="${BASE_URL}/debian13-go-latest.digest.asc"
        [[ "$SUBDIR" == "debian13-node22" ]] && DIGEST_SIG_URL="${BASE_URL}/debian13-node22-latest.digest.asc"
        [[ "$SUBDIR" == "debian13-distroless" ]] && DIGEST_SIG_URL="${BASE_URL}/debian13-distroless-latest.digest.asc"
    fi

    DIGEST_URL="${BASE_URL}/digest-latest.txt"
    DOCKERFILE_URL="${BASE_URL}/${DF_NAME}"

    TMP_IMG="${WORKDIR}/${TAR_PREFIX}.tar.gz"
    TMP_TAR_SIG="${WORKDIR}/${TAR_PREFIX}.tar.gz.asc"
    TMP_DIGEST_SIG="${WORKDIR}/${SUBDIR}-latest.digest.asc"
    TMP_DIGEST="${WORKDIR}/${SUBDIR}-digest-latest.txt"
    TMP_DOCKERFILE="${WORKDIR}/${DF_NAME}"

    echo "[$(date)] Downloading artifacts for ${SUBDIR}..."
    wget -q -O "$TMP_IMG" "$IMAGE_URL"
    wget -q -O "$TMP_TAR_SIG" "$TAR_SIG_URL"
    wget -q -O "$TMP_DIGEST_SIG" "$DIGEST_SIG_URL"
    wget -q -O "$TMP_DIGEST" "$DIGEST_URL"
    wget -q -O "$TMP_DOCKERFILE" "$DOCKERFILE_URL"

    chmod 644 "$TMP_IMG" "$TMP_TAR_SIG" "$TMP_DIGEST_SIG" "$TMP_DIGEST" "$TMP_DOCKERFILE"

    echo "[$(date)] Verifying tarball signature for ${SUBDIR}..."
    gpg --verify "$TMP_TAR_SIG" "$TMP_IMG"

    echo "[$(date)] Verifying digest signature for ${SUBDIR}..."
    gpg --verify "$TMP_DIGEST_SIG" "$TMP_DIGEST"

    echo "[$(date)] Verifying digest matches downloaded tarball..."
    ACTUAL_DIGEST=$(sha256sum "$TMP_IMG" | awk '{print $1}')
    EXPECTED_DIGEST=$(cat "$TMP_DIGEST")

    if [[ "$ACTUAL_DIGEST" != "$EXPECTED_DIGEST" ]]; then
        echo "[ERROR] Digest mismatch on ${SUBDIR} — refusing to load image."
        exit 1
    fi

    echo "[$(date)] All GPG + digest checks passed for ${SUBDIR}."

    VERIFY_LOG="${PROV_DIR}/verify-${SUBDIR}-latest.log"

    {
        echo "Verification Timestamp: $(date)"
        echo "Target Image: $SUBDIR"
        echo "Verified Image File: $TMP_IMG"
        echo "Verified Tarball Signature: $TMP_TAR_SIG"
        echo "Verified Digest Signature: $TMP_DIGEST_SIG"
        echo "Verified Digest File: $TMP_DIGEST"
        echo
        echo "Container-FORGE Key Fingerprint:"
        gpg --fingerprint "container-forge"
        echo
        echo "Digest Expected: $EXPECTED_DIGEST"
        echo "Digest Actual: $ACTUAL_DIGEST"
        echo
        echo "Result: VERIFIED OK"
    } | tee "$VERIFY_LOG"

    chown ansible:ansible "$VERIFY_LOG"
    chmod 644 "$VERIFY_LOG"

    echo "[$(date)] Loading ${IMG_NAME}:latest into local Docker host..."
    docker load -i "$TMP_IMG"
    docker tag "${IMG_NAME}:latest" "${IMG_NAME}:protected"

    echo "[$(date)] Tagged ${IMG_NAME}:protected successfully."

    if [[ "$DEST" == "both" || "$DEST" == "avocado" ]]; then
        cp "$TMP_IMG" "$IMG_DIR/"
        cp "$TMP_TAR_SIG" "$PROV_DIR/container-forge/"
        cp "$TMP_DIGEST_SIG" "$PROV_DIR/container-forge/"
        cp "$TMP_DIGEST" "$PROV_DIR/container-forge/"
        cp "$TMP_DOCKERFILE" "$DF_AVO_DIR/$DF_NAME"
        chown -R ansible:ansible "$DF_AVO_DIR/$DF_NAME" "$IMG_DIR"
    fi

    if [[ "$DEST" == "both" || "$DEST" == "grafana" ]]; then
        cp "$TMP_IMG" "$IMG2_DIR/"
        cp "$VERIFY_LOG" "${GRAF_DIR}/verify-${SUBDIR}-latest.log"
        cp "$TMP_TAR_SIG" "$GRAF_DIR/container-forge/"
        cp "$TMP_DIGEST_SIG" "$GRAF_DIR/container-forge/"
        cp "$TMP_DIGEST" "$GRAF_DIR/container-forge/"
        cp "$TMP_DOCKERFILE" "$DF_GRAF_DIR/$DF_NAME"
        chown -R ansible:ansible "$DF_GRAF_DIR/$DF_NAME" "$IMG2_DIR"
    fi

    rm -f "$TMP_IMG" "$TMP_TAR_SIG" "$TMP_DIGEST_SIG" "$TMP_DIGEST" "$TMP_DOCKERFILE"

    echo "[$(date)] Successfully processed and delivered ${SUBDIR}."
    emit_status sync "$SUBDIR" success "${EXPECTED_DIGEST:0:12}" 86400
done

CURRENT=""

echo "========================================================="
echo "[$(date)] Full sync completed for debian13-base, debian13-go, debian13-node22, debian13-node24, and debian13-postgres18."
echo "========================================================="
