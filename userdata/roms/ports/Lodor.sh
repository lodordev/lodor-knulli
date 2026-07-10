#!/bin/sh
# /userdata/roms/ports/Lodor.sh - the ES-launchable Lodor app on Knulli.  MARKER: LODOR_PORT
#
# EmulationStation's "ports" system runs this script fullscreen (the PortMaster-proven
# surface). It hands the screen to the pure-Go framebuffer wizard: onboarding (server,
# pairing, initial mirror) on first run; the Sync-now / Refresh / Tailscale management
# menu on later runs. The wizard drives the headless engine for all RomM work. Wi-Fi
# entry stays Knulli's job (connman) - Lodor ships zero wifi code.

APPDIR="${LODOR_APPDIR:-/userdata/system/lodor}"
LIB="$APPDIR/lib/romm-sync-lib.sh"
if [ ! -f "$LIB" ]; then
	echo "Lodor: $LIB missing - extract the Lodor-Knulli zip onto /userdata first."
	exit 1
fi
. "$LIB"
lodor_export_env
export LODOR_HOST_OS=knulli # the wizard's host-OS copy table (lodor#32)
log "ports: Lodor.sh open"

# Self-heal install state on every open (a fresh unzip can lose +x bits; the service may
# not be enabled yet). All best-effort - the menu must open regardless.
chmod +x /userdata/system/scripts/lodor-hook.sh /userdata/system/services/lodor \
         "$APPDIR/lodor-sync" "$APPDIR/lodor-wizard" \
         "$APPDIR/bin/"* "$APPDIR/bin/tailscale/"* 2>/dev/null
if command -v batocera-services >/dev/null 2>&1; then
	batocera-services enable lodor >/dev/null 2>&1
	# start the daemon now if it isn't running (first run after install, no reboot yet)
	if ! { [ -f /tmp/lodor-syncd.pid ] && kill -0 "$(cat /tmp/lodor-syncd.pid 2>/dev/null)" 2>/dev/null; }; then
		/userdata/system/services/lodor start >/dev/null 2>&1
	fi
fi

# LAZY Tailscale bring-up: NEVER block the menu on the tunnel. Onboarded + TS-capable with
# a persisted login -> kick a reconnect in the BACKGROUND; the menu paints immediately.
if creds_present && [ -x "$APPDIR/bin/lodor-ts.sh" ] && "$APPDIR/bin/lodor-ts.sh" available >/dev/null 2>&1; then
	if command -v setsid >/dev/null 2>&1; then
		setsid "$APPDIR/bin/lodor-ts.sh" reconnect >> "$LOG" 2>&1 &
	else
		"$APPDIR/bin/lodor-ts.sh" reconnect >> "$LOG" 2>&1 &
	fi
fi

# Hand off to the wizard (fb0-first). It locates the engine via LODOR_BIN and writes
# config.json into LODOR_PAK_DIR. HONEST failure: if the framebuffer/input can't be
# opened it exits non-zero and logs why - say so on the console instead of pretending.
log "handing to wizard"
cd "$APPDIR" || exit 1
LODOR_BIN="$APPDIR/lodor-sync" "$APPDIR/lodor-wizard" >> "$LOG" 2>&1
rc=$?
log "wizard exit rc=$rc"
if [ "$rc" != 0 ]; then
	echo "Lodor: the framebuffer UI could not start (wizard rc=$rc - fb0/input open failed?)."
	echo "Lodor: details in $LOG. An SDL/KMS fallback for GPU-composited Knulli devices is a documented follow-up."
fi
exit 0
