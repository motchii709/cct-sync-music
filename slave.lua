--[[
  Theme Park Music System - Slave v3
  Normal Computer専用 (黒白表示)
  
  Masterからのコマンドを受信し、音声を再生する。
  rednet (Wireless Modem) で通信。
  
  使い方:
    1. Wireless ModemをComputerに取り付ける
    2. SpeakerをComputerに接続する
    3. このファイルを実行する
    4. 起動時にgroup名を入力する (保存される)
    5. Masterが起動していれば自動接続
]]

------------------------------------------------------------
-- 設定
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music_v3"
local CACHE_DIR = "cache"
local CONFIG_FILE = ".slave_config"
local HEARTBEAT_INTERVAL = 5
local DL_TIMEOUT = 30

------------------------------------------------------------
-- 初期化
------------------------------------------------------------
local width, height = term.getSize()

-- Group名 & Computer名
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
        if #group_name == 0 then error("Group name required.", 0) end
    end
    if not computer_name then
        print("")
        print("Computer name (e.g. 'Front Gate'):")
        term.setCursorPos(1, 7)
        term.clearLine()
        computer_name = read()
        if #computer_name == 0 then computer_name = "Slave" end
    end
    local wf = fs.open(CONFIG_FILE, "w")
    wf.write(group_name .. "\n")
    wf.write(computer_name)
    wf.close()
end

if not fs.exists(CACHE_DIR) then fs.makeDir(CACHE_DIR) end

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached.", 0)
end

------------------------------------------------------------
-- 状態
------------------------------------------------------------
local state = "waiting"  -- waiting, connected, downloading, ready, playing, error
local current_track = nil
local volume = 1.0
local playing = false
local master_id = nil
local playback_stop = false
local play_queue = {}
local connected = false

-- ログ
local log_lines = {}
local LOG_MAX = 20

------------------------------------------------------------
-- ユーティリティ
------------------------------------------------------------
local function log(msg)
    local entry = string.format("[%s] %s", textutils.formatTime(os.time(), true), msg)
    table.insert(log_lines, entry)
    if #log_lines > LOG_MAX then
        table.remove(log_lines, 1)
    end
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function drawUI()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- ヘッダー
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setCursorPos(2, 1)
    term.write("=== " .. (computer_name or "Slave") .. " ===")

    -- ステータス
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
    local st = state
    if st == "playing" then term.setTextColor(colors.lime)
    elseif st == "error" then term.setTextColor(colors.red)
    elseif st == "downloading" then term.setTextColor(colors.yellow)
    elseif st == "connected" then term.setTextColor(colors.green)
    else term.setTextColor(colors.lightGray) end
    term.write(st)
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Track:   ")
    term.setTextColor(colors.white)
    if current_track then
        term.write(current_track.name or "unknown")
    else
        term.write("(none)")
    end
    yi = yi + 1

    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("Volume:  ")
    term.setTextColor(colors.white)
    term.write(math.floor(volume * 100) .. "%")
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
    if master_id then
        term.setTextColor(colors.green)
        term.write("ID " .. master_id)
    else
        term.setTextColor(colors.lightGray)
        term.write("Waiting...")
    end
    yi = yi + 2

    -- ログ
    term.setCursorPos(2, yi)
    term.setTextColor(colors.lightGray)
    term.write("--- Log ---")
    yi = yi + 1

    local start = math.max(1, #log_lines - (height - yi - 1))
    for i = start, #log_lines do
        if yi > height then break end
        term.setCursorPos(2, yi)
        term.setTextColor(colors.lightGray)
        local line = log_lines[i]
        if #line > width - 3 then line = string.sub(line, 1, width - 6) .. "..." end
        term.write(line)
        yi = yi + 1
    end
end

------------------------------------------------------------
-- キャッシュ
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

local function sendMessage(msg)
    msg.group = group_name
    msg.name = computer_name
    rednet.broadcast(textutils.serialize(msg), PROTOCOL)
end

local function sendToMaster(msg)
    if master_id then
        msg.group = group_name
        msg.name = computer_name
        rednet.send(master_id, textutils.serialize(msg), PROTOCOL)
    end
end

------------------------------------------------------------
-- 音声DL
------------------------------------------------------------
local function downloadTrack(track)
    if isCached(track.id) then return true end

    log("DL: " .. (track.name or track.id))
    state = "downloading"
    drawUI()

    local url = API_BASE_URL .. "?v=" .. VERSION .. "&id=" .. textutils.urlEncode(track.id)
    http.request({url = url, binary = true})

    local timer = os.startTimer(DL_TIMEOUT)
    while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "http_success" and p1 == url then
            local data = p2.readAll()
            p2.close()
            local wf = fs.open(cachePath(track.id), "wb")
            wf.write(data)
            wf.close()
            log("OK: " .. #data .. " bytes")
            state = "ready"
            drawUI()
            os.cancelTimer(timer)
            return true
        elseif ev == "http_failure" and p1 == url then
            log("FAIL: " .. (track.name or ""))
            state = "error"
            drawUI()
            os.cancelTimer(timer)
            return false
        elseif ev == "timer" and p1 == timer then
            log("TIMEOUT")
            state = "error"
            drawUI()
            return false
        end
    end
end

------------------------------------------------------------
-- 音声再生
------------------------------------------------------------
local function playFromCache(track, start_time)
    if not isCached(track.id) then
        log("Cache miss: " .. (track.id or ""))
        return
    end

    -- start_timeまで待機
    if start_time then
        while playing and os.clock() < start_time do
            sleep(0.05)
        end
    end

    if not playing then return end

    log("Playing: " .. (track.name or ""))
    state = "playing"
    current_track = track
    playback_stop = false
    playing = true
    drawUI()
    sendToMaster({type = "play_started", track = track})

    local decoder = require("cc.audio.dfpwm").make_decoder()

    local f = fs.open(cachePath(track.id), "rb")
    if not f then
        log("Cannot open cache: " .. track.id)
        state = "idle"
        playing = false
        current_track = nil
        drawUI()
        sendToMaster({type = "track_end"})
        return
    end

    local ok, err = pcall(function()
        local chunk_size = 16 * 1024

        while playing and not playback_stop do
            local chunk = f.read(chunk_size)
            if not chunk then break end

            local decoded = decoder(chunk)

            local fns = {}
            for i, speaker in ipairs(speakers) do
                fns[i] = function()
                    local name = peripheral.getName(speaker)
                    while not speaker.playAudio(decoded, volume) do
                        parallel.waitForAny(
                            function()
                                while true do
                                    local ev, p1 = os.pullEvent("speaker_audio_empty")
                                    if p1 == name then return end
                                end
                            end,
                            function()
                                while true do
                                    local ev = os.pullEvent()
                                    if ev == "playback_stopped" then return end
                                end
                            end
                        )
                        if playback_stop then return end
                    end
                end
            end

            parallel.waitForAll(table.unpack(fns))
        end
    end)

    f.close()

    if not ok then
        log("Error: " .. tostring(err))
    end

    playing = false
    state = "idle"
    current_track = nil
    drawUI()
    log("Track ended")
    sendToMaster({type = "track_end"})
end

------------------------------------------------------------
-- Rednet受信
------------------------------------------------------------
local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, cmd = pcall(textutils.unserialize, message)
            if ok and cmd and not cmd.type and cmd.group == group_name then

                if cmd.cmd == "welcome" then
                    master_id = sender_id
                    connected = true
                    state = "connected"
                    log("Connected to master: " .. sender_id)
                    drawUI()

                elseif cmd.cmd == "download" and cmd.track then
                    master_id = sender_id
                    local dl_ok = downloadTrack(cmd.track)
                    if dl_ok then
                        sendToMaster({type = "ready", track_id = cmd.track.id})
                    else
                        sendToMaster({type = "status", state = "error"})
                    end

                elseif cmd.cmd == "ping" then
                    master_id = sender_id
                    sendToMaster({type = "pong", seq = cmd.seq})

                elseif cmd.cmd == "play_at" and cmd.track then
                    master_id = sender_id
                    if cmd.volume then volume = cmd.volume end
                    table.insert(play_queue, {track = cmd.track, start_time = cmd.start_time})

                elseif cmd.cmd == "stop" then
                    playback_stop = true
                    playing = false
                    play_queue = {}
                    for _, speaker in ipairs(speakers) do
                        speaker.stop()
                    end
                    state = "connected"
                    current_track = nil
                    drawUI()
                    sendToMaster({type = "play_stopped"})
                    log("Stopped")

                elseif cmd.cmd == "volume" and cmd.level then
                    volume = math.max(0, math.min(3, cmd.level))
                    drawUI()

                elseif cmd.cmd == "heartbeat" then
                    master_id = sender_id
                    sendToMaster({type = "heartbeat", state = state, track = current_track})
                end
            end
        end
    end
end

------------------------------------------------------------
-- 音声ループ
------------------------------------------------------------
local function audioLoop()
    while true do
        if #play_queue > 0 then
            local task = table.remove(play_queue, 1)
            playFromCache(task.track, task.start_time)
        else
            sleep(0.1)
        end
    end
end

------------------------------------------------------------
-- 接続ループ (未接続なら定期的にhello送信)
------------------------------------------------------------
local function connectLoop()
    while not connected do
        sendMessage({type = "hello"})
        sleep(3)
    end
end

------------------------------------------------------------
-- メイン
------------------------------------------------------------
openRednet()
drawUI()
log("Group: " .. group_name)
log("Waiting for master...")
sendMessage({type = "hello"})

parallel.waitForAny(rednetLoop, audioLoop, connectLoop)
