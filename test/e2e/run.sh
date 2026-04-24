#!/usr/bin/env bash
# Iterate every fixture under test/e2e/fixtures/, apply its manifests, run its
# verify.sh, and tear down. Each fixture is a directory containing:
#   - manifests.yaml : kubectl apply'd into $NAMESPACE
#   - verify.sh      : exit 0 = pass; receives GATEWAY_URL, NAMESPACE, FIXTURE_DIR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FIXTURES_DIR="${FIXTURES_DIR:-${SCRIPT_DIR}/fixtures}"
NAMESPACE="${NAMESPACE:-emissary}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"

export GATEWAY_URL NAMESPACE

failed=()
passed=()

for fixture_dir in "${FIXTURES_DIR}"/*/; do
    name=$(basename "${fixture_dir%/}")
    manifests="${fixture_dir}manifests.yaml"
    verify="${fixture_dir}verify.sh"

    if [[ ! -f "${manifests}" || ! -f "${verify}" ]]; then
        echo "skip: ${name} (needs manifests.yaml and verify.sh)" >&2
        continue
    fi

    echo
    echo "=== fixture: ${name} ==="
    kubectl apply -n "${NAMESPACE}" -f "${manifests}"

    export FIXTURE_DIR="${fixture_dir%/}"
    if timeout "${VERIFY_TIMEOUT}" bash "${verify}"; then
        echo "PASS: ${name}"
        passed+=("${name}")
    else
        echo "FAIL: ${name}" >&2
        failed+=("${name}")
        echo "--- diagnostics for ${name} ---"
        kubectl -n "${NAMESPACE}" get pods,svc 2>&1 || true
        kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name=emissary-ingress --tail=200 2>&1 || true
    fi

    kubectl delete -n "${NAMESPACE}" -f "${manifests}" --ignore-not-found --wait=false 2>&1 || true
done

echo
echo "=== results ==="
echo "passed (${#passed[@]}): ${passed[*]:-}"
echo "failed (${#failed[@]}): ${failed[*]:-}"
[[ ${#failed[@]} -eq 0 ]]
