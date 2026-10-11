#!/bin/sh
# Syntax and smoke lint of the repository. It needs no hardware and no build.
#   ci/lint.sh
# Checks:
#   - every script with a "#!/bin/sh" or "#!/sbin/openrc-run" first line
#     passes `busybox sh -n` (the panel and the Alpine build containers run
#     busybox sh, so bash syntax is not allowed)
#   - every *.py file compiles (python3 -m py_compile)
#   - every *.json file of the repository parses
#   - every *.yaml file of esphome-lvgl/ has the keys that build.sh reads
#   - the relative links of README.md and docs/*.md resolve
#     (ci/check-doc-links.py)
#   - every file with a "#!" first line under image/, ci/ and esphome-lvgl/
#     has the executable mode (100755) in git, because the workflows and the
#     build scripts run them directly. A file that must stay 100644 goes into
#     the list NOEXEC below.
# Needs busybox and python3.
set -u
cd "$(dirname "$0")/.."
fail=0
n=0
for f in $(git ls-files 2>/dev/null || find . -type f -not -path './.git/*'); do
	[ -f "$f" ] || continue
	case "$(head -n1 "$f" 2>/dev/null)" in
	'#!/bin/sh'|'#!/sbin/openrc-run')
		n=$((n + 1))
		busybox sh -n "$f" || { echo "FAIL: busybox sh -n $f"; fail=1; } ;;
	esac
done
echo "== busybox sh -n: $n scripts"

# Files with a "#!" line that are not run directly (none at present).
NOEXEC=""
n=0
if git rev-parse --git-dir >/dev/null 2>&1; then
	for f in $(git ls-files -s image ci esphome-lvgl | awk '$1 == "100644" { print $4 }'); do
		[ -f "$f" ] || continue
		[ "$(head -c2 "$f" 2>/dev/null)" = '#!' ] || continue
		case " $NOEXEC " in *" $f "*) continue ;; esac
		n=$((n + 1))
		echo "FAIL: $f has a #! line and mode 100644 (git update-index --chmod=+x $f)"; fail=1
	done
fi
echo "== executable mode of scripts under image, ci, esphome-lvgl: $n wrong"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0
for f in $(find . -name '*.py' -not -path './.git/*'); do
	n=$((n + 1))
	python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$f" "$T/x.pyc" ||
		{ echo "FAIL: py_compile $f"; fail=1; }
done
echo "== python3 py_compile: $n files"

n=0
for f in $(find . -name '*.json' -not -path './.git/*'); do
	n=$((n + 1))
	python3 -m json.tool "$f" >/dev/null || { echo "FAIL: JSON $f"; fail=1; }
done
echo "== JSON: $n files"

for f in esphome-lvgl/*.yaml; do
	grep -q '^  name: ' "$f" || { echo "FAIL: $f has no esphome name (build.sh reads it)"; fail=1; }
done
echo "== ESPHome YAML names"

python3 ci/check-doc-links.py || { echo "FAIL: doc links"; fail=1; }

[ "$fail" = 0 ] && echo "lint: OK" || echo "lint: FAILED"
exit "$fail"
