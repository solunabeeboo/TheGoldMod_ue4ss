-- dna_system.lua
-- Tracks which creature DNA strands have been collected and processed.
-- Persists state to a JSON-ish flat file so forms survive game restarts.

local CreatureDB = require("creature_db")

local DNASystem = {}

-- ── State ─────────────────────────────────────────────────────────────────

-- collected[bpClass] = true  → raw DNA sample in inventory (not yet processed)
-- processed[bpClass] = true  → form fully unlocked and selectable
local _collected  = {}
local _processed  = {}

-- Derive the mod root folder from this script's own path (strips "Scripts\dna_system.lua")
local _scriptPath = debug.getinfo(1, "S").source:sub(2)  -- drop leading '@'
local _modDir     = _scriptPath:match("(.*[/\\])Scripts[/\\]") or ""
local _saveFile   = _modDir .. "dna_save.txt"

-- ── Logging ───────────────────────────────────────────────────────────────

local function Log(msg)
    print("[DNA] " .. tostring(msg) .. "\n")
end

-- ── Persistence ───────────────────────────────────────────────────────────
-- Save format: one line per entry, pipe-delimited
--   C|BP_FlashFish        ← collected
--   P|BP_CollectorLeviathan  ← processed

local function Save()
    local lines = {}
    for k in pairs(_collected) do
        lines[#lines + 1] = "C|" .. k
    end
    for k in pairs(_processed) do
        lines[#lines + 1] = "P|" .. k
    end

    local f = io.open(_saveFile, "w")
    if not f then
        Log("Cannot open save file for writing: " .. _saveFile)
        return
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    Log("Saved " .. #lines .. " DNA entries")
end

local function Load()
    local f = io.open(_saveFile, "r")
    if not f then return end  -- first run, no file yet

    for line in f:lines() do
        local kind, key = line:match("^([CP])|(.+)$")
        if kind == "C" then
            _collected[key] = true
        elseif kind == "P" then
            _processed[key] = true
        end
    end
    f:close()

    local nc, np = 0, 0
    for _ in pairs(_collected) do nc = nc + 1 end
    for _ in pairs(_processed) do np = np + 1 end
    Log("Loaded — collected:" .. nc .. " processed:" .. np)
end

-- ── Public API ────────────────────────────────────────────────────────────

-- Called when the DNA Extractor successfully samples a creature
function DNASystem.Collect(bpClass)
    -- Normalise to base class (strip _C suffix if present)
    local key = bpClass:gsub("_C$", "")

    if _processed[key] then
        Log("Already fully unlocked: " .. key)
        return false, "already_unlocked"
    end
    if _collected[key] then
        Log("Already have raw sample: " .. key)
        return false, "already_collected"
    end

    _collected[key] = true
    Save()
    Log("Collected DNA: " .. key)

    -- Notify any listeners (wheel UI, HUD notification)
    local bridge = _G["WheelBridge"]
    if bridge and bridge.OnDNACollected then
        bridge.OnDNACollected(key)
    end

    return true, "collected"
end

-- Called when the player processes a sample at the DNA Machine
function DNASystem.Process(bpClass)
    local key = bpClass:gsub("_C$", "")

    if not _collected[key] then
        Log("No raw sample for: " .. key)
        return false, "no_sample"
    end
    if _processed[key] then
        Log("Already processed: " .. key)
        return false, "already_processed"
    end

    _collected[key] = nil
    _processed[key] = true
    Save()
    Log("Processed DNA → form unlocked: " .. key)

    local bridge = _G["WheelBridge"]
    if bridge and bridge.OnFormUnlocked then
        bridge.OnFormUnlocked(key)
    end

    return true, "unlocked"
end

-- Returns list of creature DB entries that are unlocked (ready to transform)
function DNASystem.GetUnlockedForms()
    local forms = {}
    for key in pairs(_processed) do
        local entry = CreatureDB.ByClass[key]
        if entry and not entry.debugOnly then
            forms[#forms + 1] = entry
        elseif not entry then
            Log("Processed key has no DB entry: " .. key)
        end
    end
    -- Sort by tier then displayName for stable ordering
    local tierOrder = { small = 1, medium = 2, large = 3, leviathan = 4 }
    table.sort(forms, function(a, b)
        local ta = tierOrder[a.tier] or 99
        local tb = tierOrder[b.tier] or 99
        if ta ~= tb then return ta < tb end
        return a.displayName < b.displayName
    end)
    return forms
end

-- Returns list of DB entries that have a raw sample but aren't processed yet
function DNASystem.GetPendingSamples()
    local pending = {}
    for key in pairs(_collected) do
        local entry = CreatureDB.ByClass[key]
        if entry then pending[#pending + 1] = entry end
    end
    return pending
end

function DNASystem.IsCollected(bpClass)
    return _collected[bpClass:gsub("_C$", "")] == true
end

function DNASystem.IsProcessed(bpClass)
    return _processed[bpClass:gsub("_C$", "")] == true
end

-- Debug: unlock everything instantly (bind to a console command in main.lua)
function DNASystem.UnlockAll()
    for key, entry in pairs(CreatureDB.ByClass) do
        -- ByClass has both "BP_X" and "BP_X_C" → only write base key
        if not key:find("_C$") then
            _collected[key] = nil
            _processed[key] = true
        end
    end
    Save()
    Log("DEBUG: All forms unlocked")
    local bridge = _G["WheelBridge"]
    if bridge and bridge.RebuildWheel then bridge.RebuildWheel() end
end

-- Wipe save (debug)
function DNASystem.Reset()
    _collected = {}
    _processed = {}
    Save()
    Log("DEBUG: DNA state reset")
end

-- ── Init ──────────────────────────────────────────────────────────────────

Load()

return DNASystem
