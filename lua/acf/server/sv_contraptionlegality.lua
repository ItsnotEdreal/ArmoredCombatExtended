ACE = ACE or {}

-- ============================================================
-- Shared tiny utils
-- ============================================================

-- Build a consistent description for ACE convars.
local function ACE_ConVarHelp(desc) return "ACE - " .. desc end
-- Helper: short IsValid wrapper for entities.
local function IsEnt(ent) return IsValid(ent) end

-- ============================================================
-- Shared entity typing (used by both sections)
-- ============================================================

local ArmorClasses = {
	prop_physics = true,
	primitive_shape = true,
	primitive_airfoil = true,
	primitive_rail_slider = true,
	primitive_slider = true,
	primitive_ladder = true
}

local ClassToType = {
	acf_engine = "Engines",
	acf_gearbox = "Engines",
	acf_fueltank = "Ignore",
	acf_ammo = "Ammo",

	acf_gun = "Firepower",
	acf_rack = "Firepower",

	ace_crewseat_gunner = "Crew",
	ace_crewseat_loader = "Crew",
	ace_crewseat_driver = "Crew",

	ace_rwr_dir = "Electronics",
	ace_rwr_sphere = "Electronics",
	acf_missileradar = "Electronics",
	acf_opticalcomputer = "Electronics",
	ace_ecm = "Electronics",
	ace_trackingradar = "Electronics",
	ace_searchradar = "Electronics",
	ace_irst = "Electronics",
	ace_sonar = "Electronics",
	ace_gforce_meter = "Electronics",
	ace_vheat_source = "Electronics",
	ace_wind_sensor = "Electronics"
}

-- Resolve point category for an entity class.
local function ACE_GetPtsType(className)
	if ArmorClasses[className] then return "Armor" end
	return ClassToType[className] or "Ignore"
end

-- ============================================================
-- Forward declarations (keeps file readable)
-- ============================================================

local ACE_CalcContraptionArmor          -- ARMOR section
-- Ensure armor data is up to date and cached.
local function ACE_EnsureArmor(...) end -- ARMOR section

-- Implemented in ARMOR section but referenced earlier
function ACE_HasArmorInit() return false end
-- Dirty ignore check (stub before ARMOR section).
function ACE_ShouldIgnoreDirty() return true end
-- Mark armor dirty and trigger notification.
function ACE_MarkArmorDirty(...) end
-- Notify players when a contraption becomes dirty.
function ACE_NotifyContraptionModified(...) end
-- Emit debug logs for armor dirty events.
function ACE_DebugDirty(...) end

-- ============================================================
-- SECTION 1: NON ARMOR ONLY
-- Ammo cost, point totals, legal checks, contraption bookkeeping
-- ============================================================

-- ------------------------------------------------------------
-- Ammo tuning lives in acf_globals.lua (centralized)
-- ------------------------------------------------------------

local AmmoTypeFactors = ACE.AmmoTypeFactors
local AmmoCostConfig  = ACE.AmmoCostConfig

-- ------------------------------------------------------------
-- Ammo helpers
-- ------------------------------------------------------------

-- Resolve the ammo type multiplier for cost/points.
local function ACE_GetAmmoTypeFactor(ammoType)
	return AmmoTypeFactors and AmmoTypeFactors[ammoType] or 1
end

-- Compute ready rack capacity for a caliber.
local function ACE_GetReadyRackCap(calMm, totalRounds)
	local cfg = AmmoCostConfig or {}
	local readyBase, readyMax = cfg.ReadyRackBase or 0, cfg.ReadyRackMax or 0
	if readyBase <= 0 or readyMax <= 0 then return 0 end

	local readyMin = cfg.ReadyRackMin or 0
	local pivot    = cfg.ReadyRackPivot or 0
	local lowBoost = cfg.ReadyRackLowBoost or 0

	local baseCap = readyBase / math.max(calMm, 1)

	if pivot > 0 and lowBoost > 0 and calMm < pivot then
		local ratio = (pivot - calMm) / pivot
		baseCap = baseCap * (1 + lowBoost * ratio)
	end

	local cap = math.Clamp(baseCap, readyMin, readyMax)
	if totalRounds and totalRounds > 0 then
		cap = math.min(cap, totalRounds)
	end

	return math.floor(cap + 0.5)
end

-- Forward declare ammo RPS helper for use in the collectors.
local ACE_GetEntRps

-- Collect per-gun RPS totals and rack entities for a contraption.
local function ACE_BuildGunRpsAndRacks(ents)
	local gunRpsById, racks = {}, {}

	for _, ent in ipairs(ents) do
		if IsEnt(ent) then
			local cls = ent:GetClass()
			if cls == "acf_gun" then
				local id = ent.Id
				local rps = ACE_GetEntRps(ent)
				if id and rps > 0 then
					gunRpsById[id] = (gunRpsById[id] or 0) + rps
				end
			elseif cls == "acf_rack" then
				racks[#racks + 1] = ent
			end
		end
	end

	return gunRpsById, racks
end

-- Extract HE filler mass from bullet data.
local function ACE_GetAmmoBlastMass(bdata)
	if not bdata then return 0 end
	return tonumber(bdata.BoomFillerMass) or tonumber(bdata.FillerMass) or 0
end

-- Resolve ammo caliber in millimeters.
local function ACE_GetAmmoCaliberMm(bdata)
	if not bdata then return 0 end

	local best = math.max(
		bdata.Caliber or 0,
		bdata.SlugCaliber or 0,
		bdata.SlugCaliber2 or 0,
		bdata.JetCaliber or 0
	)

	if best <= 0 and bdata.Id then
		best = ACF_GetGunValue(bdata.Id, "caliber") or 0
	end

	return best * 10
end

-- Resolve maximum penetration from bullet data.
local function ACE_GetAmmoMaxPen(bdata)
	if not bdata then return 0 end

	local maxPen = tonumber(bdata.MaxPen) or 0
	if bdata.MaxPen2 then
		maxPen = math.max(maxPen, tonumber(bdata.MaxPen2) or 0)
	end
	if maxPen > 0 then return maxPen end

	local rtype = bdata.Type
	local round = rtype and ACF and ACF.RoundTypes and ACF.RoundTypes[rtype]
	if round and round.getDisplayData then
		local ok, display = pcall(round.getDisplayData, bdata)
		if ok and istable(display) then
			maxPen = math.max(maxPen, display.MaxPen or 0, display.MaxPen2 or 0)
		end
	end
	if maxPen > 0 then return maxPen end

	local filler  = bdata.BoomFillerMass or bdata.FillerMass or 0
	local hePower = ACF and ACF.HEPower or 0
	local blastDiv = ACF and ACF.HEBlastPenetration or 0
	if filler <= 0 or hePower <= 0 or blastDiv <= 0 then return 0 end

	return (filler * hePower) / blastDiv
end

-- Compute sustained rounds per second for a gun/rack.
ACE_GetEntRps = function(ent)
	local reload = ent.ReloadTime
	if reload and reload > 0 then return 1 / reload end

	local rof = ent.RateOfFire
	if rof and rof > 0 then return rof / 60 end

	return 0
end

-- Calculate the points value for an ammo crate.
local function ACE_CalcAmmoCratePoints(crate, gunRpsById, racks, readyAlloc)
	if not IsEnt(crate) then return 0 end
	local bdata = crate.BulletData
	if not bdata then return 0 end

	local rounds = crate.Capacity or 0
	if rounds <= 0 then return 0 end

	local maxPen    = ACE_GetAmmoMaxPen(bdata)
	local blastMass = ACE_GetAmmoBlastMass(bdata)
	if maxPen <= 0 and blastMass <= 0 then return 0 end

	local calMm = ACE_GetAmmoCaliberMm(bdata)
	if calMm <= 0 then return 0 end

	local typeFactor = ACE_GetAmmoTypeFactor(bdata.Type)
	if typeFactor <= 0 then return 0 end

	local ammoId = bdata.Id
	if not ammoId then return 0 end

	local rpsTotal = gunRpsById[ammoId] or 0
	if racks and ACF_CanLinkRack then
		for _, rack in ipairs(racks) do
			if IsEnt(rack) and rack.Id and ACF_CanLinkRack(rack.Id, ammoId, bdata, rack) then
				rpsTotal = rpsTotal + ACE_GetEntRps(rack)
			end
		end
	end
	if rpsTotal <= 0 then return 0 end

	local cfg = AmmoCostConfig or {}
	local refPen = cfg.RefPen or 0
	local refCal = cfg.RefCaliber or 0
	local refRps = cfg.RpsRef or 0
	local baseRound = cfg.BaseRoundPts or 0
	if refPen <= 0 or refCal <= 0 or refRps <= 0 or baseRound <= 0 then return 0 end

	local penExp = cfg.PenExp or 1
	local blastExp = cfg.BlastExp or 1
	local blastWeight = cfg.BlastWeight or 0
	local rpsExp = cfg.RpsExp or 1
	local refBlast = cfg.RefBlastMass or 0

	local penFactor = (maxPen / refPen) ^ penExp
	local blastFactor = 0
	if blastMass > 0 and refBlast > 0 then
		blastFactor = (blastMass / refBlast) ^ blastExp
	end

	local threatFactor = penFactor + blastFactor * blastWeight
	if threatFactor <= 0 then return 0 end

	local calFactor = calMm / refCal
	local rpsFactor = (rpsTotal / refRps) ^ rpsExp
	local roundPts = baseRound * threatFactor * calFactor * typeFactor

	local stowFactor = cfg.StowFactor or 1
	local tailFactor = cfg.TailFactor or 0
	local tailStartMul = cfg.TailStartMultiplier or 0

	local readyCap   = ACE_GetReadyRackCap(calMm, rounds)
	local readyCount = rounds
	local stowCount  = 0

	if readyCap > 0 then
		readyCount = readyCap
		stowCount  = math.max(rounds - readyCount, 0)
	end

	if readyAlloc and readyAlloc[crate] then
		readyCount = math.min(readyAlloc[crate], rounds)
		stowCount  = math.max(rounds - readyCount, 0)
	end

	local readyCost = roundPts * readyCount * rpsFactor
	local stowCost  = roundPts * stowCount  * stowFactor * rpsFactor

	if readyCap > 0 and tailFactor > 0 and tailStartMul > 0 then
		local tailStart = readyCap * tailStartMul
		local tail = math.max(rounds - tailStart, 0)
		if tail > 0 then
			stowCost = stowCost - (roundPts * tail * tailFactor * rpsFactor)
			if stowCost < 0 then stowCost = 0 end
		end
	end

	local name = ACF_GetGunValue(ammoId, "name") or tostring(ammoId)
	local detail = {
		Name = name,
		Type = bdata.Type or "",
		Caliber = calMm,
		Capacity = rounds,
		MaxPen = maxPen,
		Rps = rpsTotal,
		ReadyCount = readyCount,
		StowCount = stowCount,
		ReadyCost = readyCost,
		StowCost = stowCost
	}

	return readyCost + stowCost, detail
end

-- ------------------------------------------------------------
-- Legal check throttle (prevents chat spam)
-- ------------------------------------------------------------

-- Run a legality scan for a contraption.
function ACE_DoContraptionLegalCheck(checkEnt)
	checkEnt.CanLegalCheck = checkEnt.CanLegalCheck or false
	if not checkEnt.CanLegalCheck then return end

	checkEnt.CanLegalCheck = false
	timer.Simple(3, function()
		if IsEnt(checkEnt) then checkEnt.CanLegalCheck = true end
	end)

	local con = checkEnt:GetContraption() or {}
	if table.IsEmpty(con) then return end

	ACE_CheckLegalCont(con)
end

-- ------------------------------------------------------------
-- Contraption helpers (non armor)
-- ------------------------------------------------------------

-- Resolve a contraption wrapper for an entity.
local function ACE_GetContraptionFromEntity(ent)
	if not IsEnt(ent) or not ent.GetContraption then return end
	local con = ent:GetContraption()
	if not con or not con.ents or table.IsEmpty(con.ents) then return end
	return con
end

-- Resolve contraption owner for messages.
local function ACE_GetContraptionOwner(con)
	if not con then return nil end
	local base = con.GetACEBaseplate and con:GetACEBaseplate()
	if not IsEnt(base) or not base.CPPIGetOwner then return nil end
	local owner = base:CPPIGetOwner()
	return IsEnt(owner) and owner or nil
end

-- Safely format an owner name.
local function ACE_GetOwnerName(owner)
	return IsEnt(owner) and owner:Nick() or "Unknown"
end

-- ------------------------------------------------------------
-- Player warnings (over points, overweight, and dirty armor)
-- ------------------------------------------------------------

-- Evaluate legality for a contraption.
function ACE_CheckLegalCont(con)
	con.OTWarnings = con.OTWarnings or {}

	if con.ACEArmorDirty then
		ACE_NotifyContraptionModified(con)
	end

	if con.ACEPoints > ACF.PointsLimit and not con.OTWarnings.WarnedOverPoints then
		local name  = ACE_GetOwnerName(ACE_GetContraptionOwner(con))
		local above = con.ACEPoints - ACF.PointsLimit
		chatMessageGlobal(
			"[ACE] " .. name .. " has a vehicle [" .. math.ceil(above) .. "pts] over the limit costing [" ..
				math.ceil(con.ACEPoints) .. "pts / " .. math.ceil(ACF.PointsLimit) .. "pts]",
			Color(255, 234, 0)
		)
		con.OTWarnings.WarnedOverPoints = true
	end

	if con.totalMass > ACF.MaxWeight and not con.OTWarnings.WarnedOverWeight then
		local name  = ACE_GetOwnerName(ACE_GetContraptionOwner(con))
		local above = con.totalMass - ACF.MaxWeight
		chatMessageGlobal(
			"[ACE] " .. name .. " has a vehicle [" .. math.ceil(above) .. "kg] over the limit, weighing [" ..
				math.ceil(con.totalMass) .. "kg / " .. math.ceil(ACF.MaxWeight) .. "kg]",
			Color(255, 234, 0)
		)
		con.OTWarnings.WarnedOverWeight = true
	end
end

-- ------------------------------------------------------------
-- Generic entity points (non armor parts store Ent.ACEPoints)
-- ------------------------------------------------------------

-- Get points for a single entity.
function ACE_GetEntPoints(ent)
	if not IsEnt(ent) then return 0 end

	local class = ent:GetClass()
	if ArmorClasses[class]
		or class == "acf_fueltank"
		or class == "acf_ammo"
		or class == "acf_gun"
		or class == "acf_rack" then
		return 0
	end

	return ent.ACEPoints or 0
end

-- ------------------------------------------------------------
-- Non armor points (ammo + everything else)
-- ------------------------------------------------------------



-- Collect entities belonging to a contraption.
local function ACE_GetContraptionEntities(con, fallbackEnt)
	local ents = {}
	if con and con.ents then
		for ent in pairs(con.ents) do
			if IsEnt(ent) then ents[#ents + 1] = ent end
		end
	end
	if #ents == 0 and IsEnt(fallbackEnt) then ents[1] = fallbackEnt end
	return ents
end

-- Legacy manufacturing cost indicator (original mass/material system).
function ACE_GetEntLegacyCost(ent, massOverride)
	if not IsEnt(ent) then return 0 end

	local points = ent.ACEPoints or 0
	if points ~= 0 then return points end

	local mass = massOverride
	if mass == nil then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then mass = phys:GetMass() end
	end

	mass = tonumber(mass) or 0
	local pointsPerTon = ACF.PointsPerTon or 0
	if mass > 0 and pointsPerTon > 0 then
		local matTable = ACE.LegacyMatCostTables or ACE.MatCostTables or {}
		local mat = (ent.ACF and ent.ACF.Material) or "RHA"

		points = (mass / 1000) * pointsPerTon * (matTable[mat] or 1)
	end

	return points
end

-- Sum legacy manufacturing cost for a contraption.
function ACE_CalcContraptionLegacyCost(con, baseEnt)
	local total = 0
	local ents = ACE_GetContraptionEntities(con, baseEnt)
	for _, ent in ipairs(ents) do
		if IsEnt(ent) then
			total = total + ACE_GetEntLegacyCost(ent)
		end
	end
	return total
end

-- Allocate ready-rack rounds across ammo crates.
local function ACE_BuildAmmoReadyAlloc(ents)
	local cfg = AmmoCostConfig or {}
	if (cfg.ReadyRackBase or 0) <= 0 or (cfg.ReadyRackMax or 0) <= 0 then return nil end

	local groups = {}
	-- Group ammo crates by ammo id to split ready-rack capacity fairly.

	for _, ent in ipairs(ents) do
		if IsEnt(ent) and ent:GetClass() == "acf_ammo" then
			local bdata = ent.BulletData
			if bdata then
				local rounds = ent.Capacity or 0
				if rounds > 0 then
					local ammoId = bdata.Id
					if ammoId then
						local calMm = ACE_GetAmmoCaliberMm(bdata)
						if calMm > 0 then
							local group = groups[ammoId]
							if not group then
								group = { calMm = calMm, total = 0, entries = {} }
								groups[ammoId] = group
							end

							group.total = group.total + rounds
							group.entries[#group.entries + 1] = { ent = ent, rounds = rounds }
						end
					end
				end
			end
		end
	end

	local alloc = {}

	for _, group in pairs(groups) do
		local total = group.total or 0
		if total > 0 then
			local readyCap = ACE_GetReadyRackCap(group.calMm, total)
			if readyCap > 0 then
				local entries = {}
				local remaining = readyCap
				-- Use fractional remainders to distribute the leftover rounds.

				for _, entry in ipairs(group.entries) do
					local raw = readyCap * entry.rounds / total
					local base = math.floor(raw)
					remaining = remaining - base
					entries[#entries + 1] = { ent = entry.ent, rounds = entry.rounds, ready = base, frac = raw - base }
				end

				table.sort(entries, function(a, b)
					if a.frac == b.frac then
						if a.rounds == b.rounds then return tostring(a.ent) < tostring(b.ent) end
						return a.rounds < b.rounds
					end
					return a.frac > b.frac
				end)

				for _, entry in ipairs(entries) do
					if remaining <= 0 then break end
					if entry.ready < entry.rounds then
						entry.ready = entry.ready + 1
						remaining = remaining - 1
					end
				end

				for _, entry in ipairs(entries) do
					alloc[entry.ent] = entry.ready
				end
			end
		end
	end

	return next(alloc) and alloc or nil
end

-- Cached wrapper for per-crate ammo points.
function ACE_GetAmmoCratePointsForContraption(crate, con, fallbackEnt)
	if not IsEnt(crate) then return 0 end

	if con and con.ACEAmmoCache and not con.ACENonArmorDirty then
		local cache = con.ACEAmmoCache
		return ACE_CalcAmmoCratePoints(crate, cache.GunRpsById or {}, cache.Racks or {}, cache.ReadyAlloc)
	end

	local ents = ACE_GetContraptionEntities(con, fallbackEnt or crate)

	local gunRpsById, racks = ACE_BuildGunRpsAndRacks(ents)

	local readyAlloc = ACE_BuildAmmoReadyAlloc(ents)
	local pts, detail = ACE_CalcAmmoCratePoints(crate, gunRpsById, racks, readyAlloc)

	if con then
		con.ACEAmmoCache = { GunRpsById = gunRpsById, Racks = racks, ReadyAlloc = readyAlloc }
	end

	return pts, detail
end

-- Calculate non-armor points and readout details.
function ACE_CalcNonArmorPoints(con, baseEnt)
	if not con then
		return 0, { Engines = 0, Firepower = 0, Ammo = 0, Crew = 0, Electronics = 0 }, { Items = {} }
	end

	local totals = {
		Engines = 0,
		Firepower = 0,
		Ammo = 0,
		AmmoReady = 0,
		AmmoBackup = 0,
		AmmoReadyRounds = 0,
		AmmoBackupRounds = 0,
		Crew = 0,
		Electronics = 0
	}

	local nonArmor = 0
	local ents = ACE_GetContraptionEntities(con, baseEnt)

	local gunRpsById, racks = ACE_BuildGunRpsAndRacks(ents)

	local readyAlloc = ACE_BuildAmmoReadyAlloc(ents)
	local ammoCache = { GunRpsById = gunRpsById, Racks = racks, ReadyAlloc = readyAlloc }

	local minDetailPts = 300
	local detailItems = {}
	local ammoLines = {}

	-- Build a readable label for detail entries.
	local function getEntityLabel(ent)
		local label = ent:GetNWString("WireName")
		if label and label ~= "" then return label end
		if ent.Name and ent.Name ~= "" then return ent.Name end
		return ent:GetClass()
	end

	-- Add a high-cost item to the detail list.
	local function addDetail(category, label, pts, ent)
		detailItems[#detailItems + 1] = {
			category = category,
			label = label,
			pts = pts,
			idx = IsEnt(ent) and ent:EntIndex() or 0
		}
	end

	-- Aggregate ammo counts for the readout.
	local function addAmmoLine(state, caliber, ammoType, count)
		if not count or count <= 0 then return end
		local calKey = caliber and math.floor(caliber + 0.5) or 0
		if calKey <= 0 then return end

		local typeKey = (ammoType ~= "" and ammoType) or "Ammo"
		local key = string.format("%s|%d|%s", state, calKey, typeKey)

		ammoLines[key] = ammoLines[key] or { State = state, Caliber = calKey, Type = typeKey, Count = 0 }
		ammoLines[key].Count = ammoLines[key].Count + count
	end

	for _, ent in ipairs(ents) do
		if IsEnt(ent) then
			local cls = ent:GetClass()

			-- Ammo crates also contribute ready/backup counts for the readout.
			if cls == "acf_ammo" then
				local pts, detail = ACE_CalcAmmoCratePoints(ent, gunRpsById, racks, readyAlloc)
				if pts > 0 then
					nonArmor = nonArmor + pts
					totals.Ammo = totals.Ammo + pts

					if detail then
						totals.AmmoReady       = totals.AmmoReady + (detail.ReadyCost or 0)
						totals.AmmoBackup      = totals.AmmoBackup + (detail.StowCost or 0)
						totals.AmmoReadyRounds = totals.AmmoReadyRounds + (detail.ReadyCount or 0)
						totals.AmmoBackupRounds = totals.AmmoBackupRounds + (detail.StowCount or 0)

						local ammoType = detail.Type ~= "" and detail.Type or "Ammo"
						local readyCount = math.floor((detail.ReadyCount or 0) + 0.5)
						local stowCount  = math.floor((detail.StowCount or 0) + 0.5)

						if readyCount > 0 then
							addDetail("Ammo", string.format("Ready rack %s x%d", ammoType, readyCount), detail.ReadyCost or 0, ent)
						end
						if stowCount > 0 then
							addDetail("Ammo", string.format("Backup ammo %s x%d", ammoType, stowCount), detail.StowCost or 0, ent)
						end

						addAmmoLine("READY",  detail.Caliber, ammoType, readyCount)
						addAmmoLine("BACKUP", detail.Caliber, ammoType, stowCount)
					end
				end
			else
				-- Non-armor entities are tallied by their category.
				local eclass = ACE_GetPtsType(cls)
				if eclass ~= "Ignore" and eclass ~= "Armor" then
					local pts = ACE_GetEntPoints(ent)
					if pts ~= 0 then
						nonArmor = nonArmor + pts
						totals[eclass] = (totals[eclass] or 0) + pts
						addDetail(eclass, getEntityLabel(ent), pts, ent)
					end
				end
			end
		end
	end

	table.sort(detailItems, function(a, b)
		if a.pts == b.pts then return a.idx < b.idx end
		return a.pts > b.pts
	end)

	local trimmed = {}
	for _, entry in ipairs(detailItems) do
		if entry.pts >= minDetailPts then
			trimmed[#trimmed + 1] = {
				Category = entry.category,
				Label = entry.label,
				Points = math.Round(entry.pts, 1)
			}
		end
	end

	local ammoList = {}
	for _, entry in pairs(ammoLines) do
		if entry.Count and entry.Count > 0 then
			ammoList[#ammoList + 1] = {
				State = entry.State,
				Caliber = entry.Caliber,
				Type = entry.Type,
				Count = math.floor(entry.Count + 0.5)
			}
		end
	end

	return nonArmor, totals, { Items = trimmed, AmmoLines = ammoList }, ammoCache
end

-- Recompute cached non-armor totals for a contraption.
local function ACE_RebuildNonArmorPoints(con, baseEnt)
	if not con then return end

	local nonArmor, totals, details, ammoCache = ACE_CalcNonArmorPoints(con, baseEnt)

	con.ACEPointsNonArmor = nonArmor
	con.ACEPointsPerType = con.ACEPointsPerType or {}

	for k, v in pairs(totals) do
		con.ACEPointsPerType[k] = v
	end

	con.ACEPointsDetails = details
	con.ACEAmmoCache = ammoCache
	con.ACENonArmorDirty = false
end

-- ------------------------------------------------------------
-- Contraption init and point bookkeeping hooks
-- ------------------------------------------------------------

do
	-- Initialize per-contraption points state.
	local function ACE_InitPts(con)
		if con.ACEInitDone then return end
		con.ACEInitDone = true

		con.ACEPoints = 0
		con.ACEPointsNonArmor = 0

		con.ACEArmorPoints = 0
		con.ACEArmorDirty = false
		con.ACEArmorCalculated = false
		con.ACEArmorLastCalc = 0

		con.ACENonArmorDirty = true
		con.ACEAmmoCache = nil

		con.ACEPointsPerType = {}
		for _, k in ipairs({
			"Armor",
			"Engines",
			"Firepower",
			"Ammo",
			"AmmoReady",
			"AmmoBackup",
			"AmmoReadyRounds",
			"AmmoBackupRounds",
			"Crew",
			"Electronics"
		}) do
			con.ACEPointsPerType[k] = 0
		end
	end

	hook.Add("cfw.contraption.created", "ACE_InitPoints", ACE_InitPts)
	hook.Add("cfw.family.created", "ACE_InitPoints", ACE_InitPts)

	hook.Add("cfw.contraption.removed", "ACE_ContraptionRemoving", function(con)
		if not con then return end
		con.ACERemoving = true
		if con.OTWarnings then con.OTWarnings.WarnedModified = true end
	end)

	-- Handle entity addition and update point totals.
	function ACE_AddPts(con, ent)
		if not IsEnt(ent) then return end

		local cls = ent:GetClass()
		if cls == "acf_ammo" or cls == "acf_gun" or cls == "acf_rack" then
			con.ACENonArmorDirty = true
			con.ACEAmmoCache = nil
		end

		local eclass = ACE_GetPtsType(cls)
		local newPts = ACE_GetEntPoints(ent)
		local oldPts = ent._AcePts or 0

		if eclass == "Ignore" then
			if ent._ACEPointsConRef and ent._ACEPointsConRef ~= con then
				ACE_RemPts(ent._ACEPointsConRef, ent)
			end

			ent._ACEPointsConRef = con
			ent._ACEPointsConKey = ACE_GetContraptionIndex and ACE_GetContraptionIndex(con) or nil
			ent._AcePts = 0
			return
		end

		if ent._ACEPointsConRef == con then
			if eclass == "Armor" then
				ACE_MarkArmorDirty(con, ent, "addpts-existing")
			else
				local delta = newPts - oldPts
				if delta ~= 0 then
					con.ACEPoints = (con.ACEPoints or 0) + delta
					con.ACEPointsNonArmor = (con.ACEPointsNonArmor or 0) + delta
					con.ACEPointsPerType = con.ACEPointsPerType or {}
					con.ACEPointsPerType[eclass] = (con.ACEPointsPerType[eclass] or 0) + delta
					ACE_NotifyContraptionModified(con)
				end
			end

			ent._AcePts = newPts
			return
		end

		if ent._ACEPointsConRef and ent._ACEPointsConRef ~= con then
			ACE_RemPts(ent._ACEPointsConRef, ent)
		end

		ent._ACEPointsConRef = con
		ent._ACEPointsConKey = ACE_GetContraptionIndex and ACE_GetContraptionIndex(con) or nil
		ent._AcePts = newPts

		if eclass == "Armor" then
			ACE_MarkArmorDirty(con, ent, "addpts-new")
		else
			con.ACEPoints = (con.ACEPoints or 0) + newPts
			con.ACEPointsNonArmor = (con.ACEPointsNonArmor or 0) + newPts
			con.ACEPointsPerType = con.ACEPointsPerType or {}
			con.ACEPointsPerType[eclass] = (con.ACEPointsPerType[eclass] or 0) + newPts
		end
	end

	-- Handle entity removal and update point totals.
	function ACE_RemPts(con, ent)
		if not IsEnt(ent) then return end
		if ent.IsBeingRemoved and ent:IsBeingRemoved() then return end
		if ent._ACEPointsConRef and ent._ACEPointsConRef ~= con then return end

		ent._ACEPointsConKey = nil
		ent._ACEPointsConRef = nil

		local cls = ent:GetClass()
		if cls == "acf_ammo" or cls == "acf_gun" or cls == "acf_rack" then
			con.ACENonArmorDirty = true
			con.ACEAmmoCache = nil
		end

		local eclass = ACE_GetPtsType(cls)
		if eclass == "Ignore" then return end

		if eclass == "Armor" then
			ACE_MarkArmorDirty(con, ent, "rempts")
			return
		end

		local pts = ent._AcePts or 0
		con.ACEPoints = (con.ACEPoints or 0) - pts
		con.ACEPointsNonArmor = (con.ACEPointsNonArmor or 0) - pts
		con.ACEPointsPerType = con.ACEPointsPerType or {}
		con.ACEPointsPerType[eclass] = (con.ACEPointsPerType[eclass] or 0) - pts

		ACE_NotifyContraptionModified(con)
	end

	hook.Add("cfw.contraption.entityAdded", "ACE_AddPoints", ACE_AddPts)
	hook.Add("cfw.family.added", "ACE_AddPoints", ACE_AddPts)

	hook.Add("cfw.contraption.entityRemoved", "ACE_RemPoints", ACE_RemPts)
	hook.Add("cfw.family.subbed", "ACE_RemPoints", ACE_RemPts)
end

-- ------------------------------------------------------------
-- Hook PhysObj:SetMass (delegates armor marking to ARMOR wrapper)
-- ------------------------------------------------------------

do
	local PHYS = FindMetaTable("PhysObj")

	ACE._OldPhysSetMass = ACE._OldPhysSetMass or PHYS.SetMass
	local OldSetMass = ACE._OldPhysSetMass

	-- Override PhysObj:SetMass to mark armor dirty when needed.
	function PHYS:SetMass(mass)
		local ent = self:GetEntity()
		if not IsEnt(ent) then
			return OldSetMass(self, mass)
		end

		local oldPts = ent._AcePts or 0
		ent._AcePts = ACE_GetEntPoints(ent)

		OldSetMass(self, mass)

		local con = ent.GetContraption and ent:GetContraption()
		if not con then return end

		local delta = (ent._AcePts or 0) - oldPts
		local eclass = ACE_GetPtsType(ent:GetClass())

		if eclass == "Ignore" then return end

		if eclass == "Armor" then
			ACE_MarkArmorDirty(con, ent, "setmass")
			return
		end

		con.ACEPoints = (con.ACEPoints or 0) + delta
		con.ACEPointsNonArmor = (con.ACEPointsNonArmor or 0) + delta
		con.ACEPointsPerType = con.ACEPointsPerType or {}
		con.ACEPointsPerType[eclass] = (con.ACEPointsPerType[eclass] or 0) + delta

		ACE_NotifyContraptionModified(con)
	end
end

-- ============================================================
-- SECTION 2: ARMOR ONLY
-- Dirty tracking, dupe caching, scan scheduling, scan math use
-- ============================================================

-- ------------------------------------------------------------
-- Simple ignore rules
-- Limited parent-chain logic
-- ------------------------------------------------------------

-- Check whether an entity is a Wiremod class.
local function ACE_IsWireEntity(ent)
	if not IsEnt(ent) then return false end
	local cls = ent:GetClass()
	if not isstring(cls) then return false end
	return cls:sub(1, 10) == "gmod_wire_"
end

-- Check whether an entity is a missile or rack item.
local function ACE_IsMissileEntity(ent)
	if not IsEnt(ent) then return false end
	local cls = ent:GetClass()
	return cls == "ace_missile" or cls == "acf_missile"
end

-- Ignore dirty events for safe/non-armor entities.
local function ACE_ShouldIgnoreDirtyEnt(ent)
	if not IsEnt(ent) then return true end

	if ACE_IsMissileEntity(ent) then return true end

	-- Walk a few levels up the parent chain to ignore missile attachments only
	local p = ent:GetParent()
	local depth = 0
	while IsEnt(p) and depth < 4 do
		if ACE_IsMissileEntity(p) then return true end

		p = p:GetParent()
		depth = depth + 1
	end

	return false
end

-- ------------------------------------------------------------
-- Armor init and dirty rules
-- ------------------------------------------------------------

-- Check whether armor has been initialized.
function ACE_HasArmorInit(con)
	if not con then return false end
	if con.ACEArmorCalculated then return true end
	return (con.ACEArmorLastCalc or 0) > 0
end

-- Dirty ignore check (stub before ARMOR section).
function ACE_ShouldIgnoreDirty(con)
	if not con then return true end
	if con.ACERemoving then return true end
	if not ACE_HasArmorInit(con) then return true end
	return false
end

-- ------------------------------------------------------------
-- Debug logging 
-- ------------------------------------------------------------

local armorDebugCvar = CreateConVar(
	"ace_armor_debug",
	"0",
	FCVAR_ARCHIVE,
	ACE_ConVarHelp("Enable stored armor dirty logging (no live console spam).")
)

local armorDirtyLogLimit = CreateConVar(
	"ace_armor_dirty_log_limit",
	"120",
	FCVAR_ARCHIVE,
	ACE_ConVarHelp("How many stored dirty entries to keep.")
)

local armorDirtyLog = armorDirtyLog or {}

-- Build a parent chain summary for debug logs.
local function ACE_GetEntChainSummary(ent, maxDepth)
	if not IsEnt(ent) then return "?" end
	local parts = {}
	local cur = ent
	local depth = 0
	local limit = maxDepth or 4
	while IsEnt(cur) and depth <= limit do
		parts[#parts + 1] = string.format("%s(%d)", cur:GetClass(), cur:EntIndex())
		cur = cur:GetParent()
		depth = depth + 1
	end
	return table.concat(parts, " <- " )
end

-- Store a compact dirty-log entry.
local function ACE_PushDirtyLog(entry)
	local limit = math.max(10, armorDirtyLogLimit:GetInt() or 120)
	armorDirtyLog[#armorDirtyLog + 1] = entry
	while #armorDirtyLog > limit do
		table.remove(armorDirtyLog, 1)
	end
end

-- Emit debug logs for armor dirty events.
function ACE_DebugDirty(con, reason, ent, extra, action)
	if not armorDebugCvar:GetBool() then return end
	if not ACE_HasArmorInit(con) then return end

	local conId = (ACE_GetContraptionIndex and ACE_GetContraptionIndex(con)) or tostring(con)
	local entClass = IsEnt(ent) and ent:GetClass() or "?"
	local entIndex = IsEnt(ent) and ent:EntIndex() or 0

	local chain = ACE_GetEntChainSummary(ent, 5)
	local entIsMissile = IsEnt(ent) and ACE_IsMissileEntity(ent) or false
	local parent = IsEnt(ent) and ent:GetParent() or nil
	local parentIsMissile = IsEnt(parent) and ACE_IsMissileEntity(parent) or false
	local parentIsRack = IsEnt(parent) and (parent:GetClass() == "acf_rack" or parent:GetClass() == "acf_gun") or false
	local parentIsWire = IsEnt(parent) and ACE_IsWireEntity(parent) or false

	ACE_PushDirtyLog({
		t = CurTime(),
		reason = tostring(reason),
		action = tostring(action or "?"),
		conId = tostring(conId),
		entClass = tostring(entClass),
		entIndex = entIndex,
		wasDirty = con and con.ACEArmorDirty or false,
		extra = extra,
		chain = chain,
		entMissile = entIsMissile,
		parentMissile = parentIsMissile,
		parentRack = parentIsRack,
		parentWire = parentIsWire
	})
end

concommand.Add("ace_armor_dirty_log_dump", function(_, _, args)
	if not armorDebugCvar:GetBool() then
		print("[ACE] ace_armor_debug is 0")
		return
	end

	local n = tonumber(args[1] or "") or 30
	n = math.Clamp(n, 1, 200)

	print(string.format("[ACE] Dumping last %d stored armor entries", n))

	for i = math.max(1, #armorDirtyLog - n + 1), #armorDirtyLog do
		local e = armorDirtyLog[i]
		print(string.format(
			"[ACE ArmorDirty] %s action=%s id=%s ent=%s idx=%s dirty=%s extra=%s chain=%s missile=%s parentMissile=%s parentRack=%s parentWire=%s",
			tostring(e.reason),
			tostring(e.action),
			tostring(e.conId),
			tostring(e.entClass),
			tostring(e.entIndex),
			tostring(e.wasDirty),
			tostring(e.extra or ""),
			tostring(e.chain or ""),
			tostring(e.entMissile),
			tostring(e.parentMissile),
			tostring(e.parentRack),
			tostring(e.parentWire)
		))
	end
end)

concommand.Add("ace_armor_dirty_log_clear", function()
	armorDirtyLog = {}
	print("[ACE] Cleared stored armor log")
end)

-- ------------------------------------------------------------
-- Player warning when armor was made dirty after init
-- ------------------------------------------------------------

-- Broadcast the dirty notification to players.
function ACE_NotifyContraptionModified(con)
	if not ACE_HasArmorInit(con) then return end
	if con.ACERemoving then return end
	if not con.ACEArmorDirty then return end

	local base = con.GetACEBaseplate and con:GetACEBaseplate()
	if not IsEnt(base) or (base.IsBeingRemoved and base:IsBeingRemoved()) then return end
	if con.ents and next(con.ents) == nil then return end

	con.OTWarnings = con.OTWarnings or {}
	if con.OTWarnings.WarnedModified then return end

	local name = ACE_GetOwnerName(ACE_GetContraptionOwner(con))
	chatMessageGlobal(
		"[ACE] " .. name .. " modified a vehicle after cost initialization. Armor cost marked dirty.",
		Color(255, 200, 0)
	)

	con.OTWarnings.WarnedModified = true
	ACE_DebugDirty(con, "notify-sent", base, nil, "Notify")
end

-- ------------------------------------------------------------
-- Armor dirty wrapper
-- ------------------------------------------------------------

-- Mark armor as dirty and capture context.
function ACE_MarkArmorDirty(con, ent, reason)
	if not con then return end
	if ACE_ShouldIgnoreDirty(con) then return end
	if ACE_ShouldIgnoreDirtyEnt(ent) then return end

	local cls = IsEnt(ent) and ent:GetClass() or ""
	if cls == "primitive_shape" and not ent.ACEArmorDirtySeen then
		ent.ACEArmorDirtySeen = true
		ACE_DebugDirty(con, "skip-first-primitive-shape", ent, nil, "MarkDirty")
		return
	end

	if con.ACEArmorDirty then
		return
	end

	con.ACEArmorDirty = true
	ACE_DebugDirty(con, "mark-dirty:" .. tostring(reason or "unknown"), ent, nil, "MarkDirty")
	ACE_NotifyContraptionModified(con)
end

-- ============================================================
-- Dupe armor cache + AdvDupe trigger
-- ============================================================

ACE.DupeArmorCache = ACE.DupeArmorCache or {}
ACE.DupeArmorCacheVersion = ACE.DupeArmorCacheVersion or 1
ACE.DupeArmorCacheLastClear = ACE.DupeArmorCacheLastClear or CurTime()

local DupeArmorCacheTtl = CreateConVar(
	"ace_dupe_armor_cache_ttl",
	"1800",
	FCVAR_ARCHIVE,
	ACE_ConVarHelp("Seconds between clearing the dupe armor cache (0 disables).")
)

timer.Create("ACE_DupeArmorCacheGC", 60, 0, function()
	local ttl = DupeArmorCacheTtl:GetFloat()
	if ttl <= 0 then return end

	local now = CurTime()
	local last = ACE.DupeArmorCacheLastClear or now
	if now - last < ttl then return end

	ACE.DupeArmorCache = {}
	ACE.DupeArmorCacheLastClear = now
end)

concommand.Add("ace_dupe_armor_cache_clear", function()
	ACE.DupeArmorCache = {}
	ACE.DupeArmorCacheLastClear = CurTime()
end)

-- Validate an armor scan result.
local function ACE_IsValidArmorResult(front, side)
	if not front or not side then return false end
	if front ~= front or side ~= side then return false end
	if front <= 0 or side <= 0 then return false end
	return true
end

-- Create a stable armor cache key.

-- Format a position/angle tuple for dupe signatures.
local function ACE_FormatDupeTransform(pos, ang)
	if pos and pos.x ~= nil and pos.y ~= nil and pos.z ~= nil then
		pos = string.format("%.3f,%.3f,%.3f", pos.x, pos.y, pos.z)
	end

	if ang and ang.p ~= nil and ang.y ~= nil and ang.r ~= nil then
		ang = string.format("%.2f,%.2f,%.2f", ang.p, ang.y, ang.r)
	end

	return tostring(pos or ""), tostring(ang or "")
end

local function ACE_FormatArmorKey(material, ductility, armour, maxArmour, mass)
	return string.format(
		"mat=%s|duct=%.3f|arm=%.2f|max=%.2f|mass=%.2f",
		tostring(material or ""),
		tonumber(ductility) or 0,
		tonumber(armour) or 0,
		tonumber(maxArmour) or 0,
		tonumber(mass) or 0
	)
end

-- Build a signature for dupe cache lookups.
local function ACE_GetDupeSignature(dupe, created)
	if not util or not util.SHA256 then return nil end

	local entData = dupe and (dupe.Entities or dupe.Ents or dupe.EntityList or (dupe.Dupe and dupe.Dupe.Entities))
	if istable(entData) then
		local parts = {}

		for _, data in pairs(entData) do
			if istable(data) then
				local class = data.Class or data.class or "unknown"
				local model = data.Model or data.model or ""

				local mods = data.EntityMods or data.entitymods
				local acfSettings = mods and mods.acfsettings
				local massMod = mods and mods.mass
				local acf = data.ACF or data.acf

				local material  = (acfSettings and (acfSettings.Material or acfSettings.material)) or (acf and (acf.Material or acf.material))
				local ductility = (acfSettings and (acfSettings.Ductility or acfSettings.ductility)) or (acf and (acf.Ductility or acf.ductility))
				local armour    = acf and (acf.Armour or acf.Armor)
				local maxArmour = acf and (acf.MaxArmour or acf.MaxArmor)
				local mass      = massMod and (massMod.Mass or massMod.mass)
				local pos = data.Pos or data.pos
				local ang = data.Angle or data.angle or data.Ang
				local posKey, angKey = ACE_FormatDupeTransform(pos, ang)

				parts[#parts + 1] = table.concat({
					class,
					model,
					ACE_FormatArmorKey(material, ductility, armour, maxArmour, mass),
					posKey,
					angKey
				}, "|")
			end
		end

		table.sort(parts)
		if #parts > 0 then
			return tostring(ACE.DupeArmorCacheVersion) .. ":ents:" .. util.SHA256(table.concat(parts, ";"))
		end
	end

	-- Fallback to the live entity list if the dupe payload has no entity table.
	if istable(created) then
		local parts = {}

		local refEnt
		for _, ent in pairs(created) do
			if IsValid(ent) then
				refEnt = ent
				break
			end
		end

		for _, ent in pairs(created) do
			if IsValid(ent) then
				local class = ent:GetClass() or "unknown"
				local model = ent:GetModel() or ""

				local acf = ent.ACF
				local material  = acf and acf.Material
				local ductility = acf and acf.Ductility
				local armour    = acf and (acf.Armour or acf.Armor)
				local maxArmour = acf and (acf.MaxArmour or acf.MaxArmor)

				local mass = 0
				local phys = ent:GetPhysicsObject()
				if IsValid(phys) then mass = phys:GetMass() end

				local posKey, angKey = "", ""
				if IsValid(refEnt) then
					local relPos = refEnt:WorldToLocal(ent:GetPos())
					local relAng = refEnt:WorldToLocalAngles(ent:GetAngles())
					posKey, angKey = ACE_FormatDupeTransform(relPos, relAng)
				end

				parts[#parts + 1] = table.concat({
					class,
					model,
					ACE_FormatArmorKey(material, ductility, armour, maxArmour, mass),
					posKey,
					angKey
				}, "|")
			end
		end

		table.sort(parts)
		if #parts > 0 then
			return tostring(ACE.DupeArmorCacheVersion) .. ":spawn:" .. util.SHA256(table.concat(parts, ";"))
		end
	end

	return nil
end

-- Normalize AdvDupe2 hook arguments.
local function ACE_ParseAdvDupeArgs(...)
	-- Supports both common patterns:
	-- (ply, dupe, created) or (dupeInfoTable)
	local a, b, c = ...

	-- dupeInfo pattern (what you had)
	if istable(a) and (a.CreatedEntities or (a[1] and a[1].CreatedEntities)) then
		local info = a
		local dupe = info[1] or info.Dupe or info.dupe or info
		local created = info.CreatedEntities or (dupe and dupe.CreatedEntities)
		return dupe, created
	end

	-- (ply, dupe, created)
	if IsEnt(a) and a:IsPlayer() and istable(b) and istable(c) then
		return b, c
	end

	-- fallback (dupe, created)
	if istable(a) and istable(b) then
		return a, b
	end

	return nil, nil
end

hook.Add("AdvDupe_FinishPasting", "ACE_ArmorInitOnDupePaste_Trimmed", function(...)
	local dupe, created = ACE_ParseAdvDupeArgs(...)
	if not istable(created) then return end

	local cacheKey = ACE_GetDupeSignature(dupe, created)
	local cached = (cacheKey and ACE.DupeArmorCache and ACE.DupeArmorCache[cacheKey]) or nil

	-- If cache is junk, ignore it
	if cached then
		local f = cached.Front or cached.front or 0
		local s = cached.Side  or cached.side  or 0
		if not ACE_IsValidArmorResult(f, s) then
			ACE.DupeArmorCache[cacheKey] = nil
			cached = nil
		end
	end

	local cons = {}
	for _, ent in pairs(created) do
		if IsValid(ent) then
			local con = ACE_GetContraptionFromEntity(ent)
			if con then cons[con] = true end
		end
	end

	timer.Simple(0.05, function()
		for con in pairs(cons) do
			if cacheKey then con.ACEArmorCacheKey = cacheKey end
			if cached then con.ACEArmorCachedData = cached end
			ACE_EnsureArmor(con, con.GetACEBaseplate and con:GetACEBaseplate(), true)
		end
	end)
end)

-- ============================================================
-- Armor scan function
-- Builds a contraption basis and samples LOS armor for front/side
-- ============================================================

ACE_CalcContraptionArmor = function(ent)
	if not IsEnt(ent) then return 0, 0 end

	-- Resolve direction vectors and scan LOS armor samples.

	local contraption = ent.GetContraption and ent:GetContraption() or nil
	local contraptionId = contraption and ACE_GetContraptionIndex and ACE_GetContraptionIndex(contraption)
		or (ent.ACF and ent.ACF.ContraptionId)

	local contraptionEnts = {}

	if contraption and contraption.ents then
		for candidate in pairs(contraption.ents) do
			if IsEnt(candidate) then contraptionEnts[#contraptionEnts + 1] = candidate end
		end
	elseif contraptionId then
		for _, candidate in ipairs(ACE.contraptionEnts or {}) do
			if IsEnt(candidate) then
				local acf = candidate.ACF
				if acf and acf.ContraptionId == contraptionId then
					contraptionEnts[#contraptionEnts + 1] = candidate
				end
			end
		end
	end

	if #contraptionEnts == 0 then contraptionEnts[1] = ent end
	if #contraptionEnts > 1 then
		table.sort(contraptionEnts, function(a, b) return a:EntIndex() < b:EntIndex() end)
	end

	-- Prefer the largest gun as a forward-direction anchor.
	local mainGun
	for _, candidate in ipairs(contraptionEnts) do
		if IsEnt(candidate) and candidate:GetClass() == "acf_gun" then
			local m = candidate:GetModel()
			local validModel = m ~= "models/launcher/20mmsl.mdl"
				and m ~= "models/launcher/40mmsl.mdl"
				and m ~= "models/launcher/40mmgl.mdl"
			if validModel and (not mainGun
				or (candidate.Caliber or 0) > (mainGun.Caliber or 0)
				or ((candidate.Caliber or 0) == (mainGun.Caliber or 0) and candidate:EntIndex() < mainGun:EntIndex())) then
				mainGun = candidate
			end
		end
	end

	-- Normalize a vector or return nil.
	local function normalizeOrNil(vec)
		if not vec then return nil end
		local len = vec:Length()
		if len <= 1e-6 then return nil end
		return vec / len
	end

	-- Project a vector onto a plane.
	local function flattenToPlane(vec, up)
		if not vec or not up then return nil end
		return normalizeOrNil(vec - up * vec:Dot(up))
	end

	-- Resolve a world-up vector from gravity.
	local function getWorldUp()
		local gravity = physenv and physenv.GetGravity and physenv.GetGravity() or Vector(0, 0, -1)
		if gravity:LengthSqr() <= 1e-6 then return Vector(0, 0, 1) end
		return (-gravity):GetNormalized()
	end

	-- Detect sphered wheel props.
	local function isMakeSpherical(e)
		local override = e and e.RenderOverride
		return override and tostring(override):find("MakeSpherical") ~= nil
	end

	-- Estimate left/right from Axis constraints attached to makespherical wheels.
	local function getWheelAxisSide(base, up)
		if not IsEnt(base) or not constraint or not constraint.FindConstraints then return nil end
		local cons = constraint.FindConstraints(base, "Axis")
		if not istable(cons) or #cons == 0 then return nil end

		local axisSum = Vector(0, 0, 0)
		local count = 0

		for _, con in ipairs(cons) do
			if con and (con.Ent1 == base or con.Ent2 == base) then
				local other = (con.Ent1 == base) and con.Ent2 or con.Ent1
				if IsEnt(other) and isMakeSpherical(other) then
					local localAxis = (con.Ent1 == base) and con.LNorm1 or con.LNorm2
					if localAxis then
						local axisWorld = base:LocalToWorld(localAxis) - base:GetPos()
						axisWorld = axisWorld - up * axisWorld:Dot(up)
						axisWorld = normalizeOrNil(axisWorld)

						if axisWorld then
							if count > 0 and axisWorld:Dot(axisSum) < 0 then axisWorld = -axisWorld end
							axisSum = axisSum + axisWorld
							count = count + 1
						end
					end
				end
			end
		end

		return (count > 0) and normalizeOrNil(axisSum) or nil
	end

	-- Build a stable basis: up from gravity, front from gun/base, side from wheels when available.
	local upDir = getWorldUp()

	local rawFront = IsEnt(mainGun) and -mainGun:GetForward() or (ent:GetForward() * -1)
	local frontDir = flattenToPlane(rawFront, upDir) or normalizeOrNil(rawFront) or Vector(1, 0, 0)

	-- Wheel axis is preferred for side; fall back to perpendiculars if missing.
	local sideDir = getWheelAxisSide(ent, upDir)
		or normalizeOrNil(upDir:Cross(frontDir))
		or normalizeOrNil(ent:GetRight())
		or Vector(0, 1, 0)

	sideDir = normalizeOrNil(sideDir - frontDir * sideDir:Dot(frontDir)) or sideDir

	local adjustedFront = normalizeOrNil(sideDir:Cross(upDir))
	if adjustedFront and adjustedFront:Dot(frontDir) < 0 then adjustedFront = -adjustedFront end
	frontDir = adjustedFront or frontDir

	local debugDraw = armorDebugCvar:GetBool()

	-- Compute world-space bounds for a prop.
	local function getBoundsWorld(prop)
		local mins, maxs = prop:OBBMins(), prop:OBBMaxs()
		local corners = {
			Vector(mins.x, mins.y, mins.z),
			Vector(mins.x, mins.y, maxs.z),
			Vector(mins.x, maxs.y, mins.z),
			Vector(mins.x, maxs.y, maxs.z),
			Vector(maxs.x, mins.y, mins.z),
			Vector(maxs.x, mins.y, maxs.z),
			Vector(maxs.x, maxs.y, mins.z),
			Vector(maxs.x, maxs.y, maxs.z)
		}
		for i, v in ipairs(corners) do
			corners[i] = prop:LocalToWorld(v * 0.75)
		end
		return corners
	end

	-- Critical components are sampled for forward armor bias.
	local criticals = {}
	for _, cent in ipairs(contraptionEnts) do
		if IsEnt(cent) then
			local cls = cent:GetClass()
			if cls == "acf_ammo" or cls == "acf_fueltank" or cls == "acf_engine"
				or cls == "ace_crewseat_gunner" or cls == "ace_crewseat_loader" or cls == "ace_crewseat_driver" then
				criticals[#criticals + 1] = cent
			end
		end
	end

	local ignoredArmor = {
		acf_gun = true,
		acf_rack = true,
		ace_crewseat_gunner = true,
		ace_crewseat_loader = true,
		ace_crewseat_driver = true
	}

	-- Build an orthonormal basis from a direction.
	local function basisFromDir(dir)
		dir = dir:GetNormalized()
		local upHint = (math.abs(dir.z) < 0.99) and Vector(0, 0, 1) or Vector(1, 0, 0)
		local u = dir:Cross(upHint):GetNormalized()
		local v = dir:Cross(u):GetNormalized()
		return u, v
	end

	-- Calculate projected area and centroid.
	local function projectedData(comp, dir)
		local u, v = basisFromDir(dir)
		local corners = getBoundsWorld(comp)

		local minU, maxU = math.huge, -math.huge
		local minV, maxV = math.huge, -math.huge

		for _, wpos in ipairs(corners) do
			local pu, pv = wpos:Dot(u), wpos:Dot(v)
			if pu < minU then minU = pu end
			if pu > maxU then maxU = pu end
			if pv < minV then minV = pv end
			if pv > maxV then maxV = pv end
		end

		local area = (maxU - minU) * (maxV - minV)
		return area, (maxU - minU) * 0.5, (maxV - minV) * 0.5
	end

	local frontU, frontV = basisFromDir(frontDir)
	local sideU,  sideV  = basisFromDir(sideDir)

	local regionSnap = 2
	local origin = ent:WorldSpaceCenter()

	-- Build a region bucket key.
	local function regionKey(pos, u, v)
		if not pos then return nil end
		local rel = pos - origin
		local ku = math.floor(rel:Dot(u) / regionSnap + 0.5)
		local kv = math.floor(rel:Dot(v) / regionSnap + 0.5)
		return ku .. ":" .. kv
	end

	-- Accumulate armor region statistics.
	local function updateRegion(regions, key, val, weight)
		if not key or val <= 0 then return end
		local cur = regions[key]
		if not cur or val > cur.val then
			regions[key] = { val = val, weight = weight }
		end
	end

	-- Line-of-sight test with filter rules.
	local function losFiltered(startPos, endPos, targetComp)
		local filter = {}
		local total = 0
		local dir = (endPos - startPos):GetNormalized()
		local hitTarget = false

		local hullMins = Vector(-3, -3, -3)
		local hullMaxs = Vector(3, 3, 3)

		for _ = 1, 128 do
			-- Small hull keeps thin props from slipping through the trace.
			local tr = util.TraceHull({
				start  = startPos,
				endpos = endPos,
				mins   = hullMins,
				maxs   = hullMaxs,
				filter = filter,
				mask   = MASK_SOLID
			})

			if not tr.Hit then break end
			local hitEnt = tr.Entity
			if not IsEnt(hitEnt) then break end

			local skip = false

			if hitEnt.RenderOverride and tostring(hitEnt.RenderOverride):find("MakeSpherical") then
				skip = true
			end

			if not skip and hitEnt == targetComp then
				hitTarget = true
				break
			end

			if not skip then
				local cls = hitEnt:GetClass()
				local skipArmor = ignoredArmor[cls] or not ACF_Check(hitEnt)
				if skipArmor then
					skip = true
				elseif ACF_CheckClips(hitEnt, tr.HitPos) then
					skip = true
				end
			end

			if skip then
					filter[#filter + 1] = hitEnt
					startPos = tr.HitPos + dir * 0.1
			else
				-- Defensive ACF lookup for non-ACF props and holograms.
				local acf = hitEnt.ACF
				if not istable(acf) then
					filter[#filter + 1] = hitEnt
					startPos = tr.HitPos + dir * 0.1
				else
					local Mat = acf.Material or "RHA"
					local MatData = ACE_GetMaterialData(Mat)

					local armor = acf.Armour or 0
					local armorData = hitEnt.acfPropArmorData and hitEnt:acfPropArmorData()

					local effKE = (armorData and armorData.Effectiveness) or (MatData and MatData.effectiveness) or 1
					local effCHEM = (armorData and (armorData.HEATeffectiveness or armorData.HEATEffectiveness))
						or (MatData and (MatData.HEATeffectiveness or MatData.effectiveness))
						or effKE

					local eff = effKE * 0.8 + effCHEM * 0.2
					local curve = (armorData and armorData.Curve) or 1

					local ang = ACF_GetHitAngle(tr.HitNormal, dir)
					local los
					if ang >= 89 then
						los = (armor ^ curve) * eff
					else
						local cosAng = math.max(math.cos(math.rad(ang)), 0.01)
						los = (armor / (cosAng ^ ACF.SlopeEffectFactor)) ^ curve
						los = los * eff
					end

					total = total + los

					filter[#filter + 1] = hitEnt
					startPos = tr.HitPos + dir * 0.1
				end
			end
		end

		if not hitTarget then return 0 end
		return total
	end

	-- Map a ratio to a debug color.
	local function ACE_DebugColorRatio(r)
		r = math.Clamp(r or 0, 0, 1)

		-- red -> yellow -> green
		local rr = math.floor(255 * (1 - r))
		local gg = math.floor(255 * r)
		local bb = 0

		-- keep it readable when low
		if r < 0.5 then
			gg = math.floor(255 * (r * 2))
			rr = 255
		else
			rr = math.floor(255 * (1 - (r - 0.5) * 2))
			gg = 255
		end

		return Color(rr, gg, bb, 255)
	end

	local debugSamples = debugDraw and {} or nil
	local debugMaxLOS = 0


	local frontRegions, sideRegions = {}, {}

	for _, comp in ipairs(criticals) do
		local center = comp:WorldSpaceCenter()
		local size   = comp:OBBMaxs() - comp:OBBMins()

		local frontArea = projectedData(comp, frontDir)
		local sideArea  = projectedData(comp, sideDir)

		local up    = comp:GetUp()
		local right = comp:GetRight()

		local halfUp    = up    * (size.z * 0.5 * 0.95)
		local halfRight = right * (size.y * 0.5 * 0.95)

		local samples = {
			center + halfUp + halfRight,
			center + halfUp - halfRight,
			center - halfUp + halfRight,
			center - halfUp - halfRight,
			center
		}

		local sampleCount = #samples
		local weightF = (sampleCount > 0) and (frontArea / sampleCount) or 0
		local weightS = (sampleCount > 0) and (sideArea  / sampleCount) or 0

		for _, pt in ipairs(samples) do
			local frontVal = losFiltered(pt - frontDir * 200, pt, comp)
			local sideValA = losFiltered(pt - sideDir * 100, pt, comp)
			local sideValB = losFiltered(pt + sideDir * 500, pt - sideDir * 50, comp)

			local sideVal = 0
			if sideValA > 0 and (sideValB <= 0 or sideValA <= sideValB) then
				sideVal = sideValA
			elseif sideValB > 0 then
				sideVal = sideValB
			end

			if debugSamples then
				local best = math.max(frontVal or 0, sideVal or 0)
				if best > debugMaxLOS then debugMaxLOS = best end
				debugSamples[#debugSamples + 1] = {
					pos = pt,
					front = frontVal or 0,
					side = sideVal or 0
				}
			end

			if frontVal > 0 then
				updateRegion(frontRegions, regionKey(pt, frontU, frontV), frontVal, weightF)
			end
			if sideVal > 0 then
				updateRegion(sideRegions, regionKey(pt, sideU, sideV), sideVal, weightS)
			end
		end
	end

	if debugSamples and debugMaxLOS > 0 then
		for _, s in ipairs(debugSamples) do
			local best = math.max(s.front or 0, s.side or 0)
			local ratio = best / debugMaxLOS
			local col = ACE_DebugColorRatio(ratio)

			-- small square at each sample point
			debugoverlay.Box(s.pos, Vector(-1, -1, -1), Vector(1, 1, 1), 30, col)

			-- optional: label the best value
			-- debugoverlay.Text(s.pos + Vector(0, 0, 2), string.format("%.0f", best), 30, true)
		end
	end


	local accumFront, countFront = 0, 0
	for _, e in pairs(frontRegions) do
		accumFront = accumFront + e.val * e.weight
		countFront = countFront + e.weight
	end

	local accumSide, countSide = 0, 0
	for _, e in pairs(sideRegions) do
		accumSide = accumSide + e.val * e.weight
		countSide = countSide + e.weight
	end

	return (countFront > 0 and (accumFront / countFront) or 0),
	       (countSide  > 0 and (accumSide  / countSide)  or 0)
end

-- Run the armor scan for a contraption.
function ACE_GetArmorScan(ent)
	return ACE_CalcContraptionArmor(ent)
end

-- ------------------------------------------------------------
-- Armor rebuild (scan if needed, combine with non armor totals)
-- ------------------------------------------------------------

-- Ensure armor data is initialized and cached.
function ACE_EnsureArmor(con, baseEnt, force)
	if not con then return end

	if not force and not con.ACEArmorDirty then return end

	local base = baseEnt
	if (not IsEnt(base)) and con.GetACEBaseplate then base = con:GetACEBaseplate() end

	local front, side = 0, 0
	local usedCache = false

	local cached = con.ACEArmorCachedData
	if cached then
		front = cached.Front or cached.front or 0
		side  = cached.Side  or cached.side  or 0

		if ACE_IsValidArmorResult(front, side) then
			con.ACEArmorFront = front
			con.ACEArmorSide  = side
			usedCache = true
		else
			front, side = 0, 0
			usedCache = false
		end
	end

	if not usedCache and IsEnt(base) then
		front, side = ACE_CalcContraptionArmor(base)
		con.ACEArmorFront = front
		con.ACEArmorSide  = side
	end

	if con.ACENonArmorDirty or not con.ACEPointsPerType then
		ACE_RebuildNonArmorPoints(con, base)
	end

	local newArmorPts = (front + side * 2) * 4

	con.ACEPointsPerType = con.ACEPointsPerType or {}
	con.ACEPointsPerType.Armor = newArmorPts

	con.ACEArmorPoints = newArmorPts
	con.ACEArmorDirty = false
	con.ACEArmorCalculated = true
	con.ACEArmorLastCalc = CurTime()

	con.OTWarnings = con.OTWarnings or {}
	con.OTWarnings.WarnedModified = false

	local nonArmor = con.ACEPointsNonArmor or 0
	con.ACEPoints = nonArmor + newArmorPts

	local cacheKey = con.ACEArmorCacheKey
	if cacheKey and not usedCache and ACE_IsValidArmorResult(front, side) then
		ACE.DupeArmorCache = ACE.DupeArmorCache or {}
		ACE.DupeArmorCache[cacheKey] = { Front = front, Side = side }
	end

	con.ACEArmorCacheKey = nil
	con.ACEArmorCachedData = nil

	ACE_DebugDirty(con, "armor-scan-complete", base,
		string.format("front=%.2f side=%.2f cache=%s", front or 0, side or 0, tostring(usedCache)),
		"EnsureArmor"
	)
end
