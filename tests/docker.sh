#!/usr/bin/env bash
# Run tests/run.sh in a throwaway Debian container, so mosquitto does not
# need to be installed locally. Uses docker, or podman if docker is missing.
#
# Usage: tests/docker.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

if command -v docker >/dev/null; then
    runtime=docker
elif command -v podman >/dev/null; then
    runtime=podman
else
    echo "docker or podman is required" >&2
    exit 1
fi

# The repo is mounted read-only and copied, so the tests cannot change it.
exec "$runtime" run --rm --init -v "$root:/src:ro,z" docker.io/library/debian:12-slim bash -c '
    set -e
    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        mosquitto mosquitto-clients jq >/dev/null
    cp -r /src /work
    /work/tests/run.sh
'
