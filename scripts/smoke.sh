#!/usr/bin/env bash
# End-to-end headless acceptance for the demo.
#
#   1. stage the component in Components/ if it is missing
#   2. start scripts/mock_caldav.py on a free loopback port
#   3. run the project's Smoke method under tool4d
#   4. read the JSON report the method wrote and fail on any red check
#
# The exit code is the report's `success` flag, not tool4d's status: tool4d
# exits 0 even when the startup method's ASSERT fails, so a report that is
# missing or unsuccessful is the only failure signal that can be trusted.
#
#   scripts/smoke.sh [--tool4d PATH] [--report PATH]
#
# Nothing here needs a 4D licence, a serial or the IDE: tool4d is the free
# headless runtime and the mock is a plain Python stdlib server.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
report="$root/.local/smoke-report.json"
tool4d=${TOOL4D:-}

while [ $# -gt 0 ]; do
	case "$1" in
		--tool4d) tool4d=$2; shift 2 ;;
		--report) report=$2; shift 2 ;;
		-h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ -z "$tool4d" ]; then
	# Prefer the newest installed 4D application, matching the compatibility
	# version the project declares.
	for candidate in "/Applications"/4D*"/tool4d.app/Contents/MacOS/tool4d"; do
		[ -x "$candidate" ] && tool4d=$candidate
	done
fi
if [ -z "$tool4d" ] || [ ! -x "$tool4d" ]; then
	echo "FAIL tool4d not found; pass --tool4d PATH or set TOOL4D" >&2
	exit 2
fi

if [ ! -d "$root/Components/CalDAV.4dbase" ]; then
	echo "== staging the component"
	"$root/scripts/fetch_component.sh"
fi

mkdir -p "$root/.local"
port=$(python3 - <<'PY'
import socket
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)

echo "== mock on 127.0.0.1:$port"
python3 "$root/scripts/mock_caldav.py" --port "$port" \
	--log "$root/.local/mock.log" > "$root/.local/mock.out" 2>&1 &
mock=$!
cleanup() {
	kill "$mock" 2>/dev/null || true
	wait "$mock" 2>/dev/null || true
}
trap cleanup EXIT

python3 - "$port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
deadline = time.time() + 15
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            raise SystemExit(0)
    except OSError:
        time.sleep(0.1)
raise SystemExit(f"mock did not start on port {port}")
PY

rm -f "$report"
python3 - "$port" "$report" <<'PY' > "$root/.local/smoke-param.json"
import json, sys
port, report = sys.argv[1], sys.argv[2]
print(json.dumps({"url": f"http://127.0.0.1:{port}/dav/", "username": "demo",
                  "password": "demo", "report": report}))
PY

echo "== tool4d $(basename "$(dirname "$(dirname "$(dirname "$tool4d")")")")"
set +e
"$tool4d" --dataless --skip-onstartup --startup-method Smoke \
	--project="$root/Project/CalDAV-demo.4DProject" \
	--user-param="$(cat "$root/.local/smoke-param.json")" > "$root/.local/smoke.out" 2>&1
status=$?
set -e

if [ ! -f "$report" ]; then
	echo "FAIL tool4d wrote no report (exit $status); see .local/smoke.out" >&2
	tail -5 "$root/.local/smoke.out" >&2 || true
	exit 1
fi

python3 - "$report" "$status" <<'PY'
import json, sys
report, status = json.load(open(sys.argv[1], encoding="utf-8")), int(sys.argv[2])
for check in report["checks"]:
    print(("PASS " if check["ok"] else "FAIL ") + check["name"] + " — " + check["detail"])
passed = sum(1 for c in report["checks"] if c["ok"])
print(f"\n{passed}/{len(report['checks'])} checks passed (tool4d exit {status}, report success {report['success']})")
raise SystemExit(0 if report["success"] and status == 0 else 1)
PY
