AddCSLuaFile()

local floor, Clamp = math.floor, math.Clamp

-- returns last parent in chain, which has physics
function ACF_GetPhysicalParent( obj )
	if not IsValid(obj) then return nil end

	--check for fresh cached parent
	if obj.acfphysparent and ACF.CurTime < obj.acfphysstale then
		return obj.acfphysparent
	end

	local Parent = obj

	while IsValid(Parent:GetParent()) do
		Parent = Parent:GetParent()
	end

	--update cached parent
	obj.acfphysparent = Parent
	obj.acfphysstale = ACF.CurTime + 10 --when cached parent is considered stale and needs updating

	return Parent
end

--Calculates a position along a catmull-rom spline (as defined on https://www.mvps.org/directx/articles/catmull/)
--This is used for calculating engine torque curves
function ACF_CalcCurve(Points, Pos)
	local Count = #Points

	if Count < 3 then return 0 end

	if Pos <= 0 then
		return Points[1]
	elseif Pos >= 1 then
		return Points[Count]
	end

	local T	= (Pos * (Count - 1)) % 1
	local Current = math.floor(Pos * (Count - 1) + 1)
	local P0	= Points[Clamp(Current - 1, 1, Count - 2)]
	local P1	= Points[Clamp(Current, 1, Count - 1)]
	local P2	= Points[Clamp(Current + 1, 2, Count)]
	local P3	= Points[Clamp(Current + 2, 3, Count)]

	return 0.5 * ((2 * P1) +
		(P2 - P0) * T +
		(2 * P0 - 5 * P1 + 4 * P2 - P3) * T ^ 2 +
		(3 * P1 - P0 - 3 * P2 + P3) * T ^ 3)
end

--Calculates the performance characteristics of an engine, given a torque curve, max torque (in nm), idle, and redline rpm
function ACF_CalcEnginePerformanceData(curve, maxTq, idle, redline)
	local peakTq = 0
	local peakTqRPM
	local peakPower = 0
	local powerTable = {} --Power at each point on the curve for use in powerband calc
	local res = 32 --Iterations for use in calculating the curve, higher is more accurate

	--Calculate peak torque/power RPM
	for i = 0, res do
		local rpm = i / res * redline
		local perc = math.Remap(rpm, idle, redline, 0, 1)
		local curTq = ACF_CalcCurve(curve, perc)
		local power = maxTq * curTq * rpm / 9548.8

		powerTable[i] = power

		if power > peakPower then
			peakPower = power
			peakPowerRPM = rpm
		end

		if Clamp(curTq, 0, 1) > peakTq then
			peakTq = curTq
			peakTqRPM = rpm
		end
	end

	--Find the bounds of the powerband (within 10% of its peak)
	local powerbandMinRPM
	local powerbandMaxRPM

	for i = 0, res do
		local powerFrac = powerTable[i] / peakPower
		local rpm = i / res * redline

		if powerFrac > 0.9 and not powerbandMinRPM then
			powerbandMinRPM = rpm
		end

		if (powerbandMinRPM and powerFrac < 0.9 and not powerbandMaxRPM) or (i == res and not powerbandMaxRPM) then
			powerbandMaxRPM = rpm
		end
	end

	return {
		peakTqRPM = peakTqRPM,
		peakPower = peakPower,
		peakPowerRPM = peakPowerRPM,
		powerbandMinRPM = powerbandMinRPM,
		powerbandMaxRPM = powerbandMaxRPM
	}
end

-- A cheap way to check if the distance between 2 points is within a target distance.
function ACE_InDist( Pos1, Pos2, Distance )
	return (Pos2 - Pos1):LengthSqr() < Distance ^ 2
end

	-- Material Enum
	-- 65 ANTLION
	-- 66 BLOODYFLESH
	-- 67 CONCRETE / NODRAW
	-- 68 DIRT
	-- 70 FLESH
	-- 71 GRATE
	-- 72 ALIENFLESH
	-- 73 CLIP
	-- 76 PLASTIC
	-- 77 METAL
	-- 78 SAND
	-- 79 FOLIAGE
	-- 80 COMPUTER
	-- 83 SLOSH
	-- 84 TILE
	-- 86 VENT
	-- 87 WOOD
	-- 89 GLASS

function ACE_GetMaterialName( Mat )
	--concrete
	local GroundMat = "Concrete"

	--print(Mat)
	-- Dirt
	if Mat == 68 or Mat == 79 or Mat == 85 then
		GroundMat = "Dirt"
	--Sand
	elseif Mat == 78 then
	GroundMat = "Sand"
	--Metal
	elseif Mat == 77 or Mat == 86 or Mat == 80 then
	GroundMat = "Metal"
	--Snow
	elseif Mat == 74 then
	GroundMat = "Snow"
	--Glass
	elseif Mat == 89 then
		GroundMat = "Glass"
	elseif Mat == 87 then
		GroundMat = "Wood"
	elseif Mat == 66 or Mat == 70 then
		GroundMat = "Flesh"
	end

	--[[
	if GroundMat != "Concrete" then
	--print("GMat: "..GroundMat)
	else
	print("ID: "..Mat)
	end
	]]--

	return GroundMat
end

-- changes here will be automatically reflected in the armor properties tool
function ACF_CalcArmor( Area, Ductility, Mass )

	return ( Mass * 1000 / Area / 0.78 ) / ( 1 + Ductility ) ^ 0.5 * ACF.ArmorMod

end

function ACF_MuzzleVelocity( Propellant, Mass )

	local PEnergy	= ACF.PBase * ((1 + Propellant) ^ ACF.PScale-1)
	local Speed	= ((PEnergy * 2000 / Mass) ^ ACF.MVScale)
	local Final	= Speed -- - Speed * math.Clamp(Speed/2000,0,0.5)

	return Final
end

function ACF_Kinetic( Speed , Mass, LimitVel )

	LimitVel = LimitVel or 99999
	Speed = Speed / 39.37

	local Energy = {}
		Energy.Kinetic = (Mass * (Speed ^ 2)) / 2000 --Energy in KiloJoules
		Energy.Momentum = Speed * Mass

		local KE = (Mass * (Speed ^ ACF.KinFudgeFactor)) / 2000 + Energy.Momentum
		Energy.Penetration = math.max(KE - (math.max(Speed - LimitVel, 0) ^ 2) / (LimitVel * 5) * (KE / 200) ^ 0.95, KE * 0.1)

	return Energy
end

do

	--Convert old numeric IDs to the new string IDs
	local BackCompMat = {
		"RHA",
		"CHA",
		"Cer",
		"Rub",
		"ERA",
		"Alum",
		"Texto"
	}

	-- Global Ratio Setting Function
	function ACF_CalcMassRatio( obj, pwr )
		if not IsValid(obj) then return end
		local Mass		= 0
		local PhysMass	= 0
		local power		= 0
		local Compositions  = {}
		local MatSums	= {}
		local PercentMat	= {}

		-- find the physical parent highest up the chain
		local Parent = ACF_GetPhysicalParent(obj)

		-- get the shit that is physically attached to the vehicle
		local PhysEnts = ACF_GetAllPhysicalConstraints( Parent )

		-- add any parented but not constrained props you sneaky bastards
		local AllEnts = table.Copy( PhysEnts )
		for _, v in pairs( AllEnts ) do

			table.Merge( AllEnts, ACF_GetAllChildren( v ) )

		end

		for _, v in pairs( AllEnts ) do

			if IsValid( v ) then

				if v:GetClass() == "acf_engine" then
					local driverBoost = v.HasDriver and ACF.DriverTorqueBoost or 1
					power = power + (v.peakkw * 1.34 * driverBoost)
				end

				local phys = v:GetPhysicsObject()
				if IsValid( phys ) then

					Mass = Mass + phys:GetMass() --print("total mass of contraption: " .. Mass)

					if PhysEnts[ v ] then
						PhysMass = PhysMass + phys:GetMass()
					end

				end

				if pwr then
					local PhysObj = v:GetPhysicsObject()

					if IsValid(PhysObj) then

						local material		= v.ACF and v.ACF.Material or "RHA"

						--ACE doesnt update their material stats actively, so we need to update it manually here.
						if not isstring(material) then
							local Mat_ID = material + 1
							material = BackCompMat[Mat_ID]
						end

						Compositions[material]  = Compositions[material] or {}

						table.insert(Compositions[material], PhysObj:GetMass() )

					end
				end

			end
		end

		--Build the ratios here
		for _, v in pairs( AllEnts ) do
			v.acfphystotal	= PhysMass
			v.acftotal		= Mass
			v.acflastupdatemass = ACF.CurTime
		end

		obj.acfphystotal = obj.acfphystotal or PhysMass
		obj.acftotal = obj.acftotal or Mass
		obj.acflastupdatemass = ACF.CurTime

		if pwr then
			--Get mass Material composition here
			for material, tablemass in pairs(Compositions) do

				MatSums[material] = 0

				for _, mass in pairs(tablemass) do

					MatSums[material] = MatSums[material] + mass

				end

				--Gets the actual material percent of the contraption
				local totalMass = obj.acftotal or Mass
				if totalMass <= 0 then
					PercentMat[material] = 0
				else
					PercentMat[material] = MatSums[material] / totalMass
				end

			end
		end
		if pwr then return { Power = power, MaterialPercent = PercentMat, MaterialMass = MatSums } end
	end

end

--Checks if theres new versions for ACE
function ACF_UpdateChecking( )
	http.Fetch("https://raw.githubusercontent.com/ACE-Project-Team/ArmoredCombatExtended/master/lua/autorun/acf_globals.lua",function(contents)

		--maybe not the best way to get git but well......
		str = tostring("String:" .. contents)
		i,k = string.find(str,"ACF.Version =")

		local rev = tonumber(string.sub(str,k + 2,k + 4)) or 0

		if rev and ACF.Version == rev  and rev ~= 0 then

			print("[ACE | INFO]- You have the latest version! Current version: " .. rev)

		elseif rev and ACF.Version > rev and rev ~= 0 then

			print("[ACE | INFO]- You have an experimental version! Your version: " .. ACF.Version .. ". Main version: " .. rev)
		elseif rev == 0 then

			print("[ACE | ERROR]- Unable to find the latest version! Failed to connect to GitHub.")

		else

			print("[ACE | INFO]- A new version of ACE is available! Your version: " .. ACF.Version .. ". New version: " .. rev)
			if CLIENT then chat.AddText( Color( 255, 0, 0 ), "A newer version of ACE is available!" ) end

		end
		ACF.CurrentVersion = rev

	end, function()
		print("[ACE | ERROR]- Unable to find the latest version! No internet available.")

		ACF.CurrentVersion = 0
	end)
end


--Creates & updates ACE dupes.
--[[
-- USAGE:
	To Add a dupe, you have to put inside of your_addon_name/scripts/vehicles/>HERE< with the following naming:

	acedupe_[folder name]_[your dupe name].txt

	Note:
	- folder name must be ONE word (acecool, myaddon, tankpack, etc). It cannot have spaces!!!
	- your dupe name can have spaces, however, they must be '_' for the file. The loader will automatically change that symbol to spaces.

	Correct way examples:

	- acedupe_tanks_bmp2.txt
	- acedupe_cars_my_cool_car.txt
	- acedupe_thebest_the_best_of_the_best.txt
]]

do


	if CLIENT then

		concommand.Add( "acf_dupes_remount", function()

			if not AdvDupe2 then
				notification.AddLegacy( "Unable to reload the dupes.", NOTIFY_ERROR, 7)
				return
			end

			if file.Exists("acf/ace_dupespawn.txt", "DATA") then

				notification.AddLegacy( "Dupe files were reloaded!", NOTIFY_GENERIC, 7)
				file.Delete("acf/ace_dupespawn.txt")
				ACE_Dupes_Refresh()
			end
		end )

		function ACE_Dupes_Refresh()

			local files = file.Find("scripts/vehicles/acedupe_*.txt", "GAME")

			if files then

				local file_naming = {}

				local file_name
				local file_directory
				local file_exists
				local cfile_content
				local dupespawned = file.Exists("acf/ace_dupespawn.txt", "DATA")

				for _, txtfile in ipairs(files) do

					file_content   = file.Read("scripts/vehicles/" .. txtfile, "GAME") or ""
					file_naming    = string.Explode("_", txtfile)
					file_name      = table.concat( file_naming, " ", 3) -- Parses the file name
					file_name      = string.Replace( file_name, ".txt", "" )

					file_directory   = "advdupe2/ace " .. file_naming[2]
					file_exists      = file.Exists( file_directory .. "/" .. file_name .. ".txt", "DATA")

					if not file_exists then

						if not dupespawned then
							file.CreateDir(file_directory)
							file.Write(file_directory .. "/" .. file_name .. ".txt", file_content)

							print( "[ACE|INFO]- Creating dupe '" .. file_name .. "'' in " .. file_directory )
						end
					else
						--Idea: bring the analyzer from the internet instead of locally?
						cfile_content = file.Read(file_directory .. "/" .. file_name .. ".txt", "DATA") or ""

						if util.SHA256(cfile_content) ~= util.SHA256(file_content) then

							print("[ACE|INFO]- your dupe " .. file_name .. " is different/outdated! Updating....")

							file.Write(file_directory .. "/" .. file_name .. ".txt", file_content)

						end
					end
				end

				if not dupespawned then
					file.Write("acf/ace_dupespawn.txt", "This means, dupe loader will not populate the dupes if they were removed.")
				end
			end
		end

		timer.Simple(1,function()
			--Why do we need to create useless files if the user has not the advdupe2 in the first place.
			if not AdvDupe2 then
				return
			end

			ACE_Dupes_Refresh()
		end)

	end
end

timer.Simple(1, function()
	ACF_UpdateChecking()
end )


do

	--Used to reconvert old material ids
	ACE.BackCompMat = {
		[0] = "RHA",
		[1] = "CHA",
		[2] = "Cer",
		[3] = "Rub",
		[4] = "ERA",
		[5] = "Alum",
		[6] = "Texto"
	}

	--Dedicated function to get the material due to old numeric ids must be passed to the new string indexing now. Could change in a future.
	function ACE_GetMaterialData( Mat )

		if not ACE_CheckMaterial( Mat ) then

			Mat = not isstring(Mat) and ACE.BackCompMat[Mat] or "RHA"

			if not ACE_CheckMaterial( Mat ) then
				print("[ACE|ERROR]- No Armor material data found! Have the armor folder been renamed or removed? Unexpected results could occur!")
				return nil
			end
		end

		local MatData = ACE.ArmorTypes[Mat]

		return MatData
	end
end

--TODO: Use a universal function
function ACE_CheckMaterial( MatId )

	local matdata = ACE.ArmorTypes[ MatId ]

	if not matdata then return false end

	return true

end

function ACE_CheckRound( id )

	local rounddata = ACF.RoundTypes[ id ]

	if not rounddata then return false end

	return true
end

function ACE_CheckGun( gunid )

	local gundata = ACF.Weapons.Guns[ gunid ]

	if not gundata then return false end

	return true
end

function ACE_CheckRack( rackid )

	local rackdata = ACF.Weapons.Racks[ rackid ]

	if not rackdata then return false end

	return true
end

function ACE_CheckAmmo( ammoid )

	local Ammodata = ACF.Weapons.Ammo[ ammoid ]

	if not Ammodata then return false end

	return true
end

function ACE_CheckEngine( engineid )

	local enginedata = ACF.Weapons.Engines[ engineid ]

	if not enginedata then return false end

	return true
end

function ACE_CheckGearbox( gearid )

	local geardata = ACF.Weapons.Gearboxes[ gearid ]

	if not geardata then return false end

	return true
end

function ACE_CheckFuelTank( fueltankid )

	local fueltankid = ACF.Weapons.FuelTanksSize[ fueltankid ]

	if not fueltankid then return false end

	return true
end

if SERVER then
	function ACE_SendMsg(ply, ...)
		net.Start("ACE_SendMessage")
		net.WriteBool(false)
		net.WriteTable({...})
		net.Send(ply)
	end

	function ACE_SendNotification(ply, hint, duration)
		net.Start("ACE_SendMessage")
		net.WriteBool(true)
		net.WriteString(hint)
		net.WriteUInt(duration or 7, 8)
		net.Send(ply)
	end

	function ACE_BroadcastMsg(...)
		net.Start("ACE_SendMessage")
		net.WriteBool(false)
		net.WriteTable({...})
		net.Broadcast()
	end
else
	net.Receive("ACE_SendMessage", function()
		local isHint = net.ReadBool()

		if isHint then
			local hint = net.ReadString()
			local duration = net.ReadUInt(8)

			notification.AddLegacy(hint, NOTIFY_GENERIC, duration)
		else
			local msg = net.ReadTable()

			for k, v in pairs(msg) do
				if type(v) == "table" and #v == 4 then -- For some reason, color objects are sometimes converted to tables during networking?
					msg[k] = Color(v[1], v[2], v[3], v[4])
				end
			end

			chat.AddText(unpack(msg))
		end
	end)
end

--[[ IDK if this will take some usage
function ACE_Msg( type, txt )

	if not isstring(type) then
		ErrorNoHaltWithStack(( "bad argument #1 to 'type' (string expected, got " .. type( type ) .. ")" ))
		return
	end

	if not isstring(txt) then
		ErrorNoHaltWithStack(( "bad argument #2 to 'txt' (string expected, got " .. type( type ) .. ")" ))
		return
	end

	local Info

	if type == "warn"
		Info = "WARN"
	elseif type == "error"
		Info = "ERROR"
	elseif type == "info"
		Info = "INFO"
	end

	local prefix = "[ACE | " .. Info .. "]- "

	print( prefix .. txt )

end
]]

-- Helper function to check if a value exists in a table
function ACE_table_contains(table, element)
	for _, value in pairs(table) do
		if value == element then
			return true
		end
	end
	return false
end

-- Radar/IRST-specific functions
if SERVER then
	local Indexes = {}
	local IndexCount = 0
	local Unused = {}

	--- Gets a unique ID for a contraption object
	---@param Contraption any
	---@return number ID The contraption's unique ID
	function ACE_GetContraptionIndex(Contraption)
		if Indexes[Contraption] then return Indexes[Contraption] end

		if next(Unused) then
			local Index = next(Unused)

			Indexes[Contraption] = Index
			Unused[Index] = nil
		else
			IndexCount = IndexCount + 1

			Indexes[Contraption] = IndexCount
		end

		local EntID = Indexes[Contraption]

		return EntID
	end

	function ACE_ClearContraptionIndex(Contraption)
		local Index = Indexes[Contraption]

		if Index then
			Indexes[Contraption] = nil
			Unused[Index] = true
		end
	end

	hook.Add("cfw.contraption.removed", "ACE_IndexTracking_ContraptionRemoved", ACE_ClearContraptionIndex)
	hook.Add("cfw.contraption.merged", "ACE_IndexTracking_ContraptionMerged", ACE_ClearContraptionIndex)

	--- Efficiently find the index to insert a value into a sorted table
	---@param Tbl table
	---@param Value number
	---@return number Index The index to insert the value at
	function ACE_GetBinaryInsertIndex(Tbl, Value)
		local Start = 1
		local Finish = #Tbl

		if not Tbl[1] then
			return 1
		end

		while Start < Finish do
			local Mid = floor((Start + Finish) / 2)
			if Value < Tbl[Mid] then
				Finish = Mid
			else
				Start = Mid + 1
			end
		end

		if Value < Tbl[Start] then
			return Start
		else
			return Start + 1
		end
	end
end

-- ============================================================
-- ACE points/cost helpers
-- ============================================================

-- Build a consistent description for ACE convars.
function ACE_ConVarHelp(desc)
	return "ACE - " .. desc
end

-- Helper: short IsValid wrapper for entities.
function ACE_IsEnt(ent)
	return IsValid(ent)
end

-- Check whether an entity is a Wiremod class.
function ACE_IsWireEntity(ent)
	if not ACE_IsEnt(ent) then return false end
	local cls = ent:GetClass()
	if not isstring(cls) then return false end
	return cls:sub(1, 10) == "gmod_wire_"
end

-- Check whether an entity is a missile entity.
function ACE_IsMissileEntity(ent)
	if not ACE_IsEnt(ent) then return false end
	local cls = ent:GetClass()
	return cls == "ace_missile" or cls == "acf_missile"
end

ACE.ArmorClasses = ACE.ArmorClasses or {
	prop_physics = true,
	primitive_shape = true,
	primitive_airfoil = true,
	primitive_rail_slider = true,
	primitive_slider = true,
	primitive_ladder = true
}

ACE.ClassToType = ACE.ClassToType or {
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
function ACE_GetPtsType(className)
	if ACE.ArmorClasses[className] then return "Armor" end
	return ACE.ClassToType[className] or "Ignore"
end

-- Validate armor scan results.
function ACE_IsValidArmorResult(front, side)
	if not front or not side then return false end
	if front ~= front or side ~= side then return false end
	if front <= 0 or side <= 0 then return false end
	return true
end

-- Resolve the ammo type multiplier for cost/points.
function ACE_GetAmmoTypeFactor(ammoType)
	local factors = ACE.AmmoTypeFactors
	return factors and factors[ammoType] or 1
end

-- Determine whether an ammo type should use HE utility scaling.
function ACE_IsHEAmmoType(ammoType)
	return ammoType == "HE" or ammoType == "HEFS" or ammoType == "CHE"
end

-- Compute ready rack capacity for a caliber.
function ACE_GetReadyRackCap(calMm)
	local cfg = ACE.AmmoCostConfig or {}
	local readyBase = cfg.ReadyRackBase or 0
	if readyBase <= 0 then return 0 end

	local pivot    = cfg.ReadyRackPivot or 0
	local lowBoost = cfg.ReadyRackLowBoost or 0

	local baseCap = readyBase / math.max(calMm, 1)

	if pivot > 0 and lowBoost > 0 and calMm < pivot then
		local ratio = (pivot - calMm) / pivot
		baseCap = baseCap * (1 + lowBoost * ratio)
	end

	return math.floor(baseCap + 0.5)
end

-- Calculate per-round points (no RPS factors) for ammo allocation weighting.
function ACE_GetAmmoRoundPoints(bdata)
	if not bdata then return 0 end

	local maxPen = ACE_GetAmmoMaxPen(bdata)
	local blastMass = ACE_GetAmmoBlastMass(bdata)
	if maxPen <= 0 and blastMass <= 0 then return 0 end

	local calMm = ACE_GetAmmoCaliberMm(bdata)
	if calMm <= 0 then return 0 end

	local typeFactor = ACE_GetAmmoTypeFactor(bdata.Type)
	if typeFactor <= 0 then return 0 end

	local cfg = ACE.AmmoCostConfig or {}
	local refPen = cfg.RefPen or 0
	local refCal = cfg.RefCaliber or 0
	local baseRound = cfg.BaseRoundPts or 0
	if refPen <= 0 or refCal <= 0 or baseRound <= 0 then return 0 end

	local penExp = cfg.PenExp or 1
	local blastExp = cfg.BlastExp or 1
	local blastWeight = cfg.BlastWeight or 0
	local refBlast = cfg.RefBlastMass or 0

	local penFactor = (maxPen / refPen) ^ penExp
	local blastFactor = 0
	if blastMass > 0 and refBlast > 0 then
		blastFactor = (blastMass / refBlast) ^ blastExp
	end

	local utilFactor = 0
	if ACE_IsHEAmmoType(bdata.Type) and blastMass > 0 then
		local utilWeight = cfg.HeUtilWeight or 0
		local utilExp = cfg.HeUtilExp or 1
		utilFactor = (blastMass / math.max(calMm, 1)) ^ utilExp * utilWeight
	end

	local threatFactor = penFactor + blastFactor * blastWeight + utilFactor
	if threatFactor <= 0 then return 0 end

	local calFactor = calMm / refCal

	return baseRound * threatFactor * calFactor * typeFactor
end

-- Calculate threat weight for ready-rack allocation.
function ACE_GetAmmoThreatWeight(bdata)
	if not bdata then return 0 end

	local maxPen = ACE_GetAmmoMaxPen(bdata)
	local blastMass = ACE_GetAmmoBlastMass(bdata)
	if maxPen <= 0 and blastMass <= 0 then return 0 end

	local cfg = ACE.AmmoCostConfig or {}
	local refPen = cfg.RefPen or 0
	local refBlast = cfg.RefBlastMass or 0
	if refPen <= 0 then return 0 end

	local penExp = cfg.PenExp or 1
	local blastExp = cfg.BlastExp or 1
	local blastWeight = cfg.BlastWeight or 0

	local penFactor = (maxPen / refPen) ^ penExp
	local blastFactor = 0
	if blastMass > 0 and refBlast > 0 then
		blastFactor = (blastMass / refBlast) ^ blastExp
	end

	local utilFactor = 0
	if ACE_IsHEAmmoType(bdata.Type) and blastMass > 0 then
		local calMm = ACE_GetAmmoCaliberMm(bdata)
		if calMm > 0 then
			local utilWeight = cfg.HeUtilWeight or 0
			local utilExp = cfg.HeUtilExp or 1
			utilFactor = (blastMass / math.max(calMm, 1)) ^ utilExp * utilWeight
		end
	end

	return penFactor + blastFactor * blastWeight + utilFactor
end

-- Compute sustained rounds per second for a gun/rack.
function ACE_GetEntRps(ent)
	local reload = ent.ReloadTime
	if reload and reload > 0 then return 1 / reload end

	local rof = ent.RateOfFire
	if rof and rof > 0 then return rof / 60 end

	return 0
end

-- Collect per-gun RPS totals and rack entities for a contraption.
function ACE_BuildGunRpsAndRacks(ents)
	local gunRpsById, racks = {}, {}

	for _, ent in ipairs(ents) do
		if ACE_IsEnt(ent) then
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
function ACE_GetAmmoBlastMass(bdata)
	if not bdata then return 0 end
	return tonumber(bdata.BoomFillerMass) or tonumber(bdata.FillerMass) or 0
end

-- Resolve ammo caliber in millimeters.
function ACE_GetAmmoCaliberMm(bdata)
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
function ACE_GetAmmoMaxPen(bdata)
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

-- Collect entities belonging to a contraption.
function ACE_GetContraptionEntities(con, fallbackEnt)
	local ents = {}
	if con and con.ents then
		for ent in pairs(con.ents) do
			if ACE_IsEnt(ent) then ents[#ents + 1] = ent end
		end
	end
	if #ents == 0 and ACE_IsEnt(fallbackEnt) then ents[1] = fallbackEnt end
	return ents
end

-- Allocate ready-rack rounds across ammo crates.
function ACE_BuildAmmoReadyAlloc(ents)
	local cfg = ACE.AmmoCostConfig or {}
	if (cfg.ReadyRackBase or 0) <= 0 then return nil end

	local groups = {}
	-- Group ammo crates by caliber and weight by per-round cost.

	for _, ent in ipairs(ents) do
		if ACE_IsEnt(ent) and ent:GetClass() == "acf_ammo" then
			local bdata = ent.BulletData
			if bdata then
				local rounds = ent.Capacity or 0
				if rounds > 0 then
					local ammoId = bdata.Id
					if ammoId then
						local calMm = ACE_GetAmmoCaliberMm(bdata)
						if calMm > 0 then
							local group = groups[calMm]
							if not group then
								group = { calMm = calMm, total = 0, entries = {} }
								groups[calMm] = group
							end

                            local threat = ACE_GetAmmoThreatWeight(bdata)
                            local weight = threat * rounds
							group.total = group.total + math.max(weight, 0)
							group.entries[#group.entries + 1] = {
								ent = ent,
								rounds = rounds,
								weight = weight
							}
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
			local readyCap = ACE_GetReadyRackCap(group.calMm)
			if readyCap > 0 then
				local entries = {}
				local remaining = readyCap
				-- Use fractional remainders to distribute the leftover rounds.

				for _, entry in ipairs(group.entries) do
					local weight = entry.weight or 0
					local raw = 0
					if weight > 0 then
						raw = readyCap * weight / total
					end
					local base = math.floor(raw)
					local capped = math.min(base, entry.rounds)
					remaining = remaining - capped
					entries[#entries + 1] = {
						ent = entry.ent,
						rounds = entry.rounds,
						ready = capped,
						frac = raw - base
					}
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



-- ============================================================
-- ACE parsing/get helpers
-- ============================================================

-- Resolve a contraption wrapper for an entity.
function ACE_GetContraptionFromEntity(ent)
	if not ACE_IsEnt(ent) or not ent.GetContraption then return end
	local con = ent:GetContraption()
	if not con or not con.ents or table.IsEmpty(con.ents) then return end
	return con
end

-- Resolve contraption owner for messages.
function ACE_GetContraptionOwner(con)
	if not con then return nil end
	local base = con.GetACEBaseplate and con:GetACEBaseplate()
	if not ACE_IsEnt(base) or not base.CPPIGetOwner then return nil end
	local owner = base:CPPIGetOwner()
	return ACE_IsEnt(owner) and owner or nil
end

-- Safely format an owner name.
function ACE_GetOwnerName(owner)
	return ACE_IsEnt(owner) and owner:Nick() or "Unknown"
end

-- Build a parent chain summary for debug logs.
function ACE_GetEntChainSummary(ent, maxDepth)
	if not ACE_IsEnt(ent) then return "?" end
	local parts = {}
	local cur = ent
	local depth = 0
	local limit = maxDepth or 4
	while ACE_IsEnt(cur) and depth <= limit do
		parts[#parts + 1] = string.format("%s(%d)", cur:GetClass(), cur:EntIndex())
		cur = cur:GetParent()
		depth = depth + 1
	end
	return table.concat(parts, " <- ")
end

-- Format a position/angle tuple for dupe signatures.
function ACE_FormatDupeTransform(pos, ang)
	if pos and pos.x ~= nil and pos.y ~= nil and pos.z ~= nil then
		pos = string.format("%.3f,%.3f,%.3f", pos.x, pos.y, pos.z)
	end

	if ang and ang.p ~= nil and ang.y ~= nil and ang.r ~= nil then
		ang = string.format("%.2f,%.2f,%.2f", ang.p, ang.y, ang.r)
	end

	return tostring(pos or ""), tostring(ang or "")
end

function ACE_FormatArmorKey(material, ductility, armour, maxArmour, mass)
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
function ACE_GetDupeSignature(dupe, created)
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

				local material = (acfSettings and (acfSettings.Material or acfSettings.material)) or (acf and (acf.Material or acf.material))
				local ductility = (acfSettings and (acfSettings.Ductility or acfSettings.ductility)) or (acf and (acf.Ductility or acf.ductility))
				local armour = acf and (acf.Armour or acf.Armor)
				local maxArmour = acf and (acf.MaxArmour or acf.MaxArmor)
				local mass = massMod and (massMod.Mass or massMod.mass)
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
				local material = acf and acf.Material
				local ductility = acf and acf.Ductility
				local armour = acf and (acf.Armour or acf.Armor)
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
function ACE_ParseAdvDupeArgs(...)
	-- Supports both common patterns:
	-- (ply, dupe, created) or (dupeInfoTable)
	local a, b, c = ...

	if istable(a) and (a.CreatedEntities or (a[1] and a[1].CreatedEntities)) then
		local info = a
		local dupe = info[1] or info.Dupe or info.dupe or info
		local created = info.CreatedEntities or (dupe and dupe.CreatedEntities)
		return dupe, created
	end

	if ACE_IsEnt(a) and a:IsPlayer() and istable(b) and istable(c) then
		return b, c
	end

	if istable(a) and istable(b) then
		return a, b
	end

	return nil, nil
end

-- Legacy manufacturing cost indicator (original mass/material system).
function ACE_GetEntLegacyCost(ent, massOverride)
	if not ACE_IsEnt(ent) then return 0 end

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

-- Cached wrapper for per-crate ammo points.
function ACE_GetAmmoCratePointsForContraption(crate, con, fallbackEnt)
	if not ACE_IsEnt(crate) then return 0 end

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

-- Get points for a single entity.
function ACE_GetEntPoints(ent)
	if not ACE_IsEnt(ent) then return 0 end

	local class = ent:GetClass()
	if (ACE.ArmorClasses and ACE.ArmorClasses[class])
		or class == "acf_fueltank"
		or class == "acf_ammo"
		or class == "acf_gun"
		or class == "acf_rack" then
		return 0
	end

	return ent.ACEPoints or 0
end

-- Run the armor scan for a contraption.
function ACE_GetArmorScan(ent)
	if not ACE_CalcContraptionArmor then return 0, 0 end
	return ACE_CalcContraptionArmor(ent)
end





