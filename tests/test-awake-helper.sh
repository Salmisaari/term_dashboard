#!/bin/bash
set -euo pipefail
awake_test_root="$(cd "$(dirname "$0")/.." && pwd)"
awake_test_dir="$(mktemp -d /tmp/td-awake-checks.XXXXXX)"
trap 'rm -rf "$awake_test_dir"' EXIT
python3 -B -I - "$awake_test_root" "$awake_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root/'menubar/td-awake.swift').read_text().split('// Tests compile the definitions above')[0]
Path(sys.argv[2]).write_text(source + (root/'tests/awake-helper-checks.swift').read_text())
PY
swiftc "$awake_test_dir/main.swift" -o "$awake_test_dir/checks" -framework IOKit
"$awake_test_dir/checks"
