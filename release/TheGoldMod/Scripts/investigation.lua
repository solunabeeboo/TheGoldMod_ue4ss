-- investigation.lua
-- Temporary test harness.  Load via main.lua, run in-game, read logs.
-- DELETE before shipping.
--
-- Keybinds:
--   F5  — MovComp raw call (AddExternalImpulse / AddExternalVelocity)
--   F6  — UWESurvivalAttributeSet read + set oxygen to max
--   F7  — TogglePlayerCharacterVisibility hide/show (2s)
--   F10 — NotifyOnNewObject smoke test (confirm it fires on respawn)
--   F12 — FindAllOf("Actor") cost measurement

local UEHelpers = require("UEHelpers")

local function Log(msg) print("[INV] " .. tostring(msg) .. "\n") end

local function GetPC()
    local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and pc and pc:IsValid() then return pc end
    return nil
end

local function GetPawn()
    local pc = GetPC()
    if pc then
        local ok, p = pcall(function() return pc.Pawn end)
        if ok and p and p:IsValid() then return p end
    end
    local inst = FindFirstOf("BP_SN2PlayerCharacter_C")
    if inst and inst:IsValid() then return inst end
    return nil
end

-- ── F5 — MovComp raw call (no IsValid, no ForEachFunction) ───────────────
-- ForEachFunction on CharMoveComp crashes. Skip class probing entirely.
-- Just call AddExternalImpulse/Velocity directly via pcall.

RegisterKeyBind(Key.F5, function()
    ExecuteInGameThread(function()
        Log("=== F5: MovComp raw call probe ===")
        local pawn = GetPawn()
        if not pawn then Log("No pawn"); return end

        local mv = pawn.CharMoveComp
        Log("CharMoveComp=" .. tostring(mv))
        if not mv then Log("nil — abort"); return end

        -- Read MaxSwimSpeed to confirm property access works at all
        local spOk, sp = pcall(function() return mv.MaxSwimSpeed end)
        Log("MaxSwimSpeed read ok=" .. tostring(spOk) .. " val=" .. tostring(sp))

        -- Big upward kick — obvious if it works
        local i1ok, i1err = pcall(function()
            mv:AddExternalImpulse({ X=0, Y=0, Z=150000 }, false)
        end)
        Log("AddExternalImpulse(150000 up) ok=" .. tostring(i1ok) .. " err=" .. tostring(i1err))

        -- Fallback: AddExternalVelocity
        local i2ok, i2err = pcall(function()
            mv:AddExternalVelocity({ X=0, Y=0, Z=3000 })
        end)
        Log("AddExternalVelocity(3000 up) ok=" .. tostring(i2ok) .. " err=" .. tostring(i2err))

        Log("=== F5 done ===")
    end)
end)

-- ── F6 — UWESurvivalAttributeSet probe ───────────────────────────────────
-- Uses the tutorial approach: FindAllOf → filter by GetFullName → read/write.
-- Go underwater first so a successful set is visually obvious (O2 refills).

RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
        Log("=== F6: UWESurvivalAttributeSet probe ===")

        local all = FindAllOf("UWESurvivalAttributeSet")
        Log("FindAllOf count=" .. tostring(all and #all or 0))
        if not all then return end

        local attrSet = nil
        for _, s in ipairs(all) do
            local vOk, valid = pcall(function() return s:IsValid() end)
            if vOk and valid then
                local fnOk, fullName = pcall(function() return s:GetFullName() end)
                Log("  candidate=" .. tostring(fullName))
                if fnOk and fullName and fullName:find("BP_Character_01_C") then
                    attrSet = s
                    Log("  --> selected")
                    break
                end
            end
        end

        if not attrSet then Log("No player attr set found"); return end

        -- Read current values
        local oxOk,  ox  = pcall(function() return attrSet.Oxygen.CurrentValue end)
        local moxOk, mox = pcall(function() return attrSet.MaxOxygen.CurrentValue end)
        Log("Oxygen.CurrentValue  ok=" .. tostring(oxOk)  .. " val=" .. tostring(ox))
        Log("MaxOxygen.CurrentValue ok=" .. tostring(moxOk) .. " val=" .. tostring(mox))

        -- Set oxygen to max
        if moxOk and mox then
            local setOk, setErr = pcall(function()
                attrSet.Oxygen.BaseValue    = mox
                attrSet.Oxygen.CurrentValue = mox
            end)
            Log("Set Oxygen=max ok=" .. tostring(setOk) .. " err=" .. tostring(setErr))
        end

        Log("=== F6 done ===")
    end)
end)

-- ── F7 — TogglePlayerCharacterVisibility (confirmed working, re-verify) ──
-- Hides for 2s then shows. Already confirmed ok=true last run.

local _visState = false

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        if _visState then return end
        Log("=== F7: Visibility toggle ===")
        local pc = GetPC()
        if not pc then Log("No PC"); return end

        local ok1 = pcall(function() pc:TogglePlayerCharacterVisibility() end)
        Log("Hide ok=" .. tostring(ok1))
        _visState = true

        ExecuteWithDelay(2000, function()
            ExecuteInGameThread(function()
                local ok2 = pcall(function() pc:TogglePlayerCharacterVisibility() end)
                Log("Show ok=" .. tostring(ok2))
                _visState = false
                Log("=== F7 done ===")
            end)
        end)
    end)
end)

-- ── F10 — NotifyOnNewObject smoke test ───────────────────────────────────
-- Registers a NotifyOnNewObject for the player character.
-- Press F10, then die/respawn (or fast travel). If "[INV] NotifyOnNewObject fired"
-- appears in the log, the function works for player spawn detection.

RegisterKeyBind(Key.F10, function()
    ExecuteInGameThread(function()
        Log("F10: Registering NotifyOnNewObject for BP_Character_01_C — respawn to trigger")
        NotifyOnNewObject("/Game/Blueprints/Character/player/BP_Character_01.BP_Character_01_C",
            function(obj)
                ExecuteInGameThread(function()
                    Log("NotifyOnNewObject fired! obj=" .. tostring(obj))
                    local vOk, valid = pcall(function() return obj:IsValid() end)
                    Log("  IsValid=" .. tostring(vOk and valid))

                    -- While we're here, immediately grab the attr set
                    local all = FindAllOf("UWESurvivalAttributeSet")
                    Log("  AttrSets after spawn: " .. tostring(all and #all or 0))
                end)
            end)
    end)
end)

-- ── F12 — FindAllOf("Actor") cost ────────────────────────────────────────
-- 16929 actors / 73ms confirmed last run. Re-verify and check iteration cost.

RegisterKeyBind(Key.F12, function()
    ExecuteInGameThread(function()
        Log("=== F12: FindAllOf cost ===")
        local t0 = os.clock()
        local all = FindAllOf("Actor")
        local t1 = os.clock()
        Log("FindAllOf('Actor'): " .. tostring(all and #all or 0)
            .. " actors in " .. string.format("%.1f", (t1-t0)*1000) .. "ms")

        -- Cost of iterating + GetClass():GetName() on every actor
        local t2 = os.clock()
        local count = 0
        if all then
            for _, a in ipairs(all) do
                pcall(function()
                    if a:IsValid() then
                        a:GetClass():GetName()
                        count = count + 1
                    end
                end)
            end
        end
        local t3 = os.clock()
        Log("Full iteration+GetName: " .. count .. " valid in "
            .. string.format("%.1f", (t3-t2)*1000) .. "ms")
        Log("=== F12 done ===")
    end)
end)

Log("Investigation probes loaded: F5=Impulse  F6=AttrSet  F7=Visibility  F10=NotifyOnNewObject  F12=ActorCost")
