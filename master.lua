--[[
  Theme Park Music System - Master
  Advanced Computer専用 (カラー表示 + マウス操作)
  
  複数のSlave Computerをrednet経由で制御し、
  音楽を同期再生する。
  
  使い方:
    1. Wireless ModemをComputerに取り付ける
    2. SpeakerをComputerに接続する (Masterも再生可能)
    3. このファイルを実行する
    4. Slaveを起動してrednet接続を待つ
    5. Playlistタブで曲を検索・追加
    6. 再生すると全Slaveに同期配信される
]]

------------------------------------------------------------
-- 設定
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music"
local CACHE_DIR = "cache"
local SYNC_LEAD_TIME = 3.0
local RTT_SAMPLES = 3
local HEARTBEAT_INTERVAL = 10

------------------------------------------------------------
--状態
------------------------------------------------------------
local width, height = term.getSize()
local current_tab = 1

local playing = false
local now_playing = nil
local queue = {}
local looping = 0
local volume = 1.5

local search_query = ""
local search_results = nil
local search_error = false
local search_waiting = false
local search_input_mode = false
local last_search_url = nil
local selected_result = nil
local result_action_mode = false

local schedule_items = {
    {time="09:00-12:00", name="Morning",   playlist={}},
    {time="12:00-15:00", name="Afternoon",  playlist={}},
    {time="15:00-18:00", name="Evening",    playlist={}},
    {time="18:00-21:00", name="Night",      playlist={}},
}
local schedule_selected = 1
local schedule_detail_mode = false

local zones = {}

local playing_id = nil
local last_download_url = nil
local is_loading = false
local is_error = false
local decoder = require("cc.audio.dfpwm").make_decoder()

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached.", 0)
end

-- 同期制御
local sync_request = nil    -- {track=...} 同期再生リクエスト
local rtt_pong_received = false

------------------------------------------------------------
-- キャッシュ
------------------------------------------------------------
if not fs.exists(CACHE_DIR) then fs.makeDir(CACHE_DIR) end

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

local function broadcastCommand(cmd)
    rednet.broadcast(textutils.serialize(cmd), PROTOCOL)
end

------------------------------------------------------------
-- UI描画
------------------------------------------------------------
local function drawTabs()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    local tabs = {" Now Playing ", " Playlist ", " Schedule ", " Zones "}
    for i = 1, #tabs do
        if current_tab == i then
            term.setTextColor(colors.black)
            term.setBackgroundColor(colors.white)
        else
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.gray)
        end
        local pos = math.floor((width / #tabs) * (i - 0.5)) - math.ceil(#tabs[i] / 2) + 1
        term.setCursorPos(pos, 1)
        term.write(tabs[i])
    end
end

local function drawNowPlaying()
    term.setBackgroundColor(colors.black)
    if now_playing then
        term.setTextColor(colors.white)
        term.setCursorPos(2, 3)
        term.write(now_playing.name)
        if now_playing.artist then
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, 4)
            term.write(now_playing.artist)
        end
    else
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 3)
        term.write("No track selected")
    end

    if is_loading then
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif is_error then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 5)
        term.write("Error")
    end

    if playing then
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.gray)
        term.setCursorPos(2, 6)
        term.write(" Stop ")
    else
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.gray)
        term.setCursorPos(2, 6)
        term.write(" Play ")
    end

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(10, 6)
    term.write(" Skip ")

    if looping > 0 then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.white)
    else
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.gray)
    end
    term.setCursorPos(18, 6)
    if looping == 0 then term.write(" Loop:Off ")
    elseif looping == 1 then term.write(" Loop:Q   ")
    else term.write(" Loop:Song") end

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.blue)
    term.setCursorPos(2, 8)
    term.write(" Sync All ")

    term.setBackgroundColor(colors.gray)
    paintutils.drawBox(2, 10, 30, 10, colors.gray)
    local vol_w = math.floor(23 * (volume / 3) + 0.5)
    if vol_w > 0 then
        paintutils.drawBox(2, 10, 2 + vol_w - 1, 10, colors.white)
    end
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(32, 10)
    term.write(math.floor(100 * (volume / 3)) .. "%")

    if #queue > 0 then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 12)
        term.write("--- Queue ---")
        for i = 1, math.min(#queue, 6) do
            term.setTextColor(colors.white)
            term.setCursorPos(2, 12 + i)
            term.write(i .. ". " .. queue[i].name)
        end
    end

    local zone_count = 0
    for _ in pairs(zones) do zone_count = zone_count + 1 end
    if zone_count > 0 then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(35, 3)
        term.write("--- Zones ---")
        local yi = 4
        for name, info in pairs(zones) do
            if yi > height then break end
            term.setCursorPos(35, yi)
            local c = "+"
            if info.status == "playing" then c = "*"
            elseif info.status == "error" then c = "!" end
            local col = colors.white
            if info.status == "playing" then col = colors.lime
            elseif info.status == "error" then col = colors.red end
            term.setTextColor(col)
            term.write("[" .. c .. "] " .. name)
            yi = yi + 1
        end
    end
end

local function drawPlaylist()
    term.setBackgroundColor(colors.black)
    paintutils.drawFilledBox(2, 3, width - 1, 5, colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setTextColor(colors.black)
    term.setCursorPos(3, 4)
    if search_input_mode then
        term.write(search_query .. "_")
    else
        term.write(#search_query > 0 and search_query or "Search YouTube...")
    end

    if search_results then
        for i = 1, #search_results do
            local y = 7 + (i - 1) * 2
            if y > height - 2 then break end
            if selected_result == i and result_action_mode then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
            end
            term.setCursorPos(2, y)
            term.write(search_results[i].name)
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, y + 1)
            term.write(search_results[i].artist or "")
        end
    elseif search_error then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.red)
        term.setCursorPos(2, 7)
        term.write("Network error")
    elseif search_waiting then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 7)
        term.write("Searching...")
    else
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 7)
        term.write("Paste YouTube link or search keywords")
    end

    if result_action_mode and selected_result and search_results then
        local item = search_results[selected_result]
        term.setBackgroundColor(colors.black)
        term.clear()
        drawTabs()
        term.setCursorPos(2, 3)
        term.setTextColor(colors.white)
        term.write(item.name)
        term.setCursorPos(2, 4)
        term.setTextColor(colors.lightGray)
        term.write(item.artist or "")
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.setCursorPos(2, 6)
        term.write(" Play Now ")
        term.setCursorPos(2, 8)
        term.write(" Play Next ")
        term.setCursorPos(2, 10)
        term.write(" Add to Queue ")
        term.setCursorPos(2, 12)
        term.write(" Cancel ")
    end
end

local function drawSchedule()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    term.write("--- Schedule ---")

    local mc_h = math.floor(os.time())
    local mc_m = math.floor((os.time() - mc_h) * 60)
    local now_str = string.format("%02d:%02d", mc_h, mc_m)

    if schedule_detail_mode then
        local item = schedule_items[schedule_selected]
        term.setCursorPos(2, 5)
        term.write("Period: " .. item.time)
        term.setCursorPos(2, 6)
        term.write("Name:   " .. item.name)
        term.setCursorPos(2, 7)
        term.write("Tracks: " .. #item.playlist)
        if #item.playlist > 0 then
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, 9)
            term.write("--- Playlist ---")
            for i = 1, math.min(#item.playlist, 8) do
                term.setTextColor(colors.white)
                term.setCursorPos(2, 9 + i)
                term.write(i .. ". " .. item.playlist[i].name)
            end
        end
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, height - 4)
        term.write("Current time: " .. now_str)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.setCursorPos(2, height - 2)
        term.write(" Add from Queue ")
        term.setCursorPos(22, height - 2)
        term.write(" Clear All ")
        term.setCursorPos(38, height - 2)
        term.write(" Back ")
    else
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 4)
        term.write("Current time: " .. now_str)
        for i, item in ipairs(schedule_items) do
            local y = 6 + (i - 1) * 3
            if y > height - 4 then break end
            local s, e = item.time:match("(%d+:%d+)-(%d+:%d+)")
            local active = s and e and now_str >= s and now_str < e
            if schedule_selected == i then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(active and colors.lime or colors.white)
            end
            term.setCursorPos(2, y)
            term.write(item.time .. " - " .. item.name .. (active and " *" or ""))
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, y + 1)
            term.write(#item.playlist .. " tracks")
        end
    end
end

local function drawZones()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    term.write("--- Connected Zones ---")
    local yi = 5
    local found = false
    for name, info in pairs(zones) do
        found = true
        if yi > height - 6 then break end
        term.setTextColor(colors.white)
        term.setCursorPos(2, yi)
        term.write("Zone: " .. name)
        term.setCursorPos(2, yi + 1)
        local st = info.status or "unknown"
        if st == "playing" then term.setTextColor(colors.lime)
        elseif st == "error" then term.setTextColor(colors.red)
        else term.setTextColor(colors.lightGray) end
        term.write("Status:  " .. st)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, yi + 2)
        term.write("Track:   " .. (info.track and info.track.name or "(none)"))
        term.setCursorPos(2, yi + 3)
        term.write("Offset:  " .. string.format("%.0f", (info.offset or 0) * 1000) .. "ms")
        term.setCursorPos(2, yi + 4)
        local ago = os.clock() - (info.last_seen or 0)
        term.write("Last:    " .. string.format("%.0f", ago) .. "s ago")
        yi = yi + 6
    end
    if not found then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 5)
        term.write("No slaves connected.")
        term.setCursorPos(2, 6)
        term.write("Start slave.lua on other computers.")
    end
end

local function redrawScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawTabs()
    if current_tab == 1 then drawNowPlaying()
    elseif current_tab == 2 then drawPlaylist()
    elseif current_tab == 3 then drawSchedule()
    elseif current_tab == 4 then drawZones() end
end

------------------------------------------------------------
-- 音声再生 (Master、イベントループをブロックしない版)
-- 1 chunk ごとに yield し、他ループがイベントを処理できるようにする
------------------------------------------------------------
local playback_stop = false

local function stopLocalPlayback()
    playing = false
    playback_stop = true
    for _, speaker in ipairs(speakers) do
        speaker.stop()
    end
end

-- 再生コルーチン: 再生キューから1曲取り出して再生
local playback_task = nil  -- {track=...}

local function audioLoop()
    while true do
        if playback_task then
            local track = playback_task
            playback_task = nil

            if isCached(track.id) then
                -- キャッシュから再生
                playing = true
                playback_stop = false
                playing_id = track.id
                is_loading = false
                is_error = false
                redrawScreen()

                local f = fs.open(cachePath(track.id), "rb")
                local chunk_size = 16 * 1024
                local first = f.read(4)
                local read_size = chunk_size - 4

                while playing and not playback_stop do
                    local chunk = f.read(read_size)
                    if not chunk then break end

                    local decoded
                    if first then
                        decoded = decoder(first .. chunk)
                        first = nil
                        read_size = chunk_size
                    else
                        decoded = decoder(chunk)
                    end

                    local fn = {}
                    for i, speaker in ipairs(speakers) do
                        fn[i] = function()
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
                    pcall(parallel.waitForAll, table.unpack(fn))
                    if playback_stop then break end
                end
                f.close()

            else
                -- Firebaseからストリーミング
                local url = API_BASE_URL .. "?v=" .. VERSION .. "&id=" .. textutils.urlEncode(track.id)
                is_loading = true
                playing_id = track.id
                redrawScreen()
                http.request({url = url, binary = true})

                -- http_success を待つ
                while true do
                    local ev, p1, p2 = os.pullEvent()
                    if ev == "http_success" and p1 == url then
                        is_loading = false
                        redrawScreen()
                        playing = true
                        playback_stop = false

                        local handle = p2
                        local first = handle.read(4)
                        local read_size = 16 * 1024 - 4

                        while playing and not playback_stop do
                            local chunk = handle.read(read_size)
                            if not chunk then break end

                            local decoded
                            if first then
                                decoded = decoder(first .. chunk)
                                first = nil
                                read_size = read_size + 4
                            else
                                decoded = decoder(chunk)
                            end

                            local fn = {}
                            for i, speaker in ipairs(speakers) do
                                fn[i] = function()
                                    local name = peripheral.getName(speaker)
                                    while not speaker.playAudio(decoded, volume) do
                                        parallel.waitForAny(
                                            function()
                                                repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
                                            end,
                                            function()
                                                local ev2 = os.pullEvent()
                                                if ev2 == "playback_stopped" then return end
                                            end
                                        )
                                        if playback_stop then return end
                                    end
                                end
                            end
                            pcall(parallel.waitForAll, table.unpack(fn))
                            if playback_stop then break end
                        end
                        handle.close()
                        break
                    elseif ev == "http_failure" and p1 == url then
                        is_loading = false
                        is_error = true
                        redrawScreen()
                        break
                    end
                end
            end

            playing = false
            is_loading = false
            redrawScreen()
        else
            sleep(0.1)
        end
    end
end

------------------------------------------------------------
-- 同期再生 (全Slave + Master)
-- 
-- syncLoop がバックグラウンドで実行する。
-- mouseLoop はリクエストをキューイングして即座に返る。
------------------------------------------------------------
local function syncLoop()
    while true do
        if sync_request then
            local track = sync_request
            sync_request = nil

            local slave_count = 0
            for _ in pairs(zones) do slave_count = slave_count + 1 end

            now_playing = track
            is_loading = true
            is_error = false
            redrawScreen()

            if slave_count == 0 then
                -- Master単独再生
                playback_task = {track = track}
                is_loading = false
                redrawScreen()
            else
                -- Phase 1: 全SlaveにDLコマンド
                broadcastCommand({
                    cmd = "download",
                    track = {id = track.id, name = track.name, artist = track.artist}
                })
                -- MasterもDL
                if not isCached(track.id) then
                    local url = API_BASE_URL .. "?v=" .. VERSION .. "&id=" .. textutils.urlEncode(track.id)
                    last_download_url = url
                    http.request({url = url, binary = true})
                end

                -- Phase 1待機 (タイムアウト30秒)
                local timeout = os.startTimer(30)
                local ready_count = 0
                while ready_count < slave_count do
                    local ev, p1 = os.pullEvent()
                    if ev == "timer" and p1 == timeout then break end
                    -- rednetLoop が ready を処理して ready_count を増やす
                    -- ただし、rednetLoop は別ループなのでここでは待機するだけ
                    -- → 実際には rednetLoop が zones に反映し、
                    --   ここで ready_count を直接読む代わりに
                    --   zones のカウントで判定
                    ready_count = 0
                    for _, info in pairs(zones) do
                        if info.status then ready_count = ready_count + 1 end
                    end
                end
                os.cancelTimer(timeout)

                -- Phase 2: RTT計測
                local max_offset = 0
                for name, info in pairs(zones) do
                    local total_rtt = 0
                    local valid = 0
                    for s = 1, RTT_SAMPLES do
                        rtt_pong_received = false
                        broadcastCommand({cmd = "ping", seq = s})
                        local t = os.startTimer(2)
                        local st = os.clock()
                        while not rtt_pong_received do
                            local ev, p1 = os.pullEvent()
                            if ev == "timer" and p1 == t then break end
                        end
                        os.cancelTimer(t)
                        if rtt_pong_received then
                            total_rtt = total_rtt + (os.clock() - st)
                            valid = valid + 1
                        end
                    end
                    if valid > 0 then
                        local avg = total_rtt / valid
                        zones[name].offset = avg / 2
                        if avg / 2 > max_offset then max_offset = avg / 2 end
                    end
                end

                -- Phase 3: 同期再生開始
                local start_time = os.clock() + max_offset + SYNC_LEAD_TIME
                broadcastCommand({
                    cmd = "play_at",
                    track = {id = track.id, name = track.name, artist = track.artist},
                    start_time = start_time,
                    volume = volume
                })

                -- Masterも同時刻に再生開始
                playback_task = {track = track}
                is_loading = false
                redrawScreen()
            end
        else
            sleep(0.1)
        end
    end
end

------------------------------------------------------------
-- スケジューラ
------------------------------------------------------------
local function getCurrentScheduleItem()
    local h = math.floor(os.time())
    local m = math.floor((os.time() - h) * 60)
    local t = string.format("%02d:%02d", h, m)
    for _, item in ipairs(schedule_items) do
        local s, e = item.time:match("(%d+:%d+)-(%d+:%d+)")
        if s and e and t >= s and t < e then return item end
    end
    return nil
end

local last_schedule_item = nil

local function checkSchedule()
    local current = getCurrentScheduleItem()
    if current and current ~= last_schedule_item and #current.playlist > 0 then
        queue = {}
        for _, track in ipairs(current.playlist) do
            table.insert(queue, track)
        end
        if not playing and #queue > 0 then
            local track = queue[1]
            table.remove(queue, 1)
            sync_request = track
        end
        last_schedule_item = current
    end
end

------------------------------------------------------------
-- メインループ
------------------------------------------------------------
openRednet()
redrawScreen()
broadcastCommand({cmd = "master_hello"})

-- Rednet受信ループ
local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, msg = pcall(textutils.unserialize, message)
            if ok and msg then
                if msg.type == "ready" then
                    if not zones[msg.zone] then zones[msg.zone] = {} end
                    zones[msg.zone].id = sender_id
                    zones[msg.zone].last_seen = os.clock()
                    zones[msg.zone].status = "ready"
                    redrawScreen()
                elseif msg.type == "pong" then
                    rtt_pong_received = true
                elseif msg.type == "status" then
                    if not zones[msg.zone] then zones[msg.zone] = {} end
                    zones[msg.zone].id = sender_id
                    zones[msg.zone].status = msg.state
                    zones[msg.zone].track = msg.track
                    zones[msg.zone].last_seen = os.clock()
                    redrawScreen()
                elseif msg.type == "hello" then
                    if not zones[msg.zone] then zones[msg.zone] = {} end
                    zones[msg.zone].id = sender_id
                    zones[msg.zone].last_seen = os.clock()
                    zones[msg.zone].status = "connected"
                    redrawScreen()
                end
            end
        end
    end
end

-- HTTP応答ループ
local function httpLoop()
    while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "http_success" then
            if p1 == last_search_url then
                search_results = textutils.unserialiseJSON(p2.readAll())
                search_waiting = false
                search_error = false
                redrawScreen()
            elseif p1 == last_download_url and playing_id then
                local data = p2.readAll()
                p2.close()
                if not isCached(playing_id) then
                    local f = fs.open(cachePath(playing_id), "wb")
                    f.write(data)
                    f.close()
                end
                is_loading = false
                redrawScreen()
            end
        elseif ev == "http_failure" then
            if p1 == last_search_url then
                search_error = true
                search_waiting = false
                redrawScreen()
            elseif p1 == last_download_url then
                is_loading = false
                is_error = true
                redrawScreen()
            end
        end
    end
end

-- Heartbeat
local function heartbeatLoop()
    while true do
        sleep(HEARTBEAT_INTERVAL)
        broadcastCommand({cmd = "heartbeat", playing = playing, track = now_playing})
    end
end

-- スケジューラ
local function schedulerLoop()
    while true do
        checkSchedule()
        sleep(30)
    end
end

-- UI入力ループ
local function mouseLoop()
    while true do
        local ev, btn, x, y = os.pullEvent("mouse_click")
        if btn ~= 1 then goto continue end

        if y == 1 then
            if x < width / 4 then current_tab = 1
            elseif x < width / 2 then current_tab = 2
            elseif x < width * 3 / 4 then current_tab = 3
            else current_tab = 4 end
            search_input_mode = false
            result_action_mode = false
            schedule_detail_mode = false
            redrawScreen()

        elseif current_tab == 1 then
            if y == 6 then
                if x >= 2 and x < 8 then
                    if playing then
                        stopLocalPlayback()
                        broadcastCommand({cmd = "stop"})
                    elseif now_playing then
                        sync_request = now_playing
                    elseif #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                    end
                    redrawScreen()
                elseif x >= 10 and x < 16 then
                    stopLocalPlayback()
                    broadcastCommand({cmd = "stop"})
                    if looping == 1 and now_playing then
                        table.insert(queue, now_playing)
                    end
                    if #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                    else
                        now_playing = nil
                        playing = false
                        playing_id = nil
                    end
                    redrawScreen()
                elseif x >= 18 and x < 28 then
                    looping = (looping + 1) % 3
                    redrawScreen()
                end
            elseif y == 8 and x >= 2 and x < 12 then
                if now_playing then
                    sync_request = now_playing
                end
            elseif y == 10 and x >= 2 and x <= 25 then
                volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
                redrawScreen()
            end

        elseif current_tab == 2 then
            if not result_action_mode then
                if y >= 3 and y <= 5 then
                    search_input_mode = true
                    search_query = ""
                    redrawScreen()
                    term.setCursorPos(3, 4)
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    local input = read()
                    search_input_mode = false
                    if #input > 0 then
                        search_query = input
                        last_search_url = API_BASE_URL .. "?v=" .. VERSION .. "&search=" .. textutils.urlEncode(input)
                        http.request(last_search_url)
                        search_results = nil
                        search_error = false
                        search_waiting = true
                    end
                    redrawScreen()
                elseif search_results then
                    for i = 1, #search_results do
                        local ry = 7 + (i - 1) * 2
                        if y == ry or y == ry + 1 then
                            selected_result = i
                            result_action_mode = true
                            redrawScreen()
                            break
                        end
                    end
                end
            else
                if selected_result and search_results then
                    local item = search_results[selected_result]
                    if y == 6 then
                        stopLocalPlayback()
                        broadcastCommand({cmd = "stop"})
                        if item.type == "playlist" and item.playlist_items then
                            queue = {}
                            for i = 2, #item.playlist_items do
                                table.insert(queue, item.playlist_items[i])
                            end
                            now_playing = item.playlist_items[1]
                        else
                            now_playing = item
                        end
                        result_action_mode = false
                        sync_request = now_playing
                    elseif y == 8 then
                        if item.type == "playlist" and item.playlist_items then
                            for i = #item.playlist_items, 1, -1 do
                                table.insert(queue, 1, item.playlist_items[i])
                            end
                        else
                            table.insert(queue, 1, item)
                        end
                        result_action_mode = false
                        redrawScreen()
                    elseif y == 10 then
                        if item.type == "playlist" and item.playlist_items then
                            for _, t in ipairs(item.playlist_items) do
                                table.insert(queue, t)
                            end
                        else
                            table.insert(queue, item)
                        end
                        result_action_mode = false
                        redrawScreen()
                    elseif y == 12 then
                        result_action_mode = false
                        redrawScreen()
                    end
                end
            end

        elseif current_tab == 3 then
            if schedule_detail_mode then
                if y == height - 2 then
                    if x >= 2 and x < 20 then
                        local item = schedule_items[schedule_selected]
                        for _, t in ipairs(queue) do
                            table.insert(item.playlist, t)
                        end
                        redrawScreen()
                    elseif x >= 22 and x < 34 then
                        schedule_items[schedule_selected].playlist = {}
                        redrawScreen()
                    elseif x >= 38 and x < 44 then
                        schedule_detail_mode = false
                        redrawScreen()
                    end
                end
            else
                for i = 1, #schedule_items do
                    local sy = 6 + (i - 1) * 3
                    if y >= sy and y < sy + 3 then
                        schedule_selected = i
                        schedule_detail_mode = true
                        redrawScreen()
                        break
                    end
                end
            end
        end
        ::continue::
    end
end

-- ドラッグ (音量)
local function dragLoop()
    while true do
        local ev, btn, x, y = os.pullEvent("mouse_drag")
        if btn == 1 and current_tab == 1 and y == 10 and x >= 2 and x <= 25 then
            volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
            redrawScreen()
        end
    end
end

parallel.waitForAny(
    rednetLoop,
    httpLoop,
    heartbeatLoop,
    schedulerLoop,
    mouseLoop,
    dragLoop,
    audioLoop,
    syncLoop
)
