-- ============================================================
--  motor.lua
--  Abstraction for the Create rotational_speed_controller.
--  Speed is set in the range -256..256 (negative = descent).
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Motor = {}

local _rsc = nil

function Motor.init()
    _rsc = peripheral.wrap(Config.RSC)
    assert(_rsc, "No rotational_speed_controller found on side: " .. Config.RSC)
    print("[Motor] RotationalSpeedController online.")
end

-- Set RSC speed. Adds hover feedforward, applies pressure compensation, and clamps.
function Motor.setSpeed(speed, state)
    local compensation = Sensors.pressureCompensation(state)
    local lim = Config.MAX_RSC_SPEED
    local out = math.max(-lim, math.min(lim, (speed + Config.HOVER_RSC) * compensation))
    _rsc.setTargetSpeed(out)
end

-- Bring the RSC to a stop
function Motor.stop()
    _rsc.setTargetSpeed(0)
end

return Motor
