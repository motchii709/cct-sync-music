--[[
  Theme Park Music System - Master
  Advanced Computer専用 (カラー表示 + マウス操作)
  
  複数のSlave Computerをrednet経由で制御し、
  音楽を同期再生する。
  
  使い方:
    1. Wireless ModemをComputerに取り付ける
    2. このファイルを実行する
    3. Slaveを起動してrednet接続を待つ
    4. Playlistタブで曲を検索・追加
    5. 再生すると全Slaveに同期配信される
]]

------------------------------------------------------------
-- 設定
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music"
local SYNC_LEAD_TIME = 3.0
local RTT_SAMPLES = 3
local HEARTBEAT_INTERVAL = 5
local SLAVE_TIMEOUT = 15

------------------------------------------------------------
-- 状態
------------------------------------------------------------
local width, height = term.getSize()
local current_tab = 1

local playing = false
local now_playing = nil
local queue = {}
local volume = 1.5

local search_query = ""
local search_results = nil
local search_error = false
local search_waiting = false
local search_input_mode = false
local last_search_url = nil
local selected_result = nil
local result_action_mode = false

-- zones: {zone_name = {id, status, track, last_seen, offset, alive}}
local zones = {}
local playing_id = nil
local is_loading = false
local is_error = false

local sync_request = nil
local rtt_pong_received = false

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

local function sendToZone(zone_name, cmd)
    if zones[zone_name] and zones[zone_name].id then
        rednet.send(zones[zone_name].id, textutils.serialize(cmd), PROTOCOL)
    end
end

------------------------------------------------------------
-- 接続管理
------------------------------------------------------------
local function getAliveSlaves()
    local alive = {}
    for name, info in pairs(zones) do
        if info.alive then
            table.insert(alive, name)
        end
    end
    return alive
end

local function getAliveSlaveCount()
    local count = 0
    for _, info in pairs(zones) do
        if info.alive then count = count + 1 end
    end
    return count
end

local function markAllSlavesPlaying(track)
    for name, info in pairs(zones) do
        if info.alive then
            info.status = "playing"
            info.track = track
        end
    end
end

local function markAllSlavesStopped()
    for name, info in pairs(zones) do
        info.status = "idle"
        info.track = nil
    end
end

------------------------------------------------------------
-- UI描画
------------------------------------------------------------
local function drawTabs()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    local tabs = {" Now Playing ", " Playlist ", " Zones "}
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
        term.write("--- Queue (" .. #queue .. ") ---")
        for i = 1, math.min(#queue, 8) do
            term.setTextColor(colors.white)
            term.setCursorPos(2, 12 + i)
            term.write(i .. ". " .. queue[i].name)
        end
    end

    local alive = getAliveSlaveCount()
    if alive > 0 then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(35, 3)
        term.write("--- Zones (" .. alive .. ") ---")
        local yi = 4
        for name, info in pairs(zones) do
            if not info.alive then goto skip end
            if yi > height then break end
            term.setCursorPos(35, yi)
            local col = colors.white
            if info.status == "playing" then col = colors.lime
            elseif info.status == "error" then col = colors.red
            elseif info.status == "downloading" then col = colors.yellow end
            term.setTextColor(col)
            term.write(name)
            yi = yi + 1
            ::skip::
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
        term.write(" Add to Queue ")
        term.setCursorPos(2, 10)
        term.write(" Cancel ")
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
        if yi > height - 7 then break end
        term.setTextColor(colors.white)
        term.setCursorPos(2, yi)
        term.write("Zone: " .. name)
        term.setCursorPos(2, yi + 1)
        local st = info.status or "unknown"
        if info.alive then
            if st == "playing" then term.setTextColor(colors.lime)
            elseif st == "error" then term.setTextColor(colors.red)
            elseif st == "downloading" then term.setTextColor(colors.yellow)
            else term.setTextColor(colors.white) end
            term.write("Status:  " .. st)
        else
            term.setTextColor(colors.red)
            term.write("Status:  DEAD")
        end
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
    elseif current_tab == 3 then drawZones() end
end

------------------------------------------------------------
-- 同期再生 (全Slave)
--
-- 3フェーズ:
--   Phase 1: DL → ready応答を全Slaveから待つ
--   Phase 2: RTT計測
--   Phase 3: play_at 送信 → Slave再生開始確認を待つ
--   Phase 4: track_end 待機 → 次の曲へ
------------------------------------------------------------
local function syncLoop()
    while true do
        if sync_request then
            local track = sync_request
            sync_request = nil

            local slave_count = getAliveSlaveCount()
            if slave_count == 0 then
                is_loading = false
                redrawScreen()
                goto continue
            end

            now_playing = track
            playing_id = track.id
            is_loading = true
            is_error = false
            redrawScreen()

            -- Phase 1: DLコマンド送信
            broadcastCommand({
                cmd = "download",
                track = {id = track.id, name = track.name, artist = track.artist}
            })

            -- 全Slaveのready応答を待つ (タイムアウト30秒)
            local timeout = os.startTimer(30)
            while true do
                local ev, p1 = os.pullEvent()
                if ev == "timer" and p1 == timeout then break end
                -- rednetLoopがreadyを処理、zonesのstatusを更新
                local all_ready = true
                for _, info in pairs(zones) do
                    if info.alive and info.status ~= "ready" then
                        all_ready = false
                        break
                    end
                end
                if all_ready then break end
            end
            os.cancelTimer(timeout)

            -- Phase 2: RTT計測
            local max_offset = 0
            for name, info in pairs(zones) do
                if not info.alive then goto skip_rtt end
                local total_rtt = 0
                local valid = 0
                for s = 1, RTT_SAMPLES do
                    rtt_pong_received = false
                    sendToZone(name, {cmd = "ping", seq = s})
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
                ::skip_rtt::
            end

            -- Phase 3: play_at 送信
            local start_time = os.clock() + max_offset + SYNC_LEAD_TIME
            broadcastCommand({
                cmd = "play_at",
                track = {id = track.id, name = track.name, artist = track.artist},
                start_time = start_time,
                volume = volume
            })

            markAllSlavesPlaying(track)
            playing = true
            is_loading = false
            redrawScreen()

            -- Phase 4: track_end を待つ
            -- Slaveからのtrack_endメッセージか、全Slaveがidleになるのを監視
            while playing do
                local ev = os.pullEvent()
                if ev == "track_end" then
                    -- 全Slaveが再生終了したかチェック
                    local all_done = true
                    for _, info in pairs(zones) do
                        if info.alive and info.status == "playing" then
                            all_done = false
                            break
                        end
                    end
                    if all_done then break end
                elseif ev == "stop_requested" then
                    break
                end
            end

            playing = false
            markAllSlavesStopped()
            redrawScreen()

            -- 次の曲があれば自動再生
            if #queue > 0 then
                local next_track = queue[1]
                table.remove(queue, 1)
                sync_request = next_track
            end

            ::continue::
        else
            sleep(0.1)
        end
    end
end

------------------------------------------------------------
-- メインループ
------------------------------------------------------------
openRednet()
redrawScreen()
broadcastCommand({cmd = "master_hello"})

local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, msg = pcall(textutils.unserialize, message)
            if ok and msg then
                if msg.type == "hello" then
                    if not zones[msg.zone] then zones[msg.zone] = {} end
                    zones[msg.zone].id = sender_id
                    zones[msg.zone].last_seen = os.clock()
                    zones[msg.zone].alive = true
                    if not zones[msg.zone].status then
                        zones[msg.zone].status = "connected"
                    end
                    redrawScreen()

                elseif msg.type == "heartbeat" then
                    if zones[msg.zone] then
                        zones[msg.zone].last_seen = os.clock()
                        zones[msg.zone].alive = true
                        zones[msg.zone].status = msg.state
                        if msg.track then
                            zones[msg.zone].track = msg.track
                        end
                        redrawScreen()
                    end

                elseif msg.type == "ready" then
                    if zones[msg.zone] then
                        zones[msg.zone].status = "ready"
                        zones[msg.zone].last_seen = os.clock()
                        redrawScreen()
                    end

                elseif msg.type == "pong" then
                    rtt_pong_received = true

                elseif msg.type == "track_end" then
                    if zones[msg.zone] then
                        zones[msg.zone].status = "idle"
                        zones[msg.zone].track = nil
                        zones[msg.zone].last_seen = os.clock()
                        redrawScreen()
                        os.queueEvent("track_end")
                    end

                elseif msg.type == "play_started" then
                    if zones[msg.zone] then
                        zones[msg.zone].status = "playing"
                        zones[msg.zone].track = msg.track
                        zones[msg.zone].last_seen = os.clock()
                        redrawScreen()
                    end

                elseif msg.type == "play_stopped" then
                    if zones[msg.zone] then
                        zones[msg.zone].status = "idle"
                        zones[msg.zone].track = nil
                        zones[msg.zone].last_seen = os.clock()
                        redrawScreen()
                    end
                end
            end
        end
    end
end

-- 存活管理: 一定時間heartbeatが来ないSlaveをdeadにする
local function aliveCheckLoop()
    while true do
        sleep(HEARTBEAT_INTERVAL)
        for name, info in pairs(zones) do
            if info.alive then
                local elapsed = os.clock() - (info.last_seen or 0)
                if elapsed > SLAVE_TIMEOUT then
                    info.alive = false
                    info.status = "dead"
                    redrawScreen()
                end
            end
        end
    end
end

local function httpLoop()
    while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "http_success" and p1 == last_search_url then
            search_results = textutils.unserialiseJSON(p2.readAll())
            search_waiting = false
            search_error = false
            redrawScreen()
        elseif ev == "http_failure" and p1 == last_search_url then
            search_error = true
            search_waiting = false
            redrawScreen()
        end
    end
end

local function heartbeatLoop()
    while true do
        sleep(HEARTBEAT_INTERVAL)
        broadcastCommand({cmd = "heartbeat", playing = playing, track = now_playing})
    end
end

local function mouseLoop()
    while true do
        local ev, btn, x, y = os.pullEvent("mouse_click")
        if btn ~= 1 then goto continue end

        if y == 1 then
            if x < width / 3 then current_tab = 1
            elseif x < width * 2 / 3 then current_tab = 2
            else current_tab = 3 end
            search_input_mode = false
            result_action_mode = false
            redrawScreen()

        elseif current_tab == 1 then
            if y == 6 then
                if x >= 2 and x < 8 then
                    if playing then
                        playing = false
                        broadcastCommand({cmd = "stop"})
                        os.queueEvent("stop_requested")
                    elseif now_playing then
                        sync_request = now_playing
                    elseif #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                    end
                    redrawScreen()
                elseif x >= 10 and x < 16 then
                    broadcastCommand({cmd = "stop"})
                    playing = false
                    os.queueEvent("stop_requested")
                    if #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                    else
                        now_playing = nil
                        playing_id = nil
                    end
                    redrawScreen()
                end
            elseif y == 8 and x >= 2 and x < 12 then
                if now_playing then
                    sync_request = now_playing
                end
            elseif y == 10 and x >= 2 and x <= 25 then
                volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
                broadcastCommand({cmd = "volume", level = volume})
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
                        broadcastCommand({cmd = "stop"})
                        playing = false
                        if item.type == "playlist" and item.playlist_items then
                            queue = {}
                            for _, t in ipairs(item.playlist_items) do
                                table.insert(queue, t)
                            end
                            now_playing = table.remove(queue, 1)
                        else
                            now_playing = item
                        end
                        result_action_mode = false
                        sync_request = now_playing
                    elseif y == 8 then
                        if item.type == "playlist" and item.playlist_items then
                            for _, t in ipairs(item.playlist_items) do
                                table.insert(queue, t)
                            end
                        else
                            table.insert(queue, item)
                        end
                        result_action_mode = false
                        redrawScreen()
                    elseif y == 10 then
                        result_action_mode = false
                        redrawScreen()
                    end
                end
            end
        end
        ::continue::
    end
end

local function dragLoop()
    while true do
        local ev, btn, x, y = os.pullEvent("mouse_drag")
        if btn == 1 and current_tab == 1 and y == 10 and x >= 2 and x <= 25 then
            volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
            broadcastCommand({cmd = "volume", level = volume})
            redrawScreen()
        end
    end
end

parallel.waitForAny(
    rednetLoop,
    httpLoop,
    heartbeatLoop,
    aliveCheckLoop,
    mouseLoop,
    dragLoop,
    syncLoop
)
