-- traits.lua
-- Per-creature passive and active abilities.
-- Runs on a shared tick timer while transformed.
-- Abilities are keyed from creature_db.lua's abilities table.

local UEHelpers = require("UEHelpers")

local Traits = {}

local function GetPlayerPawn()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc and pc:IsValid() then
        local ok2, pawn = pcall(function() return pc:GetPawn() end)
        if ok2 and pawn and pawn:IsValid() then return pawn end
    end
    local candidates = { "BP_SN2PlayerCharacter_C", "BP_Character_01_C" }
    for _, cn in ipairs(candidates) do
        local inst = FindFirstOf(cn)
        if inst and inst:IsValid() then return inst end
    end
    return nil
end

-- ── Internal state ────────────────────────────────────────────────────────

local _cooldowns = {}
local _tickTimer  = nil
local _tickGen    = 0
local _TICK_RATE  = 0.1   -- seconds between trait ticks

Traits.OxygenImmune = false

local function Log(msg) print("[Traits] " .. tostring(msg) .. "\n") end

-- ── Helpers ───────────────────────────────────────────────────────────────

local function GetPlayer() return GetPlayerPawn() end

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

local function ActorGetForward(actor)
    local ok, fwd = pcall(function() return actor:GetActorForwardVector() end)
    if ok and fwd then return fwd end
    local rot = ActorGetRotation(actor)
    if rot then
        local yaw = math.rad(rot.Yaw or 0)
        local pitch = math.rad(rot.Pitch or 0)
        return { X = math.cos(pitch)*math.cos(yaw), Y = math.cos(pitch)*math.sin(yaw), Z = math.sin(pitch) }
    end
    return { X = 1, Y = 0, Z = 0 }
end

local function SafeCall(obj, fn, ...)
    if not obj or not obj:IsValid() then return false end
    local args = { ... }
    local ok, err = pcall(function() obj[fn](obj, table.unpack(args)) end)
    if not ok then Log("SafeCall " .. fn .. " failed: " .. tostring(err)) end
    return ok
end

-- Sphere overlap — returns array of actors within range of player.
-- NOTE: Uses FindAllOf("Actor") — only call from active abilities (keypresses),
-- never from a passive tick. Costs ~73ms to fetch + iterate.
local function GetActorsInRange(radius)
    local player = GetPlayer()
    if not player or not player:IsValid() then return {} end
    local locOk, loc = pcall(function() return ActorGetLocation(player) end)
    if not locOk or not loc then return {} end

    local results  = {}
    local allActors = FindAllOf("Actor")
    if not allActors then return results end

    for _, a in ipairs(allActors) do
        local validOk, valid = pcall(function() return a and a:IsValid() end)
        if validOk and valid and a ~= player then
            local alOk, al = pcall(function() return ActorGetLocation(a) end)
            if alOk and al then
                local dx = al.X - loc.X
                local dy = al.Y - loc.Y
                local dz = al.Z - loc.Z
                if (dx*dx + dy*dy + dz*dz) <= (radius * radius) then
                    table.insert(results, a)
                end
            end
        end
    end
    return results
end

-- Forward cone target — same FindAllOf("Actor") cost warning as above.
local function GetActorInFront(range)
    local player = GetPlayer()
    if not player or not player:IsValid() then return nil end

    local fwd = ActorGetForward(player)
    local loc = ActorGetLocation(player)
    if not loc then return nil end

    local best, bestDist = nil, range * range
    local allActors = FindAllOf("Actor")
    if not allActors then return nil end

    for _, a in ipairs(allActors) do
        if a and a:IsValid() and a ~= player then
            local al = ActorGetLocation(a)
            if al then
                local dx = al.X - loc.X
                local dy = al.Y - loc.Y
                local dz = al.Z - loc.Z
                local distSq = dx*dx + dy*dy + dz*dz
                if distSq < bestDist then
                    local dot = dx * fwd.X + dy * fwd.Y + dz * fwd.Z
                    if dot > 0 then
                        best     = a
                        bestDist = distSq
                    end
                end
            end
        end
    end
    return best
end

local function ApplyDamageToActor(target, damage, causer)
    if not target or not target:IsValid() then return end
    SafeCall(target, "TakeDamage", damage, {}, causer, causer)
end

local function LaunchActor(target, force)
    if not target or not target:IsValid() then return end
    local player = GetPlayer()
    if not player then return end
    local pLoc = ActorGetLocation(player)
    local tLoc = ActorGetLocation(target)
    if not pLoc or not tLoc then return end
    local dx = tLoc.X - pLoc.X
    local dy = tLoc.Y - pLoc.Y
    local dz = tLoc.Z - pLoc.Z
    local len = math.sqrt(dx*dx + dy*dy + dz*dz)
    if len < 1 then return end
    local impulse = { X = dx/len * force, Y = dy/len * force, Z = dz/len * force }
    local moveComp = target.CharacterMovement
    if moveComp then
        pcall(function() moveComp:AddImpulse(impulse, true) end)
    end
end

local function TickCooldowns(dt)
    for k, v in pairs(_cooldowns) do
        _cooldowns[k] = v - dt
        if _cooldowns[k] <= 0 then _cooldowns[k] = nil end
    end
end

local function OnCooldown(key)
    return _cooldowns[key] ~= nil and _cooldowns[key] > 0
end

local function StartCooldown(key, seconds)
    _cooldowns[key] = seconds
end

-- ── Oxygen suppression ────────────────────────────────────────────────────
-- TODO: Writing to GAS FGameplayAttributeData fields crashes (fires attribute
-- callbacks with no valid execution context). Needs a safe mechanism first
-- (GameplayEffect cancel or a drain-rate UFunction). Stubbed for now.

local function SuppressOxygen() end

-- ── Passive traits ────────────────────────────────────────────────────────

local function Tick_SlimeTrail(_)
    Traits.SlimeTrailActive = true
end

local function Tick_WideVision(_)
    -- Detection radius threat count — future HUD integration.
    -- NOTE: does NOT call FindAllOf("Actor") in the tick (73ms/call, catastrophic).
    -- Real implementation needs a dedicated creature-class search or a game event hook.
    Traits.NearbyThreatCount = 0
end

local function Tick_AbsorbHeal(creature)
    -- Epicurean: slow health regen.
    -- Health is not in UWESurvivalAttributeSet (which has Oxygen/Food/Water).
    -- Using property guessing until the health attribute set is identified.
    local ability = creature.abilities.absorb
    local player  = GetPlayer()
    if not player or not player:IsValid() then return end

    local healProps = { "CurrentHealth", "Health", "HealthPoints" }
    for _, p in ipairs(healProps) do
        local ok, val = pcall(function() return player[p] end)
        if ok and type(val) == "number" then
            local maxProps = { "MaxHealth", "MaxHP" }
            local maxVal = 100
            for _, mp in ipairs(maxProps) do
                local mok, mv = pcall(function() return player[mp] end)
                if mok and type(mv) == "number" then maxVal = mv; break end
            end
            local newHP = math.min(maxVal, val + ability.healPerSec * _TICK_RATE)
            pcall(function() player[p] = newHP end)
            break
        end
    end
end

-- ── Active ability implementations ────────────────────────────────────────

function Traits.ActivateMelee(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local target = GetActorInFront(abilityDef.range)
    if target then
        ApplyDamageToActor(target, abilityDef.damage, GetPlayer())
        Log("Melee hit " .. target:GetClass():GetName() .. " for " .. abilityDef.damage)
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateFlash(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    for _, a in ipairs(nearby) do
        ApplyDamageToActor(a, 1, GetPlayer())
        Log("Flash affected " .. a:GetClass():GetName())
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateElectricPulse(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    for _, a in ipairs(nearby) do
        ApplyDamageToActor(a, abilityDef.damage, GetPlayer())
    end
    Log("Electric pulse: hit " .. #nearby .. " targets")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateEMP(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    for _, a in ipairs(nearby) do
        ApplyDamageToActor(a, 1, GetPlayer())
        local mv = a.CharacterMovement
        if mv then
            pcall(function() mv.Velocity = {X=0,Y=0,Z=0} end)
        end
    end
    Log("EMP burst: stunned " .. #nearby .. " targets")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateRam(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local fwd = ActorGetForward(player)
    local mv  = player.CharacterMovement
    if mv then
        pcall(function()
            mv.Velocity = {
                X = fwd.X * abilityDef.force,
                Y = fwd.Y * abilityDef.force,
                Z = fwd.Z * abilityDef.force,
            }
        end)
    end
    local target = GetActorInFront(abilityDef.range)
    if target then
        ApplyDamageToActor(target, abilityDef.damage, player)
        LaunchActor(target, abilityDef.force * 0.5)
        Log("Ram hit " .. target:GetClass():GetName())
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateJetDash(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local fwd = ActorGetForward(player)
    local mv  = player.CharacterMovement
    if mv then
        pcall(function()
            mv.Velocity = {
                X = fwd.X * abilityDef.force,
                Y = fwd.Y * abilityDef.force,
                Z = fwd.Z * abilityDef.force * 0.3,
            }
        end)
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
    Log("Jet dash!")
end

function Traits.ActivateNeedleVolley(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local world  = player:GetWorld()
    if not world or not world:IsValid() then return end

    local projClass = StaticFindObject("/Game/Blueprints/Creatures/NeedlerShark/"
        .. abilityDef.projectile .. "." .. abilityDef.projectile .. "_C")

    if projClass and projClass:IsValid() then
        local fwd = ActorGetForward(player)
        local loc = ActorGetLocation(player)
        if not loc then return end
        local halfSpread = math.rad(abilityDef.spread / 2)

        for i = 1, abilityDef.count do
            local angle = -halfSpread + (i-1) * (math.rad(abilityDef.spread) / (abilityDef.count-1))
            local spawnFwd = {
                X = fwd.X * math.cos(angle) - fwd.Y * math.sin(angle),
                Y = fwd.X * math.sin(angle) + fwd.Y * math.cos(angle),
                Z = fwd.Z,
            }
            local spawnLoc = { X = loc.X + spawnFwd.X * 100,
                               Y = loc.Y + spawnFwd.Y * 100,
                               Z = loc.Z }
            world:SpawnActor(projClass, spawnLoc, {})
        end
        Log("Fired " .. abilityDef.count .. " needles")
    else
        Log("Needle projectile class not found — needs pak")
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateAirBurst(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if mv then
        pcall(function()
            local vOk, vel = pcall(function() return mv.Velocity end)
            mv.Velocity = { X = vOk and vel and vel.X or 0,
                            Y = vOk and vel and vel.Y or 0,
                            Z = abilityDef.force }
        end)
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivatePhase(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if not ok or not pc or not pc:IsValid() then return end

    -- TogglePlayerCharacterVisibility is a toggle, not a set. When transformed,
    -- the player is already hidden — calling it would make them visible again.
    -- Skip the toggle entirely while transformed; the puppet provides the visual.
    local Transformation = require("transformation")
    if Transformation.IsTransformed then
        Log("Phase: transformed — visibility toggle skipped (player already hidden)")
        StartCooldown(abilityKey, abilityDef.cooldown)
        return
    end

    pcall(function() pc:TogglePlayerCharacterVisibility() end)
    Log("Phase: invisible for " .. abilityDef.duration .. "s")

    ExecuteWithDelay(math.floor(abilityDef.duration * 1000), function()
        ExecuteInGameThread(function()
            -- Only re-toggle if still not transformed. If the player transformed during
            -- the phase window, transformation's ShowPlayer handles visibility on revert.
            local T = require("transformation")
            if not T.IsTransformed then
                local ok2, pc2 = pcall(function() return UEHelpers.GetPlayerController() end)
                if ok2 and pc2 and pc2:IsValid() then
                    pcall(function() pc2:TogglePlayerCharacterVisibility() end)
                end
            end
            Log("Phase ended")
        end)
    end)
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateVoidPull(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    for _, a in ipairs(nearby) do
        LaunchActor(a, abilityDef.force)
    end
    Log("Void pull: affected " .. #nearby .. " actors")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateSpeedBurst(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if not mv then return end
    local origSpeed
    local ok, v = pcall(function() return mv.MaxSwimSpeed end)
    if ok and type(v) == "number" then origSpeed = v end
    local boostSpeed = (origSpeed or 600) * (abilityDef.speedMult or 3.0)
    pcall(function() mv.MaxSwimSpeed = boostSpeed end)
    Log("Speed burst: " .. tostring(boostSpeed))
    ExecuteWithDelay(math.floor((abilityDef.duration or 3.0) * 1000), function()
        ExecuteInGameThread(function()
            local p2 = GetPlayer()
            if not p2 or not p2:IsValid() then return end
            local mv2 = p2.CharacterMovement
            if not mv2 then return end
            pcall(function() mv2.MaxSwimSpeed = origSpeed or 600 end)
            Log("Speed burst ended")
        end)
    end)
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateGravitySurge(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if not mv then return end
    local origGrav
    local ok, v = pcall(function() return mv.GravityScale end)
    if ok and type(v) == "number" then origGrav = v end
    pcall(function() mv.GravityScale = abilityDef.targetGravity or -0.3 end)
    Log("Gravity surge!")
    ExecuteWithDelay(math.floor((abilityDef.duration or 4.0) * 1000), function()
        ExecuteInGameThread(function()
            local p2 = GetPlayer()
            if not p2 or not p2:IsValid() then return end
            local mv2 = p2.CharacterMovement
            if not mv2 then return end
            pcall(function() mv2.GravityScale = origGrav or 0.0 end)
            Log("Gravity surge ended")
        end)
    end)
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateSonicBoom(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    local player = GetPlayer()
    for _, a in ipairs(nearby) do
        LaunchActor(a, abilityDef.force or 2000)
        if abilityDef.damage and abilityDef.damage > 0 then
            ApplyDamageToActor(a, abilityDef.damage, player)
        end
    end
    Log("Sonic boom: pushed " .. #nearby .. " actors")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateTailSpin(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    local player = GetPlayer()
    for _, a in ipairs(nearby) do
        ApplyDamageToActor(a, abilityDef.damage, player)
        LaunchActor(a, abilityDef.knockback or 600)
    end
    Log("Tail spin: hit " .. #nearby .. " targets")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateHealBite(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    local target = GetActorInFront(abilityDef.range)
    if target then
        ApplyDamageToActor(target, abilityDef.damage, player)
        Log("Heal bite: hit " .. target:GetClass():GetName())
        if player and player:IsValid() then
            local healAmt = abilityDef.damage * (abilityDef.healFrac or 0.5)
            local props = { "CurrentHealth", "Health", "HealthPoints" }
            for _, p in ipairs(props) do
                local ok, val = pcall(function() return player[p] end)
                if ok and type(val) == "number" then
                    local maxVal = 100
                    for _, mp in ipairs({ "MaxHealth", "MaxHP" }) do
                        local mok, mv = pcall(function() return player[mp] end)
                        if mok and type(mv) == "number" then maxVal = mv; break end
                    end
                    pcall(function() player[p] = math.min(maxVal, val + healAmt) end)
                    Log("Healed " .. healAmt)
                    break
                end
            end
        end
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateChainLightning(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local loc = ActorGetLocation(player)
    if not loc then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    table.sort(nearby, function(a, b)
        local al = ActorGetLocation(a)
        local bl = ActorGetLocation(b)
        if not al or not bl then return false end
        local da = (al.X-loc.X)^2 + (al.Y-loc.Y)^2 + (al.Z-loc.Z)^2
        local db = (bl.X-loc.X)^2 + (bl.Y-loc.Y)^2 + (bl.Z-loc.Z)^2
        return da < db
    end)
    local chains  = abilityDef.chains or 3
    local dmg     = abilityDef.damage
    local falloff = abilityDef.falloff or 0.6
    for i = 1, math.min(chains, #nearby) do
        ApplyDamageToActor(nearby[i], math.floor(dmg), player)
        Log("Chain lightning arc " .. i .. ": " .. math.floor(dmg))
        dmg = dmg * falloff
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateBlightSpores(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local pulses   = abilityDef.pulses   or 3
    local interval = abilityDef.interval or 1000
    local dmg      = abilityDef.damage   or 8
    local radius   = abilityDef.radius   or 300
    Log("Blight spores released!")
    for i = 1, pulses do
        ExecuteWithDelay(i * interval, function()
            ExecuteInGameThread(function()
                local nearby = GetActorsInRange(radius)
                for _, a in ipairs(nearby) do
                    ApplyDamageToActor(a, dmg, GetPlayer())
                end
                Log("Blight pulse: hit " .. #nearby)
            end)
        end)
    end
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateCamoBurst(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if not mv then return end
    local origSpeed
    local ok, v = pcall(function() return mv.MaxSwimSpeed end)
    if ok and type(v) == "number" then origSpeed = v end
    local boostSpeed = (origSpeed or 600) * (abilityDef.speedMult or 2.0)
    pcall(function() mv.MaxSwimSpeed = boostSpeed end)
    Log("Camo burst: speed=" .. tostring(boostSpeed))
    ExecuteWithDelay(math.floor((abilityDef.duration or 3.0) * 1000), function()
        ExecuteInGameThread(function()
            local p2 = GetPlayer()
            if not p2 or not p2:IsValid() then return end
            local mv2 = p2.CharacterMovement
            if not mv2 then return end
            pcall(function() mv2.MaxSwimSpeed = origSpeed or 600 end)
            Log("Camo burst ended")
        end)
    end)
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateVortex(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local nearby = GetActorsInRange(abilityDef.radius)
    for _, a in ipairs(nearby) do
        LaunchActor(a, abilityDef.force)  -- negative force = toward player
    end
    Log("Vortex: pulled " .. #nearby .. " actors")
    StartCooldown(abilityKey, abilityDef.cooldown)
end

function Traits.ActivateBreachDive(abilityDef, abilityKey)
    if OnCooldown(abilityKey) then return end
    local player = GetPlayer()
    if not player or not player:IsValid() then return end
    local mv = player.CharacterMovement
    if mv then
        pcall(function()
            local vOk, vel = pcall(function() return mv.Velocity end)
            mv.Velocity = {
                X = vOk and vel and vel.X or 0,
                Y = vOk and vel and vel.Y or 0,
                Z = -(abilityDef.diveForce or 3000),
            }
        end)
    end
    Log("Breach dive!")
    ExecuteWithDelay(abilityDef.delay or 1500, function()
        ExecuteInGameThread(function()
            local nearby = GetActorsInRange(abilityDef.blastRadius or 400)
            for _, a in ipairs(nearby) do
                ApplyDamageToActor(a, abilityDef.damage or 50, GetPlayer())
                LaunchActor(a, abilityDef.blastForce or 1500)
            end
            Log("Breach impact: hit " .. #nearby)
        end)
    end)
    StartCooldown(abilityKey, abilityDef.cooldown)
end

-- ── Ability dispatcher ────────────────────────────────────────────────────

local _abilityMap = {
    bite              = function(def, key) Traits.ActivateMelee(def, key) end,
    clawSwipe         = function(def, key) Traits.ActivateMelee(def, key) end,
    crushBite         = function(def, key) Traits.ActivateMelee(def, key) end,
    spineJab          = function(def, key) Traits.ActivateMelee(def, key) end,
    tailSwipe         = function(def, key) Traits.ActivateMelee(def, key) end,
    wingSlap          = function(def, key) Traits.ActivateMelee(def, key) end,
    tentacleCrush     = function(def, key) Traits.ActivateMelee(def, key) end,
    tentacleStrike    = function(def, key) Traits.ActivateMelee(def, key) end,
    ambushStrike      = function(def, key) Traits.ActivateMelee(def, key) end,
    ramStrike         = function(def, key) Traits.ActivateRam(def, key) end,
    ramCharge         = function(def, key) Traits.ActivateRam(def, key) end,
    flash             = function(def, key) Traits.ActivateFlash(def, key) end,
    bioluminescentPulse = function(def, key) Traits.ActivateFlash(def, key) end,
    electricPulse     = function(def, key) Traits.ActivateElectricPulse(def, key) end,
    empBurst          = function(def, key) Traits.ActivateEMP(def, key) end,
    voidShriek        = function(def, key) Traits.ActivateEMP(def, key) end,
    jetDash           = function(def, key) Traits.ActivateJetDash(def, key) end,
    needleVolley      = function(def, key) Traits.ActivateNeedleVolley(def, key) end,
    airBurst          = function(def, key) Traits.ActivateAirBurst(def, key) end,
    phase             = function(def, key) Traits.ActivatePhase(def, key) end,
    burrow            = function(def, key) Traits.ActivatePhase(def, key) end,
    voidPull          = function(def, key) Traits.ActivateVoidPull(def, key) end,
    grab              = function(def, key) Traits.ActivateMelee(def, key) end,
    blightLatch       = function(def, key) Traits.ActivateMelee(def, key) end,
    acidSpit          = function(def, key) Traits.ActivateMelee(def, key) end,
    echoHowl          = function(def, key) Traits.ActivateEMP(def, key) end,
    deepSonar         = function(_, _) Log("deepSonar: needs minimap integration") end,
    speedBurst        = function(def, key) Traits.ActivateSpeedBurst(def, key) end,
    gravitySurge      = function(def, key) Traits.ActivateGravitySurge(def, key) end,
    sonicBoom         = function(def, key) Traits.ActivateSonicBoom(def, key) end,
    tailSpin          = function(def, key) Traits.ActivateTailSpin(def, key) end,
    healBite          = function(def, key) Traits.ActivateHealBite(def, key) end,
    chainLightning    = function(def, key) Traits.ActivateChainLightning(def, key) end,
    blightSpores      = function(def, key) Traits.ActivateBlightSpores(def, key) end,
    camoBurst         = function(def, key) Traits.ActivateCamoBurst(def, key) end,
    vortex            = function(def, key) Traits.ActivateVortex(def, key) end,
    breachDive        = function(def, key) Traits.ActivateBreachDive(def, key) end,
}

function Traits.ActivatePrimary(creature)
    if not creature or not creature.abilities then return end
    for name, def in pairs(creature.abilities) do
        if not def.passive and (def.key == "F" or def.key == nil) then
            local fn = _abilityMap[name]
            if fn then fn(def, name)
            else Log("No handler for ability: " .. name) end
            return
        end
    end
end

function Traits.ActivateSecondary(creature)
    if not creature or not creature.abilities then return end
    for name, def in pairs(creature.abilities) do
        if not def.passive and def.key == "R" then
            local fn = _abilityMap[name]
            if fn then fn(def, name)
            else Log("No handler for ability: " .. name) end
            return
        end
    end
end

-- ── Per-tick passive processing ───────────────────────────────────────────

local _passiveHandlers = {
    slimeTrail  = Tick_SlimeTrail,
    wideVision  = Tick_WideVision,
    absorb      = Tick_AbsorbHeal,
}

local function RunPassives(creature)
    if not creature or not creature.abilities then return end
    for name, def in pairs(creature.abilities) do
        if def.passive then
            local fn = _passiveHandlers[name]
            if fn then fn(creature) end
        end
    end
end

-- ── Tick loop ─────────────────────────────────────────────────────────────

function Traits.Tick()
    local Transformation = require("transformation")
    if not Transformation or not Transformation.IsTransformed then return end
    local creature = Transformation.CurrentCreature
    if not creature then return end

    TickCooldowns(_TICK_RATE)
    SuppressOxygen()
    RunPassives(creature)
end

function Traits.StartTicking()
    if _tickTimer then return end
    _tickTimer = true
    local gen  = _tickGen
    local function ScheduleTick()
        if not _tickTimer or _tickGen ~= gen then return end
        ExecuteWithDelay(math.floor(_TICK_RATE * 1000), function()
            if not _tickTimer or _tickGen ~= gen then return end
            ExecuteInGameThread(function()
                if not _tickTimer or _tickGen ~= gen then return end
                Traits.Tick()
            end)
            ScheduleTick()
        end)
    end
    ScheduleTick()
    Log("Trait tick loop started (gen " .. gen .. ")")
end

function Traits.Reset()
    _tickGen                 = _tickGen + 1
    _cooldowns               = {}
    _tickTimer               = nil
    Traits.OxygenImmune      = false
    Traits.SlimeTrailActive  = false
    Traits.NearbyThreatCount = 0
end

return Traits
