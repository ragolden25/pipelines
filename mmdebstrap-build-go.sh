#!/bin/bash
# PATH for cron/non-login shells (fix-cron-path.sh)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# mmdebstrap-build-go.sh
#
# Builds container-forge/debian13-go. The image is built under a
# :candidate tag and smoke-tested BEFORE it becomes :latest, so a broken
# build can never replace the last good image or its signed archives.
# Exit status: 0 only if the image was built, tested, exported and signed.

GO_OUTPUT_DIR="${GO_OUTPUT_DIR:-/var/www/html/images/debian13-go}"
TAG="$(date +%Y%m%d)"
IMAGE="container-forge/debian13-go"
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
# What this image must provide: the Go toolchain. Edit this line if the toolset changes.
SMOKE_CMD="${SMOKE_CMD:-go version}"

fail() { echo "ERROR: $*" >&2; "$EMIT" build debian13-go fail "" 86400 >/dev/null 2>&1 || true; exit 1; }

echo "=== 16. Build debian13-go candidate image ==="
docker build \
        --add-host=trixie.nuc2.scires.com:192.168.110.213 \
        --no-cache -f "$GO_OUTPUT_DIR/Dockerfile.debian13.go" -t "$IMAGE":candidate "$GO_OUTPUT_DIR" \
        || fail "docker build failed; keeping the previous $IMAGE:latest"

echo "=== 16b. Smoke-test candidate, then promote to latest ==="
docker run --rm "$IMAGE":candidate bash -c "$SMOKE_CMD" \
        || fail "smoke test failed ($SMOKE_CMD); keeping the previous $IMAGE:latest"
docker tag "$IMAGE":candidate "$IMAGE":latest || fail "could not tag latest"
docker tag "$IMAGE":latest "$IMAGE":"$TAG" || fail "could not tag $TAG"

echo "=== 17. Export debian13-go archives ==="
docker save "$IMAGE":"$TAG" | gzip > "$GO_OUTPUT_DIR/debian13-go-$TAG.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save ($TAG) failed"
docker save "$IMAGE":latest | gzip > "$GO_OUTPUT_DIR/debian13-go-latest.tar.gz"
[[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || fail "docker save (latest) failed"

echo "=== 18. Digest & GPG signatures for debian13-go ==="
sha256sum "$GO_OUTPUT_DIR/debian13-go-$TAG.tar.gz" | awk '{print $1}' > "$GO_OUTPUT_DIR/digest-$TAG.txt"
sha256sum "$GO_OUTPUT_DIR/debian13-go-latest.tar.gz" | awk '{print $1}' > "$GO_OUTPUT_DIR/digest-latest.txt"

rc=0
for f in "debian13-go-$TAG.digest.asc:digest-$TAG.txt" \
         "debian13-go-latest.digest.asc:digest-latest.txt" \
         "debian13-go-$TAG.tar.gz.asc:debian13-go-$TAG.tar.gz" \
         "debian13-go-latest.tar.gz.asc:debian13-go-latest.tar.gz"; do
    gpg --batch --yes --pinentry-mode loopback --detach-sign \
        --output "$GO_OUTPUT_DIR/${f%%:*}" "$GO_OUTPUT_DIR/${f#*:}" || rc=1
done
[[ $rc -eq 0 ]] || fail "GPG signing failed"
echo "=== debian13-go build complete ==="

"$EMIT" build debian13-go success "$(cut -c1-12 "$GO_OUTPUT_DIR/digest-latest.txt")" 86400 >/dev/null 2>&1 || true
