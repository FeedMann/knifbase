-- Delta Force knife pack -- animation playback and locomotion.
--
-- THE SMOOTHNESS FIX, applied here to every knife at once.
--
-- Delta Force authors Run_In / Jog_Out / Sprint_In / Sprint_Out and the
-- Super_Sprint pair as ADDITIVE clips that ride on top of a locomotion base
-- that keeps running underneath them.  Source can only play one of them on its
-- own, and played on its own each is calmer than the loop it is leaving -- so
-- it reads as the hands stopping.  Measured on the chainsaw, whose transitions
-- are the longest of the eight: the walk loop moves the weapon bone at 6.02
-- units/s, the run loop at 10.86, and WalkToRun at 3.61.  Sprint_In is worse:
-- its last 40% is authored flat (0.04 against 1.21 at the head), so it ends on
-- a dead stop before the sprint loop starts.
--
-- So DFLocomotionAnim NEVER returns a transition clip.  A locomotion state
-- enters its loop on the frame it is wanted and the model's own sequence fades
-- do the blending.  That is what made the chainsaw smooth and what the
-- reference port the user rates as the smooth one does -- it ships idle, walk
-- and sprint and no transition clips at all.  The clips stay compiled in every
-- model; they are simply never selected.
local ACT_NONE = DF_KNIFE_ACT_NONE

local function viewmodel(self)
    local p = self:GetOwner()
    if not IsValid(p) or not p.GetViewModel then return nil end
    local vm = p:GetViewModel()
    if not IsValid(vm) then return nil end
    return vm
end
SWEP.DFViewModel = viewmodel

function SWEP:GetAnimation(key)
    return self.Animations and self.Animations[key] or nil
end

-- Length is the clip's on-screen duration and Fps is a PLAYBACK MULTIPLIER
-- (Fps/30), not a sampling rate -- that is how the knives' tables were
-- generated, and reading Fps as a frame rate would scale every lock wrongly.
function SWEP:GetAnimLength(key)
    local a = self:GetAnimation(key)
    if not a then return 0 end
    local rate = (a.Fps or 30) / 30
    if rate <= 0 then rate = 1 end
    return (a.Length or 0) / rate
end

-- Which compiled sequence this entry resolves to.  Every knife currently ships
-- exactly one sequence per entry (grep-verified); this hash exists so a future
-- multi-sequence entry still picks DETERMINISTICALLY -- same answer on every
-- call, every frame, both realms.  It must never involve util.SharedRandom:
-- that reseeds per usercmd, so two calls about the same animation can disagree.
function SWEP:DFPickSequence(a)
    if not a or not a.Sequences then return nil end
    local names = a.Sequences
    local n = #names
    if n <= 1 then return names[1] end
    return names[1 + (self:EntIndex() * 131 + self:GetDFAnimSerial() * 31) % n]
end

-- Send the entry's sequence to the viewmodel.  False means NOTHING was sent
-- (no viewmodel yet, or its model does not know this sequence -- the deploy
-- race) and the caller may retry.  There is deliberately NO read-back check:
-- the previous build verified the send by reading the sequence name back, and
-- in the live engine that read is not stable (prediction reruns hand back
-- rolled-back state), so the verify failed while the send had already gone
-- through -- and the caller's per-frame retry restarted the clip every frame.
-- That was the endlessly replaying draw animation.
-- Is the viewmodel showing OUR model right now?  The reference SWEP (the
-- tactical axe) guards its holster with exactly this comparison, and the
-- first port left it out.  The user's trace proved why it matters: a late
-- Holster call looked up "holster" BY NAME after the engine had already
-- swapped the viewmodel to the physgun -- whose model has its own sequence
-- called "holster" -- and played the physgun's put-away animation at our
-- rate 1.0.  It ends with the gun below the screen and nothing corrects it
-- until the next server-side sequence (an attack).  Names are only unique
-- within one model, so no send may happen against anyone else's model.
local function normPath(s)
    return string.lower(string.gsub(s or "", "\\", "/"))
end

function SWEP:DFOwnsViewModel(vm)
    if not IsValid(vm) or not self.ViewModel then return false end
    return normPath(vm:GetModel()) == normPath(self.ViewModel)
end

function SWEP:DFSendSequence(a)
    -- SERVER ONLY, enforced here rather than trusted to every caller.  The
    -- engine viewmodel's sequence is server-authoritative (NOTES/PITFALLS #AH),
    -- and in singleplayer GMod runs SWEP:Think on the client too.  The rule
    -- "the client never sends" was documented but not enforced, and the deploy
    -- retry broke it: DFSentOk is realm-local, so on the client it was always
    -- empty, and every draw got re-sent from the client -- each send restarts
    -- the clip, so a late one showed as the draw playing twice in a row.
    if CLIENT then return false end
    local vm = viewmodel(self)
    if not vm or not a then return false end
    if not self:DFOwnsViewModel(vm) then return false end   -- another weapon's model
    local pick = self:DFPickSequence(a)
    if not pick then return false end
    local seq = vm:LookupSequence(pick)
    if seq < 0 then return false end
    vm:SendViewModelMatchingSequence(seq)
    local rate = (a.Fps or 30) / 30
    vm:SetPlaybackRate(rate > 0 and rate or 1)
    return true
end

-- Start an ACTION clip (draw / holster / attack / inspect).  Returns the length
-- so the caller can set its own deadline from one number.
function SWEP:DFPlayAnim(key)
    local a = self:GetAnimation(key)
    if not a then return 0 end
    self:SetDFAnimName(key)
    self:SetDFAnimSerial((self:GetDFAnimSerial() + 1) % 4096)
    self:SetDFAnimStart(CurTime())
    self.DFLoopAnim = nil
    -- Whether OUR send landed (false when the viewmodel still carries the
    -- previous weapon's model, as on a give); Think retries a deploy's send
    -- until this is true.  Local state, never an engine read-back.
    self.DFSentOk = self:DFSendSequence(a)
    return self:GetAnimLength(key)
end

-- Where the clip's MOTION ends -- measured offline from the compiled source
-- clips (each knife's timing_data.lua; see measure_action_tails.py).  Delta
-- Force authors every draw and swing with a still settle tail, and hides it in
-- the original engine by blending back to locomotion at the combat table's own
-- recovery time.  Source cannot blend viewmodel sequences, so the pack ends
-- the ACTION where the motion ends instead: only frames that are already
-- still are cut, so nothing can pop, and control plus locomotion return the
-- 0.1-0.6 s earlier that the user could feel being held.  Unmeasured clips
-- fall back to their full length.
function SWEP:DFClipEnd(key)
    local full = self:GetAnimLength(key)
    local ends = self.DFMotionEnd
    if not ends then return full end
    local a = self:GetAnimation(key)
    local seq = a and a.Sequences and a.Sequences[1]
    local m = seq and ends[seq]
    if m and m > 0 and m < full then return m end
    return full
end

-- When the draw's LAST VISIBLE ACT is done (measured 98%-of-motion point):
-- from here the settle is interruptible.  Falls back to the motion end.
function SWEP:DFDrawReadyTime(key)
    key = key or self:GetDFAnimName()
    local a = self:GetAnimation(key)
    local seq = a and a.Sequences and a.Sequences[1]
    local t = self.DFDrawReady and seq and self.DFDrawReady[seq]
    if t and t > 0 then return t end
    return self:DFClipEnd(key)
end

-- Which locomotion loop the knife should be in RIGHT NOW.  Only loops are ever
-- named here; see the note at the top of the file.
function SWEP:DFLocomotionAnim()
    local p = self:GetOwner()
    if not IsValid(p) or not p:IsPlayer() then return "Idle" end
    if not p:IsOnGround() then return "Idle" end

    local speed = p:GetVelocity():Length2D()
    if speed < self.DFMoveMinSpeed then return "Idle" end

    if self:DFIsSprinting() and self:GetAnimation("Sprint_Loop") then
        return "Sprint_Loop"
    end
    -- The "Move" blend sequence (chainsaw, observer) is RETIRED, deliberately.
    -- Field record: the six knives on the plain Walk/Run loops below moved
    -- smoothly in every build, while the two Move-blend knives stuttered in
    -- four-way movement and sat still after a draw THROUGH THREE FIXES, and
    -- the working reference SWEP uses plain loops and nothing else.  Both
    -- knives ship compiled, LOOPING walk_loop / run_loop / sprint_loop
    -- (measured in their mdl), so they take the proven path like everyone
    -- else.  Do not resurrect Move without an in-game proof of its mechanism.

    local slow = p.GetSlowWalkSpeed and p:GetSlowWalkSpeed() or 0
    if slow <= 0 then
        local walk = p.GetWalkSpeed and p:GetWalkSpeed() or 200
        slow = walk * 0.5
    end
    if p:Crouching() or speed <= slow + 15 then return "Walk_Loop" end
    return "Run_Loop"
end

-- Locomotion dispatch.  Runs from SWEP:Think -- ON THE SERVER (and in the
-- predicted client pass in multiplayer), exactly the way the working reference
-- SWEP does it (the tactical axe's Think + ActiveLoopSequence marker).  The
-- engine viewmodel's sequence is SERVER-authoritative: a send made only on the
-- client does not stick in singleplayer, which is why three builds' worth of
-- client-side locomotion drivers all produced dead idle/walk/run while the
-- draw -- sent from Deploy, which runs on the server -- always played.  The
-- loops themselves are compiled LOOPING (measured in the mdl), so one send per
-- state change is all the engine needs.
-- Does the compiled model loop this entry by itself?  Read from the model's
-- own sequence DATA (static, like the sequence list -- not the engine's
-- runtime state, which is never read back here).  Measured: Polaris's
-- walk_loop is compiled WITHOUT the looping flag, so a single send plays it
-- once and then freezes on its last frame -- invisible in normal movement
-- (that is run_loop) and only reached when crouch- or slow-walking.  MW Base
-- never showed it because it re-dispatched every finished clip.
function SWEP:DFLoopsNatively(a)
    local vm = viewmodel(self)
    if not vm then return true end
    local seq = vm:LookupSequence(self:DFPickSequence(a) or "")
    if seq < 0 then return true end
    local info = vm:GetSequenceInfo(seq)
    return not info or ((info.flags or 0) % 2) == 1       -- STUDIO_LOOPING
end

function SWEP:DFLocomotionThink()
    if self:GetDFAction() ~= DF_KNIFE_ACT_NONE then return end
    local want = self:DFLocomotionAnim()
    local now = CurTime()
    if want == self.DFLoopAnim then
        -- Same state: nothing to do -- unless this loop is one the model does
        -- not loop itself and OUR clock says it has run out; then send it
        -- again from the top, which is exactly how MW Base kept it alive.
        if not self.DFLoopUntil or now < self.DFLoopUntil then return end
    end
    local a = self:GetAnimation(want)
    if not a then return end
    if self:DFSendSequence(a) then
        self.DFLoopAnim = want
        self.DFLoopUntil = nil
        if not self:DFLoopsNatively(a) then
            self.DFLoopUntil = now + self:GetAnimLength(want)
        end
    end
end

-- There is no pose-parameter code here any more.  The Move blend it served is
-- retired (see DFLocomotionAnim above); the move_speed parameter sits wherever
-- the engine leaves it, and no sequence the pack plays reads it.

if not CLIENT then return end

-- --------------------------------------------- the client cosmetic driver ---
--
-- The client NEVER SENDS A SEQUENCE.  The engine viewmodel's sequence belongs
-- to the server (locomotion is dispatched in Think, actions in their own
-- shared paths), and three builds proved that a client-only send does not
-- stick.  All that remains client-side is the camera-bone cache and this
-- heartbeat for df_knife_diag.
function SWEP:DFClientAnimation(vm)
    if not IsValid(vm) then return end
    self.DFDriverAt = RealTime()        -- df_knife_diag reads this
end

-- A plain global Think hook -- the one kind of per-frame callback that has
-- demonstrably run in this game in every build (cl_audio.lua lives on an
-- identical one).  SWEP draw-hook relays die when any addon's same-named hook
-- returns a value, with 841 addons installed.
hook.Add("Think", "DFKnifePackAnim", function()
    local p = LocalPlayer()
    if not IsValid(p) then return end
    local w = p:GetActiveWeapon()
    if not IsValid(w) or not w.DFClientAnimation then return end
    local vm = p:GetViewModel()
    if not IsValid(vm) then return end
    w:DFClientAnimation(vm)
    -- Refresh the camera cache too: one frame older than the PostDraw read
    -- that normally wins, but it keeps CalcView alive even if some addon's
    -- returned value eats the PostDrawViewModel relay.
    w:DFReadCameraBone(vm)
end)
