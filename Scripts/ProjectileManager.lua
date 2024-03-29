dofile "$CONTENT_DATA/Scripts/util.lua"

---@class ProjectileManager : ToolClass
ProjectileManager = class()
ProjectileManager.lineStats = {
	thickness = 0.35,
	colour_weak = sm.color.new(0,1,1),
	colour_strong = sm.color.new(0.75,0,0), --sm.color.new(1,0,0),
	spinSpeed = 250
}
ProjectileManager.laserSpeed = 50
ProjectileManager.laserLength = 0.75
ProjectileManager.laserDamage = 100
ProjectileManager.strongLength = 1000
ProjectileManager.explodeStats = {
	level = 8,
	destRadius = 10,
	impRadius = 25,
	magnitude = 125,
	effect = "PropaneTank - ExplosionBig"
}
ProjectileManager.killTypes = {
	terrainSurface = true,
	terrainAsset = true,
	limiter = true
}

--Hook
local gameHooked = false
local oldHud = sm.gui.createSurvivalHudGui
function hudHook()
    if not gameHooked then
        dofile("$CONTENT_a898c2c4-de95-4899-9442-697ced66b832/Scripts/vanilla_override.lua")
        gameHooked = true
    end

	return oldHud()
end
sm.gui.createSurvivalHudGui = hudHook

local oldBind = sm.game.bindChatCommand
function bindHook(command, params, callback, help)
    if not gameHooked then
        dofile("$CONTENT_a898c2c4-de95-4899-9442-697ced66b832/Scripts/vanilla_override.lua")
        gameHooked = true
    end

	return oldBind(command, params, callback, help)
end
sm.game.bindChatCommand = bindHook

function ProjectileManager:server_onCreate()
    g_pManager = self.tool

    self.sv_host = true
end

function ProjectileManager:sv_createProjectile(args)
	local strong = args.strong
	if strong and args.noHitscan ~= true then
		local dir = args.dir
		local pos = args.pos
		local hit, result = sm.physics.raycast( pos, pos + dir * self.strongLength, args.owner )
		if hit then
			local hitPos = result.pointWorld
			local stats = self.explodeStats

			sm.physics.explode(
				hitPos,
				stats.level,
				stats.destRadius,
				stats.impRadius,
				stats.magnitude,
				stats.effect
			)

			args.hitPos = hitPos
		end
	end

    self.network:sendToClients("cl_createProjectile", args)
end

function ProjectileManager:sv_onOverdriveLaserHit( pos )
	sm.physics.explode( pos, 5, 2.5, 5, 50, "PropaneTank - ExplosionSmall" )
end

function ProjectileManager:sv_onWeakLaserHit( args )
	local result = args.ray
	---@type Shape|Character|Harvestable
	local target = result.target
	if not target or not sm.exists(target) then return end

	local pos = result.pointWorld
	local type = type(target)

	if type == "Shape" then
		local data = sm.item.getFeatureData(target.uuid)
		if data and data.classname == "Package" then
			sm.event.sendToInteractable( target.interactable, "sv_e_open" )
		else
			sm.effect.playEffect(
				"Sledgehammer - Destroy", pos, vec3_zero,
				sm.vec3.getRotation( vec3_up, result.normalWorld ), vec3_one,
				{ Material = target.materialId, Color = target.color }
			)

			if sm.item.isBlock( target.uuid ) then
				target:destroyBlock( target:getClosestBlockLocalPosition(pos) )
			else
				target:destroyShape()
			end
		end
	elseif type == "Character" then
		sm.projectile.projectileAttack(
			projectile_cutter,
			self.laserDamage,
			pos,
			(target.worldPosition - pos),
			self.tool:getOwner()
		)
	else
		sm.physics.explode( pos, 3, 1, 1, 1 )
	end
end



function ProjectileManager:client_onCreate()
    self.cl_projectiles = {}
end

---@param args LaserProjectile
function ProjectileManager:cl_createProjectile(args)
    local dir = args.dir
	local strong = args.strong
	local hitPos = args.hitPos
	local overdrive = args.overdrive

	local tool = args.tool
	local pos
	if tool then
		pos = tool:isInFirstPersonView() and tool:getFpBonePos("pipe") or tool:getTpBonePos("pipe")
	else
		pos = args.pos
	end

	local laser = {
		line = Line_gun(),
		pos = pos,
		dir = strong and (hitPos and hitPos - pos or dir * self.strongLength) or dir,
		strong = strong,
		overdrive = overdrive,
		owner = args.owner,
		lifeTime = 15,
	}

	local colour =  (strong or overdrive) and self.lineStats.colour_strong or self.lineStats.colour_weak
	laser.line:init( self.lineStats.thickness, colour, strong )
	laser.line:update( pos, pos + laser.dir * self.laserLength, 0.16 )
	self.cl_projectiles[#self.cl_projectiles+1] = laser
end

function ProjectileManager:client_onUpdate(dt)
    for k, laser in pairs(self.cl_projectiles) do
		laser.lifeTime = laser.lifeTime - dt

        local owner = laser.owner
		local currentPos, dir = laser.pos, laser.dir
		local hit, result = false, {}
		if not laser.strong then
			if sm.exists(owner) then
				hit, result = sm.physics.raycast( currentPos, currentPos + dir * sm.util.clamp(dt * 50, 1, 2), owner )
			else
				hit, result = sm.physics.raycast( currentPos, currentPos + dir * sm.util.clamp(dt * 50, 1, 2))
			end
		end

		local shouldDelete = self.killTypes[result.type] == true or laser.lifeTime <= 0 or laser.line.thickness == 0
		if hit or shouldDelete then
			if self.sv_host == true and hit then
				if laser.overdrive then
					self.network:sendToServer("sv_onOverdriveLaserHit", result.pointWorld )
				elseif not shouldDelete then
					self.network:sendToServer("sv_onWeakLaserHit",
						{
							ray = RayResultToTable(result),
							dir = laser.dir,
							normal = result.normalWorld
						}
					)
				end
			end

			if shouldDelete or laser.overdrive then
				laser.line:destroy()

				if not laser.strong then
					sm.effect.playEffect(
						"Laser_hit", hit and result.pointWorld or currentPos + dir * self.laserLength,
						vec3_zero, defaultQuat, vec3_one,
						{ Color = laser.line.colour }
					)
				end

				self.cl_projectiles[k] = nil
			end
		end

		if not shouldDelete then
			if laser.strong then
				laser.line:update(currentPos, currentPos + dir, dt)
			else
				local newPos = currentPos + dir * dt * self.laserSpeed * (hit and 0.1 or 1)
				laser.pos = newPos
				laser.line:update(newPos, newPos + dir * self.laserLength, dt)
			end
		end
	end
end