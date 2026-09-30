-- Delta Force knife pack -- diagnostics.
--
-- df_knife_diag          what the held knife is and where its behaviour comes from
-- df_knife_combo_trace   10 s of press-to-swing timing, summarised
--
-- The trace exists because "the attack feels like it stores an extra swing" is
-- a timing complaint, and timing is the one thing that can be measured without
-- judging how anything looks.  It prints, per press: when it landed inside the
-- current swing, whether it chained at once, was buffered, or was dropped, and
-- how long the buffered ones waited.  That is the number to argue about.
if not CLIENT then return end

local function held()
    local p = LocalPlayer()
    local w = IsValid(p) and p:GetActiveWeapon()
    if not IsValid(w) or not w.DFAttacks or not w.GetDFAction then
        print("[df_knife] hold one of the pack's knives first")
        return nil
    end
    return w
end

local function origin(fn)
    if not isfunction(fn) then return "<none>" end
    local info = debug.getinfo(fn, "S")
    return (info.short_src or "?") .. ":" .. tostring(info.linedefined)
end

concommand.Add("df_knife_diag", function()
    local w = held()
    if not w then return end
    local p = LocalPlayer()
    local vm = p:GetViewModel()
    print("======== df_knife diag ========")
    print("class        " .. w:GetClass() .. "   base " .. tostring(w.Base))
    print("print name   " .. tostring(w.PrintName))
    print("viewmodel    " .. tostring(w.ViewModel))
    print("   valid=" .. tostring(IsValid(vm))
        .. "  bones=" .. tostring(IsValid(vm) and vm:GetBoneCount())
        .. "  tag_camera=" .. tostring(IsValid(vm) and vm:LookupBone("tag_camera")))
    print("   sequence=" .. tostring(IsValid(vm) and vm:GetSequenceName(vm:GetSequence()))
        .. "  cycle=" .. string.format("%.3f", IsValid(vm) and vm:GetCycle() or 0))
    print("attacks      " .. #w.DFAttacks .. "   buffer capacity "
        .. tostring(w.DFComboBuffer.Capacity) .. " lifetime " .. tostring(w.DFComboBuffer.Lifetime))
    for i, a in ipairs(w.DFAttacks) do
        local range, radius = w:DFAttackReach(a)
        print(string.format("   stage %d  %-8s damage %-4s cast %.3f  gate %.3f  clip %.3f  ends %.3f  reach %.1f/%.1f",
            i, tostring(a.anim), tostring(a.damage), a.cast or 0,
            math.max((a.cast or 0) + (a.backswing or 0) + (a.wait or 0), a.recovery or 0),
            a.length or 0, w:DFClipEnd(a.anim), range, radius))
    end
    print("combo mode   " .. w:DFComboMode() .. "   (df_knife_combo: 0 no buffer, 1 native, 2 no tail chaining)")
    -- DFLoopAnim lives on the realm that dispatches (the server in single-
    -- player); the vm sequence printed above is the ground truth here.
    print("state        action=" .. w:GetDFAction() .. " combo=" .. w:GetDFCombo()
        .. " queued=" .. w:GetDFQueued() .. " anim=" .. tostring(w:GetDFAnimName()))
    print("locomotion   wants " .. w:DFLocomotionAnim()
        .. "   sprinting=" .. tostring(w:DFIsSprinting())
        .. "   speed=" .. math.floor(p:GetVelocity():Length2D()))
    -- Locomotion is sent by the SERVER's Think; the client driver is cosmetic
    -- (pose blend + camera).  "sequence=" above is the ground truth: if it is
    -- stuck on a finished clip while action=0, the server dispatch is dead --
    -- send me this whole output.
    print("driver       " .. (w.DFDriverAt
            and string.format("pose/camera last ran %.0f ms ago", (RealTime() - w.DFDriverAt) * 1000)
            or "pose/camera NEVER RAN -- the DFKnifePackAnim hook is missing"))
    print("camera       " .. (w.DFCameraPos and "cached" or "NOT cached -- CalcView is a no-op"))
    print("code         Think " .. origin(w.Think) .. "   PrimaryAttack " .. origin(w.PrimaryAttack))
    print("MW Base installed: " .. tostring(weapons.Get("mg_base") ~= nil)
        .. "   (the pack does not use it either way)")
    print("===============================")
end)

-- Traces 12 s of WHATEVER is happening to the viewmodel, across weapon
-- switches: run it any time, with anything in hand, then do the repro.  It
-- measures the reported off-screen displacement directly (the viewmodel's
-- offset from the eye along the view axes) plus every candidate freeze
-- mechanism at once: sequence + cycle (a draw frozen at cycle 0 IS a weapon
-- below the screen), playback rate, and the engine's no-draw flag.
local function switchTrace()
    local t0, lastRow, lastWep, lastModel = CurTime(), -1, nil, nil
    print("[df_knife] tracing 12 s -- do the switch that breaks now")
    hook.Add("Think", "DFKnifeSwitchTrace", function()
        local p = LocalPlayer()
        if not IsValid(p) then hook.Remove("Think", "DFKnifeSwitchTrace") return end
        local t = CurTime() - t0
        local w = p:GetActiveWeapon()
        local vm = p:GetViewModel()

        local line
        if IsValid(w) and w ~= lastWep then
            line = string.format("SWITCH -> %s", w:GetClass())
            lastWep = w
        end
        if IsValid(vm) then
            local model = string.match(vm:GetModel() or "?", "([^/]+)$") or "?"
            if model ~= lastModel then
                line = (line and line .. "  " or "") .. "vm model -> " .. model
                lastModel = model
            end
        end
        if line then print(string.format("  %5.2f  %s", t, line)) end

        local row = math.floor(t / 0.1)
        if row ~= lastRow and IsValid(vm) then
            lastRow = row
            -- Where the viewmodel actually is, in view axes: forward / right /
            -- UP offsets from the eye.  "It moved to the bottom of the screen"
            -- must show here as a large negative up value; if up stays normal
            -- while the weapon LOOKS sunk, the sinking is a POSE (a draw
            -- frozen at cycle 0), not a position.
            local eye, ang = p:EyePos(), p:EyeAngles()
            local rel = vm:GetPos() - eye
            local ours = IsValid(w) and w.GetDFAction
            local dfa = ours and w:GetDFAction() or -1
            -- "left" is the running action's remaining lock in seconds: the
            -- number that decides how long a beat SHOULD last, so a beat that
            -- outlives it is measured, not argued about.
            local left = ours and math.max(0, w:GetDFActionEnd() - CurTime()) or -1
            -- gate: the engine's player attack gate as the server saw it
            -- before clearing it (seconds).  think: ms since the SERVER's
            -- SWEP:Think last ran.  A frozen beat with think growing and gate
            -- > 0 is the engine withholding the weapon; the gate hook should
            -- keep both near zero now.
            local think = ours and math.floor((CurTime() - w:GetDFThinkAt()) * 1000) or -1
            local mdl = string.match(vm:GetModel() or "?", "([^/]+)%.mdl$") or "?"
            print(string.format(
                "  %5.2f  %-18s seq=%-12s cyc=%.2f rate=%.2f up=%5.1f nodraw=%s dfact=%d left=%.2f q=%d gate=%.2f think=%d",
                t, mdl, tostring(vm:GetSequenceName(vm:GetSequence())), vm:GetCycle(),
                vm.GetPlaybackRate and vm:GetPlaybackRate() or -1,
                rel:Dot(ang:Up()), tostring(vm:GetNoDraw()), dfa,
                left, ours and w:GetDFQueued() or -1,
                ours and w:GetDFEngineGate() or -1, think))
        end
        if t > 12 then
            hook.Remove("Think", "DFKnifeSwitchTrace")
            print("[df_knife] switch trace done -- send me everything above")
        end
    end)
end
concommand.Add("df_knife_switchtrace", switchTrace)
concommand.Add("df_knife_drawtrace", switchTrace)   -- old name still works

-- df_knife_drawwatch 1 / 0 -- an ARMED recorder for intermittent draw bugs.
--
-- The user reports the draw sometimes playing twice in a row.  "Sometimes"
-- does not fit a 12-second trace, so this one stays on while you play: it
-- samples every frame, keeps the last 3 seconds, and prints them the moment it
-- sees a draw start over -- the cycle of the SAME draw sequence going backwards,
-- or a second draw starting within 3 s with no weapon switch in between.
-- The dump carries the SERVER's deploy count: if it went up twice, the engine
-- deployed twice; if it did not, something re-sent the clip.
local watch = {on = false, buf = {}, lastDump = -100}

local function drawSequences(w)
    local set = {}
    for _, key in ipairs({"Equip", "Draw_Alt"}) do
        local a = w.GetAnimation and w:GetAnimation(key)
        if a and a.Sequences then
            for _, s in ipairs(a.Sequences) do set[string.lower(s)] = true end
        end
    end
    return set
end

local function dumpWatch(reason)
    print(string.format("[df_knife] DRAW RESTART CAUGHT: %s -- last %.1f s:", reason,
        #watch.buf > 0 and (watch.buf[#watch.buf].t - watch.buf[1].t) or 0))
    local t0 = watch.buf[1] and watch.buf[1].t or 0
    local lastRow = -1
    for i, s in ipairs(watch.buf) do
        local row = math.floor((s.t - t0) / 0.05)
        -- one row per 50 ms, plus every row where something discrete changed
        local prev = watch.buf[i - 1]
        local changed = not prev or prev.seq ~= s.seq or prev.serial ~= s.serial
            or prev.deploys ~= s.deploys or prev.class ~= s.class or s.cyc + 0.05 < prev.cyc
        if changed or row ~= lastRow then
            lastRow = row
            print(string.format("  %5.2f  %-16s seq=%-12s cyc=%.2f dfact=%d serial=%d deploys=%d%s",
                s.t - t0, s.class, s.seq, s.cyc, s.dfact, s.serial, s.deploys,
                changed and prev and "   <-- change" or ""))
        end
    end
    print("[df_knife] still armed; send me everything above.  df_knife_drawwatch 0 to stop")
end

concommand.Add("df_knife_drawwatch", function(_, _, args)
    watch.on = tostring(args[1] or "1") ~= "0"
    watch.buf = {}
    if not watch.on then
        hook.Remove("Think", "DFKnifeDrawWatch")
        print("[df_knife] drawwatch off")
        return
    end
    print("[df_knife] drawwatch ARMED -- play normally; it prints by itself when a draw restarts")
    local lastDrawStart, lastDrawClass = -100, nil
    hook.Add("Think", "DFKnifeDrawWatch", function()
        local p = LocalPlayer()
        if not IsValid(p) then return end
        local w = p:GetActiveWeapon()
        local vm = p:GetViewModel()
        if not IsValid(w) or not IsValid(vm) then return end
        local now = RealTime()
        local ours = w.GetDFAction ~= nil
        local s = {
            t = now,
            class = w:GetClass(),
            seq = string.lower(tostring(vm:GetSequenceName(vm:GetSequence()))),
            cyc = vm:GetCycle(),
            dfact = ours and w:GetDFAction() or -1,
            serial = ours and w:GetDFAnimSerial() or -1,
            deploys = ours and w:GetDFDeployCount() or -1,
        }
        local buf = watch.buf
        local prev = buf[#buf]
        buf[#buf + 1] = s
        while buf[1] and now - buf[1].t > 3 do table.remove(buf, 1) end
        if not ours or not prev or now - watch.lastDump < 3 then return end

        local draws = drawSequences(w)
        if not draws[s.seq] then return end
        local reason
        if prev.class == s.class and prev.seq == s.seq and s.cyc + 0.2 < prev.cyc then
            reason = string.format("%s cycle went back %.2f -> %.2f", s.seq, prev.cyc, s.cyc)
        elseif prev.seq ~= s.seq or prev.class ~= s.class then
            -- a draw just started: a second one within 3 s on the same weapon
            -- with no switch in between is the other shape of the bug
            if lastDrawClass == s.class and now - lastDrawStart < 3 then
                local switched = false
                for _, b in ipairs(buf) do
                    if b.t >= lastDrawStart and b.class ~= s.class then switched = true break end
                end
                if not switched then
                    reason = string.format("second draw (%s) %.2f s after the first, no switch", s.seq, now - lastDrawStart)
                end
            end
            lastDrawStart, lastDrawClass = now, s.class
        end
        if reason then
            watch.lastDump = now
            dumpWatch(reason)
        end
    end)
end)

concommand.Add("df_knife_combo_trace", function()
    local w = held()
    if not w then return end
    local rows, t0 = {}, CurTime()
    local lastCombo, lastQueued, pressAt = w:GetDFCombo(), 0, nil

    print("[df_knife] 10 s combo trace -- swing, and keep pressing as you normally would.")
    hook.Add("Think", "DFKnifeComboTrace", function()
        local p = LocalPlayer()
        if not IsValid(p) or not IsValid(w) then hook.Remove("Think", "DFKnifeComboTrace") return end
        local now = CurTime() - t0

        if p:KeyPressed(IN_ATTACK) then
            local inSwing = w:GetDFAction() == 3
            local since = inSwing and (CurTime() - w:GetDFAnimStart()) or nil
            pressAt = now
            rows[#rows + 1] = {t = now, kind = "press",
                note = inSwing and string.format("%.2fs into stage %d (hit at %.2f, gate at %.2f)",
                    since, w:GetDFCombo(),
                    w:GetDFCastAt() - w:GetDFAnimStart(), w:GetDFReadyAt() - w:GetDFAnimStart())
                    or "from idle"}
        end

        local queued = w:GetDFQueued()
        if queued ~= 0 and lastQueued == 0 then
            rows[#rows + 1] = {t = now, kind = "buffered", note = "stage " .. queued}
        elseif queued == 0 and lastQueued ~= 0 and w:GetDFCombo() == lastCombo then
            rows[#rows + 1] = {t = now, kind = "buffer expired", note = "press discarded"}
        end
        lastQueued = queued

        local combo = w:GetDFCombo()
        if combo ~= lastCombo and combo ~= 0 then
            rows[#rows + 1] = {t = now, kind = "SWING", note = "stage " .. combo
                .. (pressAt and string.format("  %.0f ms after the press", (now - pressAt) * 1000) or "")}
            pressAt = nil
        end
        lastCombo = combo

        if now > 10 then
            hook.Remove("Think", "DFKnifeComboTrace")
            local presses, swings, worst = 0, 0, 0
            for _, r in ipairs(rows) do
                print(string.format("  %5.2fs  %-14s %s", r.t, r.kind, r.note))
                if r.kind == "press" then presses = presses + 1 end
                if r.kind == "SWING" then
                    swings = swings + 1
                    local ms = tonumber(string.match(r.note, "(%d+) ms"))
                    if ms and ms > worst then worst = ms end
                end
            end
            print(string.format("[df_knife] %d presses -> %d swings; longest press-to-swing wait %d ms",
                presses, swings, worst))
            if swings > presses then
                print("[df_knife] MORE SWINGS THAN PRESSES -- that is the bug; send me this list.")
            end
        end
    end)
end)
