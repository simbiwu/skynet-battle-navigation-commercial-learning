--- 职责：固定分片的BattleWorker；拥有多个Battle并定时推进整条权威输入流。
--- 边界：Skynet Battle进程；不接触Gateway fd或Protobuf bytes，Core同步no-yield。
--- 输入/输出：create/join/recover/leave/replay及inputs/disconnect -> 回包/定向FramePush。
--- ownership：每场Battle独占Runtime/Native Engine；本Service独占seats及Deadline。
--- 不负责：账号登录、持久化进程崩溃恢复、跨机Battle迁移。
local skynet = require "skynet"
local frame_sync_runtime   = require "battle.frame_sync.runtime"
local frame_sync_config   = require "config.frame_sync"
local frame_sync_asset_config  = require "config.frame_sync_asset"

local module_state =
{
    battles_by_id = {}, -- 本 Worker 独占的 Battle Runtime 表，以 battle_id 索引。 -- battle_id -> BattleRuntime；仅当前Service修改。
    battle_order = {}, -- 稳定排序的 Battle ID 列表，供单一 Heartbeat 轮询。 -- battle_id稳定升序数组；Heartbeat一次推进多场。
    dispatcher_handle = nil, -- composition root 注入的唯一可信 Dispatch handle。 -- composition root注入；唯一可信的消息发送者。
}

---@class FrameSession
---@field gateway_epoch string 网关实例身份；不含fd引用。
---@field connection_id integer 网关会话数字ID，断线后可以被重用。

local session_credentials = require "battle.session_credentials"
local random_token = session_credentials.create
local equal_token = session_credentials.equal

local function same_session(left_session, right_session)
    return left_session and right_session and
        left_session.gateway_epoch == right_session.gateway_epoch and
        left_session.connection_id == right_session.connection_id
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
    skynet.send(module_state.dispatcher_handle, "lua", "frame_push",
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
    for seat_id = 1, frame_sync_config.seats do push_to(battle, seat_id, data) end
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
        map_id        = frame_sync_asset_config.map_id,
        map_version   = frame_sync_asset_config.map_version,
        map_hash      = frame_sync_asset_config.map_hash,
        frame         = battle.core and battle.core.frame or 0,
        checkpoint    = checkpoint or "",
        tick_rate_hz       = 60,
        future_window = frame_sync_config.future_window,
        input_lead    = frame_sync_config.input_lead,
        simulation_version = frame_sync_config.simulation_version,
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
    return (frame_count * 100 + frame_sync_config.tick_rate_hz - 1) // frame_sync_config.tick_rate_hz
end

local function frame_deadline(battle, frame)
    return battle.started_at + frame_offset_cs(frame_sync_config.input_lead + frame - 1)
end

local function create(worker_command)
    if not worker_command.request or worker_command.request.simulation_version ~= frame_sync_config.simulation_version then
        return { code = "SIMULATION_VERSION" }
    end
    if #module_state.battle_order >= frame_sync_config.max_battles then return { code = "BUSY" } end
    if module_state.battles_by_id[worker_command.battle_id] then return { code = "CONFLICT" } end
    local credential = random_token() -- 不允许用math.random作为恢复凭据。
    local runtime, err = frame_sync_runtime.create(
    {
        map_id      = frame_sync_asset_config.map_id,
        window      = frame_sync_config.future_window,
        max_frames  = frame_sync_config.max_frames,
        seat_unit_instance_ids = { 1001 },
    })
    if not runtime then return { code = err and err.code or "NATIVE_OPEN" } end

    local battle =
    {
        id = worker_command.battle_id,
        status = "RUNNING",
        core = runtime,
        seats = {},
        started_at = skynet.now(),
        due = 0,
    }
    battle.due = frame_deadline(battle, 1)
    add_seat(battle, 1, worker_command.session, credential)
    module_state.battles_by_id[battle.id] = battle
    module_state.battle_order[#module_state.battle_order + 1] = battle.id
    table.sort(module_state.battle_order)
    return join_result(battle, 1, "OK", assert(battle.core.engine:save()))
end

local function join(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    -- 本课不实现组队/多人席位；已有Battle只接受原席位的恢复流程。
    if same_session(battle.seats[1].session, worker_command.session) then
        return { code = "ALREADY_JOINED" }
    end
    return { code = "FULL" }
end

local function find_seat_by_token(battle, credential)
    for seat_id = 1, frame_sync_config.seats do
        local seat = battle.seats[seat_id]
        if seat and equal_token(seat.token, credential) then return seat_id end
    end
    return nil
end

--- 恢复只更换本席位传输会话；清除旧generation尚未采用的输入。
local function recover(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = find_seat_by_token(battle, worker_command.request.resume_token)
    if not seat_id then return { code = "NOT_FOUND" } end
    if battle.status == "FAILED" then return { code = battle.failure_code } end

    local seat = battle.seats[seat_id]
    seat.generation = seat.generation + 1
    seat.session = { gateway_epoch = worker_command.session.gateway_epoch,
                     connection_id = worker_command.session.connection_id }
    seat.online = true
    frame_sync_runtime.clear_seat_pending(battle.core, seat_id)
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
    return frame_sync_runtime.accept(battle.core, seat_id, input)
end

--- 根据当前Battle的可信Session查找席位；不依赖客户端上报seat_id。
local function seat_by_session(battle, generation, session)
    if not battle then return nil end
    for seat_id = 1, frame_sync_config.seats do
        if active_seat(battle, seat_id, generation, session) then
            return seat_id
        end
    end
    return nil
end

local function inputs(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    if not battle or battle.status ~= "RUNNING" then return end
    local seat_id = seat_by_session(battle, worker_command.request.generation, worker_command.session)
    if not seat_id then return end

    local batch = worker_command.request.inputs or {}
    if #batch > frame_sync_config.input_batch then
        push_to(battle, seat_id, { code = "INPUT_BATCH" })
        return
    end
    for _, input in ipairs(batch) do
        local code = accept_input(battle, seat_id, input)
        if code ~= "OK" then push_to(battle, seat_id, { code = code }) end
    end
end

local function leave(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = seat_by_session(battle, worker_command.request.generation, worker_command.session)
    if not seat_id then return { code = "NOT_FOUND" } end
    local seat = battle.seats[seat_id]
    seat.online = false
    frame_sync_runtime.clear_seat_pending(battle.core, seat_id)
    local any_online = false
    for i = 1, frame_sync_config.seats do any_online = any_online or (battle.seats[i] and battle.seats[i].online) end
    if not any_online then battle.empty_since = skynet.now() end
    return { code = "OK" }
end

local function disconnect(session)
    for _, battle_id in ipairs(module_state.battle_order) do
        local battle = module_state.battles_by_id[battle_id]
        if battle then
            for seat_id = 1, frame_sync_config.seats do
                local seat = battle.seats[seat_id]
                if seat and seat.online and same_session(seat.session, session) then
                    seat.online = false
                    frame_sync_runtime.clear_seat_pending(battle.core, seat_id)
                end
            end
            local any_online = false
            for i = 1, frame_sync_config.seats do
                any_online = any_online or (battle.seats[i] and battle.seats[i].online)
            end
            if not any_online and not battle.empty_since then
                battle.empty_since = skynet.now()
            end
        end
    end
end

--- 回放仅返回分页；无凭据不可读取；不能把恢复Token写入Replay。
local function replay(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    if not battle then return { code = "NOT_FOUND" } end
    local seat_id = find_seat_by_token(battle, worker_command.request.resume_token)
    if not seat_id then return { code = "NOT_FOUND" } end

    local offset = worker_command.request.offset or 0
    if math.type(offset) ~= "integer" or offset < 0 or offset > #battle.core.records then
        return { code = "REPLAY_OFFSET" }
    end
    local records = {}
    for i = offset + 1, math.min(#battle.core.records, offset + frame_sync_config.replay_page) do
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
    while now >= battle.due and catchup < frame_sync_config.max_catchup do
        local ok, record, err = pcall(frame_sync_runtime.step, battle.core)
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
    for _, id in ipairs(module_state.battle_order) do
        local battle = module_state.battles_by_id[id]
        if battle then
            advance(battle, now)
            local expiry = battle.finished_at or battle.empty_since
            if battle.remove or (expiry and now - expiry >= frame_sync_config.retention_cs) then
                frame_sync_runtime.close(battle.core)
                module_state.battles_by_id[id] = nil
            else
                surviving[#surviving + 1] = id
            end
        end
    end
    order = surviving
    skynet.timeout(frame_sync_config.scheduler_poll_cs, heartbeat)
end

skynet.start(function()
    skynet.info_func(function()
        local running_battles = 0
        local finished_battles = 0
        local failed_battles = 0
        local online_seats = 0
        local min_frame
        local max_frame

        for _, battle_id in ipairs(module_state.battle_order) do
            local battle = module_state.battles_by_id[battle_id]
            if battle then
                if battle.status == "RUNNING" then
                    running_battles = running_battles + 1
                elseif battle.status == "FINISHED" then
                    finished_battles = finished_battles + 1
                elseif battle.status == "FAILED" then
                    failed_battles = failed_battles + 1
                end

                for seat_id = 1, frame_sync_config.seats do
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
            battles                    = #module_state.battle_order,
            running_battles           = running_battles,
            finished_battles          = finished_battles,
            failed_battles            = failed_battles,
            online_seats              = online_seats,
            retained_battle_frame_min = min_frame or 0,
            retained_battle_frame_max = max_frame or 0,
            dispatcher                = module_state.dispatcher_handle and skynet.address(module_state.dispatcher_handle) or "unconfigured",
        }
    end)

    skynet.dispatch("lua", function(session, source, command, worker_command)
        if command == "configure" then
            assert(frame_sync_config.tick_rate_hz == 60 and frame_sync_config.scheduler_poll_cs == 1)
            assert(module_state.dispatcher_handle == nil and worker_command.dispatcher)
            module_state.dispatcher_handle = worker_command.dispatcher
            skynet.timeout(frame_sync_config.scheduler_poll_cs, heartbeat)
            skynet.retpack(true)
            return
        end
        assert(source == module_state.dispatcher_handle, "untrusted Worker sender")
        if command == "create" then skynet.retpack(create(worker_command))
        elseif command == "join" then skynet.retpack(join(worker_command))
        elseif command == "recover" then skynet.retpack(recover(worker_command))
        elseif command == "leave" then skynet.retpack(leave(worker_command))
        elseif command == "replay" then skynet.retpack(replay(worker_command))
        elseif command == "inputs" then inputs(worker_command)
        elseif command == "disconnect" then
            disconnect(worker_command)
        elseif command == "shutdown" then
            -- Native Runtime由Worker独占；逐场关闭Context后才确认进程级关闭。
            for _, battle_id in ipairs(module_state.battle_order) do
                local battle = module_state.battles_by_id[battle_id]
                if battle and battle.core then
                    frame_sync_runtime.close(battle.core)
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
