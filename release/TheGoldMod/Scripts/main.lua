-- main.lua  (TheGoldMod coordinator)
-- Entry point loaded by UE4SS.  Requires all sub-modules and wires up
-- keybinds, level-load hooks, and pawn-change hooks.
--
-- Keybinds and behaviour are configured via the in-game ImGui panel
-- (open the game's Settings screen while TheGoldModSettings DLL is installed).
-- Key changes require Ctrl+R (hot-reload) to take effect.

local UEHelpers = require("UEHelpers")

-- ── Module load ───────────────────────────────────────────────────────────
-- Order matters: DB first (no deps), then systems that depend on it.

local DNASystem      = require("dna_system")
local Transformation = require("transformation")
local Traits         = require("traits")
local Extractor      = require("extractor_tool")
local WheelBridge    = require("wheel_bridge")

local function Log(msg)
    print("[GoldMod] " .. tostring(msg) .. "\n")
end

Log("Initializing TheGoldMod v0.1")

-- ── Settings ──────────────────────────────────────────────────────────────
-- Written by TheGoldModSettings C++ mod. Defaults match the ImGui panel defaults.

local _SETTINGS_PATH = "ue4ss/Mods/TheGoldMod/settings.txt"
local _SETTINGS_FLAG = "ue4ss/Mods/TheGoldMod/settings_open.flag"

local _WHEEL_KEY     = "G"
local _PRIMARY_KEY   = "T"
local _SECONDARY_KEY = "R"
local _REVERT_KEY    = "H"
local _PREV_KEY      = "["
local _NEXT_KEY      = "]"
local _autoUnlock    = true

-- Maps printable key strings from settings.txt to VK codes for keys that
-- can't be looked up via Key["name"] (brackets, punctuation, etc.).
local _VK = {
    ["["] = 219, ["]"] = 221, [";"] = 186, ["'"] = 222,
    [","] = 188, ["."] = 190, ["/"] = 191, ["\\"] = 220,
    ["-"] = 189, ["="] = 187, ["`"] = 192,
}

local function ResolveKey(name)
    return _VK[name] or Key[name]
end

local function LoadSettings()
    local f = io.open(_SETTINGS_PATH, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.-)%s*$")
        if     k == "WheelKey"        and v ~= "" then _WHEEL_KEY     = v
        elseif k == "PrimaryKey"      and v ~= "" then _PRIMARY_KEY   = v
        elseif k == "SecondaryKey"    and v ~= "" then _SECONDARY_KEY = v
        elseif k == "RevertKey"       and v ~= "" then _REVERT_KEY    = v
        elseif k == "PrevCreatureKey" and v ~= "" then _PREV_KEY      = v
        elseif k == "NextCreatureKey" and v ~= "" then _NEXT_KEY      = v
        elseif k == "AutoUnlock"                  then _autoUnlock    = (v == "true") end
    end
    f:close()
end

LoadSettings()

-- ── Module init ───────────────────────────────────────────────────────────

WheelBridge.Init()   -- publishes _G["WheelBridge"] before other inits
Extractor.Init()     -- registers creature BeginPlay hooks + GAS cue hooks

-- Auto-unlock: if enabled in settings, unlock all forms immediately.
-- State is persisted to dna_save.txt so it survives restarts even if the
-- setting is later disabled.
if _autoUnlock then
    DNASystem.UnlockAll()
    Log("Auto-unlock: all forms unlocked")
end

-- ── Keybinds ──────────────────────────────────────────────────────────────
-- Keys are read from settings.txt on each hot-reload (Ctrl+R).

RegisterKeyBind(Key[_WHEEL_KEY], function()
    ExecuteInGameThread(function()
        WheelBridge.ToggleWheel()
    end)
end)

RegisterKeyBind(Key[_PRIMARY_KEY], function()
    ExecuteInGameThread(function()
        if Transformation.IsTransformed and Transformation.CurrentCreature then
            Traits.ActivatePrimary(Transformation.CurrentCreature)
        end
    end)
end)

RegisterKeyBind(Key[_SECONDARY_KEY], function()
    ExecuteInGameThread(function()
        if Transformation.IsTransformed and Transformation.CurrentCreature then
            Traits.ActivateSecondary(Transformation.CurrentCreature)
        end
    end)
end)

RegisterKeyBind(Key[_REVERT_KEY], function()
    ExecuteInGameThread(function()
        if Transformation.IsTransformed then
            Traits.Reset()
            Transformation.Revert()
        end
    end)
end)

-- Debug binds (fixed keys — not user-configurable)
RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        DNASystem.UnlockAll()
        Log("DEBUG: All forms unlocked via F8")
    end)
end)

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        Traits.Reset()
        Transformation.Revert()
        DNASystem.Reset()
        Log("DEBUG: DNA state reset via F9")
    end)
end)

-- ── Level load / pawn change hooks ───────────────────────────────────────

local _loadMapHooks = {
    "/Script/Engine.GameEngine:LoadMap",
    "/Script/Engine.GameEngine:SeamlessTravel",
}
for _, path in ipairs(_loadMapHooks) do
    pcall(function()
        RegisterHook(path, function()
            Log("Level loading — clearing transform state")
            Traits.Reset()
            Transformation.OnPawnChanged()
            WheelBridge.OnLevelLoaded()
        end)
    end)
end

-- NotifyOnNewObject fires when a new player pawn is constructed (respawn, level transition).
NotifyOnNewObject(
    "/Game/Blueprints/Character/player/BP_Character_01.BP_Character_01_C",
    function()
        ExecuteInGameThread(function()
            Log("NotifyOnNewObject: player spawned — refreshing pawn")
            Traits.Reset()
            Transformation.OnPawnChanged()
            WheelBridge.OnLevelLoaded()
            -- Re-apply auto-unlock after respawn so newly loaded sessions also get it
            if _autoUnlock then DNASystem.UnlockAll() end
        end)
    end
)

-- ClientRestart fallback (fires on pawn possession; less reliable than NotifyOnNewObject)
local _restartPaths = {
    "/Script/Engine.PlayerController:ClientRestart",
    "/Game/Blueprints/Character/player/BP_SN2PlayerController.BP_SN2PlayerController_C:ClientRestart",
}
for _, path in ipairs(_restartPaths) do
    pcall(function()
        RegisterHook(path, function(_, _)
            Log("ClientRestart — refreshing pawn")
            ExecuteInGameThread(function()
                Traits.Reset()
                Transformation.OnPawnChanged()
            end)
        end)
    end)
end

-- ── Settings screen flag bridge ───────────────────────────────────────────
-- TheGoldModSettings C++ mod reads settings_open.flag to show its ImGui panel.
-- Same pattern as SN2ThirdPersonMod: poll WBP_Settings2Screen_C:IsActivated().

local function WriteSettingsFlag(val)
    local f = io.open(_SETTINGS_FLAG, "w")
    if f then f:write(val) f:close() end
end

WriteSettingsFlag("0")

pcall(function()
    RegisterHook("/Script/CommonUI.CommonActivatableWidget:BP_OnActivated", function(ctx)
        local ok, name = pcall(function() return ctx:GetClass():GetName() end)
        if ok and name and name:find("Settings", 1, true) then
            WriteSettingsFlag("1")
        end
    end)
end)

pcall(function()
    RegisterHook("/Script/CommonUI.CommonActivatableWidget:BP_OnDeactivated", function(ctx)
        local ok, name = pcall(function() return ctx:GetClass():GetName() end)
        if ok and name and name:find("Settings", 1, true) then
            WriteSettingsFlag("0")
        end
    end)
end)

local function PollSettings()
    local widget = FindFirstOf("WBP_Settings2Screen_C")
    if widget and widget:IsValid() then
        local ok, result = pcall(function() return widget:IsActivated() end)
        WriteSettingsFlag((ok and result == true) and "1" or "0")
    else
        WriteSettingsFlag("0")
    end
    ExecuteWithDelay(300, PollSettings)
end
ExecuteWithDelay(2000, PollSettings)

-- ── Test mode: cycle forms without wheel UI ───────────────────────────────
-- [  — previous form      ]  — next form
-- F8 to unlock all first, then bracket-cycle through every creature.

local _testIndex = 1

local function TransformToIndex(index)
    local forms = DNASystem.GetUnlockedForms()
    if #forms == 0 then
        Log("TEST: No forms unlocked — press F8 first")
        return
    end
    _testIndex = ((index - 1) % #forms) + 1
    local entry = forms[_testIndex]
    Log("TEST: [" .. _testIndex .. "/" .. #forms .. "] " .. entry.displayName)
    if Transformation.IsTransformed then
        Traits.Reset()
        Transformation.Revert()
    end
    ExecuteWithDelay(100, function()
        Transformation.TransformInto(entry)
        Traits.OxygenImmune = entry.oxygenImmune == true
        Traits.StartTicking()
    end)
end

RegisterKeyBind(ResolveKey(_PREV_KEY), function()
    ExecuteInGameThread(function()
        TransformToIndex(_testIndex - 1)
    end)
end)

RegisterKeyBind(ResolveKey(_NEXT_KEY), function()
    ExecuteInGameThread(function()
        TransformToIndex(_testIndex + 1)
    end)
end)

Log(string.format(
    "TheGoldMod ready — %s=Wheel  %s=Primary  %s=Secondary  %s=Revert  F8=UnlockAll  F9=Reset  %s=Prev  %s=Next",
    _WHEEL_KEY, _PRIMARY_KEY, _SECONDARY_KEY, _REVERT_KEY, _PREV_KEY, _NEXT_KEY))
