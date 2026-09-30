AddCSLuaFile()
AddCSLuaFile("sh_anim.lua")
AddCSLuaFile("sh_combat.lua")
AddCSLuaFile("cl_view.lua")
AddCSLuaFile("cl_audio.lua")
AddCSLuaFile("sh_diag.lua")

-- Delta Force knife pack -- shared standalone base.
--
-- This base replaces MW Base for the eight ported knives.  Nothing here is
-- copied from MW Base; it is written against the same MODEL data (the compiled
-- sequences and the knives' own data tables), which is what the knives actually
-- need.  The structure follows the standalone Delta Force knife SWEP the user
-- pointed at as the reference for this shape: engine viewmodel, UseHands, a
-- single "what is playing" timestamp, and looping locomotion underneath.
--
-- WHAT A KNIFE FILE SUPPLIES (all data, no behaviour):
--     SWEP.Animations       key -> { Sequences, Fps, Length }
--     SWEP.DFAttacks        three stages: anim / damage / cast / backswing /
--                           wait / recovery / length / range / radius
--     SWEP.DFComboBuffer    { Capacity, Lifetime } from the game's combo table
--     SWEP.DFDamageRates    body-part multipliers (GameMode01: all 1.0)
--     SWEP.DFDrawWeights    two draw clips, weighted
--     SWEP.DFAudioEvents /  the Wwise events and when each clip fires them
--     SWEP.DFAudioTracks
--
-- THE FOUR STATES.  Exactly one "action" owns the viewmodel at a time; when no
-- action owns it, locomotion does.  An action ends at DFActionEnd, which is the
-- length of the clip it started.
local ACT_NONE, ACT_DEPLOY, ACT_HOLSTER, ACT_ATTACK, ACT_INSPECT = 0, 1, 2, 3, 4
DF_KNIFE_ACT_NONE, DF_KNIFE_ACT_DEPLOY = ACT_NONE, ACT_DEPLOY
DF_KNIFE_ACT_HOLSTER, DF_KNIFE_ACT_ATTACK, DF_KNIFE_ACT_INSPECT = ACT_HOLSTER, ACT_ATTACK, ACT_INSPECT

SWEP.Base = "weapon_base"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.Category = "Delta Force - Knife"
SWEP.PrintName = "Delta Force Knife"

SWEP.Slot = 0
SWEP.SlotPos = 5
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = false
SWEP.ViewModelFlip = false
-- MW Base renders these knives at FOV 64; keeping that number means the pack
-- shows the same amount of blade as the builds the user already accepted.
SWEP.ViewModelFOV = 64
SWEP.UseHands = true
SWEP.HoldType = "knife"
-- Each knife sets its own v_*.mdl.  Those meshes carry no arms: the 36
-- ValveBiped bones in them are there so the player's own c_hands bonemerge on,
-- which is what UseHands does.  This default only keeps the base loadable.
SWEP.ViewModel = "models/weapons/c_arms.mdl"
SWEP.WorldModel = ""

SWEP.Primary = {ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none"}
SWEP.Secondary = {ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none"}

-- Data defaults.  A knife that does not override these is not broken, it just
-- gets the values every ported knife shares.
SWEP.Animations = {}
SWEP.DFAttacks = {}
SWEP.DFComboBuffer = {Capacity = 1, Lifetime = 0.5}
SWEP.DFDamageRates = {head = 1.0, chest = 1.0, chestUpper = 1.0,
                      leg = 1.0, legUpper = 1.0, arm = 1.0, armUpper = 1.0,
                      underwater = 0.8}
SWEP.DFArmorDamage = 40.0
SWEP.DFPenetrateLevel = 1
SWEP.DFDrawWeights = {0.5, 0.5}
SWEP.DFInspectWeights = {1.0}
SWEP.DFAudioEvents = {}
SWEP.DFAudioTracks = {}

-- Locomotion thresholds.  Walk vs run is decided against the player's own
-- speeds rather than a constant, because a server that changes run speed would
-- otherwise pin every knife to one clip (that mistake was measured once
-- already: ordinary movement read 125 against a configured 200).
SWEP.DFSprintFraction = 0.9     -- of GetRunSpeed, before a sprint clip is used
SWEP.DFMoveMinSpeed = 10        -- below this the knife is idle

if SERVER then
    util.AddNetworkString("df_knife_anim")
end

-- ---------------------------------------------------------------- convars ---
-- Combo input handling.  The game's own table says capacity 1, lifetime 0.5 s;
-- mode 1 implements exactly that.  See sh_combat.lua for what each mode does
-- and why the default is 1.
if CLIENT then
    CreateClientConVar("df_knife_vmfov", "64", true, false,
        "Delta Force knives: viewmodel FOV (64 is what these knives were built against)", 40, 120)
    CreateClientConVar("df_knife_camera", "1", true, false,
        "Delta Force knives: animated camera motion from the clip (0 disables it)", 0, 1)
end
local cvCombo = CreateConVar("df_knife_combo", "1", {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY},
    "Delta Force knives combo input: 0 drop presses during the lock, 1 native buffer, 2 native buffer but no chaining once the window closed", 0, 2)
local cvDamage = CreateConVar("df_knife_damage_multiplier", "1", {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY},
    "Delta Force knives: global damage multiplier", 0.1, 5)

function SWEP:DFComboMode() return cvCombo:GetInt() end
function SWEP:DFDamageMultiplier() return cvDamage:GetFloat() end

-- Replaced by cl_audio.lua on the client; a stub so the shared lifecycle code
-- can call it on the server without a realm test at every site.
function SWEP:DFStopAudio() end

include("sh_anim.lua")
include("sh_combat.lua")
if CLIENT then
    include("cl_view.lua")
    include("cl_audio.lua")
    include("sh_diag.lua")
end

-- ------------------------------------------------------------ networking ---
function SWEP:SetupDataTables()
    self:NetworkVar("Int", 0, "DFAction")
    self:NetworkVar("Int", 1, "DFCombo")
    self:NetworkVar("Int", 2, "DFQueued")
    self:NetworkVar("Int", 3, "DFDrawIndex")
    self:NetworkVar("Int", 4, "DFDrawSerial")
    self:NetworkVar("Int", 5, "DFAnimSerial")
    -- How many times the SERVER ran Deploy.  df_knife_drawwatch prints it
    -- next to every draw restart it catches: two deploys means the engine
    -- deployed twice; one deploy and a restart means something re-sent.
    self:NetworkVar("Int", 6, "DFDeployCount")
    self:NetworkVar("Float", 0, "DFActionEnd")
    self:NetworkVar("Float", 1, "DFCastAt")
    self:NetworkVar("Float", 2, "DFReadyAt")
    self:NetworkVar("Float", 3, "DFQueueUntil")
    self:NetworkVar("Float", 4, "DFAnimStart")
    -- Telemetry for df_knife_switchtrace, written by the SERVER only: when its
    -- SWEP:Think last ran, and how long the engine's own attack gate had left
    -- before the gate hook cleared it.  Together they show whether a frozen
    -- beat is the engine withholding Think, measured rather than inferred.
    self:NetworkVar("Float", 5, "DFThinkAt")
    self:NetworkVar("Float", 6, "DFEngineGate")
    self:NetworkVar("Bool", 0, "DFStruck")
    self:NetworkVar("Bool", 2, "DFInspectSprint")
    self:NetworkVar("String", 0, "DFAnimName")
end

-- ---------------------------------------------------------------- helpers ---
function SWEP:DFAlive()
    local p = self:GetOwner()
    return IsValid(p) and (not p:IsPlayer() or p:Alive())
end

function SWEP:DFIsSprinting()
    local p = self:GetOwner()
    if not IsValid(p) or not p:IsPlayer() then return false end
    if p:InVehicle() or p:Crouching() or not p:IsOnGround() then return false end
    if not p:KeyDown(IN_SPEED) then return false end
    local run = p.GetRunSpeed and p:GetRunSpeed() or 400
    return p:GetVelocity():Length2D() >= run * self.DFSprintFraction
end

-- The knife is "busy" whenever an action owns the viewmodel.
function SWEP:DFBusy()
    return self:GetDFAction() ~= ACT_NONE
end

function SWEP:DFEndAction()
    self:SetDFAction(ACT_NONE)
    self:SetDFActionEnd(0)
end

-- -------------------------------------------------------------- lifecycle ---
function SWEP:Initialize()
    self:SetHoldType(self.HoldType)
    -- GMod can call Deploy BEFORE Initialize when the weapon is given or
    -- picked up (documented engine quirk).  Resetting unconditionally here
    -- stomped that deploy one tick in -- the trace showed the draw playing
    -- with the action already back at NONE, which is the post-give stuck
    -- beat.  Only reset what no action has claimed.
    if self:GetDFAction() == ACT_NONE then
        self:DFEndAction()
        self:SetDFCombo(0)
        self:SetDFQueued(0)
        self.DFLoopAnim = nil
    end
end

function SWEP:DFChooseDraw()
    if self.DFForceDraw then
        self:SetDFDrawIndex(self.DFForceDraw)
        return
    end
    local serial = self:GetDFDrawSerial() + 1
    self:SetDFDrawSerial(serial)
    local weights = self.DFDrawWeights or {0.5, 0.5}
    -- Shared randomness so both realms pick the same clip; rolling math.random
    -- separately would desync the animation from its audio.
    local roll = util.SharedRandom("DFKnifeDraw", 0, 1, self:EntIndex() * 4096 + serial)
    self:SetDFDrawIndex(roll < (weights[1] or 0.5) and 1 or 2)
end

function SWEP:Deploy()
    if SERVER then self:SetDFDeployCount((self:GetDFDeployCount() + 1) % 1024) end
    self:DFStopAudio()
    self:SetDFCombo(0)
    self:SetDFQueued(0)
    self.DFLoopAnim = nil
    self.DFHolsterAt = nil
    self.DFHolsterTo = nil
    self.DFAllowHolster = false

    self:DFChooseDraw()
    local key = self:GetDFDrawIndex() == 1 and "Equip" or "Draw_Alt"
    if not self:GetAnimation(key) then key = "Equip" end
    local length = self:DFPlayAnim(key)

    -- The action ends when the draw's MOTION ends (measured), but the ENGINE
    -- fire gate stays open: NextPrimaryFire is what decides whether a click
    -- even reaches Lua, and gating it to the lock end SWALLOWED every click
    -- made during the draw's settle -- with Automatic=false the player then
    -- had to release and click again, which read as "after the draw nothing
    -- responds for a while".  Now every click reaches DFRequestAttack, which
    -- buffers a click made during the draw and swings the moment it ends.
    local ready = self:DFClipEnd(key)
    if ready <= 0 then ready = length end
    self:SetDFAction(ACT_DEPLOY)
    self:SetDFActionEnd(CurTime() + ready)
    self:SetNextPrimaryFire(CurTime() + 0.05)
    self:SetNextSecondaryFire(CurTime() + 0.05)
    return true
end

-- Holster plays its clip first and only then hands the slot over, the way the
-- reference SWEP does it.  Returning false keeps the weapon out until the
-- animation has run; the second call (DFAllowHolster) is the one that passes.
-- (This dance was removed once on a wrong deduction and RESTORED at the user's
-- order -- removing it did not touch the off-screen-viewmodel bug, and the
-- holster animation is a feature the user wants kept.)
function SWEP:DFResetHolster()
    self.DFAllowHolster = false
    self.DFHolsterAt = nil
    self.DFHolsterTo = nil
    self:DFStopAudio()
    self.DFLoopAnim = nil
end

function SWEP:Holster(nextWeapon)
    if self.DFAllowHolster then
        self:DFResetHolster()
        return true
    end

    -- The reference SWEP's guard, plus its twin.  A Holster call that arrives
    -- when this knife is no longer the active weapon, or when the viewmodel is
    -- already showing another weapon's model, is a LATE call -- the switch has
    -- happened.  Playing the clip then would resolve "holster" by name on the
    -- next weapon's model (the sunken-weapon bug).  Hand over, send nothing.
    local p = self:GetOwner()
    local vm = IsValid(p) and p.GetViewModel and p:GetViewModel() or nil
    if not self:DFOwnsViewModel(vm)
        or (IsValid(p) and p.GetActiveWeapon and p:GetActiveWeapon() ~= self) then
        self:DFResetHolster()
        return true
    end

    if IsValid(nextWeapon) then self.DFHolsterTo = nextWeapon end
    if self.DFHolsterAt then return false end

    self:DFStopAudio()
    self:SetDFCombo(0)
    self:SetDFQueued(0)

    local length = self:DFPlayAnim("Holster")
    if length <= 0 then
        self.DFAllowHolster = false
        return true
    end
    self:SetDFAction(ACT_HOLSTER)
    self:SetDFActionEnd(CurTime() + length)
    self.DFHolsterAt = CurTime() + length
    return false
end

function SWEP:OnRemove()
    self:DFStopAudio()
end

function SWEP:OnDrop()
    self:DFStopAudio()
end

-- ------------------------------------------------------------------ input ---
function SWEP:PrimaryAttack()
    local p = self:GetOwner()
    if IsValid(p) and p:IsPlayer() and not p:KeyPressed(IN_ATTACK) then return end
    self:DFRequestAttack(false)
end

function SWEP:SecondaryAttack()
    local p = self:GetOwner()
    if IsValid(p) and p:IsPlayer() and not p:KeyPressed(IN_ATTACK2) then return end
    -- Deliberate GMod mapping: right click replays the authored third stage.
    -- No heavy clip is invented for it.
    self:DFRequestAttack(true)
end

function SWEP:CanInspect()
    if not self:DFAlive() then return false end
    local a = self:GetDFAction()
    -- R may cut the draw's settle: once the draw's last visible act is done
    -- (measured DFDrawReady), the remaining tail is interruptible.
    if a == ACT_DEPLOY then
        return CurTime() >= self:GetDFAnimStart() + self:DFDrawReadyTime()
    end
    return a == ACT_NONE or a == ACT_INSPECT
end

function SWEP:Reload()
    local p = self:GetOwner()
    if IsValid(p) and p:IsPlayer() and not p:KeyPressed(IN_RELOAD) then return end
    self:DFInspect()
end

-- The inspect itself, callable from Reload or from the gate hook's key path.
function SWEP:DFInspect()
    -- MW's slow-motion hold on a second press is GONE -- removed at the user's
    -- request (2026-09-23) after it cost more bugs than it was worth.  Do not
    -- bring it back.  A second press during an inspect now does nothing, which
    -- also means it cannot restart the clip.
    if self:GetDFAction() == ACT_INSPECT then return end
    if not self:CanInspect() then return end

    local key = "Inspect"
    local alt = self:GetAnimation("Inspect_Alt")
    if alt and #(self.DFInspectWeights or {1}) > 1 then
        local serial = self:GetDFAnimSerial()
        if util.SharedRandom("DFKnifeInspect", 0, 1, self:EntIndex() * 4096 + serial)
            >= (self.DFInspectWeights[1] or 1) then
            key = "Inspect_Alt"
        end
    end

    local length = self:DFPlayAnim(key)
    if length <= 0 then return end
    self:SetDFAction(ACT_INSPECT)
    self:SetDFActionEnd(CurTime() + length)
    -- NEW: an inspect begun while sprinting keeps running while you sprint; one
    -- begun standing or walking is still cancelled the moment you start to
    -- sprint.  Recording which it was is the whole mechanism.
    self:SetDFInspectSprint(self:DFIsSprinting())
end

-- ------------------------------------------------------------------ think ---
function SWEP:Think()
    -- Heartbeat for the gate hook below and for the tracer.  Server-side only:
    -- in singleplayer this hook also runs clientside, and a client write would
    -- make the tracer report the client's Think instead of the server's.
    if SERVER then
        self.DFThinkAt = CurTime()
        self:SetDFThinkAt(self.DFThinkAt)
    end
    self:DFStep()
end

-- One step of the state machine.  Called by SWEP:Think normally, and by the
-- gate hook at the bottom of this file whenever the engine withholds Think.
-- Every branch is idempotent within a tick, so a double step is harmless.
function SWEP:DFStep()
    if not self:DFAlive() then
        if self:GetDFAction() == ACT_ATTACK then self:DFClearAttack() end
        self:DFEndAction()
        return
    end

    local now = CurTime()
    local action = self:GetDFAction()

    if self.DFHolsterAt and now >= self.DFHolsterAt then
        local target = self.DFHolsterTo
        self.DFHolsterAt = nil
        self.DFHolsterTo = nil
        self.DFAllowHolster = true
        self.DFAllowHolsterAt = now
        if SERVER and IsValid(target) then
            local p = self:GetOwner()
            if IsValid(p) and p:IsPlayer() then p:SelectWeapon(target:GetClass()) end
        end
        return
    end

    -- A switch is in flight (clip playing, or handover armed): the viewmodel
    -- belongs to the handover.  Nothing here may send a sequence in that
    -- window -- the trace of the sunken-weapon bug shows a stale sequence
    -- landing on the NEXT weapon's model at the swap instant, and every send
    -- of ours in flight widens that race.  If the engine never comes to
    -- collect the handover (switch aborted), disarm after half a second.
    if self.DFHolsterAt then return end
    if self.DFAllowHolster then
        if now > (self.DFAllowHolsterAt or now) + 0.5 then
            self.DFAllowHolster = false
        end
        return
    end

    if action == ACT_ATTACK then
        self:DFThinkAttack(now)
    elseif action == ACT_INSPECT then
        if now >= self:GetDFActionEnd() then
            self:DFEndAction()
        elseif not self:GetDFInspectSprint() and self:DFIsSprinting() then
            self:DFStopAudio()
            self:DFEndAction()
        end
    elseif action ~= ACT_NONE then
        -- A deploy whose send raced the model swap (give / fast switching) is
        -- retried until OUR OWN send reports success once.  DFSentOk is a
        -- local bool recorded at send time -- not an engine read-back.
        -- Server only: DFSentOk is realm-local, and a client-side retry is
        -- exactly what replayed the draw (see DFSendSequence).
        if SERVER and action == ACT_DEPLOY and not self.DFSentOk then
            local a = self:GetAnimation(self:GetDFAnimName())
            if a then
                self.DFSentOk = self:DFSendSequence(a)
                if self.DFSentOk then
                    -- The draw starts NOW, not when Deploy ran: slide the lock
                    -- by the delay so a late start is not cut off at the end.
                    local late = now - self:GetDFAnimStart()
                    self:SetDFAnimStart(now)
                    self:SetDFActionEnd(self:GetDFActionEnd() + late)
                end
            end
        end
        if now >= self:GetDFActionEnd() then self:DFEndAction() end
    end

    -- Drain a click that was buffered during the draw: the moment no action
    -- owns the viewmodel, the remembered press swings.
    if self:GetDFAction() == ACT_NONE then
        local queued = self:GetDFQueued()
        if queued > 0 then
            if now <= self:GetDFQueueUntil() and self:DFAlive() then
                self:DFBeginAttack(queued)
            else
                self:SetDFQueued(0)
            end
        end
    end

    -- Locomotion is dispatched HERE, in shared Think, the way the tactical-axe
    -- reference does it: on the server this is the send that actually sticks
    -- (the engine viewmodel's sequence is server-authoritative), and the
    -- engine networks it to the client like every draw and swing already is.
    self:DFLocomotionThink()
end

-- ------------------------------------------------------ the engine's gate ---
--
-- Two of the user's traces show SWEP:Think NOT RUNNING for ~1.6 s after the
-- observer is deployed: once with the action already at NONE (so Think would
-- have sent idle within a tick, yet the draw ran out and froze on its last
-- frame), once with the action held 0.8 s past its own lock.  Everything the
-- user saw in that beat -- frozen hands, knife and camera, attack and inspect
-- ignored -- is what happens when the engine skips the weapon's whole
-- ItemPostFrame: that one call is where SWEP:Think, PrimaryAttack and Reload
-- all come from, and Source skips it while the PLAYER's m_flNextAttack lies
-- in the future (the SDK's deploy/holster code sets it from an animation
-- duration the engine picks itself -- our models carry no ACT_VM_* activities
-- for it to pick from; the reference axe's model does).
--
-- This knife keeps every timing it needs in its own state machine, so the
-- player-level gate only ever hurts it.  While one of ours is the active
-- weapon, the server hook below clears that gate each tick.  If Think STILL
-- misses a tick for any other reason, the hook steps the state machine
-- itself, and routes attack / inspect presses the engine did not deliver.
-- The gate value is published for the tracer before it is cleared.
if SERVER then
    local function stale(w)
        return CurTime() - (w.DFThinkAt or -1) > engine.TickInterval() * 1.5
    end

    hook.Add("PlayerPostThink", "DFKnifeGate", function(ply)
        local w = ply:GetActiveWeapon()
        if not IsValid(w) or not w.DFStep then return end
        local now = CurTime()
        local gate = ply:GetInternalVariable("m_flNextAttack")
        if isnumber(gate) then
            w:SetDFEngineGate(math.max(0, gate - now))
            if gate > now then ply:SetSaveValue("m_flNextAttack", now) end
        end
        if stale(w) then w:DFStep() end
    end)

    hook.Add("KeyPress", "DFKnifeGateInput", function(ply, key)
        local w = ply:GetActiveWeapon()
        if not IsValid(w) or not w.DFStep or not stale(w) then return end
        if key == IN_ATTACK then
            w:DFRequestAttack(false)
        elseif key == IN_ATTACK2 then
            w:DFRequestAttack(true)
        elseif key == IN_RELOAD then
            w:DFInspect()
        end
    end)
end
