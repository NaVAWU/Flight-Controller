-- ============================================================
--  pid.lua
-- ============================================================

local PID = {}
PID.__index = PID

-- Create a new PID controller instance
function PID.new(kP, kI, kD, maxIntegral)
    return setmetatable({
        kP           = kP,
        kI           = kI,
        kD           = kD,
        maxIntegral  = maxIntegral or 10.0,
        _integral    = 0,
        _lastError   = 0,
    }, PID)
end

-- Update the controller with a new error and time delta.
-- Returns the raw output (caller is responsible for clamping to speed limits).
function PID:update(error, dt)
    dt = math.max(dt, 0.001)   -- guard against zero delta

    self._integral  = self:_clampIntegral(self._integral + error * dt)
    local derivative = (error - self._lastError) / dt
    self._lastError  = error

    return (self.kP * error)
         + (self.kI * self._integral)
         + (self.kD * derivative)
end

-- Reset integral and history (call when target changes)
function PID:reset()
    self._integral  = 0
    self._lastError = 0
end

function PID:_clampIntegral(value)
    return math.max(-self.maxIntegral, math.min(self.maxIntegral, value))
end

return PID
