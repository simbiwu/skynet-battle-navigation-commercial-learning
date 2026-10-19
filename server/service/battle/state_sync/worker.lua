--- 多场状态同步Battle的单owner Worker；消息I/O在Core提交之外执行。
--- Dispatcher显式注入；每场Context、凭据、快照历史和回放均有上限。
local skynet = require("skynet")
local state_sync_runtime = require("battle.state_sync.runtime")
local replication = require("battle.state_sync.replication")
local state_sync_config = require("config.state_sync")
local state_sync_asset_config = require("config.state_sync_asset")
local module_state =
{
    battles_by_id = {}, -- 本 Worker 独占的 Battle Runtime 表，以 battle_id 索引。
    battle_order = {}, -- Worker 内稳定排序的 Battle ID 列表。
    dispatcher_handle = nil, -- composition root 注入的唯一可信 Dispatch handle。
    battle_rotation = 0, -- Heartbeat 的轮询起点，避免固定前缀独占查询预算。 -- 每次轮询轮转Battle起点，避免到期A*预算被固定前缀独占。
}

---@class StateSession
---@field gateway_epoch string Gateway实例身份，不是账号。
---@field connection_id integer Gateway实例内连接标识，不传fd。
local function same(a, battle)
    return a and battle and a.gateway_epoch == battle.gateway_epoch and a.connection_id == battle.connection_id
end
local session_credentials = require("battle.session_credentials")
local token = session_credentials.create
local equal_token = session_credentials.equal

local function authorized(battle, request, session)
    return battle and battle.online and request.generation == battle.generation and same(battle.session, session)
end
local function snapshot(battle)
    battle.seq = battle.seq + 1
    local value = state_sync_runtime.snapshot(battle.core, battle.seq)
    battle.history[battle.seq] = value
    battle.history[battle.seq - state_sync_config.snapshot_window] = nil
    return value
end
local function joined(battle)
    return {
        code                  = "OK",
        battle_id             = battle.id,
        generation            = battle.generation,
        resume_token          = battle.token,
        map_id                = state_sync_asset_config.map_id,
        map_version           = state_sync_asset_config.map_version,
        map_hash              = state_sync_asset_config.map_hash,
        config_hash           = state_sync_asset_config.config_hash,
        tick_rate_hz          = state_sync_config.tick_rate_hz,
        snapshot_rate_hz      = state_sync_config.snapshot_rate_hz,
        speed_mm_per_sec      = battle.core.units[1].speed,
        simulation_version    = state_sync_config.simulation_version,
        input_window          = state_sync_config.input_window,
        navigation_profile_id = battle.core.units[1].unit_profile_id,
        snapshot              = snapshot(battle),
        next_cast_seq         = battle.core.cast_next,
    }
end
local function push(battle, data)
    data.battle_id = battle.id
    data.generation = battle.generation
    if battle.online then
        skynet.send(module_state.dispatcher_handle, "lua", "state_push", { session = battle.session, data = data })
    end
end
local function publish(battle, with_snapshot)
    local events = {}
    local gap = #battle.core.events > 0 and battle.ack_event < battle.core.events[1].event_seq - 1
    if not gap then
        for _, e in ipairs(battle.core.events) do
            if e.event_seq > battle.ack_event then
                events[#events + 1] = e
            end
            if #events == 64 then
                break
            end
        end
    end
    local full = with_snapshot or gap
    local current = full and snapshot(battle) or nil
    push(battle, {
        code     = gap and "EVENT_GAP" or "OK",
        events   = events,
        snapshot = current
            and replication.delta(current, not gap and battle.history[battle.ack_snapshot] or nil),
    })
    -- 回放与网络重发分别记录：只保存本次新事件和完整状态，避免回放重复副作用。
    local fresh = {}
    for _, e in ipairs(battle.core.events) do
        if e.event_seq > battle.record_event then
            fresh[#fresh + 1] = e
        end
    end
    battle.record_event = battle.core.event_seq
    if current or #fresh > 0 then
        local bytes_upper = 256 + #fresh * 192
        if current then
            bytes_upper = bytes_upper + #current.units * 384 + #current.bolts * 160
        end
        if
            #battle.replay >= state_sync_config.replay_limit
            or battle.replay_bytes + bytes_upper > state_sync_config.replay_byte_budget
        then
            error({ code = "REPLAY_LIMIT" })
        end
        battle.replay_bytes = battle.replay_bytes + bytes_upper
        battle.replay[#battle.replay + 1] = {
            battle_id  = battle.id,
            generation = 0,
            code       = "OK",
            snapshot   = current,
            events     = fresh,
        }
    end
end
local function create(worker_command)
    if worker_command.request.scenario_id ~= 1001 then
        return { code = "BAD_SCENARIO" }
    end
    if worker_command.request.simulation_version ~= state_sync_config.simulation_version then
        return { code = "SIMULATION_VERSION" }
    end
    if #module_state.battle_order >= state_sync_config.max_battles then
        return { code = "BUSY" }
    end
    local credential = token()
    local runtime, err = state_sync_runtime.create(worker_command.battle_id)
    if not runtime then
        return { code = err.code }
    end
    local battle = {
        id           = worker_command.battle_id,
        core         = runtime,
        session      = worker_command.session,
        token        = credential,
        online       = true,
        generation   = 1,
        seq          = 0,
        history      = {},
        ack_snapshot = 0,
        ack_event    = 0,
        record_event = 0,
        replay       = {},
        replay_bytes = 0,
        started      = skynet.now(),
    }
    local result = joined(battle)
    local initial = {}
    for k, v in pairs(result) do
        initial[k] = v
    end
    initial.resume_token = "" -- 凭据只用于在线恢复，不保存到Replay。
    initial.generation = 0
    battle.initial = initial
    module_state.battles_by_id[battle.id] = battle
    module_state.battle_order[#module_state.battle_order + 1] = battle.id
    return result
end
local function recover(battle, worker_command)
    if not battle or not equal_token(battle.token, worker_command.request.resume_token) then
        return { state = { code = "NOT_FOUND" } }
    end
    if battle.failure then
        return { state = { code = battle.failure } }
    end
    if battle.core.winner ~= 0 then
        return { state = { code = "ENDED" } }
    end
    state_sync_runtime.disconnect(battle.core)
    battle.generation = battle.generation + 1
    battle.session = worker_command.session
    battle.online = true
    battle.empty_since = nil
    battle.ack_snapshot, battle.ack_event = 0, battle.core.event_seq
    return { state = joined(battle) }
end
local function replay(battle, worker_command)
    if not battle or not equal_token(battle.token, worker_command.request.resume_token) then
        return { code = "NOT_FOUND" }
    end
    local offset = worker_command.request.offset
    if math.type(offset) ~= "integer" or offset < 0 or offset > #battle.replay then
        return { code = "REPLAY_OFFSET" }
    end
    local records = {}
    for i = offset + 1, math.min(#battle.replay, offset + 4) do
        records[#records + 1] = battle.replay[i]
    end
    return {
        code    = "OK",
        total   = #battle.replay,
        initial = offset == 0 and battle.initial or nil,
        records = records,
    }
end
---@class StateWorkerCommand
---@field action string create/inputs/cast/resync/recover/leave/replay；由Dispatcher映射。
---@field battle_id integer 唯一Battle实例ID；Worker决定最终会话权限。
---@field request table 已解码业务值，不含fd、buffer或Native对象。
---@field session StateSession 当前Gateway连接身份；恢复后旧身份失效。
--- Dispatcher本地call会yield；本处理函数同步修改本场，返回纯值record。
---@param worker_command StateWorkerCommand 借用至本次调用结束。
---@return table 稳定code和业务结果；不保存请求buffer。
local function control(worker_command)
    local battle = module_state.battles_by_id[worker_command.battle_id]
    local request = worker_command.request
    if worker_command.action == "create" then
        return create(worker_command)
    end
    if worker_command.action == "recover" then
        return recover(battle, worker_command)
    end
    if worker_command.action == "replay" then
        return replay(battle, worker_command)
    end
    if not authorized(battle, request, worker_command.session) then
        return { code = "NOT_FOUND" }
    end
    if battle.failure then
        return { code = battle.failure }
    end
    if worker_command.action == "inputs" then
        if request.ack_snapshot_seq > battle.seq or request.ack_event_seq > battle.core.event_seq then
            return { code = "BAD_ACK" }
        end
        battle.ack_snapshot = math.max(battle.ack_snapshot, request.ack_snapshot_seq)
        battle.ack_event = math.max(battle.ack_event, request.ack_event_seq)
        return {
            code               = state_sync_runtime.accept_inputs(battle.core, request.inputs or {}),
            consumed_input_seq = battle.core.consumed,
        }
    elseif worker_command.action == "cast" then
        return state_sync_runtime.accept_cast(battle.core, request)
    elseif worker_command.action == "resync" then
        battle.ack_event = battle.core.event_seq
        return { code = "OK", snapshot = snapshot(battle) }
    elseif worker_command.action == "leave" then
        battle.online = false
        battle.empty_since = skynet.now()
        state_sync_runtime.disconnect(battle.core)
        return { code = "OK" }
    end
    return { code = "BAD_COMMAND" }
end
local function disconnect(session)
    for _, id in ipairs(module_state.battle_order) do
        local battle = module_state.battles_by_id[id]
        if battle.online and same(battle.session, session) then
            battle.online = false
            battle.empty_since = skynet.now()
            state_sync_runtime.disconnect(battle.core)
        end
    end
end
local function heartbeat()
    local now = skynet.now()
    local budget = { remaining = state_sync_config.max_path_queries_per_poll }
    local advance_order = {}
    for offset = 1, #module_state.battle_order do
        advance_order[#advance_order + 1] = module_state.battle_order[(module_state.battle_rotation + offset - 1) % #module_state.battle_order + 1]
    end
    module_state.battle_rotation = #module_state.battle_order > 0 and (module_state.battle_rotation + 1) % #module_state.battle_order or 0
    for _, id in ipairs(advance_order) do
        local battle = module_state.battles_by_id[id]
        if not battle.failure and battle.core.winner == 0 then
            local count = 0
            local function due()
                return battle.started + ((battle.core.tick + 1) * 100 + 59) // 60
            end
            while now >= due() and count < state_sync_config.max_catchup do
                local ok, err = pcall(function()
                    state_sync_runtime.step(battle.core, budget)
                    local terminal = battle.core.winner ~= 0
                    if battle.core.tick % 3 == 0 or battle.core.event_seq > battle.record_event or terminal then
                        publish(battle, battle.core.tick % 3 == 0 or terminal)
                    end
                end)
                count = count + 1
                if not ok then
                    skynet.error("STATE_STEP_FAILED ", tostring(err))
                    battle.failure = type(err) == "table" and err.code or "INTERNAL"
                    push(battle, { code = battle.failure })
                    state_sync_runtime.close(battle.core)
                    battle.finished = now
                    break
                end
                if battle.core.winner ~= 0 then
                    battle.finished = now
                    state_sync_runtime.close(battle.core)
                    break
                end
            end
            if not battle.failure and battle.core.winner == 0 and now >= due() then
                battle.failure = "OVERLOAD"
                push(battle, { code = battle.failure })
                state_sync_runtime.close(battle.core)
                battle.finished = now
            end
        end
        local retained = battle.finished or battle.empty_since
        if retained and now - retained >= state_sync_config.retention_cs then
            state_sync_runtime.close(battle.core)
            module_state.battles_by_id[battle.id] = nil
            for index, id in ipairs(module_state.battle_order) do
                if id == battle.id then
                    table.remove(module_state.battle_order, index)
                    break
                end
            end
        end
    end
    skynet.timeout(1, heartbeat)
end
skynet.start(function()
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "configure" then
            assert(not module_state.dispatcher_handle and payload.dispatcher)
            module_state.dispatcher_handle = payload.dispatcher
            skynet.timeout(1, heartbeat)
            skynet.retpack(true)
        elseif command == "control" then
            assert(source == module_state.dispatcher_handle)
            skynet.retpack(control(payload))
        elseif command == "disconnect" then
            assert(source == module_state.dispatcher_handle)
            disconnect(payload)
        elseif command == "shutdown" then
            assert(source == module_state.dispatcher_handle)
            for _, id in ipairs(module_state.battle_order) do
                state_sync_runtime.close(module_state.battles_by_id[id].core)
            end
            skynet.retpack(true)
            skynet.exit()
        else
            error("STATE_WORKER_BAD_COMMAND")
        end
    end)
end)
