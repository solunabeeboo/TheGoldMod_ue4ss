# TheGoldMod — Blueprint Implementation Guide
## Leveraging Existing Subnautica 2 Systems

This guide covers every Blueprint/UMG asset you need to create, and for each one identifies
the existing S2 system you should extend/copy rather than build from scratch.

---

## 1. Project Setup in Unreal Editor

### Pak structure
Your mod pak must mount at:
```
Subnautica2/Content/Mods/TheGoldMod/
```
In the Editor project, keep everything under:
```
Content/Mods/TheGoldMod/
```
Cook using BPModLoaderMod conventions: export as a separate `.pak` + `.ucas` + `.utoc` and
place the `.pak` in `Subnautica2\Binaries\Win64\ue4ss\Mods\BPModLoaderMod\LogicMods\`.

### UE version
Open the project as **Unreal Engine 5.6** to match the game's binaries exactly.

---

## 2. ModActor — Entry Point (REQUIRED)

### What it is
BPModLoaderMod automatically spawns one actor per mod pak by scanning for a Blueprint
class named exactly `ModActor_C` in the pak. This is your Lua↔Blueprint communication hub.

### Create it
1. **New Blueprint Class** → parent `Actor`
2. Name it exactly: `BP_GoldMod_ModActor`  
   (it will be cooked as `BP_GoldMod_ModActor_C`)
3. Set **Replication** to `None`, **Auto Receive Input** to `Player 0`

### Variables to expose (read by Lua via property access)
| Variable Name | Type | Description |
|---|---|---|
| `WheelVisible` | Bool | Lua writes true/false to show/hide wheel |
| `UnlockedFormsPayload` | String | CSV of unlocked `bpClass` keys |
| `ActiveFormKey` | String | Currently active transformation |
| `ActiveFormName` | String | Display name of current form |
| `ExtractorTargetKey` | String | bpClass of creature in extractor range |
| `ExtractorTargetName` | String | Display name of target |
| `LastCollectedDNA` | String | Most recently collected bpClass |
| `LastUnlockedForm` | String | Most recently unlocked bpClass |

### Custom Events to implement (Lua calls these via pcall)
These are the **method calls** Lua attempts. If they exist on the actor, they will be called.
If not, Lua falls back to writing the variable above.

| Event Name | Params | What to do in BP |
|---|---|---|
| `ShowTransformWheel` | — | Call `WBP_TransformWheel::Show` |
| `HideTransformWheel` | — | Call `WBP_TransformWheel::Hide` |
| `SetUnlockedForms` | String (CSV) | Parse CSV → update wheel slots |
| `OnTransformApplied` | String bpClass, String name | Show active-form HUD element |
| `OnTransformReverted` | — | Hide active-form HUD element |
| `ShowDNACollectedNotification` | String name | Play `WBP_DNANotification` popup |
| `ShowFormUnlockedNotification` | String name | Play unlock fanfare widget |
| `SetExtractorTarget` | String bpClass, String name | Show extraction prompt |
| `ClearExtractorTarget` | — | Hide extraction prompt |
| `PlayExtractorFail` | — | Play fail sound/flash |

### Lua → Blueprint events
Implement these Custom Events in the ModActor. Lua hooks them via `RegisterHook`:

| Event Name | When to fire | Lua handler |
|---|---|---|
| `Lua_WheelSelect` | Player clicks a wheel slot | `WheelBridge.OnWheelSelect(bpClass)` |
| `Lua_WheelRevert` | Player clicks Revert button | `WheelBridge.OnWheelRevert()` |
| `Lua_ProcessingComplete` | DNA Machine finishes | `WheelBridge.OnProcessingComplete(bpClass)` |
| `Lua_ExtractorEquipped` | DNA Extractor equip anim | `Extractor.NotifyEquipped(true)` |
| `Lua_ExtractorHolstered` | DNA Extractor holster anim | `Extractor.NotifyEquipped(false)` |

**How to call Lua from BP:**  
Each of these events should call a Blueprint node chain that writes to a string variable Lua
is polling, OR (better) use the `Execute Console Command` node with a custom console command
your Lua registers — but the simplest pattern is simply to have the events exist on the actor
and let Lua's `RegisterHook("BP_GoldMod_ModActor_C:Lua_WheelSelect", ...)` intercept them.

---

## 3. DNA Extractor Item

### Reuse: `DA_Biosampler_ItemType` + `BP_EquippableBase`

The game's Biosampler is a full equippable tool. Duplicate its Data Asset and swap the mesh.

**Steps:**
1. In FModel (once you have .usmap), export `DA_Biosampler_ItemType` as a reference.
   For now, create a new **Data Asset** → parent `SN2ItemTypeDataAsset` (or whatever the
   Biosampler DA's parent class is — find it in Live View).
2. Copy all Biosampler fields. Change:
   - `ItemName` → "DNA Extractor"
   - `Description` → flavour text
   - `Icon` → your custom icon texture
   - `Mesh` → your custom static/skeletal mesh
3. **Blueprint class:** Duplicate `BP_Character_01`'s equippable tool parent or use
   `ABP_PCTools_GenericItem` as the animation Blueprint. This gives you the equip/holster
   animation states for free.
4. **Recipe:** Duplicate `DA_BiosamplingKitRecipe`, change ingredient list.

### Equip/Holster detection
The Biosampler fires `GC_Equip_Biosampler` and `GC_Holster_Biosampler` gameplay cues.
Your tool should fire its own cue tags — either reuse those exact tags (simplest, since
Lua already hooks them) or create `GC_Equip_DNAExtractor` / `GC_Holster_DNAExtractor`
and update the hook names in `extractor_tool.lua`.

**Simplest path:** Reuse the exact same tag strings (`GC_Equip_Biosampler` / 
`GC_Holster_Biosampler`). The Lua code already hooks these. Zero extra Blueprint work.

---

## 4. Transformation Wheel (WBP_TransformWheel)

### Reuse: `MI_HUD_RadialBar_Biomod` + `MI_HUD_RadialBar_Biomod_Trailing`

The game already has a radial bar material for the Biomod UI. Build your wheel on top of it.

### Widget structure
```
WBP_TransformWheel (UserWidget)
├── CanvasPanel (root)
│   ├── Image (background — M_Glitch_DNA or dark overlay)
│   ├── WBP_WheelSlot × N (dynamically spawned)
│   └── Button_Revert (center — "Revert to Human")
```

### WBP_WheelSlot (child widget, one per form)
```
WBP_WheelSlot
├── Image_Background (MI_HUD_RadialBar_Biomod — set ArcAngle param)
├── Image_Icon (creature portrait)
├── TextBlock_Name (creature display name)
└── Button (click → fires Lua_WheelSelect event on ModActor)
```

**How to build the radial layout:**
- Each slot receives: `SlotIndex` (int), `TotalSlots` (int), `bpClass` (string)
- Compute angle: `Angle = (SlotIndex / TotalSlots) * 360`
- Set `RenderTransform.Angle` on each slot to rotate it around the center
- Use `MI_HUD_RadialBar_Biomod`'s `ArcAngle` material parameter = `360 / TotalSlots`

**Populating from Lua:**  
`ModActor.SetUnlockedForms(csvPayload)` → `ParseCSV` → For each key:
- Spawn `WBP_WheelSlot` into the panel
- Set slot's `bpClass` string variable
- Look up display name from a Blueprint string table you maintain (or just display bpClass)
- On slot click → fire `Lua_WheelSelect` with `bpClass`

### Show/Hide animation
Use a `WidgetAnimation` with a scale-from-zero + fade-in on `Show`, reversed on `Hide`.
`ShowTransformWheel` event triggers `PlayAnimation(WheelOpenAnim)`.

---

## 5. DNA Collected / Form Unlocked Notifications (WBP_DNANotification)

### Reuse: `T_UI_DNA`, `T_UI_DNA1`, `T_UI_DNA2`, `T_AdaptationDNAStrand`

The game ships DNA strand textures specifically for UI use.

```
WBP_DNANotification (UserWidget)
├── Image_DNAStrand (T_AdaptationDNAStrand, animated UV scroll)
├── TextBlock_Message ("DNA Collected: Halfmoon" / "Form Unlocked!")
└── WidgetAnimation: SlideInFromRight → Hold 2s → FadeOut
```

`ModActor.ShowDNACollectedNotification(name)`:
1. Add `WBP_DNANotification` to viewport
2. Set `TextBlock_Message` text
3. Play slide-in animation
4. On animation end → Remove from parent

---

## 6. DNA Processing Machine (BP_DNAMachine)

### Reuse: `BP_ProcessorStation` parent class

The game has a Processor Station with interaction/inventory logic. Extend it.

**Steps:**
1. Create `BP_DNAMachine` → parent `BP_ProcessorStation` (or `AActor` if parent is too coupled)
2. Add `StaticMeshComponent` with your machine mesh
3. Add `BoxComponent` for interaction trigger
4. Add widget `WBP_DNAMachineUI` on interact

### WBP_DNAMachineUI
```
WBP_DNAMachineUI
├── ScrollBox_Pending (lists creatures with collected but unprocessed DNA)
│   └── WBP_SampleSlot × N (name + "Process" button)
├── TextBlock_Cost ("Costs: 2 Titanium + 1 Silicone Rubber")  
└── Button_Close
```

On "Process" button click → Fire `Lua_ProcessingComplete(bpClass)` on ModActor.

**Pending samples payload:**  
`ModActor` has `GetPendingSamplesPayload()` exposed — call it from BP on widget open to
populate the list. Lua's `WheelBridge.GetPendingSamplesPayload()` returns a CSV string of
pending bpClass keys. In BP, parse that string and build the list.

---

## 7. Active Form HUD Element (WBP_ActiveFormHUD)

Small persistent HUD element showing the current creature form.

### Reuse: `MI_HUD_RadialBar_Biomod_Trailing` for ability cooldown arcs

```
WBP_ActiveFormHUD
├── Image_CreatureIcon
├── TextBlock_CreatureName
├── WBP_AbilityIndicator (F key — primary)
│   └── Image_Cooldown (MI_HUD_RadialBar_Biomod_Trailing, driven by cooldown %)
└── WBP_AbilityIndicator (R key — secondary)
    └── Image_Cooldown (same material)
```

`ModActor.OnTransformApplied(bpClass, name)` → Add `WBP_ActiveFormHUD` to viewport, set name.
`ModActor.OnTransformReverted()` → Remove `WBP_ActiveFormHUD` from viewport.

Cooldown arcs: Set the material's scalar parameter (e.g. `RadialPercent`) each tick from Lua
by writing a float property on ModActor that the widget polls in its Tick.

---

## 8. Extractor Targeting Prompt (WBP_ExtractorPrompt)

Minimal interaction prompt that appears when a creature is in range.

```
WBP_ExtractorPrompt
├── TextBlock_Action ("[F] Sample DNA")
├── TextBlock_TargetName ("Collector Leviathan")
└── WidgetAnimation: FadeIn / FadeOut
```

`ModActor.SetExtractorTarget(bpClass, name)` → Show prompt, set name.  
`ModActor.ClearExtractorTarget()` → Hide prompt.

---

## 9. Complete Asset Checklist

| Asset | Type | Parent / Reuse |
|---|---|---|
| `BP_GoldMod_ModActor` | Blueprint Actor | `AActor` |
| `DA_DNAExtractor_ItemType` | Data Asset | Duplicate `DA_Biosampler_ItemType` |
| `BP_DNAExtractor` | Blueprint Actor | `BP_EquippableBase` or Biosampler BP |
| `ABP_DNAExtractor` | Anim Blueprint | Reuse `ABP_PCTools_GenericItem` |
| `BP_DNAMachine` | Blueprint Actor | `BP_ProcessorStation` or `AActor` |
| `WBP_TransformWheel` | Widget Blueprint | Custom (uses `MI_HUD_RadialBar_Biomod`) |
| `WBP_WheelSlot` | Widget Blueprint | Custom child |
| `WBP_DNANotification` | Widget Blueprint | Custom (uses `T_AdaptationDNAStrand`) |
| `WBP_DNAMachineUI` | Widget Blueprint | Custom |
| `WBP_ActiveFormHUD` | Widget Blueprint | Custom (uses `MI_HUD_RadialBar_Biomod_Trailing`) |
| `WBP_ExtractorPrompt` | Widget Blueprint | Custom |

---

## 10. Lua ↔ Blueprint Communication Summary

```
┌──────────────────────────────────────────────────────────┐
│                     main.lua                             │
│  (keybinds + hooks → calls module functions)             │
└──────────────┬───────────────────────────────────────────┘
               │
     ┌─────────▼──────────┐
     │   wheel_bridge.lua  │◄──── _G["WheelBridge"]
     │   (Lua↔BP bridge)   │
     └──┬──────┬──────┬───┘
        │      │      │
   DNA  │  Trans│  Extractor
   System│  form │  Tool
        │      │      │
        ▼      ▼      ▼
   dna_system  transformation  extractor_tool
                    │
                 traits.lua

BP ModActor reads/writes properties on itself.
Lua hooks ModActor Custom Events via RegisterHook.
```

**Key rule:** All Blueprint → Lua calls go through Custom Events on ModActor that Lua
intercepts with `RegisterHook`. All Lua → Blueprint calls either directly write a property
on ModActor or call a Custom Event via `pcall(function() actor:EventName() end)`.

---

## 11. Quick-Start Build Order

1. Create `BP_GoldMod_ModActor` with all variables and custom events listed in §2
2. Cook + test that UE4SS Lua can find it via `FindAllOf("BP_GoldMod_ModActor_C")`
3. Build `WBP_TransformWheel` hardcoded with 3 test slots → verify G-key opens it
4. Add `WBP_DNANotification` → verify it appears on F8 (unlock all debug key)
5. Build `BP_DNAMachine` interaction → verify `Lua_ProcessingComplete` fires
6. Add `DA_DNAExtractor_ItemType` → verify item appears in inventory/crafting
7. Polish: icons, sounds, animations
