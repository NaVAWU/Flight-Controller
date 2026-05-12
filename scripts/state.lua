-- ============================================================
--  state.lua
--  Single shared state table passed between modules.
--  Avoids globals while keeping everything accessible.
-- ============================================================

local Config = require("config")

local State = {
    -- Flight
    targetAltitude    = Config.TARGET_ALTITUDE,
    currentAltitude   = 0,
    mode              = "IDLE",   -- IDLE | ASCENT | HOLD | DESCENT

    -- Sensor calibration
    seaLevelPressure  = nil,      -- set on first sensor read

    -- Lifecycle
    running           = true,
}

return State
