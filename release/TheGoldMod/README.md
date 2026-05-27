# TheGoldMod, Subnautica 2 Creature Transformation Mod

A UE4SS Lua mod for Subnautica 2 that lets you collect creature DNA and transform into any creature in the game.

## Features

- **27 transformable creatures** — small, medium, large, and leviathan tiers
- **DNA collection system** — use the Biosampler near creatures to extract DNA samples
- **Per-creature abilities** — every creature has a unique F (primary) and R (secondary) ability
- **Puppet architecture** — spawns the real creature Blueprint, syncs position to player at 60 Hz
- **Persistent DNA saves** — unlocked forms survive game restarts

## Controls

| Key | Action |
|-----|--------|
| `G` | Open/close creature selection wheel |
| `F` | Primary ability (when transformed) |
| `R` | Secondary ability (when transformed) |
| `H` | Revert to human (panic button) |
| `[` / `]` | Cycle previous/next form (debug) |
| `F8` | Unlock all forms instantly (debug) |
| `F9` | Reset all DNA progress (debug) |

## Installation

1. Install [UE4SS v3.0.1 Beta](https://github.com/UE4SS-RE/RE-UE4SS/releases) for Subnautica 2
2. Copy the `TheGoldMod` folder into:
   ```
   Subnautica2\Binaries\Win64\ue4ss\Mods\
   ```
3. Launch the game — the mod loads automatically

The folder must be named exactly `TheGoldMod` (UE4SS uses the folder name as the mod identifier).

## Requirements

- Subnautica 2 (Early Access, UE 5.6)
- UE4SS v3.0.1 Beta or later

## Known Issues

- Transformation causes a game crash ~40–70 seconds after spawning certain creature BPs due to the `UWEAIControllerTicker` C++ singleton. Revert to human before the crash window or keep sessions short.
- `spawnRisk = true` creatures (ElusiveLeviathan, VoidLeviathanMother, WaterSlug) are blocked from spawning.

## Architecture

- `main.lua` — entry point, keybinds, level hooks
- `creature_db.lua` — all creature stats and ability definitions
- `transformation.lua` — BP puppet spawn/sync system
- `traits.lua` — all active ability implementations
- `dna_system.lua` — DNA collection/processing and save/load
- `extractor_tool.lua` — Biosampler integration and creature proximity detection
- `wheel_bridge.lua` — UI selection wheel
