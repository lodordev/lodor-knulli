#!/bin/sh
# romm-sync-lib.sh - shared Knulli (Batocera-family) Lodor library. Sourced by
# lodor-hook.sh, romm-run, romm-syncd, lodor-ts.sh and the Ports entry (Lodor.sh).
#  MARKER: LODOR_KNULLI_LIB
#
# HARD PRINCIPLES (carried from the muOS/MinUI builds, learned the hard way):
#  1. LEAN ON KNULLI'S STOCK MECHANISMS. Wi-Fi is connman's job (Knulli Network settings)
#     - Lodor ships ZERO wifi code: wifi_bring_up below is CHECK-ONLY and NEVER touches
#     the radio. Game launching is Batocera configgen's job - we bracket it via the
#     /userdata/system/scripts hook (gameStart/gameStop), we never replace it.
#  2. HONEST UI. Every status line written to /tmp/romm-phase reflects CONFIRMED state.
#     On failure we write the SPECIFIC real reason, never fake forward-progress.
#  3. FIXED BATOCERA LAYOUT. Unlike muOS (paths move between releases -> detect-and-
#     reheal), Batocera's /userdata layout is a stable documented contract
#     (roms/saves/bios/system). We pin it; env overrides exist for the off-hardware
#     sandbox harness ONLY.
#
# CGO-free shell; no bashisms beyond POSIX sh (Knulli's /bin/sh is busybox ash).

# --- App + data locations (fixed Batocera layout; LODOR_APPDIR override = sandbox) ------
APPDIR="${LODOR_APPDIR:-/userdata/system/lodor}"
BIN="$APPDIR/lodor-sync"
DATA_DIR="$APPDIR"                       # config.json, catalog-index.json, pending live here
LOG="$DATA_DIR/romm.log"
PHASE="/tmp/romm-phase"                  # honest one-line status the splash/menu reads
PROGRESS="/tmp/dl-progress"              # 0..100 the engine writes during downloads
INGAME_LOCK="/tmp/romm-in-game"
PENDING="$DATA_DIR/pending-saves.txt"

# Sysfs roots - parametrized ONLY so the no-root sandbox harness can fake link/battery
# state. On hardware these are always the real /sys trees.
LODOR_NET_SYS="${LODOR_NET_SYS:-/sys/class/net}"
LODOR_POWER_SYS="${LODOR_POWER_SYS:-/sys/class/power_supply}"

log() { echo "$(date +'%F %T') $*" >> "$LOG" 2>/dev/null; }
phase() { echo "$1" > "$PHASE" 2>/dev/null; }   # HONEST: only call with a confirmed-true line

# Export the env the engine needs. Batocera contract paths, pinned.
lodor_export_env() {
	# LODOR_PAK_DIR is the canonical app-working-dir env (engine PakDir() + wizard);
	# LODOR_DATA_DIR is kept ONLY as a back-compat alias for older scripts.
	export LODOR_PAK_DIR="$DATA_DIR"
	export LODOR_DATA_DIR="$DATA_DIR"
	export PLATFORM="${PLATFORM:-knulli}"
	PLAT="${PLAT:-knulli}"; export PLAT     # tailscale-lib device tag (sourced after us)
	export ROMS_DIR="${ROMS_DIR:-/userdata/roms}"
	export SAVES_DIR="${SAVES_DIR:-/userdata/saves}"
	export BIOS_DIR="${BIOS_DIR:-/userdata/bios}"
	export SDCARD_PATH="${SDCARD_PATH:-/userdata}"
	# TLS: the engine is a static Go binary; point Go's TLS at a CA bundle so HTTPS RomM
	# servers verify. Prefer our bundled certs, fall back to the system store if present.
	if [ -z "${SSL_CERT_FILE:-}" ]; then
		for c in "$APPDIR/certs/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt; do
			[ -f "$c" ] && { export SSL_CERT_FILE="$c"; break; }
		done
	fi
}

# --- Network: CHECK-ONLY. Knulli owns Wi-Fi via connman; we never touch the radio. ------
# A link counts when SOME non-loopback interface is operstate=up AND carries an inet
# address (wlan*, but also eth*/usb* - docked devices are online too).
wifi_is_up() {
	for _wd in "$LODOR_NET_SYS"/*; do
		[ -d "$_wd" ] || continue
		_ifc="${_wd##*/}"
		[ "$_ifc" = "lo" ] && continue
		[ "$(cat "$_wd/operstate" 2>/dev/null)" = "up" ] || continue
		ip addr show "$_ifc" 2>/dev/null | grep -q "inet " && return 0
	done
	return 1
}

# wifi_bring_up: NAME kept for source-compat with romm-run/romm-syncd (they call it before
# every network action), but on Knulli it is a CHECK, not a bring-up: connman owns the
# radio and racing it from shell caused nothing but grief on other hosts. Returns 0 only
# on a CONFIRMED live link; on failure it points the user at Knulli's own Network settings.
wifi_bring_up() {
	wifi_is_up && { phase "Network connected"; return 0; }
	phase "No network - connect Wi-Fi in Knulli's Network Settings (Main Menu), then retry"
	return 1
}

# lodor_ensure_device - quiet first-run heal (live-leg find, 2026-07-06): a preseeded or
# card-cloned config carries a token but NO device_id (the release device-state strip is
# the contract), and every save-sync engine mode hard-requires one - so saves would
# silently never sync until a full re-onboarding. When the config is paired but
# unregistered AND the server is already reachable, register ONCE under the board's
# real name. Callers proceed regardless of the outcome: on failure the engine keeps
# refusing loudly (honest), and the next reachable bracket retries.
lodor_ensure_device() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q \"device_id\" "$DATA_DIR/config.json" 2>/dev/null && return 0
	grep -q \"token\" "$DATA_DIR/config.json" 2>/dev/null || return 1
	_dn=$({ tr -d "\\0" < /sys/firmware/devicetree/base/model; } 2>/dev/null)
	[ -n "$_dn" ] || _dn=$(hostname 2>/dev/null)
	[ -n "$_dn" ] || _dn="handheld"
	case "$_dn" in [Kk]nulli*) ;; *) _dn="Knulli $_dn" ;; esac
	log "first run with a paired-but-unregistered config - registering device as: $_dn"
	phase "First run - registering this device..."
	( cd "$DATA_DIR" 2>/dev/null && "$BIN" --register-device "$_dn" ) >> "$LOG" 2>&1 \
		|| log "device registration failed (will retry next time the server is reachable)"
}

# --- clock: bounded NTP after we're verified-online (RTC-less devices boot in 1970) -----
set_clock_bounded() {
	command -v ntpd >/dev/null 2>&1 || return 0
	phase "Setting the clock..."
	( ntpd -q -n -p pool.ntp.org >/dev/null 2>&1 ) & _cp=$!
	_w=0; while kill -0 "$_cp" 2>/dev/null && [ "$_w" -lt 15 ]; do sleep 1; _w=$((_w + 1)); done
	kill -0 "$_cp" 2>/dev/null && { kill -9 "$_cp" 2>/dev/null; killall -9 ntpd 2>/dev/null; }
	return 0
}

# --- charging gate (daemon): generic sysfs scan - Knulli spans many boards (H700,
# RK35xx, ...), so no single battery node name is assumed. Charging OR Full counts. ------
is_charging() {
	for n in "$LODOR_POWER_SYS"/*/status; do
		[ -f "$n" ] || continue
		s="$(cat "$n" 2>/dev/null)"
		[ "$s" = "Charging" ] || [ "$s" = "Full" ] && return 0
	done
	return 1
}

creds_present() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q '"token"' "$DATA_DIR/config.json" 2>/dev/null || grep -q '"password"' "$DATA_DIR/config.json" 2>/dev/null
}

not_in_game() {
	[ -f "$INGAME_LOCK" ] || return 0
	_p="$(cat "$INGAME_LOCK" 2>/dev/null)"
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 1
	rm -f "$INGAME_LOCK" 2>/dev/null   # stale lock (session died without gameStop) - reap
	return 0
}
