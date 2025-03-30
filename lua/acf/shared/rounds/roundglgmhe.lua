
AddCSLuaFile()

local Round = {}

Round.type  = "Ammo" --Tells the spawn menu what entity to spawn
Round.name  = "[GLATGM-HE] - " .. ACFTranslation.ShellGLGM[1] --Human readable name
Round.model = "models/munitions/round_100mm_shot.mdl" --Shell flight model
Round.desc  = ACFTranslation.ShellGLGM[2]
Round.netid = 27 --Unique ammotype ID for network transmission

Round.Type  = "GLATGM-HE"

function Round.create( Gun, BulletData )

	local mdl = "models/missiles/rs82.mdl"
	if BulletData.Caliber > 20 then
		mdl = "models/missiles/rw61m.mdl"
	elseif BulletData.Caliber > 12.5 then
		mdl = "models/missiles/9m120.mdl"
	elseif BulletData.Caliber > 10.1 then
		mdl = "models/missiles/glatgm/9m117.mdl"
	elseif BulletData.Caliber > 7.6 then
		mdl = "models/missiles/glatgm/9m112.mdl"
	elseif BulletData.Caliber > 4 then
		mdl = "models/missiles/ffar_70mm.mdl"
	end

	local SMul = 15 / BulletData.Caliber * BulletData.MuzzleVel / 200

	local MDat = {
		Owner = Gun:CPPIGetOwner(),
		Launcher = Gun,

		Pos = Gun:GetAttachment(1).Pos + Gun:GetForward() * 39.37,
		Ang = Gun:GetAngles(),

		Mdl = mdl,

		TurnRate = 80,
		FinMul = 0.65,
		ThrusterTurnRate = 30,

		InitialVelocity = 20,
		Thrust = 44 * SMul,
		BurnTime = 10,
		MotorDelay = 0,

		BoostThrust = 200 * SMul,
		BoostTime = 0.2,
		BoostDelay = 0,

		Drag = 0.0005,
		GuidanceName = "Beam_Riding",
		FuseName = "Contact",
		HasInertial = false,
		HasDatalink = false,

		ArmDelay = 0.0,
		DelayPrediction = 0.1,
		ArmorThickness = 15,

		MotorSound = "acf_extra/ACE/missiles/Launch/RocketBasic.wav",
		BoostEffect = "Rocket Motor ATGM",
		MotorEffect = "Rocket Motor ATGM"
	}

	local BData = table.Copy( BulletData ) --Done so we don't accidentally write to the original crate bulletdata
	BData.BulletData = nil

	BData.Type = "HE"
	--BData.Id = 2	

	BData.FakeCrate = ents.Create("acf_fakecrate2")
	BData.FakeCrate:RegisterTo(BData)
	BData.Crate = BData.FakeCrate:EntIndex()
	--self:DeleteOnRemove(BData.FakeCrate)

	GenerateMissile(MDat,BData.FakeCrate,BData)
end

-- Function to convert the player's slider data into the complete round data
function Round.convert( _, PlayerData )

	local Data		= {}
	local ServerData	= {}
	local GUIData	= {}

	PlayerData.PropLength	=  PlayerData.PropLength	or 0
	PlayerData.ProjLength	=  PlayerData.ProjLength	or 0
	PlayerData.Tracer	=  PlayerData.Tracer		or 0
	PlayerData.TwoPiece	=  PlayerData.TwoPiece	or 0
	PlayerData.Data5		= math.max(PlayerData.Data5 or 0, 0) --HEFiller

	PlayerData, Data, ServerData, GUIData = ACF_RoundBaseGunpowder( PlayerData, Data, ServerData, GUIData )

	--Shell sturdiness calcs

	--Volume of the projectile as a cylinder - Volume of the filler * density of steel + Volume of the filler * density of TNT
	Data.ProjMass		= math.max(GUIData.ProjVolume-PlayerData.Data5,0) * 7.9 / 1000 + math.min(PlayerData.Data5,GUIData.ProjVolume) * ACF.HEDensity / 1000
	Data.MuzzleVel		= ACF_MuzzleVelocity( Data.PropMass, Data.ProjMass, Data.Caliber )
	local Energy			= ACF_Kinetic( Data.MuzzleVel * 39.37 , Data.ProjMass, Data.LimitVel )
	local MaxVol			= ACF_RoundShellCapacity( Energy.Momentum, Data.FrArea, Data.Caliber, Data.ProjLength )

	GUIData.MinFillerVol	= 0
	GUIData.MaxFillerVol	= math.min(GUIData.ProjVolume,MaxVol)
	GUIData.FillerVol	= math.min(PlayerData.Data5,GUIData.MaxFillerVol)
	Data.FillerMass		= GUIData.FillerVol * ACF.HEDensity / 1000

	Data.ProjMass		= math.max(GUIData.ProjVolume-GUIData.FillerVol,0) * 7.9 / 1000 + Data.FillerMass
	Data.MuzzleVel		= ACF_MuzzleVelocity( Data.PropMass, Data.ProjMass, Data.Caliber )

	--Random bullshit left
	Data.ShovePower		= 0.1
	Data.PenArea			= Data.FrArea ^ ACF.PenAreaMod
	Data.DragCoef		= ((Data.FrArea / 10000) / Data.ProjMass)
	Data.LimitVel		= 100									-- Most efficient penetration speed in m/s
	Data.KETransfert		= 0.1									-- Kinetic energy transfert to the target for movement purposes
	Data.Ricochet		= 70										-- Base ricochet angle
	Data.DetonatorAngle	= 70

	Data.BoomPower		= Data.PropMass + Data.FillerMass

	if SERVER then --Only the crates need this part
		ServerData.Id	= PlayerData.Id
		ServerData.Type	= PlayerData.Type
		return table.Merge(Data,ServerData)
	end

	if CLIENT then --Only tthe GUI needs this part
		GUIData = table.Merge(GUIData, Round.getDisplayData(Data))
		return table.Merge(Data,GUIData)
	end

end


function Round.getDisplayData(Data)
	local GUIData = {}
	GUIData.BlastRadius = Data.FillerMass ^ 0.33 * 8
	local FragMass = Data.ProjMass - Data.FillerMass
	GUIData.Fragments = math.max(math.floor((Data.FillerMass / FragMass) * ACF.HEFrag),2)
	GUIData.FragMass = FragMass / GUIData.Fragments
	GUIData.FragVel = (Data.FillerMass * ACF.HEPower * 1000 / GUIData.FragMass / GUIData.Fragments) ^ 0.5
	return GUIData
end


function Round.network( Crate, BulletData )

	Crate:SetNWString( "AmmoType", "GLATGM-HE" )
	Crate:SetNWString( "AmmoID", BulletData.Id )
	Crate:SetNWFloat( "Caliber", BulletData.Caliber )
	Crate:SetNWFloat( "ProjMass", BulletData.ProjMass )
	Crate:SetNWFloat( "FillerMass", BulletData.FillerMass )
	Crate:SetNWFloat( "PropMass", BulletData.PropMass )
	Crate:SetNWFloat( "DragCoef", BulletData.DragCoef )
	Crate:SetNWFloat( "MuzzleVel", BulletData.MuzzleVel )
	Crate:SetNWFloat( "Tracer", BulletData.Tracer )

		--For propper bullet model
	Crate:SetNWFloat( "BulletModel", Round.model )

end

function Round.cratetxt( BulletData )

	local DData = Round.getDisplayData(BulletData)

	local str =
	{
		"Relative Thrust: ", math.Round((15 / BulletData.Caliber * BulletData.MuzzleVel / 200) * 44, 1), " m/s^2\n",
		"Blast Radius: ", math.Round(DData.BlastRadius, 1), " m\n",
		"Blast Energy: ", math.floor(BulletData.FillerMass * ACF.HEPower), " KJ\n",
		"Max Blast Penetration: ", math.floor(BulletData.FillerMass * ACF.HEPower / ACF.HEBlastPenetration), " mm"
	}

	return table.concat(str)

end

function Round.propimpact( _, Bullet, Target, HitNormal, HitPos, Bone )

	if ACF_Check( Target ) then
		local Speed	= Bullet.Flight:Length() / ACF.VelScale
		local Energy	= ACF_Kinetic( Speed , Bullet.ProjMass - Bullet.FillerMass, Bullet.LimitVel )
		local HitRes	= ACF_RoundImpact( Bullet, Speed, Energy, Target, HitPos, HitNormal , Bone )

		if HitRes.Ricochet then
			return "Ricochet"
		end
	end
	return false

end

function Round.worldimpact()
	return false
end

function Round.endflight( Index, Bullet, HitPos, HitNormal )
	ACF_HE( HitPos - Bullet.Flight:GetNormalized() * 3, HitNormal, Bullet.FillerMass, Bullet.ProjMass - Bullet.FillerMass, Bullet.Owner, nil, Bullet.Gun )
	ACF_RemoveBullet( Index )
end

function Round.endeffect( _, Bullet )

	local Radius = Bullet.FillerMass ^ 0.33 * 8 * 39.37
	local Flash = EffectData()
		Flash:SetOrigin( Bullet.SimPos )
		Flash:SetNormal( Bullet.SimFlight:GetNormalized() )
		Flash:SetRadius( math.Round(math.max(Radius / 39.37, 1),2) )
	util.Effect( "ACF_Scaled_Explosion", Flash )

end

function Round.pierceeffect( _, Bullet )

	local BulletEffect = {}
		BulletEffect.Num	= 1
		BulletEffect.Src	= Bullet.SimPos - Bullet.SimFlight:GetNormalized()
		BulletEffect.Dir	= Bullet.SimFlight:GetNormalized()
		BulletEffect.Spread = Vector(0,0,0)
		BulletEffect.Tracer = 0
		BulletEffect.Force  = 0
		BulletEffect.Damage = 0
	LocalPlayer():FireBullets(BulletEffect)

	util.Decal("ExplosiveGunshot", Bullet.SimPos + Bullet.SimFlight * 10, Bullet.SimPos - Bullet.SimFlight * 10)

	local Spall = EffectData()
		Spall:SetOrigin( Bullet.SimPos )
		Spall:SetNormal( (Bullet.SimFlight):GetNormalized() )
		Spall:SetScale(math.max(((Bullet.RoundMass * (Bullet.SimFlight:Length() / 39.37) ^ 2) / 2000) / 10000, 1))
	util.Effect( "AP_Hit", Spall )

end

function Round.ricocheteffect( _, Bullet )

	local Spall = EffectData()
		Spall:SetEntity( Bullet.Crate )
		Spall:SetOrigin( Bullet.SimPos )
		Spall:SetNormal( Bullet.SimFlight:GetNormalized() )
		Spall:SetScale( Bullet.SimFlight:Length() )
		Spall:SetMagnitude( Bullet.RoundMass )
	util.Effect( "ACF_AP_Ricochet", Spall )

end

function Round.guicreate( Panel, Table )

	acfmenupanel:AmmoSelect(ACF.AmmoBlacklist.GLATGM)

	acfmenupanel:CPanelText("CrateInfoBold", "Crate information:", "DermaDefaultBold")

	acfmenupanel:CPanelText("BonusDisplay", "")

	acfmenupanel:CPanelText("Desc", "") --Description (Name, Desc)
	acfmenupanel:CPanelText("BoldAmmoStats", "Round information: ", "DermaDefaultBold")
	acfmenupanel:CPanelText("LengthDisplay", "")	--Total round length (Name, Desc)

	acfmenupanel:AmmoSlider("PropLength",0,0,1000,3, "Propellant Length", "")	--Slider (Name, Value, Min, Max, Decimals, Title, Desc)
	acfmenupanel:AmmoSlider("ProjLength",0,0,1000,3, "Projectile Length", "")	--Slider (Name, Value, Min, Max, Decimals, Title, Desc)
	acfmenupanel:CPanelText("BlastPenDisplay", "")  							--HE Fragmentation data (Name, Desc)
	acfmenupanel:AmmoSlider("FillerVol",0,0,1000,3, "HE Filler", "")			--Slider (Name, Value, Min, Max, Decimals, Title, Desc)

	ACE_Checkboxes()

	acfmenupanel:CPanelText("VelocityDisplay", "")  --Proj muzzle velocity (Name, Desc)
	acfmenupanel:CPanelText("BlastDisplay", "") --HE Blast data (Name, Desc)
	acfmenupanel:CPanelText("FragDisplay", "")  --HE Fragmentation data (Name, Desc)

	Round.guiupdate( Panel, Table )

end

function Round.guiupdate( Panel )

	local PlayerData = {}
		PlayerData.Id		= acfmenupanel.AmmoData.Data.id		--AmmoSelect GUI
		PlayerData.Type		= "GLATGM-HE"									--Hardcoded, match as Round.Type instead
		PlayerData.PropLength	= acfmenupanel.AmmoData.PropLength  --PropLength slider
		PlayerData.ProjLength	= acfmenupanel.AmmoData.ProjLength  --ProjLength slider
		PlayerData.Data5		= acfmenupanel.AmmoData.FillerVol
		PlayerData.Tracer	= acfmenupanel.AmmoData.Tracer
		PlayerData.TwoPiece	= acfmenupanel.AmmoData.TwoPiece

	local Data = Round.convert( Panel, PlayerData )

	RunConsoleCommand( "acfmenu_data1", acfmenupanel.AmmoData.Data.id )
	RunConsoleCommand( "acfmenu_data2", PlayerData.Type )
	RunConsoleCommand( "acfmenu_data3", Data.PropLength )	--For Gun ammo, Data3 should always be Propellant
	RunConsoleCommand( "acfmenu_data4", Data.ProjLength )	--And Data4 total round mass
	RunConsoleCommand( "acfmenu_data5", Data.FillerVol )
	RunConsoleCommand( "acfmenu_data10", Data.Tracer )
	RunConsoleCommand( "acfmenu_data11", Data.TwoPiece )

	---------------------------Ammo Capacity-------------------------------------
	ACE_AmmoCapacityDisplay( Data )
	-------------------------------------------------------------------------------
	acfmenupanel:AmmoSlider("PropLength", Data.PropLength, Data.MinPropLength, Data.MaxTotalLength, 3, "Propellant Length", "Propellant Mass : " .. (math.floor(Data.PropMass * 1000)) .. " g" .. "/ " .. (math.Round(Data.PropMass, 1)) .. " kg" )  --Propellant Length Slider (Name, Min, Max, Decimals, Title, Desc)
	acfmenupanel:AmmoSlider("ProjLength", Data.ProjLength, Data.MinProjLength, Data.MaxTotalLength, 3, "Projectile Length", "Projectile Mass : " .. (math.floor(Data.ProjMass * 1000)) .. " g" .. "/ " .. (math.Round(Data.ProjMass, 1)) .. " kg")  --Projectile Length Slider (Name, Min, Max, Decimals, Title, Desc)	--Projectile Length Slider (Name, Min, Max, Decimals, Title, Desc)
	acfmenupanel:CPanelText("BlastPenDisplay", "Max Blast Penetration: " .. math.floor(Data.FillerMass * ACF.HEPower / ACF.HEBlastPenetration,1) .. " mm")
	acfmenupanel:AmmoSlider("FillerVol",Data.FillerVol,Data.MinFillerVol,Data.MaxFillerVol,3, "HE Filler Volume", "HE Filler Mass : " .. (math.floor(Data.FillerMass * 1000)) .. " g")	--HE Filler Slider (Name, Min, Max, Decimals, Title, Desc)

	ACE_Checkboxes( Data )

	acfmenupanel:CPanelText("Desc", ACF.RoundTypes[PlayerData.Type].desc) --Description (Name, Desc)
	acfmenupanel:CPanelText("LengthDisplay", "Round Length : " .. (math.floor((Data.PropLength + Data.ProjLength + (math.floor(Data.Tracer * 5) / 10)) * 100) / 100) .. "/" .. Data.MaxTotalLength .. " cm") --Total round length (Name, Desc)
	acfmenupanel:CPanelText("VelocityDisplay", "Relative Thrust: " .. math.Round((15 / Data.Caliber * Data.MuzzleVel / 200) * 44, 1) .. " m/s^2")	--Proj muzzle velocity (Name, Desc)
	acfmenupanel:CPanelText("BlastDisplay", "Blast Radius : " .. (math.floor(Data.BlastRadius * 100) / 100) .. " m") --Proj muzzle velocity (Name, Desc)
	acfmenupanel:CPanelText("FragDisplay", "Fragments : " .. Data.Fragments .. "\n Average Fragment Weight : " .. (math.floor(Data.FragMass * 10000) / 10) .. " g \n Average Fragment Velocity : " .. math.floor(Data.FragVel) .. " m/s") --Proj muzzle penetration (Name, Desc)

	---------------------------Chance of Ricochet table----------------------------

	acfmenupanel:CPanelText("RicoDisplay", "Max Detonation angle: " .. Data.DetonatorAngle .. "°")

	-------------------------------------------------------------------------------
end

list.Set("HERoundTypes", "GLATGM-HE", Round ) --Set the round on chemical folder
ACF.RoundTypes[Round.Type] = Round     --Set the round properties
ACF.IdRounds[Round.netid] = Round.Type --Index must equal the ID entry in the table above, Data must equal the index of the table above