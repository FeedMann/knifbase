-- Delta Force knife pack -- three-stage combo and the hit trace.
--
-- THE COMBO INPUT FIX.
--
-- The game's own combo table gives every knife ComboInputBufferCapacity 1 and
-- ComboInputBufferLifetime 0.5: one press may be remembered, for half a second.
-- The MW Base port implemented that as
--
--     bufferUntil = max(now + Lifetime, readyAt + 0.1)
--
-- and readyAt is always later than now, so bufferUntil was ALWAYS at least
-- readyAt + 0.1.  A buffered press could therefore never expire -- it was
-- guaranteed to come out, however early it had been made.  On the observer's
-- first stage the gate opens 0.616 s in, so a press made at 0.05 s produced a
-- swing 0.57 s later, long after the player had moved on.  That is the "it
-- stores an extra attack" the user reported: one press, one swing, but the
-- swing arrives when the combo already looked finished.
--
-- Two things changed, both toward the game's own numbers:
--   1. the buffer expires exactly Lifetime after the press, full stop;
--   2. a press is only remembered once the current swing has actually LANDED
--      (past AttackCastTime).  Mashing during the wind-up can no longer stack
--      a swing behind the one being watched.
--
-- df_knife_combo picks how strict to be:
--   0  no buffer at all.  A press during the lock is dropped, which is what the
--      standalone reference SWEP does.
--   1  the game's buffer (default): remembered for 0.5 s, only after the hit.
--   2  as 1, and a press made during the recovery TAIL -- after the chain gate
--      has already opened unused -- does not start another swing.  Use this if
--      swings still arrive after the combo looked over.
local ACT_ATTACK = DF_KNIFE_ACT_ATTACK
local ACT_DEPLOY, ACT_HOLSTER = DF_KNIFE_ACT_DEPLOY, DF_KNIFE_ACT_HOLSTER

function SWEP:CanMelee()
    if not self:DFAlive() then return false end
    local a = self:GetDFAction()
    return a ~= ACT_DEPLOY and a ~= ACT_HOLSTER
end

-- How far the swing reaches, in Hammer units.
--
-- Most knives carry range and radius per stage, straight out of the game's
-- combo table.  Polaris does not: its port predates that and kept the numbers
-- on the Melee animation entry instead (Range 70.87 HU = 180 cm, Size 3.94 HU =
-- 10 cm).  Reading that entry keeps Polaris hitting exactly as far as the build
-- the user accepted, rather than silently falling back to a made-up constant.
local CM = 1 / 2.54

function SWEP:DFAttackReach(attack)
    local melee = self:GetAnimation("Melee")
    local range = attack.range or (melee and melee.Range) or (180 * CM)
    local radius = attack.radius or (melee and melee.Size) or (10 * CM)
    return range, radius
end

function SWEP:DFClearAttack()
    self:SetDFCombo(0)
    self:SetDFQueued(0)
    self:SetDFQueueUntil(0)
    self:SetDFStruck(true)
end

function SWEP:DFBeginAttack(index)
    local attacks = self.DFAttacks
    if not attacks or #attacks == 0 then return end
    index = math.Clamp(index, 1, #attacks)
    local a = attacks[index]
    local now = CurTime()

    self:SetDFAction(ACT_ATTACK)
    self:SetDFCombo(index)
    self:SetDFQueued(0)
    self:SetDFQueueUntil(0)
    self:SetDFStruck(false)

    self:DFPlayAnim(a.anim)
    self:SetDFCastAt(now + (a.cast or 0))
    -- The chain gate is the game's own cast + backswing + wait.  recovery is
    -- this port's phase lock and is only used when it is the longer of the two,
    -- so a movement change cannot cut an attack short.
    local lock = math.max((a.cast or 0) + (a.backswing or 0) + (a.wait or 0), a.recovery or 0)
    self:SetDFReadyAt(now + lock)
    -- The action holds the viewmodel until the swing's MOTION ends (measured;
    -- 0.1-0.6 s shorter than the clip), never shorter than the chain gate.
    -- The remaining authored tail is still frames -- holding them hostage was
    -- the "dead frames between actions" feel; cutting only them cannot pop.
    local clipEnd = self:DFClipEnd(a.anim)
    if clipEnd <= 0 then clipEnd = a.length or 1 end
    self:SetDFActionEnd(now + math.max(lock, clipEnd))

    -- Presses are gated by DFRequestAttack, not by the engine's fire timer.
    -- This only stops the engine calling PrimaryAttack twice inside one press.
    self:SetNextPrimaryFire(now + 0.05)
    self:SetNextSecondaryFire(now + 0.05)

    local p = self:GetOwner()
    if IsValid(p) and p:IsPlayer() then p:SetAnimation(PLAYER_ATTACK1) end
end

function SWEP:DFRequestAttack(heavy)
    local attacks = self.DFAttacks
    local n = attacks and #attacks or 0
    if n == 0 or not self:DFAlive() then return end

    local now = CurTime()
    local mode = self:DFComboMode()

    -- A click during the draw is REMEMBERED, not swallowed: it buffers like a
    -- combo press and comes out the instant the draw's action ends (Think
    -- drains the queue).  This is what "I clicked right after the draw and
    -- nothing happened" was -- the engine gate used to eat these clicks
    -- before Lua ever saw them.  Mode 0 (no buffers anywhere) still drops it.
    if self:GetDFAction() == ACT_DEPLOY then
        if mode == 0 then return end
        self:SetDFQueued(heavy and n or 1)
        -- Deliberately NOT the combo buffer's own lifetime: a draw-click means
        -- "swing as soon as the draw ends", so it must survive the rest of the
        -- draw, however early it was made.  (The combo buffer is the opposite
        -- case -- there the press must be allowed to EXPIRE before the gate,
        -- and tying its life to the gate was the stored-extra-swing bug.)
        self:SetDFQueueUntil(self:GetDFActionEnd() + 0.25)
        return
    end
    if not self:CanMelee() then return end

    if self:GetDFAction() == ACT_ATTACK then
        local index = heavy and n or (self:GetDFCombo() % n + 1)
        if now >= self:GetDFReadyAt() then
            -- Mode 2: the gate opened and nothing was waiting, so the combo is
            -- over.  Do not start a fresh swing out of the recovery tail.
            if mode == 2 then return end
            self:DFBeginAttack(index)
        elseif mode > 0 and self:GetDFQueued() == 0 and self:GetDFStruck() then
            self:SetDFQueued(index)
            self:SetDFQueueUntil(now + (self.DFComboBuffer and self.DFComboBuffer.Lifetime or 0.5))
        end
        return
    end

    self:DFBeginAttack(heavy and n or 1)
end

function SWEP:DFThinkAttack(now)
    if not self:GetDFStruck() and now >= self:GetDFCastAt() then
        self:SetDFStruck(true)
        self:DFStrike()
    end

    local queued = self:GetDFQueued()
    if queued > 0 then
        if now > self:GetDFQueueUntil() then
            self:SetDFQueued(0)
        elseif now >= self:GetDFReadyAt() then
            self:DFBeginAttack(queued)
            return
        end
    end

    if now >= self:GetDFActionEnd() then
        self:DFClearAttack()
        self:DFEndAction()
    end
end

-- ------------------------------------------------------------ the trace ---
local RATE_BY_GROUP = {
    [HITGROUP_HEAD] = "head",
    [HITGROUP_CHEST] = "chest",
    [HITGROUP_STOMACH] = "chest",
    [HITGROUP_LEFTARM] = "arm",
    [HITGROUP_RIGHTARM] = "arm",
    [HITGROUP_LEFTLEG] = "leg",
    [HITGROUP_RIGHTLEG] = "leg",
}

function SWEP:DFStrike()
    if not SERVER then return end
    local attack = self.DFAttacks[self:GetDFCombo()]
    if not attack then return end
    local p = self:GetOwner()
    if not IsValid(p) or (p:IsPlayer() and not p:Alive()) then return end

    local range, radius = self:DFAttackReach(attack)
    local forward, start = p:GetAimVector(), p:GetShootPos()
    if p:IsPlayer() then p:LagCompensation(true) end
    local settings = {start = start, endpos = start + forward * range,
                      filter = {p, self}, mask = MASK_SHOT_HULL}
    local tr = util.TraceLine(settings)
    if not tr.Hit then
        settings.mins = Vector(-radius, -radius, -radius)
        settings.maxs = Vector(radius, radius, radius)
        tr = util.TraceHull(settings)
    end
    if p:IsPlayer() then p:LagCompensation(false) end

    self.DFLastStrike = {time = CurTime(), attack = self:GetDFCombo(), hit = tr.Hit,
                         damage = attack.damage, hitgroup = tr.HitGroup, dispatched = false}
    if not tr.Hit or tr.HitSky then return end

    local ent = tr.Entity
    if IsValid(ent) then
        -- Every knife's GameMode01 damage row carries 1.0 on every body part, so
        -- this multiplier is a no-op except under water.  The trace is still
        -- dispatched with HITGROUP_GENERIC on purpose: otherwise GMod's own
        -- ScalePlayerDamage would apply ITS head x2 / limb x0.25 on top, which
        -- the original does not do.
        local rates = self.DFDamageRates or {}
        local mult = rates[RATE_BY_GROUP[tr.HitGroup] or "chest"] or 1.0
        if p:WaterLevel() >= 3 then mult = mult * (rates.underwater or 1) end
        mult = mult * self:DFDamageMultiplier()

        local damage = DamageInfo()
        damage:SetDamage(attack.damage * mult)
        damage:SetDamageType(DMG_SLASH)
        damage:SetAttacker(p)
        damage:SetInflictor(self)
        damage:SetDamagePosition(tr.HitPos)
        damage:SetDamageForce(forward * 4500)

        local damageTrace = tr
        if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
            damageTrace = {}
            for key, value in pairs(tr) do damageTrace[key] = value end
            damageTrace.HitGroup = HITGROUP_GENERIC
        end
        self.DFLastStrike.dispatched = true
        self.DFLastStrike.applied = attack.damage * mult
        ent:DispatchTraceAttack(damage, damageTrace, forward)
    end

    -- Shared impact feedback is Source's own, not mislabeled knife audio.
    local flesh = IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:GetClass() == "prop_ragdoll")
    local effect = EffectData()
    effect:SetOrigin(tr.HitPos)
    effect:SetNormal(tr.HitNormal)
    if flesh then
        util.Effect("BloodImpact", effect, true, true)
        self:EmitSound("physics/flesh/flesh_impact_bullet1.wav", 65, 100, 0.65)
    else
        effect:SetStart(start)
        effect:SetSurfaceProp(tr.SurfaceProps)
        effect:SetDamageType(DMG_SLASH)
        if IsValid(ent) then effect:SetEntity(ent) end
        util.Effect("Impact", effect, true, true)
        self:EmitSound("Weapon_Crowbar.Melee_Hit", 65, 100, 0.5)
    end
end

if SERVER then
    function SWEP:GetCapabilities() return CAP_WEAPON_MELEE_ATTACK1 end
end
