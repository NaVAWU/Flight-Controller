-- ============================================================
--  config.lua
-- ============================================================

local Config = {}

-- ── ISLAND IDENTITY ─────────────────────────────────────────
Config.ISLAND_ID        = "island_"       -- unique name per island

-- ── FLIGHT PARAMETERS ───────────────────────────────────────
Config.TARGET_ALTITUDE  = 210             -- meters
Config.MAX_SPEED        = 5.0             -- m/s ascent/descent cap
Config.HOLD_DEADBAND    = 0.5             -- meters: stop correcting inside this band
Config.LOOP_INTERVAL    = 0.1             -- seconds between flight loop ticks

-- ── MOTOR ───────────────────────────────────────────────────
Config.MOTOR_DIRECTION  = 1               -- flip to -1 if motor lifts when it should sink
Config.RPM_SCALE        = 1.0             -- multiplier: m/s → RPM (tune per gear ratio)
Config.PRESSURE_FF_MAX  = 3.0             -- max feedforward multiplier (prevents runaway)

-- ── PID TUNING ───────────────────────────────────────────────
-- Start with kI = 0. Tune kP until stable, add kD to dampen,
-- then a small kI to fix residual drift.
Config.PID_KP           = 2.0
Config.PID_KI           = 0.05
Config.PID_KD           = 1.2
Config.PID_INTEGRAL_MAX = 10.0            -- anti-windup clamp

-- ── PERIPHERALS ─────────────────────────────────────────────
Config.SIDE_MOTOR       = "left"
Config.SIDE_RSC         = "right"        -- RotationSpeedController
Config.SIDE_SENSOR      = "back"
Config.SIDE_MODEM       = "top"          -- set to nil to disable networking

-- ── NETWORKING ──────────────────────────────────────────────
Config.REDNET_CHANNEL   = 1234           -- shared across all islands

-- ── HUB TELEMETRY ───────────────────────────────────────────
-- Set HUB_URL to nil to disable telemetry entirely.
Config.HUB_URL          = "ws://your-server:8080/ws"
Config.HUB_TOKEN        = "change_me_to_a_long_random_secret"

return Config
