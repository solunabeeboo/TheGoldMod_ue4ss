-- wheel_bridge.lua
-- Lua ↔ UMG communication layer.
-- The radial wheel widget lives in Blueprint/UMG; this module
-- shuttles state between the Lua transformation system and the widget.
--
-- Protocol: Blueprint ModActor reads/writes a shared actor variable
-- ("GoldModBridge") that we place on a persistent actor, OR the
-- Blueprint calls Lua via a custom event that the Lua hook captures.
-- We support both patterns.

local UEHelpers  = require("UEHelpers")
local DNASystem  = require("dna_system")
local Transformation = require("transformation")
local Traits     = require("traits")

local WheelBridge = {}

-- ── State ─────────────────────────────────────────────────────────────────

local _wheelOpen      = false
local _currentTarget  = nil   -- CreatureDB entry the extractor is aimed at
local _pendingSelect  = nil   -- bpClass queued by Blueprint selection callback
local _bridgeActor    = nil   -- persistent actor reference (found by class name)

-- ── Logging ───────────────────────────────────────────────────────────────

local function Log(msg)
    print("[WheelBridge] " .. tostring(msg) .. "\n")
end

-- ── Bridge actor (optional UMG↔Lua shared object) ────────────────────────
-- The Blueprint ModActor can write to a well-known variable on itself
-- (e.g. a string property "LuaCommand") and we poll/hook it here.
-- Alternatively Blueprint can call a function via ExecuteUbergraph which
-- we hook by name.  We try the hook approach first.

local function FindBridgeActor()
    -- BPModLoaderMod spawns ModActor_C; our mod's Blueprint is "BP_GoldModActor_C"
    local candidates = {
        "BP_GoldModActor_C",
        "BP_GoldMod_ModActor_C",
        "ModActor_C",
    }
    for _, cn in ipairs(candidates) do
        local instances = FindAllOf(cn)
        if instances and #instances > 0 then
            for _, inst in ipairs(instances) do
                if inst and inst:IsValid() then
                    _bridgeActor = inst
                    Log("Found bridge actor: " .. cn)
                    return inst
                end
            end
        end
    end
    return nil
end

-- ── Wheel open / close ────────────────────────────────────────────────────

function WheelBridge.OpenWheel()
    if _wheelOpen then return end
    _wheelOpen = true
    Log("Wheel open")

    -- Tell the Blueprint actor to show the wheel widget
    if _bridgeActor and _bridgeActor:IsValid() then
        local ok = pcall(function()
            _bridgeActor:ShowTransformWheel()
        end)
        if not ok then
            -- Fallback: write to a bool property the Blueprint polls
            pcall(function() _bridgeActor.WheelVisible = true end)
        end
    end

    -- Pass unlocked forms to Blueprint so it can populate slots
    WheelBridge.SyncFormsToBlueprint()
end

function WheelBridge.CloseWheel()
    if not _wheelOpen then return end
    _wheelOpen = false
    Log("Wheel closed")

    if _bridgeActor and _bridgeActor:IsValid() then
        local ok = pcall(function() _bridgeActor:HideTransformWheel() end)
        if not ok then
            pcall(function() _bridgeActor.WheelVisible = false end)
        end
    end
end

function WheelBridge.ToggleWheel()
    if _wheelOpen then
        WheelBridge.CloseWheel()
    else
        WheelBridge.OpenWheel()
    end
end

function WheelBridge.IsWheelOpen()
    return _wheelOpen
end

-- ── Sync unlocked forms to Blueprint ─────────────────────────────────────
-- Blueprint stores an array of slot structs; we populate it via a
-- string-encoded payload the BP reads from a text property.
-- Format: "BP_FlashFish,BP_Bullethead,BP_CollectorLeviathan"

function WheelBridge.SyncFormsToBlueprint()
    if not _bridgeActor or not _bridgeActor:IsValid() then return end

    local forms = DNASystem.GetUnlockedForms()
    local keys  = {}
    for _, entry in ipairs(forms) do
        keys[#keys + 1] = entry.bpClass
    end

    local payload = table.concat(keys, ",")

    -- Try method call first, then property write
    local ok = pcall(function()
        _bridgeActor:SetUnlockedForms(payload)
    end)
    if not ok then
        pcall(function() _bridgeActor.UnlockedFormsPayload = payload end)
    end

    Log("Synced " .. #forms .. " forms to Blueprint")
end

-- ── Blueprint → Lua callbacks ─────────────────────────────────────────────
-- The Blueprint calls these by hooking our published global functions.
-- In the Blueprint, a Custom Event calls a native function that maps
-- to these Lua entries via ExecuteInGameThread + _G lookup.

-- Blueprint calls this when the player selects a wheel slot
function WheelBridge.OnWheelSelect(bpClass)
    Log("Wheel select: " .. tostring(bpClass))
    WheelBridge.CloseWheel()

    ExecuteInGameThread(function()
        if Transformation.IsTransformed then
            -- Already in a form — revert first, then re-transform if different
            local current = Transformation.CurrentCreature
            Traits.Reset()
            Transformation.Revert()

            if current and current.bpClass == bpClass then
                return  -- toggled off same creature
            end
        end

        local CreatureDB = require("creature_db")
        local entry = CreatureDB.ByClass[bpClass] or CreatureDB.ByClass[bpClass:gsub("_C$","")]
        if not entry then
            Log("Unknown creature: " .. tostring(bpClass))
            return
        end

        local ok = Transformation.TransformInto(entry)
        if ok then
            Traits.OxygenImmune = entry.oxygenImmune == true
            Traits.StartTicking()
        end
    end)
end

-- Blueprint calls this when player clicks the revert/human button
function WheelBridge.OnWheelRevert()
    Log("Wheel revert")
    WheelBridge.CloseWheel()
    ExecuteInGameThread(function()
        Traits.Reset()
        Transformation.Revert()
    end)
end

-- ── Transformation system callbacks ──────────────────────────────────────

function WheelBridge.OnTransformApplied(creatureEntry)
    if not _bridgeActor or not _bridgeActor:IsValid() then return end
    local ok = pcall(function()
        _bridgeActor:OnTransformApplied(creatureEntry.bpClass, creatureEntry.displayName)
    end)
    if not ok then
        pcall(function()
            _bridgeActor.ActiveFormKey  = creatureEntry.bpClass
            _bridgeActor.ActiveFormName = creatureEntry.displayName
        end)
    end
end

function WheelBridge.OnTransformReverted(prevEntry)
    if not _bridgeActor or not _bridgeActor:IsValid() then return end
    pcall(function() _bridgeActor:OnTransformReverted() end)
    pcall(function()
        _bridgeActor.ActiveFormKey  = ""
        _bridgeActor.ActiveFormName = ""
    end)
end

-- ── DNA system callbacks ──────────────────────────────────────────────────

function WheelBridge.OnDNACollected(bpClass)
    Log("DNA collected: " .. bpClass)
    if not _bridgeActor or not _bridgeActor:IsValid() then return end

    -- Show collection notification widget
    local ok = pcall(function()
        local CreatureDB = require("creature_db")
        local entry = CreatureDB.ByClass[bpClass]
        local name  = entry and entry.displayName or bpClass
        _bridgeActor:ShowDNACollectedNotification(name)
    end)
    if not ok then
        pcall(function() _bridgeActor.LastCollectedDNA = bpClass end)
    end
end

function WheelBridge.OnFormUnlocked(bpClass)
    Log("Form unlocked: " .. bpClass)
    WheelBridge.SyncFormsToBlueprint()

    if not _bridgeActor or not _bridgeActor:IsValid() then return end
    local ok = pcall(function()
        local CreatureDB = require("creature_db")
        local entry = CreatureDB.ByClass[bpClass]
        local name  = entry and entry.displayName or bpClass
        _bridgeActor:ShowFormUnlockedNotification(name)
    end)
    if not ok then
        pcall(function() _bridgeActor.LastUnlockedForm = bpClass end)
    end
end

-- ── Extractor targeting UI ────────────────────────────────────────────────

function WheelBridge.SetExtractorTarget(entry)
    _currentTarget = entry
    if not _bridgeActor or not _bridgeActor:IsValid() then return end

    if entry then
        pcall(function()
            _bridgeActor:SetExtractorTarget(entry.bpClass, entry.displayName)
        end)
        pcall(function()
            _bridgeActor.ExtractorTargetKey  = entry.bpClass
            _bridgeActor.ExtractorTargetName = entry.displayName
        end)
    else
        pcall(function() _bridgeActor:ClearExtractorTarget() end)
        pcall(function()
            _bridgeActor.ExtractorTargetKey  = ""
            _bridgeActor.ExtractorTargetName = ""
        end)
    end
end

function WheelBridge.PlayExtractorFail()
    if not _bridgeActor or not _bridgeActor:IsValid() then return end
    pcall(function() _bridgeActor:PlayExtractorFail() end)
end

-- ── DNA Processing machine interaction ───────────────────────────────────
-- Blueprint processing station calls this when the player submits a sample

function WheelBridge.OnProcessingComplete(bpClass)
    ExecuteInGameThread(function()
        local ok, reason = DNASystem.Process(bpClass)
        if ok then
            Log("Processing complete: " .. bpClass)
        else
            Log("Processing failed: " .. reason)
        end
    end)
end

-- Returns list of pending (collected but not processed) samples as CSV
function WheelBridge.GetPendingSamplesPayload()
    local pending = DNASystem.GetPendingSamples()
    local keys    = {}
    for _, entry in ipairs(pending) do
        keys[#keys + 1] = entry.bpClass
    end
    return table.concat(keys, ",")
end

-- ── Blueprint hook registration ───────────────────────────────────────────
-- Hook well-known Blueprint events on the ModActor so BP→Lua calls work.

local function TryHookBlueprintEvents()
    local candidates = {
        "BP_GoldModActor_C",
        "BP_GoldMod_ModActor_C",
    }
    for _, cn in ipairs(candidates) do
        -- WheelSelect
        pcall(function()
            RegisterHook("/" .. cn .. ":Lua_WheelSelect", function(self, params)
                local key = tostring(params and params[1] or "")
                WheelBridge.OnWheelSelect(key)
            end)
        end)
        -- WheelRevert
        pcall(function()
            RegisterHook("/" .. cn .. ":Lua_WheelRevert", function()
                WheelBridge.OnWheelRevert()
            end)
        end)
        -- ProcessingComplete
        pcall(function()
            RegisterHook("/" .. cn .. ":Lua_ProcessingComplete", function(self, params)
                local key = tostring(params and params[1] or "")
                WheelBridge.OnProcessingComplete(key)
            end)
        end)
        -- ExtractorEquipped (BP fires when item equip animation starts)
        pcall(function()
            RegisterHook("/" .. cn .. ":Lua_ExtractorEquipped", function()
                local Extractor = _G["Extractor"]
                if Extractor then Extractor.NotifyEquipped(true) end
            end)
        end)
        pcall(function()
            RegisterHook("/" .. cn .. ":Lua_ExtractorHolstered", function()
                local Extractor = _G["Extractor"]
                if Extractor then Extractor.NotifyEquipped(false) end
            end)
        end)
    end
    Log("Blueprint event hooks registered")
end

-- ── Init ──────────────────────────────────────────────────────────────────

function WheelBridge.Init()
    -- Find the bridge actor (may not exist yet at init — retry later)
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function()
            FindBridgeActor()
            if _bridgeActor then
                WheelBridge.SyncFormsToBlueprint()
            end
        end)
    end)

    TryHookBlueprintEvents()

    -- Publish to global so other modules can reach us
    _G["WheelBridge"] = WheelBridge

    Log("WheelBridge initialized")
end

-- Re-finds bridge actor after level load / respawn
function WheelBridge.OnLevelLoaded()
    _bridgeActor = nil
    _wheelOpen   = false
    ExecuteWithDelay(500, function()
        ExecuteInGameThread(function()
            FindBridgeActor()
            if _bridgeActor then
                WheelBridge.SyncFormsToBlueprint()
            end
        end)
    end)
end

-- Debug: force-open wheel (bind to numpad key in main.lua)
function WheelBridge.RebuildWheel()
    WheelBridge.SyncFormsToBlueprint()
end

return WheelBridge
