# Changelog

## [Unreleased]

### Added
- `PrevCreatureKey` and `NextCreatureKey` settings in `settings.txt` (default `[` and `]`) for cycling between creature forms in test mode
- Dynamic keybind system in `main.lua` with a VK lookup table (`_VK`) for punctuation keys that UE4SS cannot resolve by name, covering `[ ] ; ' , . / \ - = \``
- `ResolveKey(name)` helper that checks `_VK` before falling back to `Key[name]`, used for all six configurable keybinds
- `Prev Creature` and `Next Creature` rows in the TheGoldModSettings ImGui overlay panel, matching the new settings keys
- Corresponding fields (`prevCreatureKey`, `nextCreatureKey`) and char buffers in the `GMSettings` struct, `LoadSettings`, `SaveSettings`, `RenderContent`, and `SyncCustomBufs` in `dllmain.cpp`

### Changed
- Settings file renamed from `settings.ini` to `settings.txt` across all locations (mod requirement)
- `LoadSettings()` in `main.lua` now trims trailing whitespace and carriage returns from values using `(.-)%s*$`, preventing parse failures on Windows line endings
- `SaveSettings()` in `dllmain.cpp` now writes to `settings.txt` instead of `settings.ini`
- `[ ]` creature cycle keybinds changed from hardcoded VK codes 219/221 to `ResolveKey(_PREV_KEY)` / `ResolveKey(_NEXT_KEY)`, making them fully configurable via settings

### Fixed
- Crash occurring 2-10 seconds after transforming into a creature (`UWEAnimNotify_AbilityNotify` / `SN2AnimNotify_ShapeOverlap` native access violation on the game thread)
  - AI controller is now destroyed after `UnPossess()` instead of left alive, removing it from the `UWEAIControllerTicker` registry
  - `SetAnimationMode(0)` (AnimationSingleNode) is called on the puppet mesh via `GetMesh()` immediately after spawn, disabling AnimBlueprint evaluation so no AnimNotifies can fire
  - Fixed mesh access: `puppet:GetMesh()` (UFUNCTION call) is used instead of `puppet.Mesh` (property access), which returned nil for spawned creature Blueprint actors in UE4SS

---

## [0.1.0] - Initial release

- Creature transformation system using puppet architecture
- Spawns real creature Blueprint actors and syncs position to the hidden player at 60 Hz
- 28 creature forms with configurable swim speed, gravity scale, and capsule size
- Configurable keybinds for wheel, primary action, secondary action, and revert via `settings.txt`
- TheGoldModSettings DLL overlay (ImGui, D3D12) for in-game settings editing with Ctrl+R to apply
- Auto-unlock mode controlled by `AutoUnlock` setting
- DNA system tracking collected creature forms
- Third-person camera via `ToggleThirdPerson` on transformation
