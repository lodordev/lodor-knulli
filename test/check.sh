#!/bin/bash
# check.sh — the one-command gate for the Knulli Lodor integration's shell surface:
#   STATIC: bash -n + POSIX-sh parse of every shipped/test script, then shellcheck
#           (local binary, else the koalaman/shellcheck docker image, else skipped
#           with a warning — parse checks still gate).
# Shape and docker fallback follow integrations/muos/test/check.sh; the dynamic
# end-to-end pass lives in test/integ-harness.sh (offline sandbox, no root needed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KNULLI="$(cd "$HERE/.." && pwd)"
UD="$KNULLI/userdata"
APP="$UD/system/lodor"
fails=0

# ---- the shell surface under gate ----
# POSIX_FILES run on-device under Knulli's busybox ash — they MUST parse in a POSIX
# shell. BASH_FILES are x86-only harness scripts (#!/bin/bash) — bash -n only.
POSIX_FILES=(
	"$APP/lib/romm-sync-lib.sh"
	"$APP/lib/tailscale-lib.sh"
	"$APP/bin/lodor-ts.sh"
	"$APP/bin/romm-run"
	"$APP/bin/romm-syncd"
	"$UD/system/scripts/lodor-hook.sh"
	"$UD/system/services/lodor"
	"$UD/roms/ports/Lodor.sh"
	"$HERE/integ-harness.sh"
)
BASH_FILES=(
	"$HERE/check.sh"
)
FILES=("${POSIX_FILES[@]}" "${BASH_FILES[@]}")

echo "== static: bash -n + POSIX-sh parse =="
# POSIX parser: dash where present (dev container / debian), else busybox ash (Unraid/
# panther) — the on-device shell is POSIX-family, so that parse matters more than which.
POSIX_SH=()
if command -v dash >/dev/null 2>&1; then POSIX_SH=(dash)
elif command -v busybox >/dev/null 2>&1; then POSIX_SH=(busybox ash)
else echo "WARN: no dash/busybox — POSIX parse skipped (bash -n still gates)"
fi
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "GATE FAIL: missing $f"; fails=$((fails+1)); continue; }
	bash -n "$f" || { echo "GATE FAIL: bash -n $f"; fails=$((fails+1)); }
done
if [ "${#POSIX_SH[@]}" -gt 0 ]; then
	for f in "${POSIX_FILES[@]}"; do
		[ -f "$f" ] || continue
		"${POSIX_SH[@]}" -n "$f" || { echo "GATE FAIL: ${POSIX_SH[*]} -n $f"; fails=$((fails+1)); }
	done
fi

echo "== static: shellcheck =="
# Pinned excludes — same reviewed set the muOS gate pins (2026-07-03), for the same code:
#   SC1007         `CDPATH= cd --` — the empty assignment is the POINT
#   SC1090/SC1091  sources resolved at runtime ($LIB, $SELF_DIR/../lib) — not followable
#   SC2034         cross-file vars set by the lib for its sourcing scripts (BIN/PENDING/
#                  PROGRESS) — contract, not dead code
#   SC2209/SC2015  tailscale-lib.sh (ported verbatim from the field-tested nextui lib):
#                  `TS_BG=nohup` assigns a command NAME on purpose; `A && B || C` status
#                  idioms are intentional
#   SC2018/SC2019  tailscale-lib.sh device-hostname normalization uses ASCII `tr A-Z a-z`
#                  ON PURPOSE (Tailscale hostnames are ASCII; same pin as the muOS gate)
SC_EXCLUDES="SC1007,SC1090,SC1091,SC2015,SC2018,SC2019,SC2034,SC2209"
run_shellcheck() {
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck -x -e "$SC_EXCLUDES" "$@"
	elif command -v docker >/dev/null 2>&1 && docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
		ROOT="$(cd "$KNULLI/../.." && pwd)"   # repo root — all gated files live under it
		# PROBE the bind mount first: a docker CLI pointed at a REMOTE daemon (socket proxy)
		# would silently mount the remote host's paths instead of these files.
		printf '#!/bin/sh\n' > "$ROOT/.sc-probe.sh"
		if ! docker run --rm -v "$ROOT":/mnt koalaman/shellcheck:stable /mnt/.sc-probe.sh >/dev/null 2>&1; then
			rm -f "$ROOT/.sc-probe.sh"
			echo "WARN: docker daemon cannot see this filesystem (remote daemon?) — SKIPPING shellcheck"
			return 0
		fi
		rm -f "$ROOT/.sc-probe.sh"
		local rel=() f
		for f in "$@"; do rel+=("${f#"$ROOT"/}"); done
		docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck:stable \
			-x -e "$SC_EXCLUDES" "${rel[@]}"
	else
		echo "WARN: shellcheck not available (no binary, no docker image) — SKIPPING lint (parse checks still ran)"
		return 0
	fi
}
existing=()
for f in "${FILES[@]}"; do [ -f "$f" ] && existing+=("$f"); done
run_shellcheck "${existing[@]}" || { echo "GATE FAIL: shellcheck"; fails=$((fails+1)); }

echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "check.sh: ALL GATES PASSED"
	exit 0
fi
echo "check.sh: $fails gate(s) FAILED"
exit 1
