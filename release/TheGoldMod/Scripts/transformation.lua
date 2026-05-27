-- transformation.lua  (Puppet Architecture)
-- Spawns the actual creature Blueprint actor, destroys its AI controller,
-- and syncs it to the invisible player's position each tick.
--
-- Why puppet:
--   * Creature mesh + ABP run natively -- no SetAnimInstanceClass crashes
--   * Player hidden via TogglePlayerCharacterVisibility (confirmed working)
--   * Camera follows invisible player root; 3rd-person view orbits the puppet

local UEHelpers  = require("UEHelpers")
local CreatureDB = require("creature_db")

local Transformation = {}

-- ── Public state ──────────────────────────────────────────────────────────────

Transformation.IsTransformed   = false
Transformation.CurrentCreature = nil

-- ── Internal state ────────────────────────────────────────────────────────────

local _puppet      = nil
local _playerRef   = nil
local _tickActive  = false
local _syncGen     = 0       -- incremented to stop stale LoopAsync iterations
local _playerHidden = false  -- tracks TogglePlayerCharacterVisibility state

-- Blueprint class cache: bpClass -> UClass (only valid while the package is loaded)
local _classCache  = {}

local _origSwimSpeed      = nil
local _origGravityScale   = nil
local _origCapsuleRadius  = nil
local _origCapsuleHH      = nil
local _inThirdPerson      = false

-- ── Logging ───────────────────────────────────────────────────────────────────

local function Log(msg)
    print("[Transform] " .. tostring(msg) .. "\n")
end

-- ── UE5 actor helpers ─────────────────────────────────────────────────────────

local function ActorGetLocation(actor)
    local root = actor.RootComponent
    if root and root:IsValid() then
        local ok, loc = pcall(function() return root:K2_GetComponentLocation() end)
        if ok and loc then return loc end
    end
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return loc end
    return nil
end

local function ActorGetRotation(actor)
    local root = actor.RootComponent
    if root and root:IsValid() then
        local ok, rot = pcall(function() return root:K2_GetComponentRotation() end)
        if ok and rot then return rot end
    end
    local ok, rot = pcall(function() return actor:K2_GetActorRotation() end)
    if ok and rot then return rot end
    return nil
end

-- ── Player access ─────────────────────────────────────────────────────────────

local function GetPlayerPawn()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
        return pc.Pawn
    end
    for _, cn in ipairs({ "BP_SN2PlayerCharacter_C", "BP_Character_01_C" }) do
        local inst = FindFirstOf(cn)
        if inst and inst:IsValid() then return inst end
    end
    return nil
end

local function GetPC()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc and pc:IsValid() then return pc end
    return nil
end

-- ── Position + velocity sync ──────────────────────────────────────────────────
-- Runs at ~60 Hz (16 ms) via LoopAsync. A _syncPending flag ensures at most
-- one ExecuteInGameThread task is queued at a time — prevents the task-storm
-- crash that 16 ms ExecuteWithDelay chains produced (documented in SN2_DECONSTRUCTION.md).

local function StartSyncLoop()
    local gen     = _syncGen
    local pending = false
    LoopAsync(16, function()
        if not _tickActive or _syncGen ~= gen then return true end
        if pending then return false end
        pending = true
        ExecuteInGameThread(function()
            pending = false
            if not _tickActive or _syncGen ~= gen then return end
            if not _puppet    or not _puppet:IsValid()    then return end
            if not _playerRef or not _playerRef:IsValid() then return end

            local loc = ActorGetLocation(_playerRef)
            local rot = ActorGetRotation(_playerRef)
            if loc and rot then
                pcall(function()
                    _puppet:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
                end)
            end

            -- CharacterMovement on spawned creature BPs is a nullptr UObject in UE4SS
            -- on this build — IsValid() returns false. Guard before writing;
            -- pcall alone does NOT protect (nullptr writes spam log and crash after ~3s).
            pcall(function()
                local pcm = _playerRef.CharacterMovement
                local ccm = _puppet.CharacterMovement
                if pcm and pcm:IsValid() and ccm and ccm:IsValid() then
                    ccm.Velocity = pcm.Velocity
                end
            end)
        end)
        return false
    end)
end

-- ── Class lookup ──────────────────────────────────────────────────────────────

local function FindCreatureClass(bpClass)
    if _classCache[bpClass] then return _classCache[bpClass] end

    for _, cn in ipairs({ bpClass .. "_C", bpClass }) do
        local inst = FindFirstOf(cn)
        if inst then
            local ok, valid = pcall(function() return inst:IsValid() end)
            if ok and valid then
                local clsOk, cls = pcall(function() return inst:GetClass() end)
                if clsOk and cls then
                    local cvOk, cv = pcall(function() return cls:IsValid() end)
                    if cvOk and cv then
                        _classCache[bpClass] = cls
                        Log("Class from live instance: " .. bpClass)
                        return cls
                    end
                end
            end
        end
    end

    local entry = CreatureDB.ByClass[bpClass] or CreatureDB.ByClass[bpClass .. "_C"]
    if entry and entry.bpPath then
        local bpName    = entry.bpPath:match("[^/]+$")
        local classPath = entry.bpPath .. "." .. bpName .. "_C"

        pcall(function() LoadAsset(classPath) end)

        local ok, obj = pcall(function() return StaticFindObject(classPath) end)
        if ok and obj then
            local vOk, valid = pcall(function() return obj:IsValid() end)
            if vOk and valid then
                _classCache[bpClass] = obj
                Log("Class loaded via LoadAsset: " .. bpClass)
                return obj
            end
        end
        Log("LoadAsset did not make class resident: " .. classPath)
    end

    Log("Cannot resolve class for " .. bpClass)
    return nil
end

function Transformation.CacheClass(bpClass, inst)
    if _classCache[bpClass] then return end
    if not inst then return end
    local ok, valid = pcall(function() return inst:IsValid() end)
    if not ok or not valid then return end
    local clsOk, cls = pcall(function() return inst:GetClass() end)
    if clsOk and cls then
        local cvOk, cv = pcall(function() return cls:IsValid() end)
        if cvOk and cv then
            _classCache[bpClass] = cls
            Log("Class pre-cached: " .. bpClass)
        end
    end
end

-- ── Visibility helpers ────────────────────────────────────────────────────────

local function HidePlayer()
    if _playerHidden then return end
    local pc = GetPC()
    if pc then
        pcall(function() pc:TogglePlayerCharacterVisibility() end)
        _playerHidden = true
        Log("Player hidden")
    end
end

local function ShowPlayer()
    if not _playerHidden then return end
    local pc = GetPC()
    if pc then
        pcall(function() pc:TogglePlayerCharacterVisibility() end)
        _playerHidden = false
        Log("Player shown")
    end
end

-- ── Spawn helpers ─────────────────────────────────────────────────────────────

local function DestroyPuppet()
    _tickActive = false
    _syncGen    = _syncGen + 1

    if _puppet and _puppet:IsValid() then
        pcall(function() _puppet:SetActorHiddenInGame(true) end)
        pcall(function() _puppet:Destroy() end)
        Log("Puppet destroyed")
    end
    _puppet = nil

    ShowPlayer()
end

local function SpawnPuppet(creatureEntry)
    if _puppet and _puppet:IsValid() then
        pcall(function() _puppet:Destroy() end)
        Log("Cleaned up stale puppet")
    end
    _puppet = nil

    local player = GetPlayerPawn()
    if not player or not player:IsValid() then
        Log("No player pawn")
        return false
    end
    _playerRef = player

    local ok, world = pcall(function() return player:GetWorld() end)
    if not ok or not world or not world:IsValid() then
        Log("Cannot get world")
        return false
    end

    local classObj = FindCreatureClass(creatureEntry.bpClass)
    if not classObj then return false end

    local loc = ActorGetLocation(player)
    if not loc then Log("Cannot get player location"); return false end
    local rot = ActorGetRotation(player) or { Pitch = 0, Yaw = 0, Roll = 0 }

    local puppet
    ok, puppet = pcall(function() return world:SpawnActor(classObj, loc, rot) end)
    if not ok or not puppet then
        Log("SpawnActor failed: " .. creatureEntry.bpClass)
        return false
    end
    local pOk, pValid = pcall(function() return puppet:IsValid() end)
    if not pOk or not pValid then
        Log("Spawned actor invalid")
        return false
    end
    _puppet = puppet
    Log("Spawned puppet: " .. creatureEntry.bpClass)

    local cOk, ctrl = pcall(function() return puppet:GetController() end)
    if cOk and ctrl then
        local cvOk, cv = pcall(function() return ctrl:IsValid() end)
        if cvOk and cv then
            pcall(function() ctrl:UnPossess() end)
            Log("AI controller unpossessed")
        end
    end

    pcall(function() puppet:SetActorEnableCollision(false) end)

    HidePlayer()

    _tickActive = true
    _syncGen    = _syncGen + 1
    StartSyncLoop()

    return true
end

-- ── Camera ────────────────────────────────────────────────────────────────────
-- Player has NO spring arm (confirmed via retoc scan + live testing).
-- Camera is a UCameraModifier system -- ToggleThirdPerson is the only safe call.

local function ApplyCamera(enable)
    local pc = GetPC()
    if not pc then return end

    if enable then
        local tpOk = pcall(function() pc:ToggleThirdPerson() end)
        _inThirdPerson = tpOk
        Log("Camera: ToggleThirdPerson=" .. tostring(tpOk))
    elseif _inThirdPerson then
        pcall(function() pc:ToggleThirdPerson() end)
        _inThirdPerson = false
        Log("Camera: restored")
    end
end

-- ── Movement ──────────────────────────────────────────────────────────────────

local function ApplyMovement(creatureEntry)
    local player = _playerRef
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if not mv then return end

    local ok, v
    ok, v = pcall(function() return mv.MaxSwimSpeed end)
    if ok then _origSwimSpeed = v end
    ok, v = pcall(function() return mv.GravityScale end)
    if ok then _origGravityScale = v end

    pcall(function() mv.MaxSwimSpeed = creatureEntry.swimSpeed    end)
    pcall(function() mv.GravityScale = creatureEntry.gravityScale end)
end

local function RevertMovement()
    local player = _playerRef
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if not mv then return end

    if _origSwimSpeed    ~= nil then pcall(function() mv.MaxSwimSpeed = _origSwimSpeed    end) end
    if _origGravityScale ~= nil then pcall(function() mv.GravityScale = _origGravityScale end) end
    _origSwimSpeed    = nil
    _origGravityScale = nil
end

-- ── Capsule ───────────────────────────────────────────────────────────────────

local function ApplyCapsule(creatureEntry)
    local player = _playerRef
    if not player or not player:IsValid() then return end
    local cap = player.CapsuleComponent
    if not cap or not cap:IsValid() then return end
    local ok, v
    ok, v = pcall(function() return cap.CapsuleRadius end)
    if ok then _origCapsuleRadius = v end
    ok, v = pcall(function() return cap.CapsuleHalfHeight end)
    if ok then _origCapsuleHH = v end
    if creatureEntry.capsule then
        pcall(function() cap.CapsuleRadius     = creatureEntry.capsule.radius     end)
        pcall(function() cap.CapsuleHalfHeight = creatureEntry.capsule.halfHeight end)
    end
end

local function RevertCapsule()
    local player = _playerRef
    if not player or not player:IsValid() then return end
    local cap = player.CapsuleComponent
    if not cap or not cap:IsValid() then return end
    if _origCapsuleRadius ~= nil then pcall(function() cap.CapsuleRadius     = _origCapsuleRadius end) end
    if _origCapsuleHH     ~= nil then pcall(function() cap.CapsuleHalfHeight = _origCapsuleHH     end) end
    _origCapsuleRadius = nil
    _origCapsuleHH     = nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

function Transformation.TransformInto(creatureEntry)
    if Transformation.IsTransformed then
        Log("Already transformed -- revert first")
        return false
    end

    Transformation.IsTransformed   = true
    Transformation.CurrentCreature = creatureEntry

    ExecuteInGameThread(function()
        if not SpawnPuppet(creatureEntry) then
            Transformation.IsTransformed   = false
            Transformation.CurrentCreature = nil
            Log("Transform failed: " .. creatureEntry.displayName)
            return
        end

        ApplyMovement(creatureEntry)
        ApplyCapsule(creatureEntry)
        ApplyCamera(true)

        Log("Transformed into " .. creatureEntry.displayName)

        local WheelBridge = _G["WheelBridge"]
        if WheelBridge then WheelBridge.OnTransformApplied(creatureEntry) end
    end)
    return true
end

function Transformation.Revert()
    if not Transformation.IsTransformed then return end

    local prev = Transformation.CurrentCreature
    Transformation.IsTransformed   = false
    Transformation.CurrentCreature = nil

    ExecuteInGameThread(function()
        DestroyPuppet()
        RevertMovement()
        RevertCapsule()
        ApplyCamera(false)

        Log("Reverted to human")

        local WheelBridge = _G["WheelBridge"]
        if WheelBridge then WheelBridge.OnTransformReverted(prev) end
    end)
end

function Transformation.OnPawnChanged()
    _tickActive   = false
    _syncGen      = _syncGen + 1
    _puppet       = nil
    _playerRef    = nil
    _playerHidden = false
    _classCache   = {}
    Transformation.IsTransformed   = false
    Transformation.CurrentCreature = nil
    _origSwimSpeed     = nil
    _origGravityScale  = nil
    _origCapsuleRadius = nil
    _origCapsuleHH     = nil
    _inThirdPerson     = false
end

-- ── Stubs for extractor_tool compatibility ────────────────────────────────────

function Transformation.HasMesh(_)          return true end
function Transformation.CacheLiveMesh(_)    end
function Transformation.TryCacheCreature(_) end
function Transformation.PrewarmCache()      end

return Transformation
