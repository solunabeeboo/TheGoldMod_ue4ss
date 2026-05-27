-- diagnostics.lua
-- Comprehensive runtime diagnostics for TheGoldMod.
-- Monitors player state, oxygen, death events, puppet validity.
-- Logs everything needed to pinpoint crash root causes.

local UEHelpers = require("UEHelpers")
local Diag = {}

-- ── Logging ───────────────────────────────────────────────────────────────

local function Log(msg)
    print("[Diag] " .. tostring(msg) .. "\n")
end

-- ── Player helpers ────────────────────────────────────────────────────────

local function GetPlayer()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc and pc:IsValid() then
        local ok2, pawn = pcall(function() return pc:GetPawn() end)
        if ok2 and pawn and pawn:IsValid() then return pawn end
    end
    for _, cn in ipairs({ "BP_SN2PlayerCharacter_C", "BP_Character_01_C" }) do
        local inst = FindFirstOf(cn)
        if inst and inst:IsValid() then return inst end
    end
    return nil
end

-- ── Oxygen monitoring ─────────────────────────────────────────────────────
-- SN2OxygenTank::SetOxygenLevel confirmed via retoc (non-GAS direct setter).
-- UWESurvivalSetComponent::GetNormalizedOxygen confirmed for reading.

local _oxygenatorCache = nil

local function GetOxygenator(player)
    if _oxygenatorCache then
        local ok, v = pcall(function() return _oxygenatorCache:IsValid() end)
        if ok and v then return _oxygenatorCache end
        _oxygenatorCache = nil
    end
    if not player or not player:IsValid() then return nil end
    local ok, ox = pcall(function() return player:GetOxygenator() end)
    if ok and ox then
        local vOk, v = pcall(function() return ox:IsValid() end)
        if vOk and v then
            _oxygenatorCache = ox
            return ox
        end
    end
    return nil
end

-- Returns normalized oxygen 0..1, or nil if unavailable.
function Diag.ReadOxygen(player)
    player = player or GetPlayer()
    if not player or not player:IsValid() then return nil end

    -- Try UWESurvivalSetComponent::GetNormalizedOxygen (most reliable)
    local scOk, sc = pcall(function() return player.SurvivalSetComponent end)
    if scOk and sc then
        local vOk, v = pcall(function() return sc:IsValid() end)
        if vOk and v then
            local goOk, norm = pcall(function() return sc:GetNormalizedOxygen() end)
            if goOk and type(norm) == "number" then return norm end
        end
    end

    -- Fallback: GetOxygenator + GetOxygenLevel (SN2SubmarineOxygenator style)
    local ox = GetOxygenator(player)
    if ox then
        local goOk, level = pcall(function() return ox:GetOxygenLevel() end)
        if goOk and type(level) == "number" then return level end
    end

    return nil
end

-- Refills oxygen to maximum. Called every N seconds while transformed.
-- Uses SN2OxygenTank::SetOxygenLevel (non-GAS direct setter).
function Diag.RefillOxygen(player)
    player = player or GetPlayer()
    if not player or not player:IsValid() then return false end

    -- Try oxygenator SetOxygenLevel (SN2OxygenTank / SN2SubmarineOxygenator)
    local ox = GetOxygenator(player)
    if ox then
        -- Try getting max first, fall back to large constant
        local maxOxy = 100
        local mOk, mV = pcall(function() return ox:GetOxygenLevel() end) -- read current
        -- Try common max-getter names
        for _, fn in ipairs({ "GetMaxOxygen", "GetMaxOxygenLevel", "GetMaxLevel" }) do
            local fOk, fV = pcall(function() return ox[fn](ox) end)
            if fOk and type(fV) == "number" and fV > 0 then maxOxy = fV; break end
        end
        local setOk = pcall(function() ox:SetOxygenLevel(maxOxy) end)
        if setOk then return true end
    end

    -- Try SurvivalSetComponent path
    local scOk, sc = pcall(function() return player.SurvivalSetComponent end)
    if scOk and sc then
        local vOk, v = pcall(function() return sc:IsValid() end)
        if vOk and v then
            local maxOk, maxV = pcall(function() return sc:GetMaxOxygen() end)
            local maxOxy = (maxOk and type(maxV) == "number") and maxV or 100
            -- Try direct set on the component
            local setOk = pcall(function() sc:SetOxygen(maxOxy) end)
            if setOk then return true end
        end
    end

    -- Try finding SN2OxygenTank instances in world
    for _, cn in ipairs({ "SN2OxygenTank_C", "SN2OxygenTank" }) do
        local tanks = FindAllOf(cn)
        if tanks then
            for _, t in ipairs(tanks) do
                local vOk, v = pcall(function() return t:IsValid() end)
                if vOk and v then
                    -- Check if this tank belongs to our player
                    local ownerOk, owner = pcall(function() return t:GetOwner() end)
                    if ownerOk and owner then
                        local ovOk, ov = pcall(function() return owner:IsValid() end)
                        if ovOk and ov and owner == player then
                            pcall(function() t:SetOxygenLevel(999) end)
                            Log("Oxygen refilled via SN2OxygenTank")
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

-- ── Death / respawn hooks ─────────────────────────────────────────────────
-- SN2RespawnComponent::Client_Respawning fires on the client when death
-- triggers a respawn. We hook it to revert transformation BEFORE the
-- death sequence processes (which crashes while player is hidden/transformed).

local _deathHooksRegistered = false
local _onDeathCallback = nil   -- set by the caller

function Diag.SetOnDeathCallback(fn)
    _onDeathCallback = fn
end

local function TryFireDeathCallback(source)
    if _onDeathCallback then
        Log("Death detected via: " .. tostring(source))
        local ok, err = pcall(_onDeathCallback)
        if not ok then Log("Death callback error: " .. tostring(err)) end
    end
end

function Diag.RegisterDeathHooks()
    if _deathHooksRegistered then return end
    _deathHooksRegistered = true

    local hookPaths = {
        -- SN2RespawnComponent native paths (try multiple module name candidates)
        "/Script/SN2.SN2RespawnComponent:Client_Respawning",
        "/Script/Subnautica2.SN2RespawnComponent:Client_Respawning",
        "/Script/SN2.SN2RespawnComponent:Respawn",
        "/Script/SN2.SN2RespawnComponent:ConfirmRespawn",
        -- Blueprint player character respawn event
        "/Game/Blueprints/Character/player/BP_SN2PlayerCharacter.BP_SN2PlayerCharacter_C:Client_Respawning",
        "/Game/Blueprints/Character/player/BP_Character_01.BP_Character_01_C:Client_Respawning",
    }

    local registered = 0
    for _, path in ipairs(hookPaths) do
        local ok, err = pcall(function()
            RegisterHook(path, function(self)
                TryFireDeathCallback(path)
            end)
        end)
        if ok then
            Log("Death hook registered: " .. path)
            registered = registered + 1
        end
    end

    if registered == 0 then
        Log("WARNING: No death hooks registered — all paths failed")
    end
end

-- ── Comprehensive state snapshot ──────────────────────────────────────────

function Diag.Snapshot(label, puppet)
    local player = GetPlayer()
    local parts  = { "[Diag][" .. tostring(label) .. "]" }

    -- Player validity
    if not player then
        table.insert(parts, "player=NIL")
    else
        table.insert(parts, "player=valid")

        -- Oxygen
        local oxy = Diag.ReadOxygen(player)
        if oxy ~= nil then
            table.insert(parts, string.format("oxy=%.2f", oxy))
        else
            table.insert(parts, "oxy=unreadable")
        end

        -- Player location
        local locOk, loc = pcall(function() return player:K2_GetActorLocation() end)
        if locOk and loc then
            table.insert(parts, string.format("ploc=%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z))
        end

        -- Hidden state
        local hidOk, hid = pcall(function() return player.bHidden end)
        if hidOk then table.insert(parts, "hidden=" .. tostring(hid)) end
    end

    -- Puppet validity
    if puppet then
        local pOk, pv = pcall(function() return puppet:IsValid() end)
        table.insert(parts, "puppet=" .. (pOk and pv and "valid" or "INVALID"))
    end

    print(table.concat(parts, " ") .. "\n")
end

-- ── Tick monitoring ───────────────────────────────────────────────────────
-- Call Diag.OnSyncTick(tickCount, puppet) from SyncTick.
-- Logs every 20 ticks (~1s). Refills oxygen every 200 ticks (~10s).

function Diag.OnSyncTick(tickCount, puppet)
    if tickCount % 20 == 0 then
        Diag.Snapshot("t=" .. tickCount, puppet)
    end
end

-- ── Init ──────────────────────────────────────────────────────────────────

function Diag.Init()
    Diag.RegisterDeathHooks()
    Log("Diagnostics initialized")
end

function Diag.Reset()
    _oxygenatorCache = nil
end

return Diag
