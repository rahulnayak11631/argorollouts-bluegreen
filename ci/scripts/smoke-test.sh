#!/usr/bin/env bash
# Usage: smoke-test.sh <path-prefix e.g. /dev-bluegreen-preview> <expected-version>
#
# Hits the shared ingress host "ai-poc-ingress" via --resolve (it isn't
# publicly DNS-resolvable, only present in hosts files / resolved via
# --resolve here) over the NodePort HTTPS port 31083, and asserts:
#   1. HTTP 200 from <path>/actuator/health
#   2. /version reports the version we just deployed (proves this really is
#      the new preview pod, not a stale one)
#
# Retries on a version mismatch instead of failing on the first check: the
# Rollout's .status.phase flips to Healthy/Paused the instant the controller
# computes it, but the Service selector change still has to propagate through
# to kube-proxy and then to nginx-ingress's own endpoint cache - a window of
# up to a couple of seconds where the active/preview path can still briefly
# answer with the previous pod. Hit exactly this once in practice: rollout
# reported Healthy, and a curl fired ~50ms later still got the old version;
# the same URL was correct a second later. A real health/500 failure won't
# self-heal across retries, so this doesn't mask actual breakage - it just
# stops treating a still-settling endpoint as one.
set -euo pipefail

PATH_PREFIX="$1"
EXPECTED_VERSION="$2"
HOST="ai-poc-ingress"
PORT="31083"
BASE="https://${HOST}:${PORT}${PATH_PREFIX}"
MAX_ATTEMPTS=6
RETRY_DELAY=3

echo "Smoke testing ${BASE} (expecting version=${EXPECTED_VERSION})"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  HEALTH_CODE=$(curl -sk --resolve "${HOST}:${PORT}:127.0.0.1" -o /tmp/health.json -w '%{http_code}' "${BASE}/actuator/health")

  if [ "$HEALTH_CODE" != "200" ]; then
    echo "[attempt ${attempt}/${MAX_ATTEMPTS}] FAIL: /actuator/health returned HTTP ${HEALTH_CODE}"
    cat /tmp/health.json
    sleep "$RETRY_DELAY"
    continue
  fi

  VERSION_JSON=$(curl -sk --resolve "${HOST}:${PORT}:127.0.0.1" "${BASE}/version")
  ACTUAL_VERSION=$(echo "$VERSION_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")

  if [ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]; then
    echo "PASS: ${BASE} is healthy and serving version ${ACTUAL_VERSION} (attempt ${attempt}/${MAX_ATTEMPTS})"
    exit 0
  fi

  echo "[attempt ${attempt}/${MAX_ATTEMPTS}] expected version ${EXPECTED_VERSION}, got ${ACTUAL_VERSION} - endpoint may still be settling, retrying"
  sleep "$RETRY_DELAY"
done

echo "FAIL: ${BASE} never reported version ${EXPECTED_VERSION} after ${MAX_ATTEMPTS} attempts"
exit 1
