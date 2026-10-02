--- 职责：把 Battle Process 的 Gateway 请求分给地图查询或自动战斗 Manager。
--- 边界：Server RPC Adapter；不持有 fd、frame、descriptor 或 Battle Context。
--- 输入/输出：已解码 gateway_dispatch message -> cluster.send 的单向处理；结果另发 battle_result。
--- 生命周期：battle_main 注入两个 Service handle 后注册为 cluster 入口。
--- 不负责：不实现寻路、AI 或战斗结算，不接受客户端 Snapshot。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.battle"
local scenario = require "battle.scenario_1001"
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

    -- 核心计算：Command 名和数值必须同时匹配，避免错误路由。
    if payload.command == "QueryCell" and payload.command_id == 1001 then
        return skynet.call(query_service, "lua", "gateway_dispatch", payload)
    end

    if payload.command == "RunAutoBattle" and payload.command_id == 1002 then
        return run_auto_battle(payload.request)
    end

    return
    {
        ok = false,
        error =
        {
            code = "UNKNOWN_COMMAND",
            message = "command/id mismatch",
        },
    }
end


--- 执行业务分发后单向回推结果；transport token 只关联 Gateway 请求，不成为 Battle 身份。
--- payload：Gateway Proxy 转发的已解码请求；Battle 结果送往配置的 Gateway Proxy；可能 yield。
--- 失败：请求/业务错误转成受控错误 record；回推失败由项目 Proxy 路由超时收敛；Gateway 不等待业务。
---@param payload GatewayDispatch 包含 route_token 的跨进程请求。
---@return nil 业务结果通过 Cluster battle_result 单向回推，不使用 retpack。
local function forward_result(payload)
    -- 参数/状态检查：路由 token 是 Battle 回推 Gateway 的唯一关联值。
    assert(query_service ~= nil and battle_mgr ~= nil, "battle_dispatch is not ready")
    assert(
        type(payload) == "table" and
        type(payload.route_token) == "string" and
        #payload.route_token > 0 and
        #payload.route_token <= 128,
        "invalid gateway route token"
    )

    -- 核心计算：执行 Query 或 BattleMgr，统一收敛异常结果。
    local route_token = payload.route_token
    local call_ok, result = pcall(dispatch_gateway, payload)
    if not call_ok then
        skynet.error("Battle gateway dispatch failed: ", tostring(result))
        result =
        {
            ok = false,
            error =
            {
                code = "BATTLE_FAILED",
                message = "battle request failed",
            },
        }
    end

    -- 持久化/消息发送：把结果按 route token 回推 Gateway Proxy。
    local send_ok, send_error = pcall(
        cluster.send,
        process.cluster.gateway_node,
        "@" .. process.cluster.gateway_proxy_service,
        "battle_result",
        route_token,
        result
    )
    if not send_ok then
        skynet.error("Battle result forward failed: ", tostring(send_error))
    end
end


--- 固定签名的 Service 分发；Cluster data-plane 用 send，结果另发 battle_result 消息。
--- configure/ready 使用本地 call；gateway_dispatch 单向接收且会 yield，不 retpack。
skynet.start(function()
    luapanda_debug.start(8821)
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
        elseif command == "ready" then
            skynet.retpack(query_service ~= nil and battle_mgr ~= nil)
        elseif command == "gateway_dispatch" then
            forward_result(payload)
        else
            error("unknown battle_dispatch command: " .. tostring(command))
        end
    end)
end)
