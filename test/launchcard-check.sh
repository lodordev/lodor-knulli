#!/bin/sh
# launchcard-check.sh — off-hardware E2E for the Handoff launch card (task #24).
#
# Runs the REAL wizard binary through --launch-card against a STUB engine
# (LODOR_BIN) using the established off-hardware seams: LODOR_FB_DEV
# (file-backed framebuffer, no ioctls), LODOR_INPUT_SCRIPT (scripted buttons
# through the identical input loop), LODOR_FB_DUMP (rendered-frame proof).
# What this does NOT cover (hardware-only): whether EmulationStation contends
# for evdev input during Batocera's gameStart window — the RG40XXV on-device
# test. Everything else about the card is proven here.
#
# Legs:
#   1. QUIET: nothing newer -> LAUNCHCARD news=0, NO frame drawn, instant exit
#   2. CARD + PICK STATE: newer state -> card renders (fb dump exists), scripted
#      A selects "Continue from that state" -> stub records --pull-state with
#      the right --state-id -> LAUNCHCARD action=pull-state placed=1
#   3. CARD + JUST PLAY: scripted B -> action=play, engine NEVER asked to pull
#
# Env knobs:
#   LODOR_WIZARD  path to a prebuilt host-arch lodor-wizard (skips docker build)
#   LODOR_SB      sandbox (default /tmp/lodor-launchcard-check). Wiped each run.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SB=${LODOR_SB:-/tmp/lodor-launchcard-check}
rm -rf "$SB"; mkdir -p "$SB/data" "$SB/fb"

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- wizard binary (host arch so it runs natively) ----------------------------
WIZ=${LODOR_WIZARD:-}
if [ -z "$WIZ" ]; then
	WIZ="$SB/lodor-wizard"
	echo "building wizard (docker golang)..."
	docker run --rm -v "$REPO":/repo -w /repo/engine \
		-e GOFLAGS=-buildvcs=false -e GOCACHE=/repo/.gocache -e GOMODCACHE=/repo/.gomodcache \
		golang:1.25-bookworm go build -o /repo/.lodor-wizard-host ./cmd/lodor-wizard \
		|| { echo "FATAL: wizard build failed"; exit 1; }
	mv "$REPO/.lodor-wizard-host" "$WIZ"
fi
[ -x "$WIZ" ] || { echo "FATAL: no wizard binary at $WIZ"; exit 1; }

# ---- stub engine: canned probe output, records every call ---------------------
STUB="$SB/engine-stub.sh"
CALLS="$SB/engine-calls.log"
: > "$CALLS"
cat > "$STUB" << 'EOF'
#!/bin/sh
echo "$@" >> "${STUB_CALLS:?}"
case "$1" in
--list-saves)
	if [ "${STUB_SAVE_NEWER:-0}" = 1 ]; then
		printf '12\t2026-07-06\tflip\t4KB\nLOCAL=older\n'
	else
		printf '12\t2026-07-06\tflip\t4KB\nLOCAL=current\n'
	fi
	;;
--list-states)
	if [ "${STUB_STATE_NEWS:-0}" = 1 ]; then
		printf 'LISTSTATE id=42 slot=auto compat=1 known=0 age=7200 size=40960 origin=lodor/lodoros/gpsp/armhf why="-" name="x.state"\n'
		printf 'RESULT liststates=1 compatstates=1 reason=ok\n'
	else
		printf 'RESULT liststates=0 compatstates=0 reason=none\n'
	fi
	;;
--pull-state)
	printf 'RESULT placedstate=1 reason=ok path="/fake/x.state.auto"\n'
	;;
--sync-save)
	printf 'RESULT pulled=1 pushed=0 ghosts=0 reason=ok\n'
	;;
esac
exit 0
EOF
chmod +x "$STUB"

run_card() { # $1=save-newer $2=state-news $3=input-script $4=outfile
	rm -f "$SB/fb/frame.png"
	STUB_CALLS="$CALLS" STUB_SAVE_NEWER="$1" STUB_STATE_NEWS="$2" \
	LODOR_BIN="$STUB" LODOR_PAK_DIR="$SB/data" SDCARD_PATH="$SB" \
	LODOR_FB_DEV="$SB/fb/fb.raw" LODOR_FB_DUMP="$SB/fb/frame.png" \
	LODOR_INPUT_SCRIPT="$3" \
	"$WIZ" --launch-card "/roms/gamegear/Woody Pop.gg" > "$4" 2>&1
}

echo "=== leg 1: nothing newer -> silent pass-through, no frame ==="
: > "$CALLS"
run_card 0 0 "a" "$SB/leg1.out"
grep -q "LAUNCHCARD news=0" "$SB/leg1.out" \
	&& ok "quiet: LAUNCHCARD news=0" || bad "quiet output wrong: $(cat "$SB/leg1.out")"
[ ! -f "$SB/fb/frame.png" ] \
	&& ok "quiet: no frame drawn (zero UI cost)" || bad "quiet leg drew a frame"
grep -q -- "--pull-state" "$CALLS" && bad "quiet leg pulled a state" || ok "quiet: no pulls"

echo "=== leg 2: newer state -> card renders, A places it ==="
: > "$CALLS"
run_card 0 1 "a" "$SB/leg2.out"
grep -q "LAUNCHCARD news=1 action=pull-state placed=1" "$SB/leg2.out" \
	&& ok "card: state placed via first option" || bad "card output wrong: $(cat "$SB/leg2.out")"
[ -s "$SB/fb/frame.png" ] \
	&& ok "card: frame rendered to fb (dump exists)" || bad "no rendered frame"
grep -q -- "--pull-state /roms/gamegear/Woody Pop.gg --state-id 42" "$CALLS" \
	&& ok "card: engine got the RIGHT state id (42)" || bad "pull-state call wrong: $(cat "$CALLS")"

echo "=== leg 3: newer save -> B = just play, nothing pulled ==="
: > "$CALLS"
run_card 1 0 "b" "$SB/leg3.out"
grep -q "LAUNCHCARD news=1 action=play" "$SB/leg3.out" \
	&& ok "card: B falls through to play" || bad "B output wrong: $(cat "$SB/leg3.out")"
if grep -q -- "--sync-save\|--pull-state" "$CALLS"; then
	bad "just-play still pulled something"
else
	ok "card: no pulls on just-play"
fi

echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "launchcard-check: ALL PASSED (ES input contention remains the on-device check)"
	exit 0
fi
echo "launchcard-check: $fails FAILURES"
exit 1
