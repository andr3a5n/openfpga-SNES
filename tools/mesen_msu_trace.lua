-- MSU-1 register trace for Mesen 2 (MesenCE), the reference side of the
-- SNESMSU core's event log (tools/msu_log.py decodes the Pocket's side).
--
-- Use: load the MSU-1 game in Mesen, open Debug > Script Window, open this
-- file and run it, then play the section you also play on the Pocket. Stop
-- the script (or close the game) when done.
--
-- Output: msu_trace.txt in Mesen's script data folder when "Allow access to
-- I/O and OS functions" is enabled in the script window's settings, and
-- always the same lines in the script window's log.
--
-- Each line: time in ms since the script started, the frame number, then
-- what the game did: track selections, play/stop/repeat/resume, volume,
-- data port seeks, and how often and for how long it polled the status
-- register ($2000) waiting for the audio-busy or data-busy bit. In Mesen
-- these bits clear at once; on the Pocket they take a moment, which is
-- exactly the difference to compare.

local LINES_MAX = 20000  -- stop writing after this many lines

local out = nil
local lines = 0
local t0 = nil
local frame = 0
local pc_key, k_key = nil, nil

local function open_file()
  local ok, folder = pcall(function() return emu.getScriptDataFolder() end)
  if ok and folder and io and io.open then
    local f = io.open(folder .. "/msu_trace.txt", "w")
    if f then
      emu.log("Writing " .. folder .. "/msu_trace.txt")
      return f
    end
  end
  emu.log("No file access: copy the lines from this log window")
  return nil
end

-- The CPU program counter: find its key in the state table once
local function find_keys(state)
  for key, _ in pairs(state) do
    local k = string.lower(key)
    if not (k:find("sa1") or k:find("spc") or k:find("gsu") or k:find("cx4")) then
      if k:match("cpu%.pc$") and not pc_key then pc_key = key end
      if k:match("cpu%.k$") and not k_key then k_key = key end
    end
  end
end

local function now(state)
  state = state or emu.getState()
  if t0 == nil then t0 = state.masterClock end
  return (state.masterClock - t0) * 1000.0 / state.clockRate
end

local function emit(text, state)
  if lines >= LINES_MAX then return end
  lines = lines + 1
  state = state or emu.getState()
  if pc_key == nil then find_keys(state) end
  local where = ""
  if pc_key then
    local pc = state[pc_key] or 0
    local k = k_key and state[k_key] or 0
    where = string.format("  [PC %02X:%04X]", k, pc)
  end
  local line = string.format("%12.3f  f%-6d %s%s", now(state), frame, text, where)
  emu.log(line)
  if out then
    out:write(line, "\n")
    out:flush()
  end
end

-- Status polling: count reads of $2000 and report runs of them
local polls, poll_first_ms, poll_busy = 0, 0, false

local function flush_polls(state)
  if polls > 0 then
    emit(string.format("SNES: status polled %d times over %.3f ms%s", polls,
                       now(state) - poll_first_ms, poll_busy and " (busy seen)" or ""), state)
    polls, poll_busy = 0, false
  end
end

local seek = {0, 0, 0}
local track_lo = 0

local function on_write(address, value)
  local state = emu.getState()
  flush_polls(state)
  local reg = address & 0x7
  if reg <= 2 then
    seek[reg + 1] = value
  elseif reg == 3 then
    local addr = seek[1] | (seek[2] << 8) | (seek[3] << 16) | (value << 24)
    emit(string.format("SNES: data port seek to %06X", addr & 0xFFFFFF), state)
  elseif reg == 4 then
    track_lo = value
  elseif reg == 5 then
    emit(string.format("SNES: track %d selected ($2004/5)", track_lo | (value << 8)), state)
  elseif reg == 6 then
    emit(string.format("SNES: volume %d", value), state)
  elseif reg == 7 then
    local flags = {}
    if value & 1 ~= 0 then flags[#flags + 1] = "play" end
    if value & 2 ~= 0 then flags[#flags + 1] = "repeat" end
    if value & 4 ~= 0 then flags[#flags + 1] = "resume" end
    emit("SNES: control " .. (#flags > 0 and table.concat(flags, "+") or "stop"), state)
  end
end

local function on_read(address, value)
  if (address & 0x7) == 0 then
    if polls == 0 then poll_first_ms = now() end
    polls = polls + 1
    if value & 0xC0 ~= 0 then poll_busy = true end
  end
end

local function on_frame()
  frame = frame + 1
  -- A run of polls that lasted past a frame end is reported as it goes
  if polls > 1000 then flush_polls() end
end

out = open_file()
emit("trace started")

-- $2000-$2007 in banks $00-$3F and $80-$BF
for bank = 0, 0xBF do
  if bank < 0x40 or bank >= 0x80 then
    local base = (bank << 16) | 0x2000
    emu.addMemoryCallback(on_write, emu.callbackType.write, base, base + 7,
                          emu.cpuType.snes, emu.memType.snesMemory)
    emu.addMemoryCallback(on_read, emu.callbackType.read, base, base,
                          emu.cpuType.snes, emu.memType.snesMemory)
  end
end
emu.addEventCallback(on_frame, emu.eventType.endFrame)
emu.addEventCallback(function()
  flush_polls()
  emit("trace ended")
  if out then out:close() end
end, emu.eventType.scriptEnded)
