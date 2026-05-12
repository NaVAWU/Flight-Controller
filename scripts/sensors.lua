-- ============================================================
--  sensors.lua
--  Wraps the altitude_sensor peripheral.
--  Handles pressure calibration and feedforward computation.
-- ============================================================

local Config = require("config")

local Sensors = {}

local _sensor = nil

-- Initialise and validate the sensor peripheral
function Sensors.init()
    _sensor = peripheral.wrap(Config.SIDE_SENSOR)
    assert(_sensor, "No altitude_sensor found on side: " .. Config.SIDE_SENSOR)
    print("[Sensors] altitude_sensor online.")
end

-- Returns current altitude in metres
function Sensors.getHeight()
    return _sensor.getHeight()
end

-- Returns current air pressure (units depend on mod — assumed hPa)
function Sensors.getAirPressure()
    return _sensor.getAirPressure()
end

-- Calibrates the sea-level reference pressure from the current reading.
-- Call this once at startup (ideally at ground level).
function Sensors.calibrate(state)
    local pressure = _sensor.getAirPressure()
    state.seaLevelPressure = pressure
    print(("[Sensors] Calibrated sea-level pressure: %.4f"):format(pressure))
end

-- Returns the island's vertical velocity in m/s (positive = upward).
-- Uses the sublevel API from CC: Sable. Returns 0 if not on a sub-level.
function Sensors.getVerticalVelocity()
    if not sublevel.isInPlotGrid() then return 0 end
    return sublevel.getLinearVelocity().y
end

-- Returns a feedforward multiplier > 1.0 at altitude.
-- At sea level → 1.0. At lower pressure → proportionally higher.
-- Compensates for reduced lift efficiency in thinner air.
function Sensors.pressureCompensation(state)
    if not state.seaLevelPressure then
        return 1.0   -- not yet calibrated; no compensation
    end

    local pressure = _sensor.getAirPressure()

    if pressure <= 0 then
        return Config.PRESSURE_FF_MAX   -- sensor error guard
    end

    local ratio = state.seaLevelPressure / pressure
    return math.max(1.0, math.min(Config.PRESSURE_FF_MAX, ratio))
end

return Sensors
