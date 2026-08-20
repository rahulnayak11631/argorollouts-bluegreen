#!/usr/bin/env bash
# Usage: wait-for-phase.sh <namespace> <one or more expected phases, comma separated> <timeout seconds>
# Polls `.status.phase` directly instead of relying on `kubectl argo rollouts
# status` exit-code semantics (those vary by plugin version around how a
# manual-promotion Paused rollout is treated) - this is the version-proof way.
set -euo pipefail

NAMESPACE="$1"
EXPECTED_PHASES="$2"   # e.g. "Paused" or "Healthy"
TIMEOUT="${3:-180}"
ROLLOUT="bluegreen-demo"
ELAPSED=0
INTERVAL=5

echo "Waiting for rollout/${ROLLOUT} -n ${NAMESPACE} to reach phase in [${EXPECTED_PHASES}] (timeout ${TIMEOUT}s)"

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  PHASE=$(kubectl get rollout "$ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "  [${ELAPSED}s] phase=${PHASE:-<none>}"

  IFS=',' read -ra WANTED <<< "$EXPECTED_PHASES"
  for p in "${WANTED[@]}"; do
    if [ "$PHASE" == "$p" ]; then
      echo "Reached phase: ${PHASE}"
      exit 0
    fi
  done

  if [ "$PHASE" == "Degraded" ]; then
    echo "FAIL: rollout is Degraded"
    kubectl describe rollout "$ROLLOUT" -n "$NAMESPACE" || true
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "FAIL: timed out after ${TIMEOUT}s waiting for phase in [${EXPECTED_PHASES}], last phase=${PHASE:-<none>}"
exit 1
