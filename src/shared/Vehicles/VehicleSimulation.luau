local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Config = ReplicatedStorage.Shared.Vehicles.Config

local VehicleSimulation = {}
VehicleSimulation.__index = VehicleSimulation
local AllCars = {}
local ExistingCarsInContext = {}

local function AddCar(self, obj)
	if not RunService:IsServer() then
		return
	end
	obj.PrimaryPart:SetNetworkOwner(nil)

	local seat = obj:FindFirstChild("VehicleSeat")
	if not seat then
		self:Stop()
		self.Model:Destroy()
		return
	end

	self.Janitor:Add(seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = seat.Occupant
		if occ then
			local player = Players:GetPlayerFromCharacter(occ.Parent)
			if player then
				self:Stop()
				obj.PrimaryPart:SetNetworkOwner(player)
				self.Driver = player
				Remotes.VehicleAction:FireClient(player, self.Model, "Start")
			else
				obj.PrimaryPart:SetNetworkOwner(nil)
				self:Start()
			end
		else
			if self.Driver then
				Remotes.VehicleAction:FireClient(self.Driver, self.Model, "Stop")
			end
			self.Driver = nil
			obj.PrimaryPart:SetNetworkOwner(nil)
			self:Start()
		end
	end))
end

function VehicleSimulation.new(model: Model)
	local root = model.PrimaryPart

	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = { model }

	local config = Config:FindFirstChild(model.Name)

	assert(config, `Config not found for {model.Name}`)

	local self = setmetatable({}, VehicleSimulation)

	self.Chassis = root
	self.Model = model
	self.Driver = nil
	self.Config = require(config)
	self.SuspensionLengths = {}
	self.RayCastParams = Params
	self.Janitor = Janitor.new()
	self.Visualizers = {}

	self.Controls = {
		Throttle = 0,
		Steer = 0,
	}

	self.SmoothSteer = 0

	AddCar(self, model)

	for i, _v in pairs(self.Config.WheelPositions) do
		self.SuspensionLengths[i] = self.Config.Suspension.MaxLength
	end

	AllCars[self.Model] = self

	return self
end

function VehicleSimulation:Step(dt: number)
	self.SmoothSteer = math.abs(self.Controls.Steer - self.SmoothSteer) <= dt * 5 and self.Controls.Steer
		or self.SmoothSteer + math.sign(self.Controls.Steer - self.SmoothSteer) * dt * 5

	for wheelName, ogPosition in pairs(self.Config.WheelPositions) do
		local rayOrigin = self.Chassis.CFrame:ToWorldSpace(CFrame.new(ogPosition))
		local direction = -self.Chassis.CFrame.UpVector * (self.Config.Suspension.MaxLength + self.Config.WheelRadius)

		local raycast = workspace:Raycast(rayOrigin.Position, direction, self.RayCastParams)

		if raycast then
			local raycastDistance = (rayOrigin.Position - raycast.Position).Magnitude

			local springLength =
				math.clamp(raycastDistance - self.Config.WheelRadius, 0, self.Config.Suspension.MaxLength)
			local suspensionForce = self.Config.Suspension.SpringConstant
				* (self.Config.Suspension.MaxLength - springLength)
			local damperForce = self.Config.Suspension.Damping
				* ((self.SuspensionLengths[wheelName] - springLength) / dt)
			suspensionForce = self.Chassis.CFrame.UpVector * (suspensionForce + damperForce)

			local RotationOnlyWheelDirCFrame =
				CFrame.lookAt(Vector3.zero, self.Chassis.CFrame.LookVector, self.Chassis.CFrame.UpVector)

			if string.sub(wheelName, 1, 1) == "F" then
				RotationOnlyWheelDirCFrame *= CFrame.Angles(0, -math.rad(self.SmoothSteer * self.Config.SteerAngle), 0)
			end
			local LocalVelocity = RotationOnlyWheelDirCFrame:ToObjectSpace(
				CFrame.new(self.Chassis:GetVelocityAtPosition(raycast.Position))
			)
			local XForce = self.Chassis.CFrame.RightVector * -LocalVelocity.X * self.Config.WheelFriction
			local ZForce = self.Controls.Throttle == 0
					and self.Chassis.CFrame.LookVector * LocalVelocity.Z * (self.Config.WheelFriction / 4)
				or Vector3.zero
			local ThrottleForce = self.Chassis.CFrame.LookVector
				* self.Controls.Throttle
				* self.Config.Torque
				* (1 - math.min(1, math.abs(LocalVelocity.Z) / self.Config.MaxSpeed))

			if math.sign(self.Controls.Throttle) == -1 then
				ThrottleForce *= 0.6
			end

			self.SuspensionLengths[wheelName] = springLength

			self.Chassis:ApplyImpulseAtPosition(
				(suspensionForce + XForce + ZForce + ThrottleForce) * dt,
				raycast.Position
			)
		end

		if self.Config.Visualizer and RunService:IsClient() then
			local origin = rayOrigin.Position
			local down = -self.Chassis.CFrame.UpVector

			local suspensionLength

			if raycast then
				local raycastDistance = (raycast.Position - origin).Magnitude

				suspensionLength =
					math.clamp(raycastDistance - self.Config.WheelRadius, 0, self.Config.Suspension.MaxLength)
			else
				suspensionLength = self.Config.Suspension.MaxLength
			end

			local suspensionEnd = origin + down * suspensionLength
			local wheelEnd = suspensionEnd + down * self.Config.WheelRadius

			local function updateStick(name: string, startPosition: Vector3, endPosition: Vector3, color: Color3)
				local key = wheelName .. name
				local stick = self.Visualizers[key]

				if not stick then
					stick = Instance.new("Part")
					stick.Name = name
					stick.Anchored = true
					stick.CanCollide = false
					stick.CanQuery = false
					stick.CanTouch = false
					stick.Material = Enum.Material.Neon
					stick.Color = color
					stick.Parent = workspace

					self.Visualizers[key] = stick
					self.Janitor:Add(stick)
				end

				local length = (endPosition - startPosition).Magnitude

				if length <= 0.001 then
					stick.Transparency = 1
					return
				end

				stick.Transparency = 0

				local midpoint = startPosition:Lerp(endPosition, 0.5)

				stick.Size = Vector3.new(0.08, 0.08, length)
				stick.CFrame = CFrame.lookAt(midpoint, endPosition)
			end

			updateStick("SuspensionVisualizer", origin, suspensionEnd, Color3.new(0, 0.5, 1))

			updateStick("WheelRadiusVisualizer", suspensionEnd, wheelEnd, Color3.new(1, 0, 0))
		end
	end
end

function VehicleSimulation:Start()
	ExistingCarsInContext[self.Model] = self
end

function VehicleSimulation:Stop()
	print(ExistingCarsInContext[self.Model])
	if ExistingCarsInContext[self.Model] then
		ExistingCarsInContext[self.Model] = nil
	end
end

function VehicleSimulation:Destroy()
	self:Stop()
	if AllCars[self.Model] then
		AllCars[self.Model] = nil
	end
	self.Janitor:Destroy()
end

if RunService:IsClient() then
	Remotes.VehicleAction.OnClientEvent:Connect(function(model, action)
		if action == "Start" then
			local car = AllCars[model] or VehicleSimulation.new(model)
			car:Start()
		end

		if action == "Stop" then
			local car = ExistingCarsInContext[model]
			if car then
				car:Stop()
			end
		end
	end)
end

RunService.PreSimulation:Connect(function(dt)
	for _, car in ExistingCarsInContext do
		car:Step(dt)

		if RunService:IsClient() then
			local seat = car.Model:FindFirstChild("VehicleSeat")

			if seat then
				car.Controls.Throttle = seat.ThrottleFloat
				car.Controls.Steer = seat.SteerFloat
			end
		end
	end
end)

return VehicleSimulation
