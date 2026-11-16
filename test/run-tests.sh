#!/usr/bin/env bash
# Everything that can be tested without a microphone: the curve solver (node)
# and the helper's settings, config and file handling (python).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

status=0
echo "== curve solver"
node test/eq.test.mjs || status=1
echo
echo "== helper"
python3 -I -B test/helper_test.py || status=1
exit $status
