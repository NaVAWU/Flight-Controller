-- ============================================================
--  telemetry.lua
--  Streams island status to the central WebSocket hub and
--  handles commands sent back from the server (SET_ALTITUDE,
--  SHUTDOWN). Call Telemetry.init(controller) once, then
--  Telemetry.tick(state) in a loop (blocks ~1s per call).
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Telemetry = {}

local _ws  = nil
local _pid = nil   -- injected so SET_ALTITUDE can reset it

local function connect()
    local ws, err = http.websocket(Config.HUB_URL, {
        ["Authorization"] = "Bearer " .. Config.HUB_TOKEN,
    })
    if ws then
        _ws = ws
        print("[TEL] Connected to hub.")
        return true
    end
    print("[TEL] Connection failed: " .. tostring(err))
    return false
end

-- ── Command handlers ─────────────────────────────────────────

local _cmdHandlers = {}

_cmdHandlers["SET_ALTITUDE"] = function(msg, state)
    if type(msg.target) ~= "number" then return end
    print(("[TEL] SET_ALTITUDE → %dm"):format(msg.target))
    state.targetAltitude = msg.target
    if _pid then _pid:reset() end
end

_cmdHandlers["SHUTDOWN"] = function(msg, state)
    print("[TEL] SHUTDOWN received from hub.")
    state.running = false
end

local function handleMessage(raw, state)
    local ok, msg = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(msg) ~= "table" then return end
    if msg.ok then return end   -- ack from server, ignore
    if type(msg.cmd) ~= "string" then return end
    local handler = _cmdHandlers[msg.cmd]
    if handler then
        handler(msg, state)
    else
        print(("[TEL] Unknown command: %s"):format(msg.cmd))
    end
end

-- Drain all incoming messages for `timeout` seconds.
-- Uses a timer event so multiple messages in quick succession are never missed.
local function drainMessages(state, timeout)
    local timer = os.startTimer(timeout)
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "websocket_message" then
            handleMessage(ev[3], state)
        elseif ev[1] == "websocket_closed" then
            _ws = nil
            break
        elseif ev[1] == "timer" and ev[2] == timer then
            break
        end
    end
end

-- ── Public API ────────────────────────────────────────────────

-- Call once at startup, passing the PID controller so SET_ALTITUDE can reset it.
function Telemetry.init(pidController)
    _pid = pidController
    if Config.HUB_URL then connect() end
end

function Telemetry.isConnected()
    return _ws ~= nil
end

-- Send status and wait up to 1 second for an incoming command.
-- Reconnects automatically on send failure.
function Telemetry.tick(state)
    if not _ws then
        if not connect() then sleep(1); return end
    end

    -- Send status
    local payload = textutils.serialiseJSON({
        type     = "status",
        island   = Config.ISLAND_ID,
        altitude = state.currentAltitude,
        target   = state.targetAltitude,
        velocity = state.currentVelocity,
        mode     = state.mode,
        pressure = Sensors.getAirPressure(),
        config   = {
            island_id        = Config.ISLAND_ID,
            target_altitude  = Config.TARGET_ALTITUDE,
            hold_deadband    = Config.HOLD_DEADBAND,
            loop_interval    = Config.LOOP_INTERVAL,
            max_rsc_speed    = Config.MAX_RSC_SPEED,
            hover_rsc        = Config.HOVER_RSC or 0,
            pressure_ff_max  = Config.PRESSURE_FF_MAX,
            pid_kp           = Config.PID_KP,
            pid_ki           = Config.PID_KI,
            pid_kd           = Config.PID_KD,
            pid_integral_max = Config.PID_INTEGRAL_MAX,
            rsc              = Config.RSC,
            side_sensor      = Config.SIDE_SENSOR,
            side_modem       = Config.SIDE_MODEM,
            rednet_channel   = Config.REDNET_CHANNEL,
        },
    })

    local ok, err = pcall(_ws.send, payload)
    if not ok then
        print("[TEL] Send error: " .. tostring(err))
        pcall(_ws.close)
        _ws = nil
        sleep(1)
        return
    end

    -- Drain all incoming messages for 1 second (handles acks + any queued commands)
    drainMessages(state, 1)
end

function Telemetry.close()
    if _ws then
        pcall(_ws.close)
        _ws = nil
    end
end

return Telemetry
