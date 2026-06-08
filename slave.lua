--[[
  Theme Park Music System - Slave v3
  Normal Computer専用 (黒白表示)
  
  Masterからのコマンドを受信し、音声を再生する。
  rednet (Wireless Modem) で通信。
  
  使い方:
    1. Wireless ModemをComputerに取り付ける
    2. SpeakerをComputerに接続する
    3. wget https://raw.githubusercontent.com/motchii709/cct-sync-music/master/slave.lua slave
    4. slave で起動
  更新方法:
    1. wget https://raw.githubusercontent.com/motchii709/cct-sync-music/master/slave.lua slave
    2. slave で再起動
]]

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music_v3"
local CACHE_DIR = "cache"
local CONFIG_FILE = ".slave_config"
local HELLO_INTERVAL = 3
local HEARTBEAT_INTERVAL = 5
local DL_TIMEOUT = 30
local MASTER_TIMEOUT = 30

------------------------------------------------------------
-- Initialization
------------------------------------------------------------
local width, height = term.getSize()

local function trunc(str)
    if #str > width then return string.sub(str, 1, width - 3) .. "..." end
    return str
end

-- Config
local group_name = nil
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
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Theme Park Music - Slave ===")
    print("")
    if not group_name then
        print("Group name:")
        term.setCursorPos(1, 4)
        term.clearLine()
        group_name = read()
        if not group_name or #group_name == 0 then error("Group name required.", 0) end
    end
    if not computer_name then
        print("")
        print("Computer name (e.g. 'Front Gate'):")
        term.setCursorPos(1, 7)
        term.clearLine()
        computer_name = read()
        if not computer_name or #computer_name == 0 then computer_name = "Slave" end
    end
    local wf = fs.open(CONFIG_FILE, "w")
    if wf then
        wf.write(group_name .. "\n")
        wf.write(computer_name)
        wf.close()
    end
end

-- Cache dir
if not fs.exists(CACHE_DIR) then fs.makeDir(CACHE_DIR) end

-- Speakers
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached.", 0)
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local state = {
    connected = false,
    masterId = nil,
    status = "IDLE",
    track = nil,
    volume = 1.0,
    playback_stop = false,
    lastMasterTime = os.clock(),
    lastHello = 0,
}

local play_queue = {}

-- Log
local log_lines = {}
local LOG_MAX = 20

------------------------------------------------------------
-- Utilities
------------------------------------------------------------
local function logMsg(msg)
    local entry = string.format("[%s] %s", textutils.formatTime(os.time(), true), msg)
    table.insert(log_lines, entry)
    if #log_lines > LOG_MAX then
        table.remove(log_lines, 1)
    end
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function uiUpdate()
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setCursorPos(2, 1)
    term.write(trunc("=== " .. (computer_name or "Slave") .. " ==="))

    local yi = 3
    term.setBackgroundColor(colors.black)

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Group:   ")
    term.setTextColor(colors.white)
    term.write(group_name)
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Status:  ")
    local st = state.status
    if st == "PLAYING" then term.setTextColor(colors.lime)
    elseif st == "ERROR" then term.setTextColor(colors.red)
    elseif st == "DOWNLOADING" then term.setTextColor(colors.yellow)
    elseif st == "CONNECTED" or st == "READY" then term.setTextColor(colors.green)
    else term.setTextColor(colors.lightGray) end
    term.write(st)
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Track:   ")
    term.setTextColor(colors.white)
    if state.track then
        local tname = state.track.name or state.track.id or "unknown"
        term.write(trunc(tname))
    else
        term.write("(none)")
    end
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Volume:  ")
    term.setTextColor(colors.white)
    term.write(math.floor(state.volume * 100) .. "%")
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Speakers: ")
    term.setTextColor(colors.white)
    term.write(#speakers)
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Master:  ")
    if state.masterId then
        term.setTextColor(colors.green)
        term.write("ID " .. state.masterId)
    else
        term.setTextColor(colors.lightGray)
        term.write("Waiting...")
    end
    yi = yi + 2

    -- Log
    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("--- Log ---")
    yi = yi + 1

    local start = math.max(1, #log_lines - (height - yi - 1))
    for i = start, #log_lines do
        if yi > height then break end
        term.setCursorPos(2, yi)
        term.setTextColor(colors.lightGray)
        term.write(trunc(log_lines[i]))
        yi = yi + 1
    end
end

------------------------------------------------------------
-- Cache
------------------------------------------------------------
local function cachePath(track_id)
    return CACHE_DIR .. "/" .. track_id .. ".dfpwm"
end

local function isCached(track_id)
    return fs.exists(cachePath(track_id))
end

------------------------------------------------------------
-- Rednet
------------------------------------------------------------
local function openRednet()
    local modem = peripheral.find("modem")
    if not modem then error("No wireless modem attached.", 0) end
    rednet.open(peripheral.getName(modem))
end

local function sendToMaster(msg)
    if not state.masterId then return end
    local out = {}
    for k, v in pairs(msg) do out[k] = v end
    out.group = group_name
    out.name = computer_name
    rednet.send(state.masterId, textutils.serialize(out), PROTOCOL)
end

local function broadcastToMaster(msg)
    local out = {}
    for k, v in pairs(msg) do out[k] = v end
    out.group = group_name
    out.name = computer_name
    rednet.broadcast(textutils.serialize(out), PROTOCOL)
end

------------------------------------------------------------
-- Download
------------------------------------------------------------
local function downloadTrack(track)
    local track_id = track.id
    if isCached(track_id) then return true end

    logMsg("DL: " .. (track.name or track_id))
    state.status = "DOWNLOADING"
    uiUpdate()

    local url = API_BASE_URL .. "?v=" .. VERSION .. "&id=" .. textutils.urlEncode(track_id)
    local ok, data = pcall(function()
        http.request({url = url, binary = true})
        local timer = os.startTimer(DL_TIMEOUT)
        while true do
            local ev, p1, p2 = os.pullEvent()
            if ev == "http_success" and p1 == url then
                local d = p2.readAll()
                p2.close()
                os.cancelTimer(timer)
                return d
            elseif ev == "http_failure" and p1 == url then
                os.cancelTimer(timer)
                return nil
            elseif ev == "timer" and p1 == timer then
                return nil
            end
        end
    end)

    if ok and data and #data > 0 then
        -- Check available space
        local free = fs.getFreeSpace(CACHE_DIR)
        if free < #data + 1024 then
            logMsg("No space: need " .. #data .. "B, free " .. free .. "B")
            state.status = "ERROR"
            uiUpdate()
            return false
        end
        local wf = fs.open(cachePath(track_id), "wb")
        if wf then
            local w_ok, w_err = pcall(wf.write, wf, data)
            wf.close()
            if not w_ok then
                logMsg("Write error: " .. tostring(w_err))
                pcall(fs.delete, cachePath(track_id))
                state.status = "ERROR"
                uiUpdate()
                return false
            end
        else
            logMsg("Cannot open file for write")
            state.status = "ERROR"
            uiUpdate()
            return false
        end
        logMsg("OK: " .. #data .. " bytes")
        state.status = "READY"
        uiUpdate()
        return true
    else
        logMsg("FAIL: " .. (track.name or track_id))
        state.status = "ERROR"
        uiUpdate()
        return false
    end
end

------------------------------------------------------------
-- Audio playback
------------------------------------------------------------
local function playAudio(track)
    local track_id = track.id
    local path = cachePath(track_id)
    if not fs.exists(path) then
        logMsg("Cache miss: " .. track_id)
        sendToMaster({type = "track_end"})
        return
    end

    logMsg("Playing: " .. (track.name or track_id))
    state.status = "PLAYING"
    state.track = track
    state.playback_stop = false
    uiUpdate()
    sendToMaster({type = "play_started", track = track})

    local decoder = require("cc.audio.dfpwm").make_decoder()
    local f = fs.open(path, "rb")
    if not f then
        logMsg("Cannot open cache")
        state.status = "READY"
        state.track = nil
        uiUpdate()
        sendToMaster({type = "track_end"})
        return
    end

    local ok, err = pcall(function()
        local chunk_size = 16 * 1024
        while not state.playback_stop do
            local chunk = f.read(chunk_size)
            if not chunk then break end

            local decoded = decoder(chunk)
            if decoded then
                -- Play through all speakers
                for _, sp in ipairs(speakers) do
                    pcall(sp.playAudio, decoded, state.volume)
                end
                -- Wait for speakers to finish
                while true do
                    if state.playback_stop then break end
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
        end
    end)

    f.close()
    for _, sp in ipairs(speakers) do
        pcall(sp.stop)
    end

    if not ok then
        logMsg("Error: " .. tostring(err))
    end

    if not state.playback_stop then
        state.status = "READY"
    end
    state.track = nil
    uiUpdate()
    logMsg("Track ended")
    sendToMaster({type = "track_end"})
end

------------------------------------------------------------
-- Audio loop (processes play_queue)
------------------------------------------------------------
local function audioLoop()
    while true do
        if #play_queue > 0 then
            local task = table.remove(play_queue, 1)
            playAudio(task.track)
        else
            sleep(0.1)
        end
    end
end

------------------------------------------------------------
-- Rednet receive
------------------------------------------------------------
local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, cmd = pcall(textutils.unserialize, message)
            if ok and cmd and cmd.group == group_name then
                state.lastMasterTime = os.clock()

                if cmd.cmd == "welcome" then
                    state.connected = true
                    state.masterId = sender_id
                    state.status = "READY"
                    logMsg("Connected: " .. sender_id)
                    uiUpdate()

                elseif cmd.cmd == "download" and cmd.track then
                    state.masterId = sender_id
                    local dl_ok = downloadTrack(cmd.track)
                    if dl_ok then
                        sendToMaster({type = "ready", track_id = cmd.track.id})
                    else
                        sendToMaster({type = "track_end"})
                    end

                elseif cmd.cmd == "ping" then
                    state.masterId = sender_id
                    sendToMaster({type = "pong", seq = cmd.seq})

                elseif cmd.cmd == "play_at" and cmd.track then
                    state.masterId = sender_id
                    if cmd.volume then state.volume = cmd.volume end
                    table.insert(play_queue, {track = cmd.track, start_time = cmd.start_time})

                elseif cmd.cmd == "stop" then
                    state.masterId = sender_id
                    state.playback_stop = true
                    play_queue = {}
                    for _, sp in ipairs(speakers) do
                        pcall(sp.stop)
                    end
                    state.track = nil
                    state.status = "READY"
                    uiUpdate()
                    sendToMaster({type = "play_stopped"})
                    logMsg("Stopped")

                elseif cmd.cmd == "volume" and cmd.level then
                    state.volume = math.max(0, math.min(3, cmd.level))
                    uiUpdate()

                elseif cmd.cmd == "heartbeat" then
                    state.masterId = sender_id
                    sendToMaster({type = "heartbeat", state = state.status, track = state.track})
                end
            end
        end
    end
end

------------------------------------------------------------
-- Connect loop
------------------------------------------------------------
local function connectLoop()
    while true do
        if not state.connected then
            if os.clock() - state.lastHello >= HELLO_INTERVAL then
                broadcastToMaster({type = "hello"})
                state.lastHello = os.clock()
            end
        else
            if os.clock() - state.lastMasterTime > MASTER_TIMEOUT then
                state.connected = false
                state.masterId = nil
                state.status = "IDLE"
                logMsg("Master lost, reconnecting...")
                uiUpdate()
            end
        end
        sleep(1)
    end
end

------------------------------------------------------------
-- Main
------------------------------------------------------------
openRednet()
uiUpdate()
logMsg("Group: " .. group_name)
logMsg("Waiting for master...")
broadcastToMaster({type = "hello"})

parallel.waitForAny(connectLoop, rednetLoop, audioLoop)
