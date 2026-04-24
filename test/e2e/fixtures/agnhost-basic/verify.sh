#!/usr/bin/env bash
# Verifies that Emissary routes /backend/* to the agnhost service and that
# agnhost's /echo handler sees our query string intact (i.e. the request made
# the full round trip through Envoy, not just a generic 200 from somewhere).
set -euo pipefail

: "${GATEWAY_URL:?GATEWAY_URL must be set}"

token="agnhost-probe-$(date +%s)-${RANDOM}"
url="${GATEWAY_URL}/backend/echo?msg=${token}"

for i in $(seq 1 30); do
    code=$(curl -sS -o /tmp/e2e-body -w '%{http_code}' "${url}" || echo 000)
    if [[ "${code}" == "200" ]] && grep -q "${token}" /tmp/e2e-body; then
        echo "ok: got HTTP 200 with echoed token"
        cat /tmp/e2e-body; echo
        exit 0
    fi
    echo "attempt ${i}: HTTP ${code}"
    sleep 2
done

echo "verify failed: never got HTTP 200 with echoed token at ${url}" >&2
echo "last response body:"
cat /tmp/e2e-body 2>/dev/null || true
echo
exit 1
