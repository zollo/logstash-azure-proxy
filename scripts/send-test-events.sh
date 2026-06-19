#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# send-test-events.sh — POST the sample F5 TS payloads to the running proxy.
#
# Usage:
#   ./scripts/send-test-events.sh [URL]
#
# URL defaults to http://localhost:8080 (override for a remote/alt port).
# With DEBUG_STDOUT=true on the container you can watch each event get
# classified and routed in the container logs:  docker compose logs -f
# ---------------------------------------------------------------------------
set -euo pipefail

URL="${1:-http://localhost:8080}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS_DIR="${SCRIPT_DIR}/../examples/events"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not installed." >&2
  exit 1
fi

shopt -s nullglob
payloads=("${EVENTS_DIR}"/*.json)
if [ ${#payloads[@]} -eq 0 ]; then
  echo "No sample payloads found in ${EVENTS_DIR}" >&2
  exit 1
fi

for f in "${payloads[@]}"; do
  echo ">> POST $(basename "$f") -> ${URL}"
  curl -fsS -XPOST "${URL}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${f}" \
    && echo "   ok" || echo "   FAILED"
done

echo "Done. Check Azure Log Analytics (tables F5Telemetry_*_CL) or the container logs."
