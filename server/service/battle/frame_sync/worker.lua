--- 职责：固定分片的BattleWorker；拥有多个Battle并定时推进整条权威输入流。
--- 边界：Skynet Battle进程；不接触Gateway fd或Protobuf bytes，Core同步no-yield。
--- 输入/输出：create/join/recover/leave/replay及inputs/disconnect -> 回包/定向FramePush。
--- ownership：每场Battle独占Runtime/Native Engine；本Service独占seats及Deadline。
--- 不负责：账号登录、持久化进程崩溃恢复、跨机Battle迁移。
local skynet = require "skynet"
local core   = require "battle.frame_sync.runtime"
local conf   = require "config.frame_sync"
local asset  = require "config.frame_sync_asset"

local battles      = {}  -- battle_id -> BattleRuntime；仅当前Service修改。
local order        = {}  -- battle_id稳定升序数组；Heartbeat一次推进多场。
local dispatcher   = nil -- composition root注入；唯一可信的消息发送者。

---@class FrameSession
---@field gateway_epoch string 网关实例身份；不含fd引用。
---@field connection_id integer 网关会话数字ID，断线后可以被重用。

local credentials = require "battle.session_credentials"
local random_token = credentials.create
local equal_token = credentials.equal

local function same_session(a, b)
    return a and b and a.gateway_epoch == b.gateway_epoch and
        a.connection_id == b.connection_id
end

local function active_seat(battle, seat_id, generation, session)
    local seat = battle and battle.seats[seat_id]
    return seat and seat.online and seat.generation == generation and
        same_session(seat.session, session)
end

--- 发送到特定席位当前会话；独立FramePush命令，无请求关联字段。
local function push_to(battle, seat_id, data)
    local seat = battle.seats[seat_id]
    if not seat or not seat.online then return end
    skynet.send(dispatcher, "lua", "frame_push",
    {
        session = seat.session,
        data =
        {
            battle_id = battle.id,
            generation = seat.generation,
            records = data.records or {},
            code = data.code or "OK",
            winner = battle.core and battle.core.winner or 0,
            checkpoint = data.checkpoint or "",
        },
    })
end

local function push_all(battle, data)
    for seat_id = 1, conf.seats do push_to(battle, seat_id, data) end
end

local function join_result(battle, seat_id, code, checkpoint)
    local seat = assert(battle.seats[seat_id])
    return
    {
        code          = code,
        battle_id     = battle.id,
        seat_id       = seat_id,
        resume_token  = seat.token,
        generation    = seat.generation,
        map_id        = asset.map_id,
        map_version   = asset.map_version,
        map_hash      = asset.map_hash,
        frame         = battle.core and battle.core.frame or 0,
        checkpoint    = checkpoint or "",
        tick_rate_hz       = 60,
        future_window = conf.future_window,
        input_lead    = conf.input_lead,
        simulation_version = conf.simulation_version,
    }
end

local function add_seat(battle, seat_id, session, credential)
    assert(not battle.seats[seat_id] and credential and #credential == 32)
    battle.seats[seat_id] =
    {
        token = credential,
        generation = 1,
        session = { gateway_epoch = session.gateway_epoch,
                    connection_id = session.connection_id },
        online = true,
    }
end

local function frame_offset_cs(frame_count)
    -- Skynet时间精度为10ms；向上取整映射截止点，不改变Core的1/60秒逻辑步长。
    return (frame_count * 100 + conf.tick_rate_hz - 1) // conf.tick_rate_hz
end

local function frame_deadline(battle, frame)
    return battle.started_at + frame_offset_cs(conf.input_lead + frame - 1)
end

local function create(args)
    if not args.request or args.request.simulation_version ~= conf.simulation_version then
        return { code = "SIMULATION_VERSION" }
    end
    if #order >= conf.max_battles then return { code = "BUSY" } end
    if battles[args.battle_id] then return { code = "CONFLICT" } end
    local credential = random_token() -- 不允许用math.random作为恢复凭据。
    local runtime, err = core.create(
    {
        map_id      = asset.map_id,
        window      = conf.future_window,
        max_frames  = conf.max_frames,
        seat_unit_instance_ids = { 1001 },
    })
    if not runtime then return { code = err and err.code or "NATIVE_OPEN" } end

    local battle =
    {
        id = args.battle_id,
        status = "RUNNING",
        core = runtime,
        seats = {},
        started_at = skynet.now(),
        due = 0,
    }
    battle.due = frame_deadline(battle, 1)
    add_seat(battle, 1, args.session, credential)
    battles[battle.id] = battle
    order[#order + 1] = battle.id
    table.sort(order)
    return join_result(battle, 1, "OK", assert(battle.core.engine:save()))
end

local function join(args)
    local battle = battles[args.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    -- 本课不实现组队/多人席位；已有Battle只接受原席位的恢复流程。
    if same_session(battle.seats[1].session, args.session) then
        return { code = "ALREADY_JOINED" }
    end
    return { code = "FULL" }
end

local function find_seat_by_token(battle, credential)
    for seat_id = 1, conf.seats do
        local seat = battle.seats[seat_id]
        if seat and equal_token(seat.token, credential) then return seat_id end
    end
    return nil
end

--- 恢复只更换本席位传输会话；清除旧generation尚未采用的输入。
local function recover(args)
    local battle = battles[args.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = find_seat_by_token(battle, args.request.resume_token)
    if not seat_id then return { code = "NOT_FOUND" } end
    if battle.status == "FAILED" then return { code = battle.failure_code } end

    local seat = battle.seats[seat_id]
    seat.generation = seat.generation + 1
    seat.session = { gateway_epoch = args.session.gateway_epoch,
                     connection_id = args.session.connection_id }
    seat.online = true
    core.clear_seat_pending(battle.core, seat_id)
    battle.empty_since = nil

    local checkpoint = assert(battle.core.engine:save())
    return join_result(battle, seat_id,
        "OK", checkpoint)
end

--- Deadline依赖Worker单调时钟；Skynet Timer晚执行不会重新开放过期的Frame。
local function accept_input(battle, seat_id, input)
    local frame = input.frame
    if math.type(frame) == "integer" and frame > battle.core.frame then
        local deadline = frame_deadline(battle, frame)
        if skynet.now() >= deadline then return "LATE" end
    end
    return core.accept(battle.core, seat_id, input)
end

--- 根据当前Battle的可信Session查找席位；不依赖客户端上报seat_id。
local function seat_by_session(battle, generation, session)
    if not battle then return nil end
    for seat_id = 1, conf.seats do
        if active_seat(battle, seat_id, generation, session) then
            return seat_id
        end
    end
    return nil
end

local function inputs(args)
    local battle = battles[args.battle_id]
    if not battle or battle.status ~= "RUNNING" then return end
    local seat_id = seat_by_session(battle, args.request.generation, args.session)
    if not seat_id then return end

    local batch = args.request.inputs or {}
    if #batch > conf.input_batch then
        push_to(battle, seat_id, { code = "INPUT_BATCH" })
        return
    end
    for _, input in ipairs(batch) do
        local code = accept_input(battle, seat_id, input)
        if code ~= "OK" then push_to(battle, seat_id, { code = code }) end
    end
end

local function leave(args)
    local battle = battles[args.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = seat_by_session(battle, args.request.generation, args.session)
    if not seat_id then return { code = "NOT_FOUND" } end
    local seat = battle.seats[seat_id]
    seat.online = false
    core.clear_seat_pending(battle.core, seat_id)
    local any_online = false
    for i = 1, conf.seats do any_online = any_online or (battle.seats[i] and battle.seats[i].online) end
    if not any_online then battle.empty_since = skynet.now() end
    return { code = "OK" }
end

local function disconnect(session)
    for _, battle_id in ipairs(order) do
        local battle = battles[battle_id]
        if battle then
            for seat_id = 1, conf.seats do
                local seat = battle.seats[seat_id]
                if seat and seat.online and same_session(seat.session, session) then
                    seat.online = false
                    core.clear_seat_pending(battle.core, seat_id)
                end
            end
            local any_online = false
            for i = 1, conf.seats do
                any_online = any_online or (battle.seats[i] and battle.seats[i].online)
            end
            if not any_online and not battle.empty_since then
                battle.empty_since = skynet.now()
            end
        end
    end
end

--- 回放仅返回分页；无凭据不可读取；不能把恢复Token写入Replay。
local function replay(args)
    local battle = battles[args.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = find_seat_by_token(battle, args.request.resume_token)
    if not seat_id then return { code = "NOT_FOUND" } end

    local offset = args.request.offset or 0
    if math.type(offset) ~= "integer" or offset < 0 or offset > #battle.core.records then
        return { code = "REPLAY_OFFSET" }
    end
    local records = {}
    for i = offset + 1, math.min(#battle.core.records, offset + conf.replay_page) do
        records[#records + 1] = battle.core.records[i]
    end
    local initial
    if offset == 0 then
        initial = join_result(battle, seat_id, "OK", battle.core.initial)
        initial.resume_token = "" -- 回放文件绝不包含恢复凭据。
        initial.frame = 0
    end
    return { code = "OK", records = records, total = #battle.core.records,
             initial = initial }
end

local function advance(battle, now)
    if battle.status ~= "RUNNING" then return end
    local catchup = 0
    while now >= battle.due and catchup < conf.max_catchup do
        local ok, record, err = pcall(core.step, battle.core)
        if not ok or not record then
            battle.status = "FAILED"
            battle.failure_code = "INTERNAL"
            battle.finished_at = now
            skynet.error("FRAME_CORE_FAILED battle_id=", battle.id,
                " error=", tostring(ok and err and err.code or record))
            push_all(battle, { code = "INTERNAL" })
            return
        end
        catchup = catchup + 1
        battle.due = frame_deadline(battle, battle.core.frame + 1)
        push_all(battle, { records = { record }, code = "OK" })
        if battle.core.winner ~= 0 then
            battle.status = "FINISHED"
            battle.finished_at = now
            return
        end
    end
    if now >= battle.due then
        battle.status = "FAILED"
        battle.failure_code = "OVERLOAD"
        battle.finished_at = now
        push_all(battle, { code = "OVERLOAD" })
    end
end

--- 一个Worker一个Timer；更新Battle时不yield，结束后清理独占Runtime。
local function heartbeat()
    local now = skynet.now()
    local surviving = {}
    for _, id in ipairs(order) do
        local battle = battles[id]
        if battle then
            advance(battle, now)
            local expiry = battle.finished_at or battle.empty_since
            if battle.remove or (expiry and now - expiry >= conf.retention_cs) then
                core.close(battle.core)
                battles[id] = nil
            else
                surviving[#surviving + 1] = id
            end
        end
    end
    order = surviving
    skynet.timeout(conf.scheduler_poll_cs, heartbeat)
end

skynet.start(function()
    skynet.info_func(function()
        local running_battles = 0
        local finished_battles = 0
        local failed_battles = 0
        local online_seats = 0
        local min_frame
        local max_frame

        for _, battle_id in ipairs(order) do
            local battle = battles[battle_id]
            if battle then
                if battle.status == "RUNNING" then
                    running_battles = running_battles + 1
                elseif battle.status == "FINISHED" then
                    finished_battles = finished_battles + 1
                elseif battle.status == "FAILED" then
                    failed_battles = failed_battles + 1
                end

                for seat_id = 1, conf.seats do
                    local seat = battle.seats[seat_id]
                    if seat and seat.online then
                        online_seats = online_seats + 1
                    end
                end

                local frame = battle.core and battle.core.frame or 0
                min_frame = min_frame and math.min(min_frame, frame) or frame
                max_frame = max_frame and math.max(max_frame, frame) or frame
            end
        end

        return
        {
            battles                   = #order,
            running_battles           = running_battles,
            finished_battles          = finished_battles,
            failed_battles            = failed_battles,
            online_seats              = online_seats,
            retained_battle_frame_min = min_frame or 0,
            retained_battle_frame_max = max_frame or 0,
            dispatcher                = dispatcher and skynet.address(dispatcher) or "unconfigured",
        }
    end)

    skynet.dispatch("lua", function(session, source, command, args)
        if command == "configure" then
            assert(conf.tick_rate_hz == 60 and conf.scheduler_poll_cs == 1)
            assert(dispatcher == nil and args.dispatcher)
            dispatcher = args.dispatcher
            skynet.timeout(conf.scheduler_poll_cs, heartbeat)
            skynet.retpack(true)
            return
        end
        assert(source == dispatcher, "untrusted Worker sender")
        if command == "create" then skynet.retpack(create(args))
        elseif command == "join" then skynet.retpack(join(args))
        elseif command == "recover" then skynet.retpack(recover(args))
        elseif command == "leave" then skynet.retpack(leave(args))
        elseif command == "replay" then skynet.retpack(replay(args))
        elseif command == "inputs" then inputs(args)
        elseif command == "disconnect" then
            disconnect(args)
        elseif command == "shutdown" then
            -- Native Runtime由Worker独占；逐场关闭Context后才确认进程级关闭。
            for _, battle_id in ipairs(order) do
                local battle = battles[battle_id]
                if battle and battle.core then
                    core.close(battle.core)
                    battle.core = nil
                end
            end
            battles = {}
            order = {}
            skynet.retpack(true)
            skynet.exit()
        else
            error("unknown Frame Worker command: " .. tostring(command))
        end
    end)
end)
