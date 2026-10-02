return {
	WheelPositions = {
		FL = Vector3.new(-5, 0, -4),
		FR = Vector3.new(5, 0, -4),
		BL = Vector3.new(-5, 0, 4),
		BR = Vector3.new(5, 0, 4),
	},

	Suspension = {
		MaxLength = 2.5,
		SpringConstant = 10000,
		Damping = 1500,
	},

	WheelRadius = 1.25,
	WheelFriction = 100,
	Visualizer = true,

	Torque = 1500,
	MaxSpeed = 100,
	SteerAngle = 30,
}
