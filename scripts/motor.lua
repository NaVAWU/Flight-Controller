-- ============================================================
--  motor.lua
--  Abstraction for the electric_motor + Create_RotationSpeedController.
--  All speed values passed in are m/s; conversion to RPM happens here.
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Motor = {}

local _motor = nil
local _rsc   = nil

-- Initialise and validate both peripherals
function Motor.init()
    _motor = peripheral.wrap(Config.SIDE_MOTOR)
    _rsc   = peripheral.wrap(Config.SIDE_RSC)
    assert(_motor, "No electric_motor found on side: "   .. Config.SIDE_MOTOR)
    assert(_rsc,   "No RotationSpeedController found on: " .. Config.SIDE_RSC)
    print("[Motor] electric_motor + RSC online.")
end

-- Set motor to a desired velocity in m/s.
-- Applies pressure feedforward so commands mean the same thing at any altitude.
function Motor.setSpeed(mps, state)
    local compensation = Sensors.pressureCompensation(state)
    local rpm = mps
              * compensation
              * Config.RPM_SCALE
              * Config.MOTOR_DIRECTION

    _rsc.setTargetSpeed(rpm)
    _motor.rotate()
end

-- Bring the motor to a safe stop
function Motor.stop()
    _rsc.setTargetSpeed(0)
    _motor.stop()
end

return Motor
