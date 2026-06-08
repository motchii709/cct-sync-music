--[[
  Theme Park Music System - Slave
  Normal Computer専用 (黒白表示)
  
  Masterからのコマンドを受信し、音声を再生する。
  rednet (Wireless Modem) で通信。
  
  使い方:
    1. Wireless ModemをComputerに取り付ける
    2. SpeakerをComputerに接続する
    3. このファイルを実行する
    4. 初回起動時にzone名を入力する (保存される)
    5. 2回目以降は自動でzone名が読み込まれる
]]

------------------------------------------------------------
-- 設定
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music"
local CACHE_DIR = "cache"
local CONFIG_FILE = ".slave_config"

------------------------------------------------------------
-- 初期化
------------------------------------------------------------
local zone_name = nil
local f = fs.open(CONFIG_FILE, "r")
if f then
    zone_name = f.readLine()
    f.close()
end

if not zone_name then
    term.write("Zone name: ")
    zone_name = read()
    if #zone_name == 0 then
        error("Zone name cannot be empty.", 0)
    end
    local wf = fs.open(CONFIG_FILE, "w")
    wf.write(zone_name)
    wf.close()
end

if not fs.exists(CACHE_DIR) then
    fs.makeDir(CACHE_DIR)
end

local decoder = require("cc.audio.dfpwm").make_decoder()

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached.", 0)
end

-- 状態
local state = "idle"
local current_track = nil
local volume = 1.0
local playing = false
local master_id = nil
local playback_stop = false

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function drawUI()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Theme Park Music - Slave ===")
    print("")
    print("Zone:     " .. zone_name)
    print("Status:   " .. state)
    if current_track then
        print("Track:    " .. (current_track.name or "unknown"))
    else
        print("Track:    (none)")
    end
    print("Volume:   " .. math.floor(volume * 100) .. "%")
    print("Speakers: " .. #speakers)
    print("Master:   " .. (master_id and ("ID " .. master_id) or "Waiting..."))
end

local function log(msg)
    local _, y = term.getCursorPos()
    if y > 17 then
        term.scroll(1)
        term.setCursorPos(1, 17)
    end
    print("[" .. string.format("%.1f", os.clock()) .. "] " .. msg)
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
-- 音声DL
------------------------------------------------------------
local function downloadTrack(track)
    if isCached(track.id) then
        return true
    end

    log("DL: " .. track.name)
    state = "downloading"
    drawUI()

    local url = API_BASE_URL .. "?v=" .. VERSION .. "&id=" .. textutils.urlEncode(track.id)
    http.request({url = url, binary = true})

    local timer = os.startTimer(30)
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
            log("FAIL: " .. track.name)
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
-- 音声再生 (diskキャッシュから、start_timeまで待機して再生)
-- この関数は長時間ブロックする。
-- playback_stop フラグで途中停止可能。
------------------------------------------------------------
local function playFromCache(track, start_time)
    if not isCached(track.id) then
        log("Cache miss: " .. track.name)
        return
    end

    -- 開始時刻まで待機
    if start_time then
        while playing and os.clock() < start_time do
            sleep(0.05)
        end
    end

    if not playing then return end

    log("Playing: " .. track.name)
    state = "playing"
    current_track = track
    playback_stop = false
    drawUI()

    local f = fs.open(cachePath(track.id), "rb")
    local chunk_size = 16 * 1024
    local first_chunk = f.read(4)
    local read_size = chunk_size - 4

    while playing and not playback_stop do
        local chunk = f.read(read_size)
        if not chunk then break end

        local decoded
        if first_chunk then
            decoded = decoder(first_chunk .. chunk)
            first_chunk = nil
            read_size = chunk_size
        else
            decoded = decoder(chunk)
        end

        local fns = {}
        for i, speaker in ipairs(speakers) do
            fns[i] = function()
                local name = peripheral.getName(speaker)
                while not speaker.playAudio(decoded, volume) do
                    parallel.waitForAny(
                        function()
                            repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
                        end,
                        function()
                            local ev = os.pullEvent()
                            if ev == "playback_stopped" then return end
                        end
                    )
                    if playback_stop then return end
                end
            end
        end

        local ok = pcall(parallel.waitForAll, table.unpack(fns))
        if not ok then break end
    end

    f.close()
    playing = false
    state = "idle"
    drawUI()
end

------------------------------------------------------------
-- Rednet
------------------------------------------------------------
local function openRednet()
    local modem = peripheral.find("modem")
    if not modem then
        error("No wireless modem attached.", 0)
    end
    rednet.open(peripheral.getName(modem))
end

local function sendMessage(msg)
    msg.zone = zone_name
    rednet.broadcast(textutils.serialize(msg), PROTOCOL)
end

------------------------------------------------------------
-- メイン
-- 
-- 架構: 2つの_coroutine を parallel.waitForAny で並行実行
--   1. rednetLoop: 継続的にrednetメッセージを受信し、
--      コマンドに応じて再生要求をキューイング
--   2. audioLoop: 再生要求をキューから取り出して実行
--
-- これにより:
--   - 再生中でも rednetメッセージを受信できる
--   - stopコマンドで即座に再生停止可能
--   - play_at の start_time 待機中もコマンド受信可能
------------------------------------------------------------
openRednet()
drawUI()
log("Zone: " .. zone_name)
log("Waiting...")
sendMessage({type = "hello", zone = zone_name})

local play_queue = {}  -- {track=..., start_time=...}

local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, cmd = pcall(textutils.unserialize, message)
            if ok and cmd and not cmd.type then
                master_id = sender_id

                if cmd.cmd == "download" and cmd.track then
                    local dl_ok = downloadTrack(cmd.track)
                    if dl_ok then
                        sendMessage({type = "ready", track_id = cmd.track.id})
                    end

                elseif cmd.cmd == "ping" then
                    sendMessage({type = "pong", seq = cmd.seq})

                elseif cmd.cmd == "play_at" and cmd.track then
                    if cmd.volume then volume = cmd.volume end
                    table.insert(play_queue, {track = cmd.track, start_time = cmd.start_time})

                elseif cmd.cmd == "stop" then
                    playback_stop = true
                    playing = false
                    for _, speaker in ipairs(speakers) do
                        speaker.stop()
                    end
                    state = "idle"
                    drawUI()

                elseif cmd.cmd == "volume" and cmd.level then
                    volume = math.max(0, math.min(3, cmd.level))
                    drawUI()
                end
            end
        end
    end
end

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

parallel.waitForAny(rednetLoop, audioLoop)
