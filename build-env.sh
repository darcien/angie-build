# Shared build pins, sourced by build.sh and tests/repro.sh (single source:
# the ARG defaults pinned in the Dockerfile). Not executable on purpose.
#
# SOURCE_DATE_EPOCH: passed explicitly so BuildKit stamps image
# config/history timestamps with it (it only honors it as a build arg).
# BUILD_CREATED: RFC 3339 rendering of the same epoch for the OCI
# .created label — derived, never wall clock, so repro builds agree.
SOURCE_DATE_EPOCH="$(sed -n 's/^ARG SOURCE_DATE_EPOCH=//p' Dockerfile)"
[ -n "$SOURCE_DATE_EPOCH" ] || { echo 'SOURCE_DATE_EPOCH pin missing from Dockerfile' >&2; exit 1; }
# date -r (BSD/macOS) vs -d @ (GNU/coreutils)
BUILD_CREATED="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
[ -n "$BUILD_CREATED" ] || { echo 'cannot render BUILD_CREATED from SOURCE_DATE_EPOCH' >&2; exit 1; }
