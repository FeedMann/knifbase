-- Delta Force knife pack -- action audio.
--
-- Audio follows the sequence that is ACTUALLY on screen, never a timer started
-- alongside it.  The reason is singleplayer: the code that starts a clip runs on
-- the server while the viewmodel picks and plays it on the client, so the only
-- thing that knows what is really playing, and how far into it, is the
-- viewmodel itself.  So read it every frame.
--
-- DFAudioTracks is keyed by COMPILED SEQUENCE NAME (melee, fire_02, inspect),
-- not by animation key, because that is what GetSequenceName returns.  A table
-- keyed the other way fires nothing and reports nothing.
local volume = CreateClientConVar("df_knife_volume", "0.75", true, false,
    "Delta Force knives: original action audio volume", 0, 1)

local active, state
local tails = {}

local function stopAll(keepTails)
    if state then
        for _, entry in ipairs(state.playing or {}) do
            if not keepTails or entry.cut then
                entry.patch:Stop()
            else
                tails[#tails + 1] = entry
            end
        end
    end
    if not keepTails then
        for _, entry in ipairs(tails) do entry.patch:Stop() end
        tails = {}
    end
    state = nil
end

function SWEP:DFStopAudio()
    if active == self then stopAll(false) end
end

local function choose(w, name)
    local event = w.DFAudioEvents and w.DFAudioEvents[name]
    if not event or not event.choices or #event.choices == 0 then return nil end
    w.DFAudioLast = w.DFAudioLast or {}
    local last = w.DFAudioLast[name]
    local total = 0
    for i, entry in ipairs(event.choices) do
        if #event.choices == 1 or (event.avoid or 0) == 0 or i ~= last then
            total = total + (entry.weight or 1)
        end
    end
    if total <= 0 then return event.choices[1].path end
    local pick = math.Rand(0, total)
    for i, entry in ipairs(event.choices) do
        if #event.choices == 1 or (event.avoid or 0) == 0 or i ~= last then
            pick = pick - (entry.weight or 1)
            if pick <= 0 then
                w.DFAudioLast[name] = i
                return entry.path
            end
        end
    end
    return event.choices[#event.choices].path
end

-- There is no seekable channel any more.  It existed for one feature -- MW's
-- slow-motion inspect hold, which had to pause the long inspect WAV with the
-- animation -- and the user removed that feature (2026-09-23) as more bugs
-- than it was worth.  What remains of it is one flag: an inspect's long sound
-- is CUT when the sequence changes, where a swing's short tail rings out.

hook.Add("Think", "DFKnifePackAudio", function()
    local p = LocalPlayer()
    if not IsValid(p) then stopAll(false); active = nil; return end
    local w = p:GetActiveWeapon()
    if not IsValid(w) or not w.DFAudioTracks or not w.GetDFAnimSerial or not p:Alive() then
        stopAll(false); active = nil; return
    end
    local vm = p:GetViewModel()
    if not IsValid(vm) then stopAll(false); return end
    if active ~= w then stopAll(false); active = w end

    local sequence = vm:GetSequenceName(vm:GetSequence())
    local cycle = vm:GetCycle()
    local serial = w:GetDFAnimSerial()
    if not state or state.sequence ~= sequence or state.serial ~= serial or cycle + 0.2 < state.cycle then
        -- Holster cuts everything; anything else lets the previous sound ring
        -- out rather than chopping it mid-swing.
        stopAll(sequence ~= "holster")
        state = {sequence = sequence, serial = serial, cycle = cycle, fired = {}, playing = {}}
    end

    local t = cycle * vm:SequenceDuration(vm:GetSequence())
    for i, event in ipairs(w.DFAudioTracks[sequence] or {}) do
        if not state.fired[i] and t >= event.time then
            state.fired[i] = true
            -- Do not burst obsolete cues when a correction jumps far into a
            -- sequence, and never start an already-expired one.
            if t - event.time < 0.2 and (not event.stop or t < event.stop) then
                local path = choose(w, event.event)
                if path then
                    local patch = CreateSound(p, path)
                    if patch then
                        patch:SetSoundLevel(0)
                        patch:PlayEx(volume:GetFloat(), 100)
                        -- An inspect's sound runs as long as the clip, so it is
                        -- cut with the clip; a swing's short tail rings out.
                        state.playing[#state.playing + 1] = {patch = patch, stop = event.stop,
                            cut = string.find(sequence, "inspect", 1, true) ~= nil,
                            expires = CurTime() + SoundDuration(path) + 0.1}
                    end
                end
            end
        end
    end

    for i = #state.playing, 1, -1 do
        local entry = state.playing[i]
        if entry.stop and t >= entry.stop then
            entry.patch:Stop()
            table.remove(state.playing, i)
        end
    end
    for i = #tails, 1, -1 do
        if CurTime() >= tails[i].expires then
            tails[i].patch:Stop()
            table.remove(tails, i)
        end
    end
    state.cycle = cycle
end)

hook.Add("ShutDown", "DFKnifePackStopAudio", function() stopAll(false) end)
hook.Add("EntityRemoved", "DFKnifePackRemovedAudio", function(ent)
    if ent == active then stopAll(false); active = nil end
end)
