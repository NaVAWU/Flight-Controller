-- ============================================================
--  main.lua
-- ============================================================

local Config    = require("config")
local State     = require("state")
local PID       = require("pid")
local Sensors   = require("sensors")
local Motor     = require("motor")
local Network   = require("network")
local Telemetry = require("telemetry")

-- ── INITIALISE ───────────────────────────────────────────────

print("============================================")
print((" Flight Controller — %s"):format(Config.ISLAND_ID))
print("============================================")

Sensors.init()
Motor.init()

-- Calibrate pressure reference at current position
Sensors.calibrate(State)

-- Build PID controller
local controller = PID.new(
    Config.PID_KP,
    Config.PID_KI,
    Config.PID_KD,
    Config.PID_INTEGRAL_MAX
)

-- Networking (passes PID so SET_ALTITUDE can reset it)
Network.init(controller)

-- Telemetry (passes PID so hub SET_ALTITUDE can reset it)
Telemetry.init(controller)

-- ── HELPERS ──────────────────────────────────────────────────

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function saveHoverRSC(value)
    local f = fs.open("config.lua", "r")
    if not f then return end
    local src = f.readAll(); f.close()
    local result, n = src:gsub(
        "Config%.HOVER_RSC%s*=[^\n]*",
        "Config.HOVER_RSC = " .. tostring(value))
    if n == 0 then
        result = result:gsub(
            "return Config",
            "Config.HOVER_RSC = " .. tostring(value) .. "\nreturn Config")
    end
    local g = fs.open("config.lua", "w")
    if not g then
        print("[TRIM] ERROR: could not write config.lua — trim not saved")
        return
    end
    g.write(result); g.close()
end

local _lastLogSecond = -1

local function logStatus()
    local s = math.floor(os.clock())
    if s == _lastLogSecond then return end
    _lastLogSecond = s
    print(("[%s] Alt: %.1fm | Target: %dm | Vel: %+.2fm/s | Mode: %s"):format(
        Config.ISLAND_ID,
        State.currentAltitude,
        State.targetAltitude,
        State.currentVelocity,
        State.mode))
end

-- ── FLIGHT LOOP ──────────────────────────────────────────────

local _steadyStart = nil
local TRIM_WINDOW  = 20                      -- seconds of steady state before trimming
local TRIM_MAX     = 15                      -- RSC: sanity cap on trim delta
local TRIM_VEL     = 0.1                     -- m/s: max velocity to qualify as steady
local TRIM_ERR     = Config.HOLD_DEADBAND * 2  -- metres: max error to qualify as steady

local function flightLoop()
    print(("[FC] Flight loop started. Target: %dm"):format(State.targetAltitude))
    local lastTime = os.clock()

    while State.running do
        local now = os.clock()
        local dt  = now - lastTime
        lastTime  = now

        -- Read sensors
        State.currentAltitude  = Sensors.getHeight()
        State.currentVelocity  = Sensors.getVerticalVelocity()
        local error  = State.targetAltitude - State.currentAltitude
        local absErr = math.abs(error)

        -- Update flight mode label
        if absErr <= Config.HOLD_DEADBAND then
            State.mode = "HOLD"
        elseif error > 0 then
            State.mode = "ASCENT"
        else
            State.mode = "DESCENT"
        end

        -- Compute and apply motor command
        if absErr <= Config.HOLD_DEADBAND then
            Motor.setSpeed(0, State)   -- hover in place; stop() would cut thrust and drop the island
        else
            local raw     = controller:update(error, dt)
            local desired = clamp(raw, -Config.MAX_RSC_SPEED, Config.MAX_RSC_SPEED)
            Motor.setSpeed(desired, State)
        end

        -- Trim learning: once the island has been steady for TRIM_WINDOW seconds,
        -- fold the I-term into HOVER_RSC so the integral starts fresh next flight.
        local trimEligible = absErr < TRIM_ERR
                          and math.abs(State.currentVelocity) < TRIM_VEL
        if trimEligible then
            if not _steadyStart then _steadyStart = now end
            if now - _steadyStart >= TRIM_WINDOW then
                local delta = Config.PID_KI * controller._integral
                if math.abs(delta) > TRIM_MAX then
                    print(("[TRIM] delta %.2f exceeds limit — skipping"):format(delta))
                else
                    local saved = math.floor(Config.HOVER_RSC + delta + 0.5)
                    Config.HOVER_RSC = saved
                    controller:reset()
                    saveHoverRSC(saved)
                    print(("[TRIM] HOVER_RSC updated to %d (delta %+.2f)"):format(saved, delta))
                end
                _steadyStart = nil
            end
        else
            _steadyStart = nil
        end

        logStatus()
        sleep(Config.LOOP_INTERVAL)
    end

    Motor.stop()
    print("[FC] Flight loop stopped.")
end

-- ── NETWORK LOOP ─────────────────────────────────────────────

local function networkLoop()
    if not Network.isAvailable() then return end
    print("[NET] Network loop started.")
    while State.running do
        Network.poll(State)
        sleep(0)   -- yield without delaying
    end
    print("[NET] Network loop stopped.")
end

-- ── TELEMETRY LOOP ───────────────────────────────────────────

local function telemetryLoop()
    if not Config.HUB_URL then return end
    print("[TEL] Telemetry loop started.")
    while State.running do
        Telemetry.tick(State)
    end
    Telemetry.close()
    print("[TEL] Telemetry loop stopped.")
end

-- ── RUN ──────────────────────────────────────────────────────

parallel.waitForAll(flightLoop, networkLoop, telemetryLoop)
print("Flight controller shut down cleanly.")
