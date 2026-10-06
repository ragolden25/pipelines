#!/bin/bash
# mmdebstrap-build-node24.sh
#
# Builds container-forge/debian13-node24. The image is built under a
# :candidate tag and smoke-tested BEFORE it becomes :latest, so a broken
# build can never replace the last good image or its signed archives.
# Exit status: 0 only if the image was built, tested, exported and signed.

NODE24_OUTPUT_DIR="${NODE24_OUTPUT_DIR:-/var/www/html/images/debian13-node24}"
TAG="$(date +%Y%m%d)"
IMAGE="container-forge/debian13-node24"
# What this image must provide: Node >= 24.20 (Prometheus >= 3.15 UI build), npm and
# pnpm. Edit this line if the required toolset changes.
SMOKE_CMD="${SMOKE_CMD:-node --version && npm --version && pnpm --version && node -e 'const [a,b]=process.versions.node.split(\".\").map(Number); process.exit(a>24||(a===24&&b>=20)?0:1)'}"

fail() { echo "ERROR: $*" >&2; exit 1; }

echo "=== 1. Build debian13-node24 candidate image ==="
docker build \
        --add-host=trixie.nuc2.scires.com:192.168.110.213 \
        --no-cache -f "$NODE24_OUTPUT_DIR/Dockerfile.debian13.node24" -t "$IMAGE":candidate "$NODE24_OUTPUT_DIR" \
        || fail "docker build failed; keeping the previous $IMAGE:latest"

echo "=== 2. Smoke-test candidate, then promote to latest ==="
docker run --rm "$IMAGE":candidate bash -c "$SMOKE_CMD" \
        || fail "smoke test failed ($SMOKE_CMD); keeping the previous $IMAGE:latest"
docker tag "$IMAGE":candidate "$IMAGE":latest || fail "could not tag latest"
docker tag "$IMAGE":latest "$IMAGE":"$TAG"    || fail "could not tag $TAG"

echo "=== 3. Export debian13-node24 archives ==="
docker save "$IMAGE":"$TAG" | gzip > "$NODE24_OUTPUT_DIR/debian13-node24-$TAG.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save ($TAG) failed"
docker save "$IMAGE":latest | gzip > "$NODE24_OUTPUT_DIR/debian13-node24-latest.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save (latest) failed"

echo "=== 4. Digest & GPG signatures for debian13-node24 ==="
sha256sum "$NODE24_OUTPUT_DIR/debian13-node24-$TAG.tar.gz" | awk '{print $1}' > "$NODE24_OUTPUT_DIR/digest-$TAG.txt"
sha256sum "$NODE24_OUTPUT_DIR/debian13-node24-latest.tar.gz" | awk '{print $1}' > "$NODE24_OUTPUT_DIR/digest-latest.txt"

rc=0
for f in "debian13-node24-$TAG.digest.asc:digest-$TAG.txt" \
         "debian13-node24-latest.digest.asc:digest-latest.txt" \
         "debian13-node24-$TAG.tar.gz.asc:debian13-node24-$TAG.tar.gz" \
         "debian13-node24-latest.tar.gz.asc:debian13-node24-latest.tar.gz"; do
    gpg --batch --yes --pinentry-mode loopback --detach-sign \
        --output "$NODE24_OUTPUT_DIR/${f%%:*}" "$NODE24_OUTPUT_DIR/${f#*:}" || rc=1
done
[[ $rc -eq 0 ]] || fail "GPG signing failed"
echo "=== debian13-node24 build complete ==="
