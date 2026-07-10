# Lodor for Knulli

A **no-fork** [RomM](https://github.com/rommapp/romm) client for stock
[Knulli](https://knulli.org) (Batocera-family CFW). Wireless library mirroring,
download-on-launch, and automatic save sync — delivered entirely through Knulli's own
extension surfaces (a Ports entry, the user script hook, and a boot service). Stock
Knulli stays stock: nothing in the firmware is patched or replaced.

Validated target: Anbernic RG35XX Flip (Allwinner H700, arm64).

## What it does

- **Mirror your RomM library** — every game on your server appears in EmulationStation
  (0-byte stubs for games not yet on the card).
- **Download on launch** — pick a game you don't have; it downloads over Wi-Fi
  (hash-verified), then launches. Already-downloaded games launch instantly, offline.
- **Automatic save sync** — saves are pulled before play and pushed after (or queued
  offline and pushed later by a charging-gated background daemon). Play the same game
  across devices without thinking about it.
- **On-device onboarding** — a built-in wizard (framebuffer UI) walks through server
  pairing on first launch; later launches offer Sync-now / re-setup.

## How it stays no-fork

| Piece | Knulli surface used |
|---|---|
| `Lodor` entry (wizard + sync menu) | `roms/ports/Lodor.sh` — a standard Ports entry |
| Download-on-launch + save bracket | `system/scripts/lodor-hook.sh` — Batocera's own per-game user script hook |
| Background save daemon | `system/services/lodor` — Batocera's user service |
| Wi-Fi, RetroArch, box art | stock Knulli — inherited, not re-implemented |

Launching a game is **never** gated on sync — if anything network-side fails, the game
still runs.

## Install

1. Extract `Lodor-Knulli-<version>.zip` **onto `/userdata`** (over the network share
   `\\KNULLI\share`, or onto the SD card's `share` partition).
2. Open **Ports → Lodor** once. First run walks you through pairing with your RomM
   server and mirroring your library; it also enables the boot service and the hook.
3. Connect Wi-Fi in Knulli's own **Network Settings** — Lodor never touches the radio.

Configuration lives in `system/lodor/` (`config.json`; see `config.json.example`).
The app ships the public Mozilla CA bundle so HTTPS verification works on-device, and
optional bundled Tailscale binaries for private server access.

## Update

Download the new `Lodor-Knulli-<version>.zip` and extract it onto `/userdata` again —
your pairing and settings are kept (`config.json` is never shipped in the zip).

## Build

The sync engine and wizard are CGO-free static Go binaries (Knulli variant is the
`knulli` build tag):

```sh
cd engine
CGO_ENABLED=0 GOARCH=arm64 go build -tags knulli -trimpath -ldflags "-s -w" ./cmd/lodor-sync
CGO_ENABLED=0 GOARCH=arm64 go build -tags knulli -trimpath -ldflags "-s -w" ./cmd/lodor-wizard
```

The release pipeline builds both, gates them (static, branding, PII, redistributable),
and assembles `Lodor-Knulli-<version>.zip`.

## Layout

```
userdata/
  roms/ports/Lodor.sh            # ES Ports entry → onboarding wizard / sync menu
  roms/ports/gamelist.xml        # name + description + icon for the Ports entry
  system/scripts/lodor-hook.sh   # launch hook: stub-fetch → save-pull → game → save-push
  system/services/lodor          # boot service (charging-gated offline save-push daemon)
  system/lodor/                  # engine, wizard, shell libs, certs, config
test/
  check.sh                       # shell-surface gate (parse + shellcheck)
  integ-harness.sh               # end-to-end sandbox harness
  launchcard-check.sh            # launch-card flow checks
```

## Related

- [lodor](https://github.com/lodordev/lodor) — the sync engine (all releases publish there too)
- [lodoros](https://github.com/lodordev/lodoros) — the MinUI-fork flagship for Miyoo devices
- [lodor-nextui](https://github.com/lodordev/lodor-nextui) — the NextUI (TrimUI) pak
- [lodor-muos](https://github.com/lodordev/lodor-muos) — the muOS app

## Notes

- BYOB: no BIOS or firmware is bundled, ever. Use the engine's `--download-bios`
  against your own server's collection.
- Saves are matched per libretro corename, exactly where stock RetroArch reads them.
