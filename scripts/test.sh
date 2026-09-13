#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/swiftpm.sh" build --product QuotaChecks
binary_dir="$("$project_dir/scripts/swiftpm.sh" build --show-bin-path)"
"$binary_dir/QuotaChecks"
