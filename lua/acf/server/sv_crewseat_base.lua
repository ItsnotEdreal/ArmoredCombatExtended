-- Server-side crewseat functionality and G-force system
-- Notes:
--  - G-force is computed per-seat from seat position delta (works even when parented).
--  - Resting should read ~1G (gravity).
--  - No timer.Create() here to avoid duplicate timers during lua refresh.

include("acf/shared/sh_crewseat_base.lua")

ACE = ACE or {}

-- Rare crew names (easter eggs)
local rareNames = {
	"Mr.Marty", "RDC", "Cheezus", "KemGus", "Golem Man", "Arend", "Mac",
	"Firstgamerable", "kerbal cadet", "Psycho Dog", "Ferv", "Rice",
	"spEAM", "Orange_Fox", "Dedem", "Garry"
}

local randomPrefixes = {
	"John", "Bob", "Sam", "Joe", "Ben", "Alex", "Chris", "David", "Eric", "Frank",
	"Antonio", "Ivan", "Alexander", "Victor", "Elon", "Vladimir", "Donald"
}
local randomSuffixes = {
	"Smith", "Johnson", "Dover", "Wang", "Kim", "Lee", "Brown", "Davis", "Evans",
	"Garcia", "", "Russel", "King", "Musk", "Popov"
}

function ACE_GenerateCrewName()
	local randomNum = math.random(1, 100)

	if randomNum <= 2 then
		return rareNames[math.random(1, #rareNames)]
	end

	local prefix = randomPrefixes[math.random(1, #randomPrefixes)]
	local suffix = randomSuffixes[math.random(1, #randomSuffixes)]
	return prefix .. " " .. suffix
end

-- =========================================================
-- G-FORCE CALCULATION (PER ENTITY)
-- =========================================================

local vec_up = Vector(0, 0, 1)
local INCHES_PER_S2_PER_G = 386.22

local function EnsureGForceState(ent)
	local st = ent.ACE_GForceState
	if st then return st end

	st = {
		LastTime = CurTime(),
		LastPos = ent:GetPos(),
		LastVel = Vector(0, 0, 0),

		-- Smoothed felt-g in local space
		GVec = Vector(0, 0, 1),
		GMag = 1,
	}

	ent.ACE_GForceState = st
	ent.CurrentGForce = 1
	ent.GForceVector = st.GVec

	return st
end

-- Returns:
--  gMag: number (includes gravity, so resting ~= 1)
--  gVec: Vector (local-space felt acceleration in Gs; resting ~= (0,0,1))
function ACE_CalcEntityGForce(ent)
	if not IsValid(ent) then
		return 1, Vector(0, 0, 1)
	end

	local st = EnsureGForceState(ent)

	local now = CurTime()
	local dt = now - st.LastTime

	-- Avoid divide-by-zero and massive spikes after lag/loading
	if dt <= 0 then
		return st.GMag, st.GVec
	end

	if dt > 0.5 then
		-- If we skipped too long, reset state
		st.LastTime = now
		st.LastPos = ent:GetPos()
		st.LastVel = Vector(0, 0, 0)
		st.GVec = Vector(0, 0, 1)
		st.GMag = 1
		ent.CurrentGForce = 1
		ent.GForceVector = st.GVec
		return 1, st.GVec
	end

	local pos = ent:GetPos()
	local vel = (pos - st.LastPos) / dt
	local accel_world = (vel - st.LastVel) / dt

	-- Convert world accel to local accel
	-- (WorldToLocal on a position, so use pos+accel trick)
	local accel_local = ent:WorldToLocal(pos + accel_world) - ent:WorldToLocal(pos)

	-- Add gravity so resting reads 1G upward (felt acceleration)
	accel_local.z = accel_local.z + INCHES_PER_S2_PER_G

	local gVec = accel_local / INCHES_PER_S2_PER_G
	local gMag = gVec:Length()

	-- Smooth factor based on dt (exponential smoothing)
	-- Higher multiplier = snappier response
	local alpha = 1 - math.exp(-dt * 10)

	st.GVec = st.GVec + (gVec - st.GVec) * alpha
	st.GMag = st.GMag + (gMag - st.GMag) * alpha

	-- Snap to exactly 1G when almost stationary and near 1G
	if math.abs(st.GMag - 1) < 0.05 and vel:Length() < 5 then
		st.GMag = 1
		st.GVec = Vector(0, 0, 1)
	end

	st.LastTime = now
	st.LastPos = pos
	st.LastVel = vel

	ent.CurrentGForce = st.GMag
	ent.GForceVector = st.GVec

	return st.GMag, st.GVec
end

-- =========================================================
-- CREWSEAT COMMON HELPERS
-- =========================================================

-- Shared initialization for crewseats
function ACE_InitializeCrewseat(ent, modelType)
	local class = ent:GetClass()

	-- Validate model type, fallback to default if invalid
	if not modelType or not ACE.CrewseatModels or not ACE.CrewseatModels[modelType] then
		modelType = (ACE.CrewseatDefaults and ACE.CrewseatDefaults[class]) or "Sitting"
	end

	local model = ACE.CrewseatModels[modelType]

	ent:SetModel(model)
	ent:SetMoveType(MOVETYPE_VPHYSICS)
	ent:PhysicsInit(SOLID_VPHYSICS)
	ent:SetUseType(SIMPLE_USE)
	ent:SetSolid(SOLID_VPHYSICS)

	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetMass(85) -- requested seat weight
	end

	ent.Master = {}
	ent.ACF = ent.ACF or {}
	ent.ACF.Health = ent.ACF.Health or 1
	ent.ACF.MaxHealth = ent.ACF.MaxHealth or 1
	ent.ACF.Armour = ent.ACF.Armour or 1

	ent.Name = ent.Name or ACE_GenerateCrewName()
	ent.Weight = 85
	ent.AnglePenalty = 0
	ent.GForcePenalty = 0

	ent.ModelType = modelType
	ent.Model = model

	ent.Sound = ent.Sound or ("npc/combine_soldier/die" .. tostring(math.random(1, 3)) .. ".wav")
	ent.SoundPitch = ent.SoundPitch or 100

	ent.NextLegalCheck = ACF.CurTime + math.random(ACF.Legal.Min, ACF.Legal.Max)
	ent.Legal = true
	ent.LegalIssues = ""

	ent.SpecialHealth = false
	ent.SpecialDamage = true

	-- Initialize g-force state
	ent.ACE_GForceState = nil
	EnsureGForceState(ent)

	return model
end

-- Shared angle penalty calculation
local startPenalty = 45
local maxPenalty = 90

function ACE_UpdateCrewseatAnglePenalty(ent)
	-- Clamp dot to avoid NaN from acos
	local dot = math.Clamp(ent:GetUp():Dot(vec_up), -1, 1)
	local curSeatAngle = math.deg(math.acos(dot))

	ent.AnglePenalty = math.Clamp(math.Remap(curSeatAngle, startPenalty, maxPenalty, 0, 1), 0, 1)
	return ent.AnglePenalty
end

-- G-force penalty calculation (0..1)
-- Penalties start at 2G and max out at 6G
function ACE_UpdateGForcePenalty(ent)
	local gTotal, gVec = ACE_CalcEntityGForce(ent) -- gVec is local-space felt G vector; rest ~= (0,0,1)
	ent.CurrentGForce = gTotal
	ent.GForceVector = gVec

	-- Excess over gravity (rest -> 0)
	local gExcess = (gVec - Vector(0, 0, 1)):Length()
	ent.CurrentGForceExcess = gExcess

	ent.GForcePenalty = math.Clamp(math.Remap(gExcess, 2, 6, 0, 1), 0, 1)
	return ent.GForcePenalty, gTotal, gExcess
end

-- Crewseat-specific legal check (includes model validation)
function ACE_CrewseatLegalCheck(ent)
	if ACF.CurTime > ent.NextLegalCheck then
		ent.Legal, ent.LegalIssues = ACF_CheckLegal(ent, ent.Model, math.Round(ent.Weight, 2), nil, true, true)

		if ent.Legal then
			local currentModel = ent:GetModel()
			if not (ACE_IsValidCrewseatModel and ACE_IsValidCrewseatModel(currentModel)) then
				ent.Legal = false
				ent.LegalIssues = "Invalid crewseat model"
			end
		end

		ent.NextLegalCheck = ACF.Legal.NextCheck(ent.Legal)
	end

	return ent.Legal
end

-- Shared OnRemove
function ACE_CrewseatOnRemove(ent)
	for Key in pairs(ent.Master or {}) do
		if ent.Master[Key] and ent.Master[Key]:IsValid() then
			ent.Master[Key]:Unlink(ent)
		end
	end
end

-- Shared damage function
function ACE_CrewseatDamage(ent, Entity, Energy, FrArea, Inflictor)
	ent.ACF.Armour = 3
	local HitRes = ACF_PropDamage(Entity, Energy, FrArea, 0, Inflictor)
	return HitRes
end

-- Play death sound
function ACE_CrewseatDeathSound(ent)
	EmitSound(ent.Sound, ent:GetPos(), 50, CHAN_AUTO, 1, 75, 0, ent.SoundPitch)
end

-- Find replacement loader seat
function ACE_FindReplacementLoader(ent, maxDistSqr)
	maxDistSqr = maxDistSqr or 624100 -- 20m squared

	local closestDist = math.huge
	local replaceEnt = nil

	for _, SeatEnt in pairs(ACE.Crewseats or {}) do
		if not IsValid(SeatEnt) then continue end
		if SeatEnt:CPPIGetOwner() ~= ent:CPPIGetOwner() then continue end
		if SeatEnt:GetClass() ~= "ace_crewseat_loader" then continue end

		local sqDist = SeatEnt:GetPos():DistToSqr(ent:GetPos())
		if sqDist < maxDistSqr and sqDist < closestDist then
			closestDist = sqDist
			replaceEnt = SeatEnt
		end
	end

	return replaceEnt, closestDist
end