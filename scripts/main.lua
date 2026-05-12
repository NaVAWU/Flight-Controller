-- ============================================================
--  main.lua
-- ============================================================

local Config  = require("config")
local State   = require("state")
local PID     = require("pid")
local Sensors = require("sensors")
local Motor   = require("motor")
local Network = require("network")

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

-- ── HELPERS ──────────────────────────────────────────────────

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local _lastLogSecond = -1

local function logStatus()
    local s = math.floor(os.clock())
    if s == _lastLogSecond then return end
    _lastLogSecond = s
    print(("[%s] Alt: %.1fm | Target: %dm | Mode: %s"):format(
        Config.ISLAND_ID,
        State.currentAltitude,
        State.targetAltitude,
        State.mode))
end

-- ── FLIGHT LOOP ──────────────────────────────────────────────

local function flightLoop()
    print(("[FC] Flight loop started. Target: %dm"):format(State.targetAltitude))
    local lastTime = os.clock()

    while State.running do
        local now = os.clock()
        local dt  = now - lastTime
        lastTime  = now

        -- Read sensors
        State.currentAltitude = Sensors.getHeight()
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
            Motor.stop()
        else
            local raw     = controller:update(error, dt)
            local desired = clamp(raw, -Config.MAX_SPEED, Config.MAX_SPEED)
            Motor.setSpeed(desired, State)
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

-- ── RUN ──────────────────────────────────────────────────────

parallel.waitForAll(flightLoop, networkLoop)
print("Flight controller shut down cleanly.")
