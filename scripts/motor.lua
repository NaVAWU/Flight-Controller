-- ============================================================
--  motor.lua
--  Abstraction for the Create electric_motor peripheral.
--  Speed is set directly on the motor in the range -256..256.
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Motor = {}

local _motors = {}

function Motor.init()
    for _, side in ipairs(Config.MOTORS) do
        local m = peripheral.wrap(side)
        assert(m, "No electric_motor found on side: " .. side)
        _motors[#_motors + 1] = m
    end
    print(("[Motor] %d electric_motor(s) online."):format(#_motors))
end

-- Set all motors to the same speed. Applies pressure feedforward and clamps to -256..256.
function Motor.setSpeed(speed, state)
    local compensation = Sensors.pressureCompensation(state)
    local out = speed * compensation * Config.MOTOR_DIRECTION
    out = math.max(-256, math.min(256, out))
    for _, m in ipairs(_motors) do m.setSpeed(out) end
end

-- Bring all motors to a stop
function Motor.stop()
    for _, m in ipairs(_motors) do m.setSpeed(0) end
end

return Motor
