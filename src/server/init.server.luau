local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VehicleSimulation = require(ReplicatedStorage.Shared.Vehicles.VehicleSimulation)
local vehicleFolder = ReplicatedStorage.Shared.Vehicles
local Config = vehicleFolder.Config

local car = VehicleSimulation.new(workspace.BaseCar)
car:Start()
