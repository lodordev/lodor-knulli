# Lodor for Knulli

Turns a Knulli (Batocera-family) handheld into a thin client for your own RomM server:
your whole library shows up in EmulationStation as tiny placeholder files, a game
downloads over Wi-Fi the moment you launch it, and saves sync to the server around every
play session. The device stays offline otherwise.

## Install

1. Extract `Lodor-Knulli-<version>.zip` **onto `/userdata`** (over the network share
   `\\KNULLI\share`, or onto the second SD card's `share` partition). You should end up
   with:
   - `/userdata/system/lodor/` — the app: engine (`lodor-sync`), UI (`lodor-wizard`),
     helper scripts, bundled CA certificates and Tailscale binaries
   - `/userdata/system/scripts/lodor-hook.sh` — the launch hook (fetch-on-launch +
     save sync around every game; Batocera runs it automatically before/after each game)
   - `/userdata/system/services/lodor` — the boot service (starts the charging-gated
     background save-sync daemon)
   - `/userdata/roms/ports/Lodor.sh` — the "Lodor" entry under Ports in EmulationStation
2. Open **Ports → Lodor** once. First run walks you through pairing with your RomM
   server and mirroring your library; it also enables the boot service and makes sure
   the hook is executable.
   (Or enable the service by hand: Main Menu → System Settings → Services → **lodor**.)
3. Connect Wi-Fi in Knulli's own **Network Settings** — Lodor never touches the radio,
   it only checks whether you're online.

## What each piece does

| Piece | Job |
|---|---|
| `system/lodor/lodor-sync` | The headless engine. ALL RomM logic: pairing, catalog mirror, hash-verified downloads, save push/pull, BIOS, collections. |
| `system/lodor/lodor-wizard` | Framebuffer UI: onboarding + the Sync-now / Refresh / Tailscale menu, and the one-frame launch splashes. |
| `system/scripts/lodor-hook.sh` | Batocera configgen hook. `gameStart`: 0-byte stub → download (honest on-screen failure if offline), then opportunistic save pull. `gameStop`: push the save (or queue it offline), reconcile the ✘/✓ marker, refresh gamelists. Never blocks a launch. |
| `system/services/lodor` | `start`: re-assert executable bits + launch `romm-syncd`. `stop`: kill it. |
| `system/lodor/bin/romm-syncd` | Tiny poll loop: only when **charging**, **not in a game** and **paired**, pushes the offline save queue. |
| `roms/ports/Lodor.sh` | The ES-launchable app entry (Ports). Self-heals install state on every open. |

## Uninstall

Disable the `lodor` service, then delete `/userdata/system/lodor`,
`/userdata/system/scripts/lodor-hook.sh`, `/userdata/system/services/lodor` and
`/userdata/roms/ports/Lodor.sh`. Downloaded games and saves stay where they are.

## Phase-D hardware checklist (first on-device test)

- [ ] Does `lodor-wizard` render on `/dev/fb0` on a GPU/KMS Knulli build, or does it need
      the documented SDL fallback? (Ports → Lodor; check `system/lodor/romm.log`.)
- [ ] Do 0-byte stubs show up in EmulationStation's game lists, and does launching one
      drive the hook (splash → download → play)? Does ES's scraper leave them alone?
- [ ] `curl http://127.0.0.1:1234/reloadgames` — is the ES webserver on by default on
      Knulli, and does the post-game gamelist refresh land without a menu restart?
- [ ] Save round-trip on real hardware: play → quit → push (or queue → charge → daemon
      push) → wipe → launch → pull restores.
- [ ] Archive formats: which stub extensions does each Knulli emulator accept, and does
      the `.7z`→raw extract path behave for NDS?
- [ ] Service semantics: does `batocera-services enable lodor` + reboot start the daemon
      (check `/tmp/lodor-syncd.pid`), and does shutdown call `stop`?
- [ ] `gameStart`/`gameStop` arg order matches this Knulli release's configgen
      (`<system> <emulator> <core> <rom>`).
