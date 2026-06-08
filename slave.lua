--[[
  Theme Park Music System - Slave v3 (Audio Relay)
  Normal Computer (monochrome, no mouse)

  Receives raw DFPWM audio from master via rednet and plays through speakers.
  No local cache, no HTTP — master handles all downloading.

  Setup:
    1. Attach Wireless Modem + Speaker(s) to computer
    2. Place .slave_config file with two lines: group_name, computer_name
    3. Run: slave
]]

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local PROTOCOL       = "park_music_v3"
local CONFIG_FILE    = ".slave_config"
local HELLO_INTERVAL = 3
local MASTER_TIMEOUT = 30
local UI_REFRESH     = 0.5
local LOG_MAX        = 20

------------------------------------------------------------
-- Terminal helpers
------------------------------------------------------------
local width, height = term.getSize()

local function trunc(str)
    if not str then return "" end
    str = tostring(str)
    if #str > width then
        if width > 3 then
            return str:sub(1, width - 3) .. "..."
        end
        return str:sub(1, width)
    end
    return str
end

local function pad(str, n)
    str = tostring(str)
    if #str >= n then return str:sub(1, n) end
    return str .. string.rep(" ", n - #str)
end

------------------------------------------------------------
-- Config (line-based, backward compatible)
------------------------------------------------------------
local group_name    = nil
local computer_name = nil

do
    local f = fs.open(CONFIG_FILE, "r")
    if f then
        local g = f.readLine()
        local c = f.readLine()
        f.close()
        if g and #g > 0 then group_name = g end
        if c and #c > 0 then computer_name = c end
    end
end

if not group_name or not computer_name then
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Park Music - Slave Setup ===")
    print("")
    if not group_name then
        print("Group name:")
        term.setCursorPos(1, 4)
        term.clearLine()
        group_name = read()
        if not group_name or #group_name == 0 then
            error("Group name required.", 0)
        end
    end
    if not computer_name then
        print("")
        print("Computer name (e.g. 'Front Gate'):")
        term.setCursorPos(1, 7)
        term.clearLine()
        computer_name = read()
        if not computer_name or #computer_name == 0 then
            computer_name = "Slave"
        end
    end
    local wf = fs.open(CONFIG_FILE, "w")
    if wf then
        wf.write(group_name .. "\n")
        wf.write(computer_name)
        wf.close()
    end
end

------------------------------------------------------------
-- Speakers
------------------------------------------------------------
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached.", 0)
end

------------------------------------------------------------
-- Audio decoder
------------------------------------------------------------
local decoder = require("cc.audio.dfpwm").make_decoder()

------------------------------------------------------------
-- State
------------------------------------------------------------
local state = {
    connected      = false,
    masterId       = nil,
    status         = "IDLE",   -- IDLE | CONNECTED | WAITING | PLAYING | ERROR
    track          = nil,
    volume         = 1.0,
    playback_stop  = false,
    lastMasterTime = os.clock(),
    lastHello      = 0,
    play_at_time   = nil,
}

------------------------------------------------------------
-- Log
------------------------------------------------------------
local log_lines = {}

local function logMsg(msg)
    local entry = string.format("[%s] %s",
        textutils.formatTime(os.time(), true), msg)
    table.insert(log_lines, entry)
    if #log_lines > LOG_MAX then
        table.remove(log_lines, 1)
    end
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function uiUpdate()
    term.clear()

    -- Header bar (inverse via spaces)
    term.setCursorPos(1, 1)
    term.write(trunc(" " .. computer_name .. " " ..
        string.rep("=", math.max(0, width - #computer_name - 3))))

    local y = 3
    local function row(label, value)
        if y > height then return end
        term.setCursorPos(2, y)
        term.write(pad(label .. ":", 9) .. tostring(value))
        y = y + 1
    end

    row("Group",    group_name)
    row("Status",   state.status)
    if state.track then
        local tname = state.track.name or state.track.id or "unknown"
        row("Track", tname)
    else
        row("Track", "-")
    end
    row("Volume",   string.format("%.0f%%", state.volume * 100))
    row("Speakers", tostring(#speakers))
    if state.masterId then
        row("Master", "ID " .. state.masterId)
    else
        row("Master", "waiting...")
    end

    y = y + 1
    if y <= height then
        term.setCursorPos(2, y)
        term.write(string.rep("-", width - 2))
        y = y + 1
    end

    if y <= height then
        term.setCursorPos(2, y)
        term.write("Log:")
        y = y + 1
    end

    local visible = math.max(0, height - y)
    local start = math.max(1, #log_lines - visible + 1)
    for i = start, #log_lines do
        if y > height then break end
        term.setCursorPos(2, y)
        term.write(trunc(log_lines[i]))
        y = y + 1
    end
end

------------------------------------------------------------
-- Protocol helpers
------------------------------------------------------------
local function sendToMaster(msg)
    if not state.masterId then return end
    local out = {}
    for k, v in pairs(msg) do out[k] = v end
    out.group    = group_name
    out.computer = computer_name
    rednet.send(state.masterId, textutils.serialize(out), PROTOCOL)
end

local function broadcast(msg)
    local out = {}
    for k, v in pairs(msg) do out[k] = v end
    out.group    = group_name
    out.computer = computer_name
    rednet.broadcast(textutils.serialize(out), PROTOCOL)
end

------------------------------------------------------------
-- playChunk: decode and play one DFPWM chunk
------------------------------------------------------------
local function playChunk(data)
    local ok, decoded = pcall(decoder, data)
    if not ok or not decoded or #decoded == 0 then return end

    for _, sp in ipairs(speakers) do
        pcall(sp.playAudio, decoded, state.volume)
    end

    while not state.playback_stop do
        local any_busy = false
        for _, sp in ipairs(speakers) do
            local s_ok, level = pcall(sp.getAudioLevel)
            if s_ok and level > 0 then
                any_busy = true
                break
            end
        end
        if not any_busy then break end
        os.pullEvent("speaker_audio_empty")
    end
end

------------------------------------------------------------
-- Command handler
------------------------------------------------------------
local function handleCommand(sender_id, cmd)
    if not cmd or not cmd.cmd then return end
    state.lastMasterTime = os.clock()

    local c = cmd.cmd

    if c == "welcome" then
        state.connected = true
        state.masterId  = sender_id
        state.status    = "CONNECTED"
        logMsg("Connected to master " .. sender_id)

    elseif c == "download" then
        sendToMaster({type = "ready"})
        logMsg("Download-ready sent")

    elseif c == "ping" then
        sendToMaster({type = "pong", seq = cmd.seq})

    elseif c == "play_at" then
        if cmd.volume then
            state.volume = math.max(0, math.min(3, cmd.volume))
        end
        state.status         = "WAITING"
        state.track          = cmd.track
        state.playback_stop  = false
        if cmd.delay and cmd.delay > 0 then
            state.play_at_time = os.clock() + cmd.delay
            logMsg("Scheduled in " .. string.format("%.1fs", cmd.delay) ..
                   ": " .. (cmd.track and cmd.track.name or "?"))
        else
            state.play_at_time = nil
            state.status = "PLAYING"
            logMsg("Playing now: " .. (cmd.track and cmd.track.name or "?"))
        end

    elseif c == "stop" then
        state.playback_stop = true
        state.status    = state.connected and "CONNECTED" or "IDLE"
        state.track     = nil
        state.play_at_time = nil
        for _, sp in ipairs(speakers) do
            pcall(sp.stop)
        end
        sendToMaster({type = "track_end"})
        logMsg("Stopped")

    elseif c == "volume" then
        state.volume = math.max(0, math.min(3, cmd.level or 1.0))
        logMsg("Volume " .. string.format("%.0f%%", state.volume * 100))

    elseif c == "heartbeat" then
        sendToMaster({
            type  = "heartbeat",
            state = state.status,
            track = state.track,
        })

    elseif c == "audio_end" then
        state.playback_stop = true
        state.status    = state.connected and "CONNECTED" or "IDLE"
        state.track     = nil
        state.play_at_time = nil
        for _, sp in ipairs(speakers) do
            pcall(sp.stop)
        end
        sendToMaster({type = "track_end"})
        logMsg("Track ended")
    end
end

------------------------------------------------------------
-- Connect loop: send hello, detect master loss
------------------------------------------------------------
local function connectLoop()
    while true do
        if not state.connected then
            if os.clock() - state.lastHello >= HELLO_INTERVAL then
                broadcast({type = "hello"})
                state.lastHello = os.clock()
                logMsg("Hello broadcast")
            end
        else
            if os.clock() - state.lastMasterTime > MASTER_TIMEOUT then
                state.connected      = false
                state.masterId       = nil
                state.status         = "IDLE"
                state.track          = nil
                state.playback_stop  = true
                state.play_at_time   = nil
                logMsg("Master lost, reconnecting...")
            end
        end
        sleep(1)
    end
end

------------------------------------------------------------
-- Rednet loop: protocol messages + raw audio chunks
------------------------------------------------------------
local function rednetLoop()
    while true do
        local sender_id, message, proto = rednet.receive(PROTOCOL)
        if sender_id and message then
            if type(message) == "string" and #message > 0 and message:sub(1, 1) == "{" then
                -- Protocol message
                local ok, cmd = pcall(textutils.unserialize, message)
                if ok and type(cmd) == "table" and cmd.group == group_name then
                    handleCommand(sender_id, cmd)
                end
            elseif type(message) == "string" and #message > 0 then
                -- Raw DFPWM audio chunk
                if state.status == "PLAYING" then
                    playChunk(message)
                end
            end
        end
    end
end

------------------------------------------------------------
-- Audio loop: play_at scheduling + UI refresh
------------------------------------------------------------
local function audioLoop()
    while true do
        if state.status == "WAITING" and state.play_at_time then
            if os.clock() >= state.play_at_time then
                state.status       = "PLAYING"
                state.play_at_time = nil
                logMsg("Playback started")
            end
        end
        uiUpdate()
        sleep(UI_REFRESH)
    end
end

------------------------------------------------------------
-- Main
------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then
    error("No wireless modem attached.", 0)
end
rednet.open(peripheral.getName(modem))

logMsg("Group: " .. group_name)
logMsg("Speakers: " .. #speakers)
logMsg("Waiting for master...")
broadcast({type = "hello"})

parallel.waitForAny(connectLoop, rednetLoop, audioLoop)
