#!/usr/bin/env bash
set -euo pipefail

# Health check script for monero-node
# Returns 0 if healthy, 1 if unhealthy, 2 if syncing
# Usage: ./health-check.sh [url]

URL="${1:-https://localhost/health}"

response=$(curl -sfk --max-time 10 "${URL}" 2>/dev/null) || {
    echo "UNHEALTHY: Cannot reach monerod at ${URL}"
    exit 1
}

# Check if response is valid JSON with expected fields
echo "${response}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('status') != 'OK':
    print(f'UNHEALTHY: Bad status: {data.get(\"status\")}')
    sys.exit(1)
height = data.get('height', 0)
target = data.get('target_height', 0)
synced = height >= target - 5 if target > 0 else True
if not synced:
    print(f'SYNCING: {height}/{target}')
    sys.exit(2)
print(f'HEALTHY: height={height}, difficulty={data.get(\"difficulty\",0)}, connections={data.get(\"outgoing_connections_count\",0)+data.get(\"incoming_connections_count\",0)}')
sys.exit(0)
" 2>/dev/null
exit $?
