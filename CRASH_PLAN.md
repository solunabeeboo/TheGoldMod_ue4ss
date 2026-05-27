# TheGoldMod — Crash Diagnosis & Fix Plan
Last updated: 2026-05-26 (session 3)

---

## GOAL
Zero crashes during transformation.

---

## CURRENT ARCHITECTURE (as of session 2)
SkeletalMeshActor puppet — NOT creature BPs.

- Spawn `/Script/Engine.SkeletalMeshActor` at player location
- Set creature SkeletalMesh via `SetSkeletalMeshAsset`
- Sync position to player every 50ms (SyncTick)
- Hide real player via `TogglePlayerCharacterVisibility`
- No UWEAIController, no UWEAIControllerTicker registration, no AI at all

**Why the architecture changed:**
Every `UWEAICharacter` BP spawn auto-registers a controller with `UWEAIControllerTicker`
(C++ singleton, no Lua API). No combination of post-spawn modifications could prevent
the ticker from eventually crashing on it. SkeletalMeshActor has zero AI components.

---

## CONFIRMED CRASH CAUSES

### Crash A — Puppet killed by world AI (~8s) — IRRELEVANT
- SkeletalMeshActor is not UWEAIPawn, world AI does not target it.

### Crash B — UWEAIControllerTicker (~40-71s) — IRRELEVANT
- SkeletalMeshActor spawns no controller, never registers with ticker.

### Crash C — Stale respawn callbacks (~30s) — IRRELEVANT
- No respawn cycle, no callbacks scheduled.

### Crash D — PostProcessAnimBlueprint (~6s) — CONFIRMED FIXED
- `SetSkeletalMesh` → `InitAnim` instantiates the mesh's PostProcessABP (e.g. Electric Geordie
  has a UWE ABP with `UWEAnimNotify_AbilityNotify`). That ABP runs as a SEPARATE `UAnimInstance`
  and fires notifies independently. `bFireNotifyEvents` on the main instance does NOT affect it.
- **FIX:** `SetDisablePostProcessBlueprint(true)` called before PlayAnimation.
  Confirmed working — crash moved from ~6s to ~10s.
- **NOTE:** Must be called BEFORE PlayAnimation (which calls InitAnim internally). The flag
  persists on SkeletalMeshComponent across InitAnim calls.

### Crash E — Main animation AnimNotifies (~5-10s) — INVESTIGATING
- `AS_ElectricGeordie_01_Swim` contains `UWEAnimNotify_AbilityNotify` and/or
  `SN2AnimNotify_ShapeOverlap` at ~5-10s keyframe. These call GetOwner() → cast to
  UWEAIPawn → null on SkeletalMeshActor → AV crash.
- **Approach:** `bFireNotifyEvents=false` on the AnimSingleNodeInstance suppresses all
  notify dispatch for that instance. Verified via readback (write+read the C++ UPROPERTY).
  Re-suppressed every SyncTick (50ms).
- **Status (session 3):** PlayAnimation + readback implemented. Untested this session.

---

## WHAT WE HAVE TRIED — RESULTS

| Change | Result | Notes |
|---|---|---|
| Creature BP puppet | ~40-71s crash | Crash B. UWEAIControllerTicker. |
| SkeletalMeshActor + PlayAnimation | ~6s crash | Crash D. PostProcessABP. |
| + SetDisablePostProcessBlueprint(true) | ~10s crash | Crash D fixed, Crash E exposed. |
| + SetAnimationMode(1) approach | NO CRASH, no animation | SetAnimationMode ok=false from Lua (enum marshal fail). |
| + PlayAnimation + bFireNotifyEvents readback | UNTESTED | Session 3 implementation. |

---

## WHAT CAUSES CRASHES — DEFINITIVE LIST

**BANNED operations:**
- Any modification to a `UWEAIController` — always causes faster crashes
- Spawning `UWEAICharacter` BPs as puppets — ticker crash is unavoidable
- `K2_ClearAllTimers` on any object — partially executes C++, kills vital timers

**NOT banned but requires suppression:**
- `PlayAnimation` on creature `UAnimSequence` — safe IF `bFireNotifyEvents=false` is
  confirmed via readback before notifies fire. BANNED if suppression readback returns non-false.

**CONFIRMED safe:**
- `SetSkeletalMeshAsset` on SkeletalMeshComponent
- `SetDisablePostProcessBlueprint(true)` on SkeletalMeshComponent
- `SetCollisionEnabled(0)` on SkeletalMeshComponent
- `K2_SetActorLocationAndRotation` on SkeletalMeshActor
- `TogglePlayerCharacterVisibility()` on PlayerController
- `ToggleThirdPerson()` on PlayerController

---

## KNOWN BUGS FIXED (session 3)

### Bug 1 — SetAnimationMode(1) fails from Lua
- `EAnimationMode::Type` enum parameter cannot be marshaled by UE4SS → ok=false → no
  AnimSingleNodeInstance → animation skipped entirely.
- **FIX:** Replaced with `PlayAnimation(animAsset, true)` which handles the mode switch
  internally in C++. After PlayAnimation returns, get AnimInstance and verify bFireNotifyEvents.

### Bug 2 — Oxygen depletion during transformation
- `SuppressOxygen()` in traits.lua was completely stubbed. Player died from oxygen
  depletion during transformation.
- **FIX:** `Diag.RefillOxygen(_playerRef)` called every 200 SyncTicks (~10s) from
  transformation.lua SyncTick loop.

### Bug 3 — Phase ability double-toggle
- `ActivatePhase` called `TogglePlayerCharacterVisibility()` regardless of transform state.
  When transformed (player already hidden), this toggled the player VISIBLE for `duration`
  seconds, then toggled back invisible.
- **FIX:** Skip visibility toggle in `ActivatePhase` when `Transformation.IsTransformed`.
  Also guards the delayed re-toggle callback.

---

## CURRENT STATE & NEXT STEPS

**What works (confirmed):**
- SkeletalMeshActor spawn: ok
- SetSkeletalMesh: ok
- SetDisablePostProcessBlueprint: ok (fixes PostProcessABP crash)
- SyncTick (50ms position sync): ok
- HidePlayer / ShowPlayer: ok
- Camera (ToggleThirdPerson): ok
- Movement / capsule overrides: ok
- PlayAnimation: ok (confirmed via log from earlier session that it works without mode switch)

**What needs testing (session 3 changes):**
1. PlayAnimation + bFireNotifyEvents readback:
   - Expected log: `PlayAnimation: ok=true` → `GetAnimInstance: valid=true` →
     `bFireNotifyEvents readback: false` → `Notify suppression confirmed — animation running`
   - If readback ≠ false: `Stopped for safety` → static pose, no crash
   - Test: transform, watch for 60+ seconds. If stable → Crash E is solved.

2. Oxygen refill (RefillOxygen every 200 ticks):
   - Test: transform, don't surface. Should not die from oxygen depletion.

3. Phase fix:
   - Test: transform → press Phase ability key → should log `visibility toggle skipped`.

**If bFireNotifyEvents readback fails (returns nil):**
- The property doesn't exist on this UE5.6 AnimInstance build, or UE4SS can't reflect it.
- Alternative: find a notify-free animation sequence in the game's asset registry.
  Command: `retoc print-script-objects global.utoc | Select-String "AnimSequence"` 
  Look for sequences without "Swim" that are simple idle poses.
- Alternative 2: Use a different mesh that has no PostProcessABP and no notifies in its idles.

---

## KEY ARCHITECTURE FACTS

- **SkeletalMeshActor**: `/Script/Engine.SkeletalMeshActor` — plain engine actor,
  always resident, no LoadAsset needed. Has `SkeletalMeshComponent` by default.
- **SetSkeletalMeshAsset** (UE5) / **SetSkeletalMesh** (UE4 fallback): confirmed callable.
- **PlayAnimation**: internally calls SetAnimationMode(SingleNode) + SetAnimation + Play in C++.
  CANNOT be decomposed from Lua (SetAnimationMode fails from Lua with enum param error).
- **SetAnimationMode(1) from Lua**: ALWAYS FAILS — `ok=false`. Enum param marshaling error.
  Do not attempt. Use PlayAnimation instead.
- **bFireNotifyEvents**: `uint8 bFireNotifyEvents:1` UPROPERTY on UAnimInstance (BlueprintReadWrite).
  Controls notify dispatch. Must verify via readback (write false → read back) because UE4SS
  returns ok=true for both real C++ UPROPERTY writes AND silent Lua table fallbacks.
- **PostProcessAnimBlueprint**: mesh asset property — ABP auto-instantiated by InitAnim.
  Created on SetSkeletalMesh AND on PlayAnimation (which calls InitAnim internally).
  SetDisablePostProcessBlueprint(true) prevents recreation and destroys existing instance.
  Must be called BEFORE PlayAnimation.
- **AnimNotifies**: baked into UAnimSequence keyframes. Fire at specific playback times.
  Creature animations contain UWE notifies that crash on non-UWEAIPawn owners.
- **UWEAIControllerTicker**: C++ singleton, zero UFunctions. Only crashes if actor has
  a controller. SkeletalMeshActor never registers.
- **pcall**: catches Lua errors only. C++ AV crashes are uncatchable.

---

## CRASH DUMP NOTES

Location: `C:\Games\Subnautica 2\Subnautica2\Binaries\Win64\ue4ss\crash_*.dmp`
Most recent meaningful crash: `crash_2026_05_26_12_24_25.7041038.dmp` (session 2, ~5.8s, AnimNotify)

Dump sizes:
- ~52MB: native AV from game thread (confirmed for both ticker crash AND AnimNotify crash)
- ~76MB: different crash type
- 0 bytes: no-dump crash (game hang or bypass of UE4SS dump handler)
