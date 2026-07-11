#!/bin/sh
# lodor-hook.sh - Batocera/Knulli configgen user-script hook for Lodor.  MARKER: LODOR_HOOK
#
# Installed at /userdata/system/scripts/lodor-hook.sh (MUST be +x - configgen silently
# skips non-executable scripts). Batocera's configgen runs every script in that dir
# BLOCKING (subprocess.call) with positional args:
#     gameStart <system> <emulator> <core> <rom>   (after config-gen, BEFORE the emulator)
#     gameStop  <system> <emulator> <core> <rom>   (after the emulator exits)
# Unlike muOS we never replace the launcher - we BRACKET it:
#     gameStart = stub fetch-on-launch + opportunistic save pull-before
#     gameStop  = save push/queue + marker reconcile + gamelist refresh
#
# HARD RULES:
#  - NEVER block the launch pipeline hard: every failure logs + exits 0. A stub we could
#    not download stays 0-byte; the emulator then fails on the empty file LOUDLY and the
#    on-screen splash + log already said exactly why.
#  - NEVER add meaningful latency to a non-stub launch: every network call is guarded by
#    the stub / already-reachable conditions and hard-bounded.

EVENT="${1:-}"
case "$EVENT" in gameStart|gameStop) ;; *) exit 0 ;; esac
shift
SYSTEM="${1:-}"; EMU="${2:-}"; CORE="${3:-}"; ROM="${4:-}"; ROM="${ROM%/}"
[ -n "$ROM" ] || exit 0

# Resolve the lib: env override (sandbox harness) -> fixed Batocera path -> relative
# (this script and system/lodor share a parent). If the lib is missing we MUST leave the
# stock launch untouched - exit 0, no side effects.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0" 2>/dev/null || echo "$0")")" && pwd 2>/dev/null)
LIB=""
for c in "${LODOR_APPDIR:+$LODOR_APPDIR/lib/romm-sync-lib.sh}" \
         /userdata/system/lodor/lib/romm-sync-lib.sh \
         "$SELF_DIR/../lodor/lib/romm-sync-lib.sh"; do
	[ -n "$c" ] && [ -f "$c" ] && { LIB="$c"; break; }
done
[ -z "$LIB" ] && exit 0
. "$LIB"
lodor_export_env

# Tailscale (tier-1) lib lives next to romm-sync-lib.sh. A tier-2 (direct) host never
# touches this; if the lib is absent the tier-1 helpers below no-op to "not tier-1".
TS_LIB="$(dirname -- "$LIB")/tailscale-lib.sh"
[ -f "$TS_LIB" ] && . "$TS_LIB" 2>/dev/null

# Display-only name: ROM basename minus extension, minus the leading cloud/on-device
# marker (#183 pattern: the splash font is ASCII-only; ✘/✓ would render as "?????").
# $ROM stays raw - the file on the card genuinely carries the marker.
NAME=$(basename "$ROM"); NAME="${NAME%.*}"
NAME_DISP="$NAME"
case "$NAME_DISP" in
	"✘ "*)   NAME_DISP="${NAME_DISP#✘ }" ;;
	"✓ "*)   NAME_DISP="${NAME_DISP#✓ }" ;;
	"[^] "*)  NAME_DISP="${NAME_DISP#\[^\] }" ;;
	"[v] "*)  NAME_DISP="${NAME_DISP#\[v\] }" ;;
esac

# Batocera sorts saves per-SYSTEM (/userdata/saves/<system>/), not per-core - pin the
# engine's save subdir to the system configgen just told us. No corename resolution needed.
[ -n "$SYSTEM" ] && export LODOR_SAVE_SUBDIR="$SYSTEM"

# engine() - EVERY engine call goes through this: the engine loads config.json CWD-relative
# (RG34XX field bug 2026-07-04), so cd to $DATA_DIR in a subshell first.
engine() { ( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR failed (engine $1)"; "$BIN" "$@" ); }

# splash <title> <body> [good|bad] - best-effort one-frame fb0 feedback via the wizard's
# pure-Go presenter. NEVER gates the launch, NEVER fakes progress: if the wizard binary or
# fb0 is unavailable it just logs; the /tmp/romm-phase line still carries the honest status.
splash() {
	_wz="$APPDIR/lodor-wizard"
	[ -x "$_wz" ] || { log "splash unavailable (no wizard bin) - phase-only: $1"; return 0; }
	LODOR_BIN="$BIN" "$_wz" --splash "$1" "$2" "${3:-}" >> "$LOG" 2>&1 \
		|| log "splash render failed (fb busy?) - phase-only: $1"
}

# ensure_tunnel_up - SYNCHRONOUS tier-1 gate for the download path. For a Tailscale/SOCKS5
# host the engine dials RomM THROUGH the userspace tunnel; it must be Running before any
# --download or the dial just times out. Bounded (~25s inside tailscale_up). Tier-2 = no-op.
ensure_tunnel_up() {
	command -v tailscale_is_tier1 >/dev/null 2>&1 || return 0   # lib absent -> treat as tier-2
	tailscale_is_tier1 || return 0                              # tier-2 (direct) host
	[ "$(tailscale_status 2>/dev/null)" = "connected" ] && return 0
	phase "Connecting to your server..."
	splash "Connecting" "Reaching your server over Tailscale..." good
	tailscale_up >> "$LOG" 2>&1
	[ "$(tailscale_status 2>/dev/null)" = "connected" ]
}

# server_reachable - cheap gate for the OPPORTUNISTIC save pull/push (never brings anything
# up, adds <1s when dark). Tier-1 also needs the tunnel Running or the engine would burn its
# whole timeout on a dead SOCKS5 dial.
server_reachable() {
	wifi_is_up || return 1
	command -v tailscale_is_tier1 >/dev/null 2>&1 || return 0
	tailscale_is_tier1 || return 0
	[ "$(tailscale_status 2>/dev/null)" = "connected" ]
}

# =========================== gameStart ====================================================
if [ "$EVENT" = "gameStart" ]; then
	# In-game marker for the daemon (don't fight the session for the radio). Our own PID
	# dies when this hook returns; $PPID is the configgen process, which lives for the
	# whole emulation session and whose death makes the lock stale (not_in_game reaps it).
	echo "$PPID" > "$INGAME_LOCK" 2>/dev/null
	log "gameStart SYSTEM=$SYSTEM EMU=$EMU CORE=$CORE ROM=$ROM"

	# --- 1. Fetch-on-launch: a 0-byte stub means the real ROM isn't on the card yet. ----
	if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
		phase "Downloading $NAME_DISP..."
		splash "Downloading" "$NAME_DISP" good
		NET_OK=0; TS_FAIL=0
		if wifi_bring_up; then
			if ensure_tunnel_up; then NET_OK=1
			else TS_FAIL=1; log "fetch-on-launch: Tailscale tunnel not Running - cannot reach tier-1 server"; fi
		else
			log "fetch-on-launch: no network"
		fi
		DL_OK=0
		if [ "$NET_OK" = 1 ]; then
			DL_OUT="/tmp/lodor-dl.$$"
			engine --download "$ROM" > "$DL_OUT" 2>&1; DL_RC=$?
			cat "$DL_OUT" >> "$LOG" 2>/dev/null
			# HONEST success: engine rc=0 AND its own hash-verified "downloaded=1" verdict
			# AND the file really has bytes now.
			if [ "$DL_RC" = 0 ] && grep -q 'downloaded=1' "$DL_OUT" 2>/dev/null && [ -s "$ROM" ]; then
				DL_OK=1
			elif [ ! -s "$ROM" ]; then
				# RETRY ONCE: a first --download can race a tunnel that only just reached
				# Running. Cheap insurance against the cold-start race.
				log "fetch-on-launch: first --download did not land - retry once"
				ensure_tunnel_up >> "$LOG" 2>&1
				engine --download "$ROM" > "$DL_OUT" 2>&1; DL_RC=$?
				cat "$DL_OUT" >> "$LOG" 2>/dev/null
				if [ "$DL_RC" = 0 ] && grep -q 'downloaded=1' "$DL_OUT" 2>/dev/null && [ -s "$ROM" ]; then
					DL_OK=1
				fi
			fi
			rm -f "$DL_OUT" 2>/dev/null
		fi
		if [ ! -s "$ROM" ]; then
			# HONEST, LOUD failure - real cause + real fix - then exit 0: we cannot abort
			# Batocera's pipeline from a hook, and we must not block it. The emulator will
			# fail on the empty file; the splash (held briefly) + log say exactly why.
			phase "Download failed"
			if [ "$TS_FAIL" = 1 ]; then
				splash "Can't reach your server" "Tailscale isn't connected. Check Wi-Fi, or open Ports -> Lodor -> Tailscale -> Reconnect, then launch again." bad
			elif wifi_is_up; then
				splash "Download failed" "Couldn't download $NAME_DISP. The server or transfer failed - check your RomM server, then launch again." bad
			else
				splash "No Wi-Fi" "Can't download $NAME_DISP while offline. Connect Wi-Fi in Knulli's Network Settings, then launch again." bad
			fi
			log "fetch-on-launch FAILED (rom still empty) - emulator will fail on the empty file; exit 0 (never block the pipeline)"
			sleep 3
			exit 0
		fi
		phase "Downloaded $NAME_DISP"
	fi

	# --- 1b. Multi-disc next-disc fetch (lodor#7 disc-1-first). ---------------------
	# The engine downloads multi-disc games DISC-1-FIRST and writes a LOCAL-ONLY
	# .m3u (only discs with real bytes are listed; later discs are folder stubs +
	# a manifest canonical list). A populated .m3u is NOT a 0-byte stub, so step
	# 1's gate can never re-trigger for it — this block is the re-trigger, keyed
	# off `engine --check-rom` (manifest census; the local-only playlist's own
	# refs always read "complete"). One disc per launch (--fetch-next-disc,
	# idempotent); the daemon prefetch completes the set in the background.
	# RetroArch boots the m3u's first entry, so with disc 1 present the game
	# launches even if this fetch fails — never a harder gate than the game needs
	# (we cannot abort Batocera's pipeline anyway); a missing disc 1 gets the stub
	# path's full network treatment and, on failure, the same honest splash +
	# exit 0. Skipped right after a stub fill (disc 1 just landed this launch —
	# one disc per launch is the design).
	lodor_m3u_for() {
		case "$1" in
			*.m3u) printf '%s' "$1"; return 0 ;;
		esac
		_gd=$(dirname "$1"); _pd=$(dirname "$_gd"); _gn=$(basename "$_gd")
		_cand="$_pd/$_gn.m3u"
		[ -f "$_cand" ] && printf '%s' "$_cand"
	}
	# 0 (true) if the engine's OFFLINE completeness gate says the disc set is
	# incomplete (RESULT complete=0). --check-rom runs pre-config: filesystem +
	# mirror manifest only, never the radio. FAIL-OPEN: no engine binary /
	# unparseable output -> 1 ("complete") -> no fetch, launch as before.
	lodor_rom_incomplete() {
		[ -x "$BIN" ] || return 1
		_ckout=$(engine --check-rom "$1" 2>/dev/null)
		case "$_ckout" in *"complete=0"*) return 0 ;; esac
		return 1
	}
	# 0 (true) if the FIRST listed disc is missing/0-byte (empty list = broken).
	lodor_m3u_first_missing() {
		_m="$1"; [ -f "$_m" ] || return 0
		_dir=$(dirname "$_m"); _CR=$(printf '\r')
		while IFS= read -r _line || [ -n "$_line" ]; do
			_line=${_line%"$_CR"}
			[ -n "$_line" ] || continue
			case "$_line" in \#*) continue ;; esac
			case "$_line" in
				/*) _dp="$_line" ;;
				*)  _dp="$_dir/$_line" ;;
			esac
			[ -s "$_dp" ] && return 1
			return 0
		done < "$_m"
		return 0
	}
	LODOR_M3U="$(lodor_m3u_for "$ROM")"
	if [ -n "$LODOR_M3U" ] && [ -s "$LODOR_M3U" ] && [ "${DL_OK:-0}" != 1 ] && lodor_rom_incomplete "$LODOR_M3U"; then
		if lodor_m3u_first_missing "$LODOR_M3U"; then
			# Disc 1 itself missing: unlaunchable without it — the stub path's job.
			phase "Downloading $NAME_DISP..."
			splash "Downloading" "$NAME_DISP (disc 1)" good
			if wifi_bring_up && ensure_tunnel_up; then
				engine --fetch-next-disc "$LODOR_M3U" >> "$LOG" 2>&1 || log "next-disc fetch (disc 1) failed"
			else
				log "next-disc fetch (disc 1): no network"
			fi
			if lodor_m3u_first_missing "$LODOR_M3U"; then
				phase "Download failed"
				if wifi_is_up; then
					splash "Download failed" "Couldn't download $NAME_DISP's first disc - check your RomM server, then launch again." bad
				else
					splash "No Wi-Fi" "Can't download $NAME_DISP's disc while offline. Connect Wi-Fi in Knulli's Network Settings, then launch again." bad
				fi
				log "next-disc fetch FAILED (disc 1 still missing) - emulator will fail on the missing disc; exit 0 (never block the pipeline)"
				sleep 3
				exit 0
			fi
		elif server_reachable; then
			# Disc 1 present: fetch the next missing disc OPPORTUNISTICALLY (no cold
			# bring-up — an offline relaunch stays instant). Failure -> the game still
			# launches on the discs it has; the daemon prefetch completes the set.
			phase "Downloading $NAME_DISP (next disc)..."
			splash "Downloading" "$NAME_DISP - fetching the next disc" good
			engine --fetch-next-disc "$LODOR_M3U" >> "$LOG" 2>&1 \
				|| log "next-disc fetch failed (non-blocking) - launching on the discs present"
			phase "Ready"
		else
			log "multi-disc incomplete but server not reachable - launching on the discs present (daemon will prefetch)"
		fi
	fi

	# --- 2. Launch gate (Handoff, task #24 - 2026-07-07): when the server is
	# ALREADY reachable (radio warm from a stub fetch, or Wi-Fi kept on - never a cold
	# bring-up), the wizard probes for anything NEWER (save lineage; unseen compatible
	# state) and shows the interactive launch card ONLY then - silent instant
	# pass-through otherwise. The user chooses: continue from the state / pull the
	# save / just play. Bounded by timeout (a walked-away card must not hold the
	# pipeline); any failure falls through to launch. Wizard absent -> the old
	# silent save pull, so a partial install degrades to known behavior. ------------
	if server_reachable; then
		lodor_ensure_device
		_WIZ="$APPDIR/lodor-wizard"
		if [ -x "$_WIZ" ]; then
			if command -v timeout >/dev/null 2>&1; then
				( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (card)"; LODOR_BIN="$BIN" exec timeout 90 "$_WIZ" --launch-card "$ROM" ) >> "$LOG" 2>&1 || log "launch-card skipped (non-blocking)"
			else
				( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (card)"; LODOR_BIN="$BIN" "$_WIZ" --launch-card "$ROM" ) >> "$LOG" 2>&1 || log "launch-card skipped (non-blocking)"
			fi
		elif command -v timeout >/dev/null 2>&1; then
			( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (pull)"; exec timeout 25 "$BIN" --sync-save "$ROM" ) >> "$LOG" 2>&1
		else
			engine --sync-save "$ROM" >> "$LOG" 2>&1
		fi
	fi
	exit 0
fi

# =========================== gameStop =====================================================
# The emulator has exited; RetroArch already wrote any battery save to
# /userdata/saves/<system>/. Push now if the server is reachable, else queue for the
# daemon. A quit must never block on the radio (offline-first).
log "gameStop SYSTEM=$SYSTEM ROM=$ROM"
_rb=$(basename "$ROM"); _rbne="${_rb%.*}"
SAVED="${SAVES_DIR:-/userdata/saves}/$SYSTEM"
[ -d "$SAVED" ] || SAVED="${SAVES_DIR:-/userdata/saves}"
# Escape find's fnmatch metachars in the stem (#162: No-Intro names carry [!]/[T-En] etc).
# Order-safe: `]`->placeholder first so the `[`->`[[]` pass can't re-mangle a just-emitted
# bracket, then placeholder->`[]]`.
_rb_g=$(printf %s "$_rb" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
_rbne_g=$(printf %s "$_rbne" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
# NAME-FILTER ONLY, no mtime test (CLOCK-FIX 2026-06-30: a stale RTC made fresh saves look
# old and silently skipped the push; the engine MD5-dedups so an unchanged save is a
# verified no-op, not a redundant transfer).
if find "$SAVED" \( \
	-iname "$_rbne_g.srm" -o -iname "$_rbne_g.sav" -o -iname "$_rbne_g.dsv" \
	-o -iname "$_rbne_g.mcr" -o -iname "$_rbne_g.mcd" -o -iname "$_rbne_g.brm" \
	-o -iname "$_rbne_g.eep" -o -iname "$_rbne_g.sra" -o -iname "$_rbne_g.fla" \
	-o -iname "$_rbne_g.mpk" -o -iname "$_rbne_g.nv" -o -iname "$_rbne_g.rtc" \
	-o -iname "$_rbne_g.state*" \
	-o -iname "$_rb_g.srm" -o -iname "$_rb_g.sav" -o -iname "$_rb_g.dsv" \
	-o -iname "$_rb_g.mcr" -o -iname "$_rb_g.mcd" -o -iname "$_rb_g.brm" \
	-o -iname "$_rb_g.eep" -o -iname "$_rb_g.sra" -o -iname "$_rb_g.fla" \
	-o -iname "$_rb_g.mpk" -o -iname "$_rb_g.nv" -o -iname "$_rb_g.rtc" \
	-o -iname "$_rb_g.state*" \
\) 2>/dev/null | grep -q .; then
	if server_reachable; then
		lodor_ensure_device
		engine --push-save "$ROM" >> "$LOG" 2>&1 \
			|| { grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"; log "push failed -> queued pending"; }
	else
		grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
		log "save present, offline -> queued pending"
	fi
fi

# Handoff v1: push new save STATES after the battery save (additive-only; the
# engine dedups vs its ledger and no-ops honestly without statecores.json).
# Best-effort — a state push can never block the quit path. Offline queues the
# rom into pending-states.txt (--queue-state: no network, instant); the online
# branch drains that queue after pushing the current rom's states.
if server_reachable; then
	engine --push-states "$ROM" >> "$LOG" 2>&1 || log "push-states failed (non-blocking)"
	engine --push-pending-states >> "$LOG" 2>&1 || log "push-pending-states failed (non-blocking)"
else
	engine --queue-state "$ROM" >> "$LOG" 2>&1 || log "queue-state failed (non-blocking)"
fi

# Marker reconcile: filesystem-only + offline; safe now the emulator has exited (renaming
# in the download->launch window would pull the file out from under the launcher). Only a
# non-empty (on-device) file can earn its ✓ - a still-stub game is skipped.
if [ -s "$ROM" ]; then
	engine --reconcile "$ROM" >> "$LOG" 2>&1 || log "reconcile failed - marker stays until next refresh"
fi

# ES gamelist refresh: names/covers on Knulli come from gamelist.xml, not the filename -
# the engine's --write-gamelists mode emits them (landing from the parallel engine work).
# Tolerate its absence honestly until it exists.
engine --write-gamelists >> "$LOG" 2>&1 \
	|| log "write-gamelists unavailable (engine mode not landed yet) - gamelist.xml unchanged"
# Ask EmulationStation to reload gamelists via its local webserver - best-effort (the
# webserver may be disabled; 2s cap so a dead port can't stall the quit path).
curl -s -m 2 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true

rm -f "$INGAME_LOCK" 2>/dev/null
exit 0
