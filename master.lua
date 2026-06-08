--[[
  Theme Park Music System - Master v3
  Advanced Computer専用 (カラー表示 + マウス操作)
  
  複数のSlave Computerをrednet経由で制御し、
  音楽を同期再生する。
  
   使い方:
    1. Wireless ModemをComputerに取り付ける
    2. wget https://raw.githubusercontent.com/motchii709/cct-sync-music/master/master.lua master
    3. 以降は `master` で起動 (自動更新される)
]]

------------------------------------------------------------
-- 自動更新
------------------------------------------------------------
local SELF_URL = "https://raw.githubusercontent.com/motchii709/cct-sync-music/master/master.lua"
local SELF_NAME = "master"

do
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Theme Park Music - Master ===")
    print("")
    print("Checking for updates...")
    local ok, result = pcall(function()
        http.request(SELF_URL)
        local timer = os.startTimer(10)
        while true do
            local ev, p1, p2 = os.pullEvent()
            if ev == "http_success" and p1 == SELF_URL then
                local data = p2.readAll()
                p2.close()
                return data
            elseif ev == "http_failure" and p1 == SELF_URL then
                return nil
            elseif ev == "timer" and p1 == timer then
                return nil
            end
        end
    end)
    if ok and result then
        local f = fs.open(SELF_NAME, "w")
        if f then
            f.write(result)
            f.close()
            print("Updated! Restarting...")
            sleep(1)
            shell.run(SELF_NAME)
            return
        end
    end
    print("Using current version.")
    sleep(0.5)
end

------------------------------------------------------------
-- 設定
------------------------------------------------------------
local API_BASE_URL = "https://ipod-2to6magyna-uc.a.run.app/"
local VERSION = "2.1"
local PROTOCOL = "park_music_v3"
local SYNC_LEAD_TIME = 3.0
local RTT_SAMPLES = 3
local HEARTBEAT_INTERVAL = 5
local SLAVE_TIMEOUT = 15
local CONFIG_FILE = ".master_config"

------------------------------------------------------------
-- 初期化
------------------------------------------------------------
local width, height = term.getSize()

-- グループ名 (初回入力 or ファイルから読み込み)
local group_name = nil
do
    local f = fs.open(CONFIG_FILE, "r")
    if f then
        group_name = f.readLine()
        f.close()
    end
    if not group_name then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        print("=== Theme Park Music - Master ===")
        print("")
        print("Group name:")
        term.setBackgroundColor(colors.gray)
        term.setCursorPos(1, 4)
        term.clearLine()
        term.setCursorPos(1, 4)
        group_name = read()
        if #group_name == 0 then error("Group name required.", 0) end
        local wf = fs.open(CONFIG_FILE, "w")
        wf.write(group_name)
        wf.close()
    end
end

------------------------------------------------------------
-- 状態
------------------------------------------------------------
local current_tab = 1  -- 1=NowPlaying, 2=Playlist, 3=Slaves, 4=Log

-- 再生
local playing = false
local now_playing = nil
local queue = {}
local volume = 1.5

-- 検索
local search_query = ""
local search_results = nil
local search_error = false
local search_waiting = false
local search_input_mode = false
local last_search_url = nil
local selected_result = nil
local result_action_mode = false

-- Slave管理
local slaves = {}
local playing_id = nil
local is_loading = false
local is_error = false

-- 同期
local sync_request = nil
local rtt_pong_by_id = {}  -- per-slave pong tracking

-- ログ
local log_lines = {}
local LOG_MAX = 50

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

local function getSlaveCount()
    local count = 0
    for _ in pairs(slaves) do count = count + 1 end
    return count
end

local function getAliveSlaveCount()
    local count = 0
    for _, info in pairs(slaves) do
        if info.alive then count = count + 1 end
    end
    return count
end

local function markAllPlaying(track)
    for _, info in pairs(slaves) do
        if info.alive then
            info.status = "playing"
            info.track = track
        end
    end
end

local function markAllStopped()
    for _, info in pairs(slaves) do
        info.status = "idle"
        info.track = nil
    end
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
    local out = {}
    for k, v in pairs(cmd) do out[k] = v end
    out.group = group_name
    rednet.broadcast(textutils.serialize(out), PROTOCOL)
end

local function sendTo(id, cmd)
    local out = {}
    for k, v in pairs(cmd) do out[k] = v end
    out.group = group_name
    rednet.send(id, textutils.serialize(out), PROTOCOL)
end

------------------------------------------------------------
-- UI: タブバー
------------------------------------------------------------
local function drawTabs()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    local tabs = {" Now Playing ", " Playlist ", " Slaves ", " Log "}
    for i = 1, #tabs do
        if current_tab == i then
            term.setTextColor(colors.black)
            term.setBackgroundColor(colors.white)
        else
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.gray)
        end
        local pos = math.max(1, math.floor((width / #tabs) * (i - 0.5)) - math.ceil(#tabs[i] / 2) + 1)
        term.setCursorPos(pos, 1)
        term.write(tabs[i])
    end
    -- グループ名表示
    term.setTextColor(colors.yellow)
    term.setBackgroundColor(colors.gray)
    local gx = math.max(1, width - #group_name)
    term.setCursorPos(gx, 1)
    term.write(group_name)
end

------------------------------------------------------------
-- UI: Now Playing
------------------------------------------------------------
local function drawNowPlaying()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    if now_playing then
        term.setCursorPos(2, 3)
        local name = now_playing.name or "unknown"
        if #name > width - 3 then name = string.sub(name, 1, width - 6) .. "..." end
        term.write(name)
        if now_playing.artist then
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, 4)
            local artist = now_playing.artist
            if #artist > width - 3 then artist = string.sub(artist, 1, width - 6) .. "..." end
            term.write(artist)
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
        if is_loading then
            term.write(" Cancel ")
        else
            term.write(" Play ")
        end
    end

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(10, 6)
    term.write(" Skip ")

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.blue)
    term.setCursorPos(2, 8)
    term.write(" Sync All ")

    paintutils.drawBox(2, 10, 25, 10, colors.gray)
    local vol_w = math.floor(23 * (volume / 3) + 0.5)
    if vol_w > 0 then
        paintutils.drawBox(2, 10, 2 + vol_w - 1, 10, colors.white)
    end
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(27, 10)
    term.write(math.floor(100 * (volume / 3)) .. "%")

    if #queue > 0 then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 12)
        term.write("--- Queue (" .. #queue .. ") ---")
        for i = 1, math.min(#queue, height - 13) do
            term.setTextColor(colors.white)
            term.setCursorPos(2, 12 + i)
            local qname = queue[i].name or "unknown"
            if #qname > width - 5 then qname = string.sub(qname, 1, width - 8) .. "..." end
            term.write(i .. ". " .. qname)
        end
    end
end

------------------------------------------------------------
-- UI: Playlist
------------------------------------------------------------
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
            local rname = search_results[i].name or "unknown"
            if #rname > width - 3 then rname = string.sub(rname, 1, width - 6) .. "..." end
            term.write(rname)
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, y + 1)
            local rartist = search_results[i].artist or ""
            if #rartist > width - 3 then rartist = string.sub(rartist, 1, width - 6) .. "..." end
            term.write(rartist)
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
        if item then
            term.setBackgroundColor(colors.black)
            term.clear()
            drawTabs()
            term.setCursorPos(2, 3)
            term.setTextColor(colors.white)
            local iname = item.name or "unknown"
            if #iname > width - 3 then iname = string.sub(iname, 1, width - 6) .. "..." end
            term.write(iname)
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
end

------------------------------------------------------------
-- UI: Slaves
------------------------------------------------------------
local function drawSlaves()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    local alive = getAliveSlaveCount()
    term.write("--- Connected Slaves (" .. alive .. "/" .. getSlaveCount() .. ") ---")

    local yi = 5
    local found = false
    for id, info in pairs(slaves) do
        found = true
        if yi > height - 5 then break end

        term.setCursorPos(2, yi)
        if info.alive then
            term.setTextColor(colors.white)
            local idstr = "ID: " .. id .. "  " .. (info.name or "")
            if #idstr > width - 3 then idstr = string.sub(idstr, 1, width - 6) .. "..." end
            term.write(idstr)
            yi = yi + 1
            term.setCursorPos(2, yi)
            local st = info.status or "unknown"
            if st == "playing" then term.setTextColor(colors.lime)
            elseif st == "error" then term.setTextColor(colors.red)
            elseif st == "downloading" then term.setTextColor(colors.yellow)
            else term.setTextColor(colors.lightGray) end
            term.write("Status:  " .. st)
            yi = yi + 1
            term.setCursorPos(2, yi)
            term.setTextColor(colors.lightGray)
            local tname = info.track and info.track.name or "(none)"
            if #tname > width - 12 then tname = string.sub(tname, 1, width - 15) .. "..." end
            term.write("Track:   " .. tname)
            yi = yi + 1
            term.setCursorPos(2, yi)
            term.write("Offset:  " .. string.format("%.0f", (info.offset or 0) * 1000) .. "ms")
            yi = yi + 1
            local ago = os.clock() - (info.last_seen or 0)
            term.write("Last:    " .. string.format("%.0f", ago) .. "s ago")
            yi = yi + 2
        else
            term.setTextColor(colors.red)
            term.write("ID: " .. id .. "  DEAD")
            yi = yi + 2
        end
    end

    if not found then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 5)
        term.write("No slaves connected.")
        term.setCursorPos(2, 6)
        term.write("Start slave.lua on other computers.")
        term.setCursorPos(2, 8)
        term.write("Group: " .. group_name)
    end
end

------------------------------------------------------------
-- UI: Log
------------------------------------------------------------
local function drawLog()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    term.write("--- Log (" .. #log_lines .. " entries) ---")

    local start = math.max(1, #log_lines - (height - 5))
    local yi = 5
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
-- 描画
------------------------------------------------------------
local last_redraw = 0
local needs_redraw = false

local function scheduleRedraw()
    needs_redraw = true
end

local function redrawScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawTabs()
    if current_tab == 1 then drawNowPlaying()
    elseif current_tab == 2 then drawPlaylist()
    elseif current_tab == 3 then drawSlaves()
    elseif current_tab == 4 then drawLog() end
    needs_redraw = false
    last_redraw = os.clock()
end

------------------------------------------------------------
-- 同期再生
------------------------------------------------------------
local function syncLoop()
    while true do
        if sync_request then
            local track = sync_request
            sync_request = nil

            local slave_count = getAliveSlaveCount()
            if slave_count == 0 then
                is_loading = false
                log("No slaves connected")
                scheduleRedraw()
                goto continue
            end

            -- 既に再生中の場合は停止してから開始
            if playing then
                playing = false
                broadcastCommand({cmd = "stop"})
                markAllStopped()
                sleep(0.5)
            end

            now_playing = track
            playing_id = track.id
            is_loading = true
            is_error = false
            log("Starting: " .. (track.name or track.id))
            scheduleRedraw()

            -- Phase 1: DLコマンド送信
            broadcastCommand({
                cmd = "download",
                track = {id = track.id, name = track.name, artist = track.artist}
            })

            -- 全Slaveのready応答を待つ (タイムアウト30秒)
            local deadline = os.clock() + 30
            while true do
                local all_ready = true
                for _, info in pairs(slaves) do
                    if info.alive and info.status ~= "ready" then
                        all_ready = false
                        break
                    end
                end
                if all_ready then break end
                if os.clock() > deadline then
                    log("DL timeout")
                    break
                end
                sleep(0.1)
            end

            -- Phase 2: RTT計測
            local max_offset = 0
            for id, info in pairs(slaves) do
                if not info.alive then goto skip_rtt end
                local total_rtt = 0
                local valid = 0
                for s = 1, RTT_SAMPLES do
                    rtt_pong_by_id[id] = nil
                    sendTo(id, {cmd = "ping", seq = s})
                    local st = os.clock()
                    while rtt_pong_by_id[id] ~= s and os.clock() - st < 2 do
                        sleep(0.1)
                    end
                    if rtt_pong_by_id[id] == s then
                        total_rtt = total_rtt + (os.clock() - st)
                        valid = valid + 1
                    end
                end
                if valid > 0 then
                    local avg = total_rtt / valid
                    slaves[id].offset = avg / 2
                    if avg / 2 > max_offset then max_offset = avg / 2 end
                end
                ::skip_rtt::
            end

            -- Phase 3: play_at 送信
            local start_time = os.clock() + max_offset + SYNC_LEAD_TIME
            log("Play at: " .. string.format("+%.1fs", max_offset + SYNC_LEAD_TIME))
            broadcastCommand({
                cmd = "play_at",
                track = {id = track.id, name = track.name, artist = track.artist},
                start_time = start_time,
                volume = volume
            })

            markAllPlaying(track)
            playing = true
            is_loading = false
            scheduleRedraw()

            -- Phase 4: track_end を待つ
            while playing do
                local all_done = true
                for _, info in pairs(slaves) do
                    if info.alive and info.status == "playing" then
                        all_done = false
                        break
                    end
                end
                if all_done then break end
                sleep(0.1)
            end

            playing = false
            markAllStopped()
            log("Track ended: " .. (track.name or ""))
            scheduleRedraw()

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
-- Rednet受信
------------------------------------------------------------
local function rednetLoop()
    while true do
        local sender_id, message, protocol = rednet.receive(PROTOCOL)
        if sender_id and message then
            local ok, msg = pcall(textutils.unserialize, message)
            if ok and msg and msg.group == group_name then
                if msg.type == "hello" then
                    if not slaves[sender_id] then
                        slaves[sender_id] = {id = sender_id}
                        log("Slave connected: ID " .. sender_id)
                    end
                    slaves[sender_id].last_seen = os.clock()
                    slaves[sender_id].alive = true
                    slaves[sender_id].name = msg.name or ("Slave " .. sender_id)
                    if not slaves[sender_id].status then
                        slaves[sender_id].status = "connected"
                    end
                    sendTo(sender_id, {cmd = "welcome"})
                    scheduleRedraw()

                elseif msg.type == "heartbeat" then
                    if slaves[sender_id] then
                        slaves[sender_id].last_seen = os.clock()
                        slaves[sender_id].alive = true
                        slaves[sender_id].status = msg.state
                        if msg.track then
                            slaves[sender_id].track = msg.track
                        end
                        scheduleRedraw()
                    end

                elseif msg.type == "ready" then
                    if slaves[sender_id] then
                        slaves[sender_id].status = "ready"
                        slaves[sender_id].last_seen = os.clock()
                        log("Ready: " .. sender_id)
                        scheduleRedraw()
                    end

                elseif msg.type == "pong" then
                    if slaves[sender_id] then
                        -- per-slave, per-sequence pong tracking
                        local seq = msg.seq
                        if seq then
                            rtt_pong_by_id[sender_id] = seq
                        else
                            rtt_pong_by_id[sender_id] = 0
                        end
                    end

                elseif msg.type == "track_end" then
                    if slaves[sender_id] then
                        slaves[sender_id].status = "idle"
                        slaves[sender_id].track = nil
                        slaves[sender_id].last_seen = os.clock()
                        log("End: " .. sender_id)
                        scheduleRedraw()
                    end

                elseif msg.type == "play_started" then
                    if slaves[sender_id] then
                        slaves[sender_id].status = "playing"
                        slaves[sender_id].track = msg.track
                        slaves[sender_id].last_seen = os.clock()
                        log("Playing: " .. sender_id)
                        scheduleRedraw()
                    end

                elseif msg.type == "play_stopped" then
                    if slaves[sender_id] then
                        slaves[sender_id].status = "idle"
                        slaves[sender_id].track = nil
                        slaves[sender_id].last_seen = os.clock()
                        log("Stopped: " .. sender_id)
                        scheduleRedraw()
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- 存活管理
------------------------------------------------------------
local function aliveCheckLoop()
    while true do
        sleep(HEARTBEAT_INTERVAL)
        for id, info in pairs(slaves) do
            if info.alive then
                local elapsed = os.clock() - (info.last_seen or 0)
                if elapsed > SLAVE_TIMEOUT then
                    info.alive = false
                    info.status = "dead"
                    log("Dead: ID " .. id)
                    scheduleRedraw()
                end
            end
        end
    end
end

------------------------------------------------------------
-- HTTP受信 (フィルタ済み)
------------------------------------------------------------
local function httpLoop()
    while true do
        local ev, p1, p2 = os.pullEvent("http_success")
        if p1 == last_search_url then
            local ok, data = pcall(function() return p2.readAll() end)
            if p2 then p2.close() end
            if ok and data then
                local ok2, parsed = pcall(textutils.unserialiseJSON, data)
                if ok2 and parsed then
                    search_results = parsed
                    search_waiting = false
                    search_error = false
                else
                    search_error = true
                    search_waiting = false
                end
            else
                search_error = true
                search_waiting = false
            end
            scheduleRedraw()
        end
    end
end

local function httpFailLoop()
    while true do
        local ev, p1 = os.pullEvent("http_failure")
        if p1 == last_search_url then
            search_error = true
            search_waiting = false
            scheduleRedraw()
        end
    end
end

------------------------------------------------------------
-- Heartbeat送信
------------------------------------------------------------
local function heartbeatLoop()
    while true do
        sleep(HEARTBEAT_INTERVAL)
        broadcastCommand({cmd = "heartbeat"})
    end
end

------------------------------------------------------------
-- 描画スケジューラ
------------------------------------------------------------
local function drawScheduler()
    while true do
        sleep(0.1)
        if needs_redraw and os.clock() - last_redraw > 0.3 then
            redrawScreen()
        end
    end
end

------------------------------------------------------------
-- マウス操作
------------------------------------------------------------
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
            scheduleRedraw()

        elseif current_tab == 1 then
            if y == 6 then
                if x >= 2 and x < 8 then
                    if playing then
                        playing = false
                        broadcastCommand({cmd = "stop"})
                        log("Stopped by user")
                    elseif is_loading then
                        -- Loading中: キャンセル
                        is_loading = false
                        is_error = false
                        sync_request = nil
                        broadcastCommand({cmd = "stop"})
                        log("Cancelled by user")
                    elseif now_playing then
                        sync_request = now_playing
                    elseif #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                    end
                    scheduleRedraw()
                elseif x >= 10 and x < 16 then
                    broadcastCommand({cmd = "stop"})
                    playing = false
                    is_loading = false
                    if #queue > 0 then
                        now_playing = queue[1]
                        table.remove(queue, 1)
                        sync_request = now_playing
                        log("Skipped to next")
                    else
                        now_playing = nil
                        playing_id = nil
                        log("Skipped (queue empty)")
                    end
                    scheduleRedraw()
                end
            elseif y == 8 and x >= 2 and x < 12 then
                if now_playing and not is_loading then
                    sync_request = now_playing
                    log("Sync: " .. (now_playing.name or ""))
                end
            elseif y == 10 and x >= 2 and x <= 25 then
                volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
                broadcastCommand({cmd = "volume", level = volume})
                scheduleRedraw()
            end

        elseif current_tab == 2 then
            if not result_action_mode then
                if y >= 3 and y <= 5 then
                    search_input_mode = true
                    redrawScreen()
                    term.setCursorPos(3, 4)
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    local input = read(nil, nil, search_query)
                    search_input_mode = false
                    if #input > 0 then
                        search_query = input
                        last_search_url = API_BASE_URL .. "?v=" .. VERSION .. "&search=" .. textutils.urlEncode(input)
                        http.request(last_search_url)
                        search_results = nil
                        search_error = false
                        search_waiting = true
                    end
                    scheduleRedraw()
                elseif search_results then
                    for i = 1, #search_results do
                        local ry = 7 + (i - 1) * 2
                        if y == ry or y == ry + 1 then
                            selected_result = i
                            result_action_mode = true
                            scheduleRedraw()
                            break
                        end
                    end
                end
            else
                if selected_result and search_results then
                    local item = search_results[selected_result]
                    if item then
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
                            log("Play: " .. (item.name or ""))
                            sync_request = now_playing
                        elseif y == 8 then
                            if item.type == "playlist" and item.playlist_items then
                                for _, t in ipairs(item.playlist_items) do
                                    table.insert(queue, t)
                                end
                                log("Queue: " .. #item.playlist_items .. " tracks")
                            else
                                table.insert(queue, item)
                                log("Queue: " .. (item.name or ""))
                            end
                            result_action_mode = false
                            scheduleRedraw()
                        elseif y == 10 then
                            result_action_mode = false
                            scheduleRedraw()
                        end
                    end
                end
            end
        end
        ::continue::
    end
end

------------------------------------------------------------
-- ドラッグ (ボリューム) - スロットル
------------------------------------------------------------
local function dragLoop()
    local last_vol_broadcast = 0
    while true do
        local ev, btn, x, y = os.pullEvent("mouse_drag")
        if btn == 1 and current_tab == 1 and y == 10 and x >= 2 and x <= 25 then
            volume = math.max(0, math.min(3, (x - 2) / 23 * 3))
            local now = os.clock()
            if now - last_vol_broadcast > 0.2 then
                broadcastCommand({cmd = "volume", level = volume})
                last_vol_broadcast = now
            end
            scheduleRedraw()
        end
    end
end

------------------------------------------------------------
-- メイン
------------------------------------------------------------
openRednet()
log("Master started: " .. group_name)
redrawScreen()
broadcastCommand({cmd = "master_hello"})

parallel.waitForAny(
    rednetLoop,
    httpLoop,
    httpFailLoop,
    heartbeatLoop,
    aliveCheckLoop,
    mouseLoop,
    dragLoop,
    syncLoop,
    drawScheduler
)
