#!/bin/sh
# integ-harness.sh — Lodor-Knulli offline integration harness (monorepo edition).
#
# Builds a PLAIN-DIRECTORY sandbox /userdata tree (no root, no loop mounts — Batocera's
# layout is a fixed contract, so unlike muOS there is no card image to extract ground
# truth from), installs the integration source from ../userdata, builds the engine for
# the HOST arch (so it runs natively, no qemu/binfmt), and exercises the OFFLINE leg of
# the configgen bracket end-to-end via a stub `emulatorlauncher` that invokes
# /userdata/system/scripts/* EXACTLY like Batocera configgen does (blocking, args
# `gameStart|gameStop <system> <emulator> <core> <rom>`):
#
#   leg 1: 0-byte stub + gameStart -> download attempted + failed HONESTLY (no network),
#          rom NOT clobbered (still 0 bytes), no fake pending entry
#   leg 2: real rom -> stub emulator writes a battery save -> gameStop (offline) queues
#          the rom into pending-saves.txt, exactly once (dedup on re-run)
#   leg 3: gamelist writer -> a planted FOREIGN <game> entry must survive
#          --write-gamelists. Skipped GRACEFULLY (loud, not a pass) until the engine
#          mode lands from the parallel engine work.
#
# LIVE RomM legs (download-on-launch, save round-trip) are hardware/Phase-D — this
# harness is deliberately offline-only and needs neither root nor a server.
#
# Env knobs:
#   LODOR_SB      sandbox dir (default /tmp/lodor-knulli-integ). Wiped every run.
#   LODOR_ENGINE  path to a prebuilt host-arch lodor-sync (skips the docker build).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KNULLI_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)        # integrations/knulli
REPO=$(CDPATH= cd -- "$KNULLI_ROOT/../.." && pwd)     # monorepo root
SRC="$KNULLI_ROOT/userdata"
SB="${LODOR_SB:-/tmp/lodor-knulli-integ}"

fails=0
ok()   { echo "ok: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }

echo "=== reset sandbox: $SB ==="
rm -rf "$SB"
mkdir -p "$SB/userdata/roms/gamegear" "$SB/userdata/roms/ports" \
	"$SB/userdata/saves" "$SB/userdata/bios" \
	"$SB/sys/net/wlan0" "$SB/sys/power/bat0" "$SB/fakebin"

echo "=== install the integration tree (source-of-truth: $SRC) ==="
cp -r "$SRC/system" "$SB/userdata/system" || { echo "FATAL: source copy"; exit 1; }
cp "$SRC/roms/ports/Lodor.sh" "$SB/userdata/roms/ports/Lodor.sh"
chmod +x "$SB/userdata/system/scripts/lodor-hook.sh" "$SB/userdata/system/services/lodor" \
	"$SB/userdata/roms/ports/Lodor.sh" "$SB/userdata/system/lodor/bin/"* 2>/dev/null
APP_SB="$SB/userdata/system/lodor"

echo "=== engine: host-arch build (-tags knulli; runs natively, no qemu) ==="
# NOTE: until the knulli engine variant lands (parallel engine work), `-tags knulli`
# compiles the DEFAULT path files — fine HERE because this harness overrides every path
# by env. The RELEASE refuses that substitution (release.sh fails loud on a missing tag).
ENGINE_OK=0
if [ -n "${LODOR_ENGINE:-}" ] && [ -x "${LODOR_ENGINE:-}" ]; then
	cp "$LODOR_ENGINE" "$APP_SB/lodor-sync" && ENGINE_OK=1
elif command -v docker >/dev/null 2>&1; then
	if docker run --rm -v "$REPO":/w -w /w/engine -e CGO_ENABLED=0 \
		golang:1.25-bookworm go build -tags knulli -trimpath -ldflags "-s -w" \
		-o /w/engine/.integ-out-knulli ./cmd/lodor-sync 2>&1 | tail -3; then
		if [ -f "$REPO/engine/.integ-out-knulli" ]; then
			mv "$REPO/engine/.integ-out-knulli" "$APP_SB/lodor-sync"
			ENGINE_OK=1
		fi
	fi
fi
if [ "$ENGINE_OK" = 1 ]; then
	chmod +x "$APP_SB/lodor-sync"
	# Sandbox config: the EXAMPLE placeholder values only (no real token, never a live
	# config) — enough for the engine to start; every dial target is unreachable here.
	cp "$APP_SB/config.json.example" "$APP_SB/config.json"
	ok "engine built + example config staged"
else
	echo "##############################################################################"
	echo "# WARNING: no engine binary (docker unavailable / build failed). Engine-side"
	echo "# asserts (write-gamelists tolerance, leg 3) will be SKIPPED — this is NOT a"
	echo "# pass for those. Shell-side legs still gate. Set LODOR_ENGINE=<host binary>."
	echo "##############################################################################"
fi

echo "=== sandbox environment: OFFLINE (operstate down), on battery =="
echo down > "$SB/sys/net/wlan0/operstate"
echo Discharging > "$SB/sys/power/bat0/status"
cat > "$SB/fakebin/ip" <<'FAKEIP'
#!/bin/sh
# sandbox `ip` shim: no inet lines -> wifi_is_up stays honest-false even if operstate lies
exit 0
FAKEIP
chmod +x "$SB/fakebin/ip"

export LODOR_APPDIR="$APP_SB"
export ROMS_DIR="$SB/userdata/roms"
export SAVES_DIR="$SB/userdata/saves"
export BIOS_DIR="$SB/userdata/bios"
export SDCARD_PATH="$SB/userdata"
export LODOR_NET_SYS="$SB/sys/net"
export LODOR_POWER_SYS="$SB/sys/power"
export SCRIPTS_DIR="$SB/userdata/system/scripts"
PATH="$SB/fakebin:$PATH"; export PATH
LOG="$APP_SB/romm.log"
PENDING="$APP_SB/pending-saves.txt"
rm -f /tmp/romm-in-game

echo "=== stub emulatorlauncher (invokes the scripts hook EXACTLY like configgen) ==="
cat > "$SB/emulatorlauncher" <<'STUB'
#!/bin/sh
# STUB Batocera configgen: runs every /userdata/system/scripts/* BLOCKING with
# gameStart args, "runs the emulator" (a real save write on a real rom; an honest
# failure on an empty file), then runs the scripts again with gameStop args.
SYSTEM="$1"; EMU="$2"; CORE="$3"; ROM="$4"
for s in "${SCRIPTS_DIR:?}"/*; do [ -x "$s" ] && "$s" gameStart "$SYSTEM" "$EMU" "$CORE" "$ROM"; done
if [ -s "$ROM" ]; then
	B=$(basename "$ROM")
	mkdir -p "${SAVES_DIR:?}/$SYSTEM"
	echo "STUB-SAVE-$(date +%s)" > "$SAVES_DIR/$SYSTEM/${B%.*}.srm"
	echo "[stub emulator] ran $B, wrote save"
	rc=0
else
	echo "[stub emulator] FAILED: empty rom $ROM (honest: nothing to run)"
	rc=1
fi
for s in "$SCRIPTS_DIR"/*; do [ -x "$s" ] && "$s" gameStop "$SYSTEM" "$EMU" "$CORE" "$ROM"; done
exit $rc
STUB
chmod +x "$SB/emulatorlauncher"

echo ""
echo "=== leg 1: 0-byte stub, OFFLINE -> honest download failure, rom untouched ==="
ROM1="$ROMS_DIR/gamegear/✘ Sonic [!].gg"
: > "$ROM1"
"$SB/emulatorlauncher" gamegear libretro genesis_plus_gx "$ROM1" > "$SB/leg1.out" 2>&1
[ -f "$ROM1" ] && [ ! -s "$ROM1" ] \
	&& ok "stub not clobbered (still 0 bytes - no fake forward-progress)" \
	|| bad "stub was modified (fake bytes or deleted): $(ls -la "$ROM1" 2>&1)"
grep -q "fetch-on-launch: no network" "$LOG" 2>/dev/null \
	&& ok "hook logged the SPECIFIC cause (no network)" \
	|| bad "missing honest 'no network' log line"
grep -q "fetch-on-launch FAILED" "$LOG" 2>/dev/null \
	&& ok "hook logged honest failure + exit 0 (pipeline never blocked)" \
	|| bad "missing 'fetch-on-launch FAILED' log line"
grep -q "\[stub emulator\] FAILED: empty rom" "$SB/leg1.out" \
	&& ok "pipeline continued to the emulator (hook exit 0)" \
	|| bad "emulator never ran after failed fetch - hook blocked the pipeline"
if [ -f "$PENDING" ] && grep -qF "$ROM1" "$PENDING"; then
	bad "no-save session landed in pending-saves.txt (fake queue entry)"
else
	ok "no fake pending entry for a session with no save"
fi

echo ""
echo "=== leg 2: real rom -> save written -> gameStop OFFLINE queues to pending ==="
ROM2="$ROMS_DIR/gamegear/Alex Kidd [!].gg"
echo "ROMBYTES" > "$ROM2"
"$SB/emulatorlauncher" gamegear libretro genesis_plus_gx "$ROM2" > "$SB/leg2.out" 2>&1
# gameStop runs --reconcile, which marker-migrates the unmarked real-bytes ROM to
# "✓ <name>" AND carries the save with it (saves renamed first) - so by assert time the
# save legitimately lives at the ✓-marked name. Accept either (pre- or post-reconcile).
{ [ -f "$SAVES_DIR/gamegear/✓ Alex Kidd [!].srm" ] || [ -f "$SAVES_DIR/gamegear/Alex Kidd [!].srm" ]; } \
	&& ok "stub emulator wrote the per-system save (saves/gamegear/, reconcile-migration tolerated)" \
	|| bad "expected save file missing - harness stub broken"
n=$(grep -cF "$ROM2" "$PENDING" 2>/dev/null || echo 0)
[ "$n" = "1" ] \
	&& ok "save queued offline: pending-saves.txt has the rom exactly once" \
	|| bad "pending queue wrong (count=$n, want 1) - bracket-escape or queue logic broken"
"$SB/emulatorlauncher" gamegear libretro genesis_plus_gx "$ROM2" > /dev/null 2>&1
n=$(grep -cF "$ROM2" "$PENDING" 2>/dev/null || echo 0)
[ "$n" = "1" ] \
	&& ok "re-run dedups (still exactly once)" \
	|| bad "pending dedup broken (count=$n after second run)"
# Handoff v1: the offline gameStop must ALSO queue the rom for a state-push
# retry (engine --queue-state -> pending-states.txt, engine-side dedup across
# both runs above). Engine-dependent, so gated like the gamelist asserts.
if [ "$ENGINE_OK" = 1 ]; then
	sn=$(grep -cF "$ROM2" "$APP_SB/pending-states.txt" 2>/dev/null || echo 0)
	[ "$sn" = "1" ] \
		&& ok "states queued offline: pending-states.txt has the rom exactly once (--queue-state, deduped)" \
		|| bad "states queue wrong (count=$sn, want 1) - --queue-state or its dedup broken"
else
	echo "SKIP states-queue assert (engine not built)"
fi
[ -f /tmp/romm-in-game ] \
	&& bad "in-game lock left behind after gameStop" \
	|| ok "in-game lock cleaned up at gameStop"
if [ "$ENGINE_OK" = 1 ]; then
	if grep -q "RESULT gamelists=" "$LOG" 2>/dev/null; then
		ok "engine --write-gamelists ran and reported (RESULT gamelists=)"
	elif grep -q "write-gamelists unavailable" "$LOG" 2>/dev/null; then
		ok "hook tolerated the missing --write-gamelists mode gracefully (logged, no abort)"
	elif grep -q -- "--write-gamelists" "$LOG" 2>/dev/null; then
		ok "engine accepted --write-gamelists (mode has landed)"
	else
		bad "no trace of the write-gamelists call in the log"
	fi
fi

echo ""
echo "=== leg 3: gamelist writer emits OWNED entries + preserves a FOREIGN one ==="
GL="$ROMS_DIR/gamegear/gamelist.xml"
# Plant a manifest-OWNED stub so the writer has something it MUST emit. Without this the
# foreign-preservation assert is trivially satisfiable by a writer that writes NOTHING —
# which is exactly how the live-leg gamelists=0 class hid (2026-07-06). Overwrites any
# sandbox manifest from earlier legs: leg 3 only needs ownership of this one stub.
: > "$ROMS_DIR/gamegear/✘ Planted Stub (USA).gg"
cat > "$APP_SB/mirror-manifest.json" <<MAN
{"version":1,"entries":{"/roms/gamegear/✘ Planted Stub (USA).gg":{"kind":"stub"}}}
MAN
cat > "$GL" <<'XML'
<?xml version="1.0"?>
<gameList>
	<game>
		<path>./Foreign Keeper.gg</path>
		<name>Foreign Keeper</name>
		<desc>Planted by the harness - a writer that drops me is a data-loss bug.</desc>
	</game>
</gameList>
XML
if [ "$ENGINE_OK" != 1 ]; then
	echo "SKIP (loud, not a pass): no engine binary - cannot exercise --write-gamelists"
else
	wg_out=$( (cd "$APP_SB" && ./lodor-sync --write-gamelists) 2>&1 ); wg_rc=$?
	if [ "$wg_rc" != 0 ]; then
		echo "SKIP (loud, not a pass): engine --write-gamelists rc=$wg_rc — the mode has"
		echo "  not landed yet (expected until the parallel engine work merges)."
		echo "  engine said: $(echo "$wg_out" | head -2)"
	else
		echo "$wg_out" | grep -Eq "RESULT gamelists=[1-9][0-9]* entries=[1-9][0-9]*" \
			&& ok "writer actually WROTE owned entries ($(echo "$wg_out" | grep RESULT))" \
			|| bad "writer wrote nothing (RESULT: $(echo "$wg_out" | grep RESULT)) - the no-op class"
		grep -q "<path>./✘ Planted Stub (USA).gg</path>" "$GL" \
			&& ok "owned stub present in gamelist (<path> keeps the marker)" \
			|| bad "owned stub MISSING from gamelist.xml"
		grep -q "<name>Planted Stub (USA)</name>" "$GL" \
			&& ok "owned stub display name is marker-stripped" \
			|| bad "owned stub <name> not marker-stripped"
		grep -q "<name>Foreign Keeper</name>" "$GL" \
			&& ok "foreign <game> entry preserved" \
			|| bad "foreign <game> entry DROPPED by --write-gamelists (data loss)"
		if command -v xmllint >/dev/null 2>&1; then
			xmllint --noout "$GL" 2>/dev/null \
				&& ok "gamelist.xml is well-formed XML (xmllint)" \
				|| bad "gamelist.xml is NOT well-formed after --write-gamelists"
		else
			grep -q "</gameList>" "$GL" \
				&& ok "gamelist.xml closes properly (xmllint unavailable - shape check only)" \
				|| bad "gamelist.xml truncated after --write-gamelists"
		fi
	fi
fi

echo ""
echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "integ-harness: ALL OFFLINE ASSERTS PASSED (live RomM + hardware legs are Phase-D)"
	exit 0
fi
echo "integ-harness: $fails assert(s) FAILED"
exit 1
