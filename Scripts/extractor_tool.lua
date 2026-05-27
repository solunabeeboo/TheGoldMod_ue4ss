-- extractor_tool.lua
-- Hooks the Biosampler GAS events so the DNA Extractor tool
-- captures creature DNA when the player uses it near a creature.
-- Also registers per-creature BeginPlay hooks to populate the class cache.

local UEHelpers      = require("UEHelpers")
local CreatureDB     = require("creature_db")
local DNASystem      = require("dna_system")
local Transformation = require("transformation")

local Extractor = {}

-- ── Config ────────────────────────────────────────────────────────────────

local SAMPLE_RANGE     = 400   -- UU — how close the player must be to sample
local SCAN_INTERVAL_MS = 200   -- how often we check for nearby targets while equipped

-- ── State ─────────────────────────────────────────────────────────────────

local _equipped    = false
local _scanRunning = false

-- ── Logging ───────────────────────────────────────────────────────────────

local function Log(msg)
    print("[Extractor] " .. tostring(msg) .. "\n")
end

-- ── Geometry helpers ──────────────────────────────────────────────────────

local function VecDist(a, b)
    local dx = a.X - b.X
    local dy = a.Y - b.Y
    local dz = a.Z - b.Z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function GetPlayerLocation()
    local pawn = UEHelpers.GetPlayer()   -- GetPlayerPawn does not exist; GetPlayer() returns the pawn
    if not pawn or not pawn:IsValid() then return nil end
    local ok, loc = pcall(function() return pawn:GetActorLocation() end)
    if ok and loc then return loc end
    return nil
end

-- ── Nearby creature detection ─────────────────────────────────────────────
-- Iterates known creature classes only — not FindAllOf("Actor").

local function FindNearbyCreature()
    local playerLoc = GetPlayerLocation()
    if not playerLoc then return nil, nil end

    local bestDist   = SAMPLE_RANGE
    local bestEntry  = nil
    local bestActor  = nil

    for _, entry in pairs(CreatureDB.All) do
        local classNames = { entry.bpClass .. "_C", entry.bpClass }
        for _, cn in ipairs(classNames) do
            local instances = FindAllOf(cn)
            if instances then
                for _, inst in ipairs(instances) do
                    if inst and inst:IsValid() then
                        local ok, loc = pcall(function() return inst:GetActorLocation() end)
                        if ok and loc then
                            local dist = VecDist(playerLoc, loc)
                            if dist < bestDist then
                                bestDist  = dist
                                bestEntry = entry
                                bestActor = inst
                            end
                        end
                    end
                end
            end
        end
    end

    return bestEntry, bestActor
end

-- ── Sampling logic ────────────────────────────────────────────────────────

local function AttemptSample()
    local entry, _ = FindNearbyCreature()
    local bridge = _G["WheelBridge"]
    if not entry then
        if bridge and bridge.SetExtractorTarget then
            bridge.SetExtractorTarget(nil)
        end
        return
    end
    if bridge and bridge.SetExtractorTarget then
        bridge.SetExtractorTarget(entry)
    end
end

function Extractor.OnFirePressed()
    if not _equipped then return end

    ExecuteInGameThread(function()
        local entry, _ = FindNearbyCreature()
        if not entry then
            Log("No creature in range")
            local bridge = _G["WheelBridge"]
            if bridge and bridge.PlayExtractorFail then bridge.PlayExtractorFail() end
            return
        end

        if DNASystem.IsProcessed(entry.bpClass) then
            Log("Already fully unlocked: " .. entry.displayName)
            return
        end
        if DNASystem.IsCollected(entry.bpClass) then
            Log("Sample already in inventory: " .. entry.displayName)
            return
        end

        local ok, reason = DNASystem.Collect(entry.bpClass)
        if ok then
            Log("Sampled: " .. entry.displayName)
        else
            Log("Sample failed: " .. reason)
        end
    end)
end

-- ── Scan loop (runs while extractor is equipped) ──────────────────────────

local function ScanTick()
    if not _scanRunning then return end
    ExecuteInGameThread(function()
        if not _scanRunning then return end
        AttemptSample()
    end)
    ExecuteWithDelay(SCAN_INTERVAL_MS, function()
        ScanTick()
    end)
end

-- ── GAS event hooks ───────────────────────────────────────────────────────

local function OnBiosamplerEquipped(_, _)
    _equipped    = true
    _scanRunning = true
    Log("Extractor equipped")
    ExecuteWithDelay(50, function() ScanTick() end)
end

local function OnBiosamplerHolstered(_, _)
    _equipped    = false
    _scanRunning = false
    Log("Extractor holstered")
    local bridge = _G["WheelBridge"]
    if bridge and bridge.SetExtractorTarget then bridge.SetExtractorTarget(nil) end
end

local function TryHookBiosamplerCues()
    local cueNames = {
        "GCN_Equip_Biosampler",
        "GC_Equip_Biosampler_C",
        "GCN_Equip_Biosampler_C",
        "BP_GC_Equip_Biosampler_C",
    }
    for _, cn in ipairs(cueNames) do
        local obj = StaticFindObject(cn)
        if obj and obj:IsValid() then
            local ok1 = pcall(function()
                RegisterHook("/" .. cn .. ":OnActive", OnBiosamplerEquipped)
            end)
            local ok2 = pcall(function()
                RegisterHook("/" .. cn .. ":OnRemove", OnBiosamplerHolstered)
            end)
            if ok1 or ok2 then
                Log("Hooked biosampler cue: " .. cn)
                return
            end
        end
    end
    Log("Biosampler cue class not found — equip state must come from Blueprint ModActor")
end

-- ── Creature BeginPlay class caching ─────────────────────────────────────

local _hookedClasses = {}

local function RegisterCreatureHook(entry)
    if _hookedClasses[entry.bpClass] then return end
    _hookedClasses[entry.bpClass] = true

    local classVariants = { entry.bpClass .. "_C", entry.bpClass }
    for _, cn in ipairs(classVariants) do
        local ok = pcall(function()
            RegisterHook("/" .. cn .. ":ReceiveBeginPlay", function(self)
                ExecuteInGameThread(function()
                    Transformation.CacheClass(entry.bpClass, self)
                end)
            end)
        end)
        if ok then
            Log("Hooked BeginPlay for " .. cn)
            break
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────────

function Extractor.Init()
    for _, entry in pairs(CreatureDB.All) do
        RegisterCreatureHook(entry)
    end

    TryHookBiosamplerCues()

    Log("Extractor initialized")
end

function Extractor.NotifyEquipped(isEquipped)
    if isEquipped then
        OnBiosamplerEquipped(nil, nil)
    else
        OnBiosamplerHolstered(nil, nil)
    end
end

function Extractor.IsEquipped()
    return _equipped
end

_G["Extractor"] = Extractor

return Extractor
