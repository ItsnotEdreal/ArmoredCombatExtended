
ACE = ACE or {}

include("acf/shared/sh_ace_functions.lua")

local IsEnt = ACE_IsEnt

-- ============================================================
-- Point and armor calculation logic for contraption scans
-- ============================================================

-- Calculate the points value for an ammo crate.
function ACE_CalcAmmoCratePoints(crate, gunRpsById, racks, readyAlloc)
    if not IsEnt(crate) then return 0 end
    local bdata = crate.BulletData
    if not bdata then return 0 end

    local rounds = crate.Capacity or 0
    if rounds <= 0 then return 0 end

    local maxPen = ACE_GetAmmoMaxPen(bdata)
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

    local cfg = ACE.AmmoCostConfig or {}
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

    local readyCap = ACE_GetReadyRackCap(calMm)
    local readyCount = rounds
    local stowCount = 0

    if readyCap > 0 then
        readyCount = math.min(readyCap, rounds)
        stowCount = math.max(rounds - readyCount, 0)
    end

    if readyAlloc and readyAlloc[crate] then
        readyCount = math.min(readyAlloc[crate], rounds)
        stowCount = math.max(rounds - readyCount, 0)
    end

    local readyCost = roundPts * readyCount * rpsFactor
    local stowCost = roundPts * stowCount * stowFactor * rpsFactor

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
    local function addAmmoLine(state, caliber, ammoType, count, points)
        if not count or count <= 0 then return end
        local calKey = caliber and math.floor(caliber + 0.5) or 0
        if calKey <= 0 then return end

        local typeKey = (ammoType ~= "" and ammoType) or "Ammo"
        local key = string.format("%s|%d|%s", state, calKey, typeKey)

        ammoLines[key] = ammoLines[key] or {
            State = state,
            Caliber = calKey,
            Type = typeKey,
            Count = 0,
            Points = 0
        }
        ammoLines[key].Count = ammoLines[key].Count + count
        ammoLines[key].Points = ammoLines[key].Points + (points or 0)
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
                        totals.AmmoReady = totals.AmmoReady + (detail.ReadyCost or 0)
                        totals.AmmoBackup = totals.AmmoBackup + (detail.StowCost or 0)
                        totals.AmmoReadyRounds = totals.AmmoReadyRounds + (detail.ReadyCount or 0)
                        totals.AmmoBackupRounds = totals.AmmoBackupRounds + (detail.StowCount or 0)

                        local ammoType = detail.Type ~= "" and detail.Type or "Ammo"
                        local readyCount = math.floor((detail.ReadyCount or 0) + 0.5)
                        local stowCount = math.floor((detail.StowCount or 0) + 0.5)

                        if readyCount > 0 then
                            addDetail("Ammo", string.format("Ready rack %s x%d", ammoType, readyCount), detail.ReadyCost or 0, ent)
                        end
                        if stowCount > 0 then
                            addDetail("Ammo", string.format("Backup ammo %s x%d", ammoType, stowCount), detail.StowCost or 0, ent)
                        end

                        addAmmoLine("READY", detail.Caliber, ammoType, readyCount, detail.ReadyCost)
                        addAmmoLine("BACKUP", detail.Caliber, ammoType, stowCount, detail.StowCost)
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
                Count = math.floor(entry.Count + 0.5),
                Points = math.Round(entry.Points or 0, 1)
            }
        end
    end

    return nonArmor, totals, { Items = trimmed, AmmoLines = ammoList }, ammoCache
end

-- Recompute cached non-armor totals for a contraption.
function ACE_RebuildNonArmorPoints(con, baseEnt)
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


-- ============================================================
-- Armor scan logic
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

    local debugDraw = ACE.ArmorDebugCvar and ACE.ArmorDebugCvar:GetBool() or false

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
    local sideU, sideV = basisFromDir(sideDir)

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
                start = startPos,
                endpos = endPos,
                mins = hullMins,
                maxs = hullMaxs,
                filter = filter,
                mask = MASK_SOLID
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
        local size = comp:OBBMaxs() - comp:OBBMins()
        local maxDim = math.max(size.x, size.y, size.z)
        local frontDist = math.max(maxDim * 1.5, 200)
        local sideNear = math.max(maxDim * 0.75, 100)
        local sideFar = math.max(maxDim * 3, 500)
        local sideBack = math.max(maxDim * 0.25, 50)

        local frontArea = projectedData(comp, frontDir)
        local sideArea = projectedData(comp, sideDir)

        local up = comp:GetUp()
        local right = comp:GetRight()

        local halfUp = up * (size.z * 0.5 * 0.95)
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
        local weightS = (sampleCount > 0) and (sideArea / sampleCount) or 0

        for _, pt in ipairs(samples) do
            local frontVal = losFiltered(pt - frontDir * frontDist, pt, comp)
            local sideValA = losFiltered(pt - sideDir * sideNear, pt, comp)
            local sideValB = losFiltered(pt + sideDir * sideFar, pt - sideDir * sideBack, comp)

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
        side = cached.Side or cached.side or 0

        if ACE_IsValidArmorResult(front, side) then
            con.ACEArmorFront = front
            con.ACEArmorSide = side
            usedCache = true
        else
            front, side = 0, 0
            usedCache = false
        end
    end

    if not usedCache and IsEnt(base) then
        front, side = ACE_CalcContraptionArmor(base)
        con.ACEArmorFront = front
        con.ACEArmorSide = side
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

    if ACE_DebugDirty then
        ACE_DebugDirty(con, "armor-scan-complete", base,
            string.format("front=%.2f side=%.2f cache=%s", front or 0, side or 0, tostring(usedCache)),
            "EnsureArmor"
        )
    end
end

_G.ACE_EnsureArmor = ACE_EnsureArmor

