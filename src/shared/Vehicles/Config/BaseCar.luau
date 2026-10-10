return {
	WheelPositions = {
		FL = Vector3.new(-4.5, -1, -9.5),
		FR = Vector3.new(4.5, -1, -9.5),
		BL = Vector3.new(-4.5, -1, 8),
		BR = Vector3.new(4.5, -1, 8),
	},

	Suspension = {
		MaxLength = 2.5,
		SpringConstant = 11000,
		Damping = 500,
		IdleDamping = 1400,
		MaxForce = 25000,
	},

	WheelRadius = 4.476 / 2,

	LateralFriction = 120,
	RollingResistance = 0,
	CoastBrakeForce = 100,
	BrakeForce = 2400,
	ReverseEngageSpeed = 0.5,
	MaxLateralForce = 8000,
	MaxRollingForce = 600,

	Visualizer = false,

	Torque = 2000,
	MaxSpeed = 150,
	SteerAngle = 30,
}
