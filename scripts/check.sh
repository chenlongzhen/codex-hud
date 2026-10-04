#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/scripts/swift.sh" run HUDCoreChecks
