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

	seat.Massless = true

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
	self.WheelSpin = {}
	self.Steering = self.Model.Body:FindFirstChild("Steering")

	self.Controls = {
		Throttle = 0,
		Steer = 0,
	}

	self.SmoothSteer = 0
	self.Welds = {}
	self.VisualSuspensionLengths = {}

	AddCar(self, model)

	for i, v in pairs(self.Config.WheelPositions) do
		self.SuspensionLengths[i] = self.Config.Suspension.MaxLength
		self.VisualSuspensionLengths[i] = self.Config.Suspension.MaxLength
		self.WheelSpin[i] = 0

		local wheel = self.Model.Wheels:FindFirstChild(i)

		if wheel then
			wheel.Massless = true
			wheel.CanCollide = false
			wheel.CanTouch = false

			local weld = wheel:FindFirstChild(i .. "Weld")

			if not weld then
				if RunService:IsServer() then
					weld = Instance.new("Weld")
					weld.Name = i .. "Weld"
					weld.Part0 = self.Chassis
					weld.Part1 = wheel
					weld.C0 = CFrame.new(v)
					weld.C1 = CFrame.Angles(0, 0, (string.sub(i, 2, 2) == "R" and 1 or -1) * math.rad(90))
					weld.Parent = wheel
				else
					weld = wheel:WaitForChild(i .. "Weld")
				end
			end

			self.Welds[i] = weld
		end
	end

	AllCars[self.Model] = self

	if RunService:IsServer() then
		self:Start()
	end

	return self
end

function VehicleSimulation:Step(dt: number)
	if dt <= 0 then
		return
	end

	local wheelCount = 0
	for _ in self.Config.WheelPositions do
		wheelCount += 1
	end
	local massPerWheel = self.Chassis.AssemblyMass / math.max(1, wheelCount)
	local throttle = self.Controls.Throttle
	local hasThrottle = math.abs(throttle) >= 0.01
	local chassisForwardSpeed = self.Chassis.AssemblyLinearVelocity:Dot(self.Chassis.CFrame.LookVector)
	local isBraking = hasThrottle
		and throttle * chassisForwardSpeed < 0
		and math.abs(chassisForwardSpeed) > self.Config.ReverseEngageSpeed
	local seat = self.Model:FindFirstChild("VehicleSeat")
	local isUnoccupied = not seat or seat.Occupant == nil

	self.SmoothSteer = math.abs(self.Controls.Steer - self.SmoothSteer) <= dt * 5 and self.Controls.Steer
		or self.SmoothSteer + math.sign(self.Controls.Steer - self.SmoothSteer) * dt * 5

	if self.Steering then
		--	self.Steering:PivotTo(self.Steering:GetPivot() * CFrame.Angles(math.rad(75 * self.Controls.Steer), 0, 0))
	end

	for wheelName, ogPosition in pairs(self.Config.WheelPositions) do
		local rayOrigin = self.Chassis.CFrame:ToWorldSpace(CFrame.new(ogPosition))
		local direction = -self.Chassis.CFrame.UpVector * (self.Config.Suspension.MaxLength + self.Config.WheelRadius)

		local raycast = workspace:Raycast(rayOrigin.Position, direction, self.RayCastParams)

		local springLength

		if raycast then
			local raycastDistance = (rayOrigin.Position - raycast.Position).Magnitude

			springLength = math.clamp(raycastDistance - self.Config.WheelRadius, 0, self.Config.Suspension.MaxLength)

			local suspensionForce = self.Config.Suspension.SpringConstant
				* (self.Config.Suspension.MaxLength - springLength)

			local groundVelocity = Vector3.zero
			if raycast.Instance:IsA("BasePart") then
				groundVelocity = raycast.Instance:GetVelocityAtPosition(raycast.Position)
			end
			local contactVelocity = self.Chassis:GetVelocityAtPosition(raycast.Position) - groundVelocity
			local damping = isUnoccupied and self.Config.Suspension.IdleDamping or self.Config.Suspension.Damping

			damping = math.min(damping, massPerWheel / dt)
			local damperForce = -contactVelocity.Y * damping

			suspensionForce = Vector3.yAxis
				* math.clamp(suspensionForce + damperForce, 0, self.Config.Suspension.MaxForce)

			local RotationOnlyWheelDirCFrame =
				CFrame.lookAt(Vector3.zero, self.Chassis.CFrame.LookVector, self.Chassis.CFrame.UpVector)

			if string.sub(wheelName, 1, 1) == "F" then
				RotationOnlyWheelDirCFrame *= CFrame.Angles(0, -math.rad(self.SmoothSteer * self.Config.SteerAngle), 0)
			end

			local wheelForward = RotationOnlyWheelDirCFrame.LookVector
			local groundForward = wheelForward - raycast.Normal * wheelForward:Dot(raycast.Normal)
			if groundForward.Magnitude > 0.001 then
				RotationOnlyWheelDirCFrame = CFrame.lookAt(Vector3.zero, groundForward.Unit, raycast.Normal)
			end
			local LocalVelocity = RotationOnlyWheelDirCFrame:VectorToObjectSpace(contactVelocity)

			local forwardSpeed = -LocalVelocity.Z
			local angularVelocity = forwardSpeed / self.Config.WheelRadius

			self.WheelSpin[wheelName] += angularVelocity * dt

			local XForce = Vector3.zero

			do
				local lateralLimit =
					math.min(self.Config.MaxLateralForce, math.abs(LocalVelocity.X) * massPerWheel / dt)
				local lateralForce =
					math.clamp(-LocalVelocity.X * self.Config.LateralFriction, -lateralLimit, lateralLimit)

				XForce = RotationOnlyWheelDirCFrame.RightVector * lateralForce
			end

			local ZForce = Vector3.zero
			local ThrottleForce = Vector3.zero

			if isBraking or not hasThrottle then
				local resistance
				if isBraking then
					resistance = self.Config.BrakeForce * math.abs(throttle)
				else
					resistance = math.min(
						self.Config.CoastBrakeForce + math.abs(forwardSpeed) * self.Config.RollingResistance,
						self.Config.MaxRollingForce
					)
				end
				local stopForce = math.abs(forwardSpeed) * massPerWheel / dt
				ZForce = -RotationOnlyWheelDirCFrame.LookVector
					* math.sign(forwardSpeed)
					* math.min(resistance, stopForce)
			else
				ThrottleForce = RotationOnlyWheelDirCFrame.LookVector
					* throttle
					* self.Config.Torque
					* (1 - math.min(1, math.abs(forwardSpeed) / self.Config.MaxSpeed))

				if throttle < 0 then
					ThrottleForce *= 0.6
				end
			end

			self.SuspensionLengths[wheelName] = springLength

			self.Chassis:ApplyImpulseAtPosition(
				(suspensionForce + XForce + ZForce + ThrottleForce) * dt,
				raycast.Position
			)
		else
			springLength = self.Config.Suspension.MaxLength

			self.SuspensionLengths[wheelName] = self.Config.Suspension.MaxLength
		end

		local alpha = 1 - math.exp(-15 * dt)

		local visualLength = self.VisualSuspensionLengths[wheelName]

		visualLength += (springLength - visualLength) * alpha

		self.VisualSuspensionLengths[wheelName] = visualLength

		local weld = self.Welds[wheelName]

		if weld then
			local steerAngle = 0

			if string.sub(wheelName, 1, 1) == "F" then
				steerAngle = -math.rad(self.Config.SteerAngle * self.SmoothSteer)
			end

			weld.C0 = CFrame.new(ogPosition)
				* CFrame.new(0, -visualLength, 0)
				* CFrame.Angles(0, steerAngle, 0)
				* CFrame.Angles(-self.WheelSpin[wheelName], 0, 0)
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
	self.Controls.Throttle = 0
	self.Controls.Steer = 0
	ExistingCarsInContext[self.Model] = self
end

function VehicleSimulation:Stop()
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
		if RunService:IsClient() then
			local seat = car.Model:FindFirstChild("VehicleSeat")

			if seat then
				car.Controls.Throttle = seat.ThrottleFloat

				car.Controls.Steer = seat.SteerFloat
			end
		end

		car:Step(dt)
	end
end)

return VehicleSimulation
