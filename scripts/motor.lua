-- ============================================================
--  motor.lua
--  Abstraction for the Create electric_motor peripheral.
--  Speed is set directly on the motor in the range -256..256.
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Motor = {}

local _motor = nil

function Motor.init()
    _motor = peripheral.wrap(Config.SIDE_MOTOR)
    assert(_motor, "No electric_motor found on side: " .. Config.SIDE_MOTOR)
    print("[Motor] electric_motor online.")
end

-- Set motor speed. Applies pressure feedforward and clamps to -256..256.
function Motor.setSpeed(speed, state)
    local compensation = Sensors.pressureCompensation(state)
    local out = speed * compensation * Config.MOTOR_DIRECTION
    out = math.max(-256, math.min(256, out))
    _motor.setSpeed(out)
end

-- Bring the motor to a stop
function Motor.stop()
    _motor.setSpeed(0)
end

return Motor
