#!/usr/bin/env bash
# Usage: smoke-test.sh <path-prefix e.g. /dev-bluegreen-preview> <expected-version>
#
# Hits the shared ingress host "ai-poc-ingress" via --resolve (it isn't
# publicly DNS-resolvable, only present in hosts files / resolved via
# --resolve here) over the NodePort HTTPS port 31083, and asserts:
#   1. HTTP 200 from <path>/actuator/health
#   2. /version reports the version we just deployed (proves this really is
#      the new preview pod, not a stale one)
set -euo pipefail

PATH_PREFIX="$1"
EXPECTED_VERSION="$2"
HOST="ai-poc-ingress"
PORT="31083"
BASE="https://${HOST}:${PORT}${PATH_PREFIX}"

echo "Smoke testing ${BASE} (expecting version=${EXPECTED_VERSION})"

HEALTH_CODE=$(curl -sk --resolve "${HOST}:${PORT}:127.0.0.1" -o /tmp/health.json -w '%{http_code}' "${BASE}/actuator/health")
cat /tmp/health.json
if [ "$HEALTH_CODE" != "200" ]; then
  echo "FAIL: /actuator/health returned HTTP ${HEALTH_CODE}"
  exit 1
fi

VERSION_JSON=$(curl -sk --resolve "${HOST}:${PORT}:127.0.0.1" "${BASE}/version")
echo "version response: ${VERSION_JSON}"
ACTUAL_VERSION=$(echo "$VERSION_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")

if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "FAIL: expected version ${EXPECTED_VERSION}, got ${ACTUAL_VERSION}"
  exit 1
fi

echo "PASS: ${BASE} is healthy and serving version ${ACTUAL_VERSION}"
