-- Delta Force knife pack -- first person view.
--
-- CAMERA.  Every clip animates a bone called tag_camera, and that bone IS the
-- weapon's camera motion: the swing that throws the view around, the little
-- settle after a draw.  Reading it back is the same transform MW Base applies,
-- because it is the only thing the data supports -- take the camera bone's
-- matrix, express the viewmodel's own transform in it, and push the view by the
-- difference.  Without this the knife swings and the view stays dead still.
--
-- WHERE THE BONE IS READ, AND WHY NOT IN CalcView.
--
-- The first build read the bone inside CalcView and called vm:SetupBones() to
-- make sure it was there.  That flickered every knife, and the hands with them.
-- CalcView runs BEFORE the engine places the viewmodel for this frame, so
-- SetupBones filled the bone cache from the PREVIOUS frame's transform and
-- marked it built for this frame; at draw time the engine reused it, and the
-- knife plus the bonemerged c_hands were drawn a frame behind the camera.  Move
-- the mouse and the two come apart, every frame.
--
-- So the transform is read in PostDrawViewModel, where the bones belong to the
-- frame that was just drawn and nothing has to be forced, and CalcView only
-- consumes what was cached.  The value is a pure animation quantity -- the
-- viewmodel's origin expressed in the camera bone's frame, which is the same
-- number wherever the viewmodel happens to be in the world -- so using the
-- previous frame's copy costs one frame of lag on a camera shake and nothing
-- else.  It is never forced, never invalidated, and never touched mid-render.
local cvFov = GetConVar("df_knife_vmfov")
local cvCamera = GetConVar("df_knife_camera")

function SWEP:DFReadCameraBone(vm)
    if not IsValid(vm) then return end
    local bone = vm:LookupBone("tag_camera")
    if not bone then return end
    local m = vm:GetBoneMatrix(bone)
    if not m then return end

    local world = Matrix()
    world:SetTranslation(vm:GetPos())
    world:SetAngles(vm:GetAngles())
    local camera = m:GetInverse() * world
    self.DFCameraPos = camera:GetTranslation()
    self.DFCameraAng = camera:GetAngles()
end

function SWEP:PostDrawViewModel(vm, weapon, ply)
    self:DFReadCameraBone(vm)
end

-- There is deliberately NO SWEP:PreDrawViewModel here, and the playback driver
-- does NOT live in a SWEP draw hook.  SWEP:PreDrawViewModel is relayed by the
-- base gamemode's GM:PreDrawViewModel, and hook.Call short-circuits the moment
-- ANY addon's PreDrawViewModel hook returns a value -- the relay then never
-- runs.  This user has 841 workshop addons; the driver lived here for exactly
-- one build, and idle/walk/run went dead in game while the same code had run
-- fine from Think.  The driver now lives on a plain global Think hook at the
-- bottom of sh_anim.lua -- the same kind cl_audio.lua uses, which has
-- demonstrably run in this game every round.  PostDrawViewModel below is only
-- the camera-bone read; if its relay is ever eaten too, the Think driver also
-- refreshes the camera cache one frame late, and CalcView keeps working.

function SWEP:CalcView(ply, pos, ang, fov)
    self.ViewModelFOV = math.Clamp((cvFov and cvFov:GetFloat()) or 64, 40, 120)
    if cvCamera and not cvCamera:GetBool() then return pos, ang, fov end

    local cp, ca = self.DFCameraPos, self.DFCameraAng
    if not cp or not ca then return pos, ang, fov end

    -- Copies.  The engine reuses the vector and angle it hands in, and CalcView
    -- is not guaranteed to run exactly once per frame -- mutating them in place
    -- lets one frame's offset land on top of another's.
    local outPos, outAng = Vector(pos), Angle(ang)
    outAng:RotateAroundAxis(outAng:Forward(), ca.r)
    outAng:RotateAroundAxis(outAng:Up(), -ca.y)
    outAng:RotateAroundAxis(outAng:Right(), ca.p)
    outPos:Add(outAng:Forward() * -cp.x)
    outPos:Add(outAng:Up() * -cp.z)
    outPos:Add(outAng:Right() * cp.y)
    return outPos, outAng, fov
end

-- ------------------------------------------------------- selection icon ---
-- The icons were drawn as 512x192 of content centred in a 512x256 power-of-two
-- PNG, so the visible band is UV 0.125 .. 0.875.  Sampling those rows keeps the
-- aspect and the alpha edges exactly as they were accepted.
local SRC_W, SRC_H = 512, 192

function SWEP:DFIconRect(x, y, width, height)
    if width <= 0 or height <= 0 then return x, y, 0, 0 end
    local pad = math.min(10, width * 0.08, height * 0.1)
    local scale = math.min((width - pad * 2) / SRC_W, (height - pad * 2) / SRC_H)
    local w, h = SRC_W * scale, SRC_H * scale
    return x + (width - w) / 2, y + (height - h) / 2, w, h
end

function SWEP:DrawWeaponSelection(x, y, width, height, alpha)
    if not self.DFSelectIcon then return end
    self.DFSelectMaterial = self.DFSelectMaterial or Material(self.DFSelectIcon, "smooth")
    if self.DFSelectMaterial:IsError() then return end
    local dx, dy, dw, dh = self:DFIconRect(x, y, width, height)
    if dw <= 0 or dh <= 0 then return end
    surface.SetDrawColor(255, 255, 255, math.Clamp(alpha or 255, 0, 255))
    surface.SetMaterial(self.DFSelectMaterial)
    surface.DrawTexturedRectUV(dx, dy, dw, dh, 0, 0.125, 1, 0.875)
    if self.PrintWeaponInfo then
        self:PrintWeaponInfo(x + width + 10, y + 10 + height * 0.95, alpha or 255)
    end
end
