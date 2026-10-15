--- 多场状态同步Battle的单owner Worker；消息I/O在Core提交之外执行。
--- Dispatcher显式注入；每场Context、凭据、快照历史和回放均有上限。
local skynet = require("skynet")
local core = require("battle.state_sync.runtime")
local replication = require("battle.state_sync.replication")
local conf = require("config.state_sync")
local asset = require("config.state_sync_asset")
local battles, order = {}, {}
local dispatcher
local rotation = 0 -- 每次轮询轮转Battle起点，避免到期A*预算被固定前缀独占。

---@class StateSession
---@field gateway_epoch string Gateway实例身份，不是账号。
---@field connection_id integer Gateway实例内连接标识，不传fd。
local function same(a, b)
    return a and b and a.gateway_epoch == b.gateway_epoch and a.connection_id == b.connection_id
end
local credentials = require("battle.session_credentials")
local token = credentials.create
local equal_token = credentials.equal

local function authorized(b, req, session)
    return b and b.online and req.generation == b.generation and same(b.session, session)
end
local function snapshot(b)
    b.seq = b.seq + 1
    local value = core.snapshot(b.core, b.seq)
    b.history[b.seq] = value
    b.history[b.seq - conf.snapshot_window] = nil
    return value
end
local function joined(b)
    return {
        code                  = "OK",
        battle_id             = b.id,
        generation            = b.generation,
        resume_token          = b.token,
        map_id                = asset.map_id,
        map_version           = asset.map_version,
        map_hash              = asset.map_hash,
        config_hash           = asset.config_hash,
        tick_rate_hz          = conf.tick_rate_hz,
        snapshot_rate_hz      = conf.snapshot_rate_hz,
        speed_mm_per_sec      = b.core.units[1].speed,
        simulation_version    = conf.simulation_version,
        input_window          = conf.input_window,
        navigation_profile_id = b.core.units[1].unit_profile_id,
        snapshot              = snapshot(b),
        next_cast_seq         = b.core.cast_next,
    }
end
local function push(b, data)
    data.battle_id = b.id
    data.generation = b.generation
    if b.online then
        skynet.send(dispatcher, "lua", "state_push", { session = b.session, data = data })
    end
end
local function publish(b, with_snapshot)
    local events = {}
    local gap = #b.core.events > 0 and b.ack_event < b.core.events[1].event_seq - 1
    if not gap then
        for _, e in ipairs(b.core.events) do
            if e.event_seq > b.ack_event then
                events[#events + 1] = e
            end
            if #events == 64 then
                break
            end
        end
    end
    local full = with_snapshot or gap
    local current = full and snapshot(b) or nil
    push(b, {
        code     = gap and "EVENT_GAP" or "OK",
        events   = events,
        snapshot = current
            and replication.delta(current, not gap and b.history[b.ack_snapshot] or nil),
    })
    -- 回放与网络重发分别记录：只保存本次新事件和完整状态，避免回放重复副作用。
    local fresh = {}
    for _, e in ipairs(b.core.events) do
        if e.event_seq > b.record_event then
            fresh[#fresh + 1] = e
        end
    end
    b.record_event = b.core.event_seq
    if current or #fresh > 0 then
        local bytes_upper = 256 + #fresh * 192
        if current then
            bytes_upper = bytes_upper + #current.units * 384 + #current.bolts * 160
        end
        if
            #b.replay >= conf.replay_limit
            or b.replay_bytes + bytes_upper > conf.replay_byte_budget
        then
            error({ code = "REPLAY_LIMIT" })
        end
        b.replay_bytes = b.replay_bytes + bytes_upper
        b.replay[#b.replay + 1] = {
            battle_id  = b.id,
            generation = 0,
            code       = "OK",
            snapshot   = current,
            events     = fresh,
        }
    end
end
local function create(args)
    if args.request.scenario_id ~= 1001 then
        return { code = "BAD_SCENARIO" }
    end
    if args.request.simulation_version ~= conf.simulation_version then
        return { code = "SIMULATION_VERSION" }
    end
    if #order >= conf.max_battles then
        return { code = "BUSY" }
    end
    local credential = token()
    local runtime, err = core.create(args.battle_id)
    if not runtime then
        return { code = err.code }
    end
    local b = {
        id           = args.battle_id,
        core         = runtime,
        session      = args.session,
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
    local result = joined(b)
    local initial = {}
    for k, v in pairs(result) do
        initial[k] = v
    end
    initial.resume_token = "" -- 凭据只用于在线恢复，不保存到Replay。
    initial.generation = 0
    b.initial = initial
    battles[b.id] = b
    order[#order + 1] = b.id
    return result
end
local function recover(b, args)
    if not b or not equal_token(b.token, args.request.resume_token) then
        return { state = { code = "NOT_FOUND" } }
    end
    if b.failure then
        return { state = { code = b.failure } }
    end
    if b.core.winner ~= 0 then
        return { state = { code = "ENDED" } }
    end
    core.disconnect(b.core)
    b.generation = b.generation + 1
    b.session = args.session
    b.online = true
    b.empty_since = nil
    b.ack_snapshot, b.ack_event = 0, b.core.event_seq
    return { state = joined(b) }
end
local function replay(b, args)
    if not b or not equal_token(b.token, args.request.resume_token) then
        return { code = "NOT_FOUND" }
    end
    local offset = args.request.offset
    if math.type(offset) ~= "integer" or offset < 0 or offset > #b.replay then
        return { code = "REPLAY_OFFSET" }
    end
    local records = {}
    for i = offset + 1, math.min(#b.replay, offset + 4) do
        records[#records + 1] = b.replay[i]
    end
    return {
        code    = "OK",
        total   = #b.replay,
        initial = offset == 0 and b.initial or nil,
        records = records,
    }
end
---@class StateWorkerCommand
---@field action string create/inputs/cast/resync/recover/leave/replay；由Dispatcher映射。
---@field battle_id integer 唯一Battle实例ID；Worker决定最终会话权限。
---@field request table 已解码业务值，不含fd、buffer或Native对象。
---@field session StateSession 当前Gateway连接身份；恢复后旧身份失效。
--- Dispatcher本地call会yield；本处理函数同步修改本场，返回纯值record。
---@param args StateWorkerCommand 借用至本次调用结束。
---@return table 稳定code和业务结果；不保存请求buffer。
local function control(args)
    local b = battles[args.battle_id]
    local req = args.request
    if args.action == "create" then
        return create(args)
    end
    if args.action == "recover" then
        return recover(b, args)
    end
    if args.action == "replay" then
        return replay(b, args)
    end
    if not authorized(b, req, args.session) then
        return { code = "NOT_FOUND" }
    end
    if b.failure then
        return { code = b.failure }
    end
    if args.action == "inputs" then
        if req.ack_snapshot_seq > b.seq or req.ack_event_seq > b.core.event_seq then
            return { code = "BAD_ACK" }
        end
        b.ack_snapshot = math.max(b.ack_snapshot, req.ack_snapshot_seq)
        b.ack_event = math.max(b.ack_event, req.ack_event_seq)
        return {
            code               = core.accept_inputs(b.core, req.inputs or {}),
            consumed_input_seq = b.core.consumed,
        }
    elseif args.action == "cast" then
        return core.accept_cast(b.core, req)
    elseif args.action == "resync" then
        b.ack_event = b.core.event_seq
        return { code = "OK", snapshot = snapshot(b) }
    elseif args.action == "leave" then
        b.online = false
        b.empty_since = skynet.now()
        core.disconnect(b.core)
        return { code = "OK" }
    end
    return { code = "BAD_COMMAND" }
end
local function disconnect(session)
    for _, id in ipairs(order) do
        local b = battles[id]
        if b.online and same(b.session, session) then
            b.online = false
            b.empty_since = skynet.now()
            core.disconnect(b.core)
        end
    end
end
local function heartbeat()
    local now = skynet.now()
    local budget = { remaining = conf.max_path_queries_per_poll }
    local advance_order = {}
    for offset = 1, #order do
        advance_order[#advance_order + 1] = order[(rotation + offset - 1) % #order + 1]
    end
    rotation = #order > 0 and (rotation + 1) % #order or 0
    for _, id in ipairs(advance_order) do
        local b = battles[id]
        if not b.failure and b.core.winner == 0 then
            local count = 0
            local function due()
                return b.started + ((b.core.tick + 1) * 100 + 59) // 60
            end
            while now >= due() and count < conf.max_catchup do
                local ok, err = pcall(function()
                    core.step(b.core, budget)
                    local terminal = b.core.winner ~= 0
                    if b.core.tick % 3 == 0 or b.core.event_seq > b.record_event or terminal then
                        publish(b, b.core.tick % 3 == 0 or terminal)
                    end
                end)
                count = count + 1
                if not ok then
                    skynet.error("STATE_STEP_FAILED ", tostring(err))
                    b.failure = type(err) == "table" and err.code or "INTERNAL"
                    push(b, { code = b.failure })
                    core.close(b.core)
                    b.finished = now
                    break
                end
                if b.core.winner ~= 0 then
                    b.finished = now
                    core.close(b.core)
                    break
                end
            end
            if not b.failure and b.core.winner == 0 and now >= due() then
                b.failure = "OVERLOAD"
                push(b, { code = b.failure })
                core.close(b.core)
                b.finished = now
            end
        end
        local retained = b.finished or b.empty_since
        if retained and now - retained >= conf.retention_cs then
            core.close(b.core)
            battles[b.id] = nil
            for index, id in ipairs(order) do
                if id == b.id then
                    table.remove(order, index)
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
            assert(not dispatcher and payload.dispatcher)
            dispatcher = payload.dispatcher
            skynet.timeout(1, heartbeat)
            skynet.retpack(true)
        elseif command == "control" then
            assert(source == dispatcher)
            skynet.retpack(control(payload))
        elseif command == "disconnect" then
            assert(source == dispatcher)
            disconnect(payload)
        elseif command == "shutdown" then
            assert(source == dispatcher)
            for _, id in ipairs(order) do
                core.close(battles[id].core)
            end
            skynet.retpack(true)
            skynet.exit()
        else
            error("STATE_WORKER_BAD_COMMAND")
        end
    end)
end)
