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
local HEARTBEAT_INTERVAL = 10

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
        term.write("--- Queue (" .. #queue .. " tracks) ---")
        for i = 1, math.min(#queue, 8) do
            term.setTextColor(colors.white)
            term.setCursorPos(2, 12 + i)
            term.write(i .. ". " .. queue[i].name)
        end
        if #queue > 8 then
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, 21)
            term.write("...+" .. (#queue - 8) .. " more")
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
            local col = colors.white
            if info.status == "playing" then col = colors.lime
            elseif info.status == "error" then col = colors.red end
            term.setTextColor(col)
            term.write(name)
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
    elseif current_tab == 3 then drawZones() end
end

------------------------------------------------------------
-- 同期再生
------------------------------------------------------------
local function syncLoop()
    while true do
        if sync_request then
            local track = sync_request
            sync_request = nil

            local slave_count = 0
            for _ in pairs(zones) do slave_count = slave_count + 1 end

            now_playing = track
            playing_id = track.id
            is_loading = true
            is_error = false
            redrawScreen()

            if slave_count == 0 then
                is_loading = false
                redrawScreen()
            else
                broadcastCommand({
                    cmd = "download",
                    track = {id = track.id, name = track.name, artist = track.artist}
                })

                local timeout = os.startTimer(30)
                local ready_count = 0
                while ready_count < slave_count do
                    local ev, p1 = os.pullEvent()
                    if ev == "timer" and p1 == timeout then break end
                    ready_count = 0
                    for _, info in pairs(zones) do
                        if info.status then ready_count = ready_count + 1 end
                    end
                end
                os.cancelTimer(timeout)

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

                local start_time = os.clock() + max_offset + SYNC_LEAD_TIME
                broadcastCommand({
                    cmd = "play_at",
                    track = {id = track.id, name = track.name, artist = track.artist},
                    start_time = start_time,
                    volume = volume
                })

                playing = true
                is_loading = false
                redrawScreen()

                -- 曲が終わるかstopされるまで待機
                while playing do
                    sleep(0.5)
                end

                -- 次の曲があれば自動再生
                if #queue > 0 then
                    local next_track = queue[1]
                    table.remove(queue, 1)
                    sync_request = next_track
                end
            end
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

local function httpLoop()
    while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "http_success" then
            if p1 == last_search_url then
                search_results = textutils.unserialiseJSON(p2.readAll())
                search_waiting = false
                search_error = false
                redrawScreen()
            end
        elseif ev == "http_failure" then
            if p1 == last_search_url then
                search_error = true
                search_waiting = false
                redrawScreen()
            end
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
    mouseLoop,
    dragLoop,
    syncLoop
)
