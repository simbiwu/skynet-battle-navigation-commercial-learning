--- 职责：把 Battle Process 的 Gateway 请求分给地图查询或自动战斗 Manager。
--- 边界：Server RPC Adapter；不持有 fd、frame、descriptor 或 Battle Context。
--- 输入/输出：已解码 send_data message -> 业务处理；结果仍通过统一 send_data 返回。
--- 生命周期：battle_main 注入两个 Service handle 后注册为 cluster 入口。
--- 不负责：不实现寻路、AI 或战斗结算，不接受客户端 Snapshot。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.battle"
local scenario = require "battle.scenario_1001"
local protocol_registry = require "gateway.protocol.navigation_registry"
local command_ids = protocol_registry.command_ids
local luapanda_debug = require "shared.debug.luapanda_debug"

local query_service = nil    -- 本进程 Query Service，由 battle_main 注入一次。
local battle_mgr = nil       -- 本进程 BattleMgr，由 battle_main 注入一次。
local in_flight = 0          -- 正在等待自动战斗结果的请求数，由此 Service 独占。
local MAX_IN_FLIGHT = 4      -- 超限立即返回 BUSY，避免无限排队。
local MAX_EVENTS = 100       -- 一次网络结果允许的最大 Event 数。
local MAX_POINTS = 200      -- 所有 MOVE_PATH 点的总数上限。
local MAX_TEXT_BYTES = 64   -- 单个事件文本的最大 UTF-8 byte 数。

local RESULT = {
    OK = 1, BAD_SCENARIO = 2, BUSY = 3,
    BATTLE_FAILED = 4, RESULT_TOO_LARGE = 5,
}

--- 注入已有的本地 Service handle；重复注入视为启动错误。
--- handles 由 battle_main 拥有；成功返回 true；无 I/O、无 yield。
--- boolean 配置成功；重复配置或非法 handle 抛错。
---@param handles BattleDispatchHandles 本进程已创建的 Query/BattleMgr handles。
---@return boolean 配置成功；重复配置或非法 handle 抛错。
local function configure(handles)
    assert(query_service == nil and battle_mgr == nil, "battle_dispatch already configured")
    assert(type(handles) == "table" and type(handles.query_service) == "number" and
        type(handles.battle_mgr) == "number", "invalid battle_dispatch handles")
    query_service = handles.query_service
    battle_mgr = handles.battle_mgr
    return true
end

--- 返回一个可预期业务拒绝；消息为固定短文案，不包含 Server 堆栈。
--- code/message：当前请求结果码和诊断；新建 record，无 I/O、无 yield。
local function rejected(code, message)
    return { ok = true, response = { result = code, message = message } }
end

--- 在编码前限制 Event、路点及事件文本；编码后的帧长仍由 Gateway 检查。
--- result：Worker 返回的纯数据；返回 boolean；O(events + points)，无 yield。
local function within_response_budget(result)
    -- 参数/状态检查：结果必须包含有界的事件数组。
    if type(result) ~= "table" or type(result.events) ~= "table" or
        #result.events > MAX_EVENTS then
        return false
    end

    -- 核心计算：逐个检查事件文本和路径点预算。
    local point_count = 0
    for _, event in ipairs(result.events) do
        if type(event) ~= "table" or type(event.type) ~= "string" or
            #event.type > MAX_TEXT_BYTES or
            type(event.reason or "") ~= "string" or
            #(event.reason or "") > MAX_TEXT_BYTES or
            type(event.result or "") ~= "string" or
            #(event.result or "") > MAX_TEXT_BYTES or
            type(event.points or {}) ~= "table" then
            return false
        end

        point_count = point_count + #(event.points or {})
        if point_count > MAX_POINTS then
            return false
        end
    end

    return true
end


--- 客户端只提供 scenario_id；Snapshot 由 Server 固定场景模块构造。
--- request：已解码 Protobuf record；返回 response record；Manager call 会 yield。
---@param request RunAutoBattleRequest 已解码的自动战斗请求；由当前 Service 拥有。
---@return BattleResultRecord Battle 结果或稳定业务失败 record；Manager call 可能 yield。
local function run_auto_battle(request)
    -- 参数/状态检查：只接受已登记的场景，并限制并发数量。
    if type(request) ~= "table" or request.scenario_id ~= 1001 then
        return rejected(RESULT.BAD_SCENARIO, "unknown scenario_id")
    end

    if in_flight >= MAX_IN_FLIGHT then
        return rejected(RESULT.BUSY, "battle request limit reached")
    end

    -- 数据准备：由 Server 固定场景模块构造 Snapshot。
    local snapshot = assert(scenario.make_snapshot(request.scenario_id))

    -- 核心计算：同步调用 BattleMgr；in_flight 在调用前后成对修改。
    in_flight = in_flight + 1
    local call_ok, result, worker_error = pcall(
        skynet.call,
        battle_mgr,
        "lua",
        "simulate",
        snapshot
    )
    in_flight = in_flight - 1

    if not call_ok or result == nil then
        skynet.error(
            "RunAutoBattle failed: ",
            tostring(call_ok and worker_error and worker_error.code or result)
        )
        return rejected(RESULT.BATTLE_FAILED, "battle simulation failed")
    end

    -- 参数/状态检查：限制返回事件、文本和路径点总量。
    if not within_response_budget(result) then
        return rejected(RESULT.RESULT_TOO_LARGE, "battle result exceeds response limit")
    end

    -- 收尾：组装跨进程返回的纯数据 record。
    --- Event table 与 Proto BattleEvent 字段名一致，跨进程只传纯数据。
    return
    {
        ok = true,
        response =
        {
            result = RESULT.OK,
            message = "",
            battle_id = result.battle_id,
            battle_version = result.battle_version,
            map_id = result.map_id,
            map_version = result.map_version,
            seed = result.seed,
            battle_result = result.result,
            end_logic_ms = result.end_logic_ms,
            events = result.events,
        },
    }
end


--- 保留 QueryCell 路由，增加 RunAutoBattle；错误 command/id 组合显式拒绝。
--- payload：Gateway 解码的纯 table；Query/Manager call 会 yield。
---@param payload GatewayDispatch Gateway Proxy 转发的已解码请求。
---@return BattleResultRecord Query/Battle 业务结果；本地 call 可能 yield。
local function dispatch_gateway(payload)
    -- 参数/状态检查：Battle 依赖必须已经由 battle_main 注入。
    assert(query_service ~= nil and battle_mgr ~= nil, "battle_dispatch is not ready")
    assert(type(payload) == "table", "gateway payload must be table")

    -- 核心计算：CommandId 选择唯一业务处理器，避免 Gateway 参与业务路由。
    if payload.command_id == command_ids.QUERY_CELL then
        return skynet.call(query_service, "lua", "query_cell", { request = payload.data })
    end

    if payload.command_id == command_ids.RUN_AUTO_BATTLE then
        return run_auto_battle(payload.data)
    end

    skynet.error(
        "Unknown Gateway command id=",
        tostring(payload.command_id)
    )
    return nil
end


--- 执行业务分发；有返回数据时通过统一 send_data 发回 Gateway。
--- payload：Gateway 转发的连接身份、command_id 和已解码 data；可能 yield。
local function forward_data(payload)
    assert(query_service ~= nil and battle_mgr ~= nil,
        "battle_dispatch is not ready")
    assert(
        type(payload) == "table" and type(payload.data) == "table",
        "gateway data is required"
    )
    assert(type(payload.gateway_epoch) == "string", "gateway_epoch is required")
    assert(math.type(payload.connection_id) == "integer" and
        payload.connection_id >= 0,
        "connection_id must be non-negative")
    assert(math.type(payload.command_id) == "integer" and
        payload.command_id > 0,
        "command_id must be positive")

    local call_ok, response = pcall(dispatch_gateway, payload)
    if not call_ok then
        skynet.error("Battle gateway dispatch failed: ", tostring(response))
        return
    end

    if response == nil then
        return
    end

    local send_ok, send_error = pcall(
        cluster.send,
        process.cluster.gateway_node,
        "@" .. process.cluster.gateway_proxy_service,
        "send_data",
        {
            gateway_epoch = payload.gateway_epoch,
            connection_id = payload.connection_id,
            command_id = payload.command_id,
            data = response,
        }
    )
    if not send_ok then
        skynet.error("Battle gateway send_data failed: ", tostring(send_error))
    end
end

--- 通知 Gateway 关闭指定连接；只传递连接身份，不保存或等待业务状态。
--- data.connection_id 必须大于 0；广播关闭不属于本接口。
local function close_connection(data)
    assert(type(data) == "table", "gateway close data is required")
    assert(type(data.gateway_epoch) == "string", "gateway_epoch is required")
    assert(math.type(data.connection_id) == "integer" and
        data.connection_id > 0,
        "connection_id must be positive for close")

    local ok, err = pcall(
        cluster.send,
        process.cluster.gateway_node,
        "@" .. process.cluster.gateway_proxy_service,
        "close",
        data
    )
    if not ok then
        skynet.error("Battle gateway close failed: ", tostring(err))
    end
end

skynet.start(function()
    luapanda_debug.start(8821)
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
        elseif command == "ready" then
            skynet.retpack(query_service ~= nil and battle_mgr ~= nil)
        elseif command == "send_data" then
            forward_data(payload)
        elseif command == "close" then
            close_connection(payload)
        else
            error("unknown battle_dispatch command: " .. tostring(command))
        end
    end)
end)
