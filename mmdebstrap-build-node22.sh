#!/bin/bash
# PATH for cron/non-login shells (fix-cron-path.sh)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# mmdebstrap-build-node22.sh
#
# Builds container-forge/debian13-node22. The image is built under a
# :candidate tag and smoke-tested BEFORE it becomes :latest, so a broken
# build can never replace the last good image or its signed archives.
# Exit status: 0 only if the image was built, tested, exported and signed.

NODE22_OUTPUT_DIR="${NODE22_OUTPUT_DIR:-/var/www/html/images/debian13-node22}"
TAG="$(date +%Y%m%d)"
IMAGE="container-forge/debian13-node22"
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
# What this image must provide: Node, npm and pnpm (the Prometheus staging
# script runs pnpm in this image). Edit this line if the toolset changes.
SMOKE_CMD="${SMOKE_CMD:-node --version && npm --version && pnpm --version}"

fail() { echo "ERROR: $*" >&2; "$EMIT" build debian13-node22 fail "" 86400 >/dev/null 2>&1 || true; exit 1; }

echo "=== 22. Build debian13-node22 candidate image ==="
docker build \
        --add-host=trixie.nuc2.scires.com:192.168.110.213 \
        --no-cache -f "$NODE22_OUTPUT_DIR/Dockerfile.debian13.node22" -t "$IMAGE":candidate "$NODE22_OUTPUT_DIR" \
        || fail "docker build failed; keeping the previous $IMAGE:latest"

echo "=== 23. Smoke-test candidate, then promote to latest ==="
docker run --rm "$IMAGE":candidate bash -c "$SMOKE_CMD" \
        || fail "smoke test failed ($SMOKE_CMD); keeping the previous $IMAGE:latest"
docker tag "$IMAGE":candidate "$IMAGE":latest || fail "could not tag latest"
docker tag "$IMAGE":latest "$IMAGE":"$TAG"    || fail "could not tag $TAG"

echo "=== 24. Export debian13-node22 archives ==="
docker save "$IMAGE":"$TAG" | gzip > "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save ($TAG) failed"
docker save "$IMAGE":latest | gzip > "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save (latest) failed"

echo "=== 25. Digest & GPG signatures for debian13-node22 ==="
sha256sum "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz" | awk '{print $1}' > "$NODE22_OUTPUT_DIR/digest-$TAG.txt"
sha256sum "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz" | awk '{print $1}' > "$NODE22_OUTPUT_DIR/digest-latest.txt"

rc=0
for f in "debian13-node22-$TAG.digest.asc:digest-$TAG.txt" \
         "debian13-node22-latest.digest.asc:digest-latest.txt" \
         "debian13-node22-$TAG.tar.gz.asc:debian13-node22-$TAG.tar.gz" \
         "debian13-node22-latest.tar.gz.asc:debian13-node22-latest.tar.gz"; do
    gpg --batch --yes --pinentry-mode loopback --detach-sign \
        --output "$NODE22_OUTPUT_DIR/${f%%:*}" "$NODE22_OUTPUT_DIR/${f#*:}" || rc=1
done
[[ $rc -eq 0 ]] || fail "GPG signing failed"
echo "=== debian13-node22 build complete ==="
"$EMIT" build debian13-node22 success "$(cut -c1-12 "$NODE22_OUTPUT_DIR/digest-latest.txt")" 86400 >/dev/null 2>&1 || true
