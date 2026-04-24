#!/usr/bin/env bash
set -euo pipefail

: "${GATEWAY_URL:?GATEWAY_URL must be set}"
: "${FIXTURE_DIR:?FIXTURE_DIR must be set}"

if ! command -v grpcurl >/dev/null 2>&1; then
    echo "verify failed: grpcurl is not on PATH." >&2
    echo "  macOS: brew install grpcurl" >&2
    echo "  other: https://github.com/fullstorydev/grpcurl/releases" >&2
    exit 1
fi

host="${GATEWAY_URL#*://}"
host="${host%%[:/]*}"
port=80

for i in $(seq 1 30); do
    response=$(grpcurl -plaintext \
        -import-path "${FIXTURE_DIR}" -proto health.proto \
        -d '{"service":""}' \
        "${host}:${port}" grpc.health.v1.Health/Check 2>&1 || true)
    if grep -q '"status": "SERVING"' <<<"${response}"; then
        echo "ok: gRPC Health/Check returned SERVING"
        echo "${response}"
        exit 0
    fi
    echo "attempt ${i}: ${response}"
    sleep 2
done

echo "verify failed: never got SERVING from ${host}:${port}" >&2
exit 1
