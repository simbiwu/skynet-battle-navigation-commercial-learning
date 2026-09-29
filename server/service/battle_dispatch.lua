-- 职责：把 Battle Process 的 Gateway 请求分给地图查询或自动战斗 Manager。
-- 边界：Server RPC Adapter；不持有 fd、frame、descriptor 或 Battle Context。
-- 输入/输出：已解码 gateway_dispatch record -> 对应的响应或错误 record。
-- 生命周期：battle_main 注入两个 Service handle 后注册为 cluster 入口。
-- 不负责：不实现寻路、AI 或战斗结算，不接受客户端 Snapshot。
local skynet = require "skynet"
local scenario = require "battle.scenario_1001"

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

-- 注入已有的本地 Service handle；重复注入视为启动错误。
-- handles 由 battle_main 拥有；成功返回 true；无 I/O、无 yield。
local function configure(handles)
    assert(query_service == nil and battle_mgr == nil, "battle_dispatch already configured")
    assert(type(handles) == "table" and type(handles.query_service) == "number" and
        type(handles.battle_mgr) == "number", "invalid battle_dispatch handles")
    query_service = handles.query_service
    battle_mgr = handles.battle_mgr
    return true
end

-- 返回一个可预期业务拒绝；消息为固定短文案，不包含 Server 堆栈。
-- code/message：当前请求结果码和诊断；新建 record，无 I/O、无 yield。
local function rejected(code, message)
    return { ok = true, response = { result = code, message = message } }
end

-- 在编码前限制 Event、路点及事件文本；编码后的帧长仍由 Gateway 检查。
-- result：Worker 返回的纯数据；返回 boolean；O(events + points)，无 yield。
local function within_response_budget(result)
    if type(result) ~= "table" or type(result.events) ~= "table" or
        #result.events > MAX_EVENTS then return false end
    local point_count = 0
    for _, event in ipairs(result.events) do
        if type(event) ~= "table" or type(event.type) ~= "string" or
            #event.type > MAX_TEXT_BYTES or
            type(event.reason or "") ~= "string" or
            #(event.reason or "") > MAX_TEXT_BYTES or
            type(event.result or "") ~= "string" or
            #(event.result or "") > MAX_TEXT_BYTES or
            type(event.points or {}) ~= "table" then return false end
        point_count = point_count + #(event.points or {})
        if point_count > MAX_POINTS then return false end
    end
    return true
end

-- 客户端只提供 scenario_id；Snapshot 由 Server 固定场景模块构造。
-- request：已解码 Protobuf record；返回 response record；Manager call 会 yield。
local function run_auto_battle(request)
    if type(request) ~= "table" or request.scenario_id ~= 1001 then
        return rejected(RESULT.BAD_SCENARIO, "unknown scenario_id")
    end
    if in_flight >= MAX_IN_FLIGHT then
        return rejected(RESULT.BUSY, "battle request limit reached")
    end
    local snapshot = assert(scenario.make_snapshot(request.scenario_id))
    in_flight = in_flight + 1
    local call_ok, result, worker_error = pcall(
        skynet.call, battle_mgr, "lua", "simulate", snapshot)
    in_flight = in_flight - 1
    if not call_ok or result == nil then
        skynet.error("RunAutoBattle failed: ",
            tostring(call_ok and worker_error and worker_error.code or result))
        return rejected(RESULT.BATTLE_FAILED, "battle simulation failed")
    end
    if not within_response_budget(result) then
        return rejected(RESULT.RESULT_TOO_LARGE, "battle result exceeds response limit")
    end
    -- Event table 与 Proto BattleEvent 字段名一致，跨进程只传纯数据。
    return { ok = true, response = {
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
    } }
end

-- 保留 QueryCell 路由，增加 RunAutoBattle；错误 command/id 组合显式拒绝。
-- payload：Gateway 解码的纯 table；Query/Manager call 会 yield。
local function dispatch_gateway(payload)
    assert(query_service ~= nil and battle_mgr ~= nil, "battle_dispatch is not ready")
    assert(type(payload) == "table", "gateway payload must be table")
    if payload.command == "QueryCell" and payload.command_id == 1001 then
        return skynet.call(query_service, "lua", "gateway_dispatch", payload)
    end
    if payload.command == "RunAutoBattle" and payload.command_id == 1002 then
        return run_auto_battle(payload.request)
    end
    return { ok = false, error = {
        code = "UNKNOWN_COMMAND", message = "command/id mismatch",
    } }
end

-- 固定签名的 Service 分发；session/source 是 Skynet 元数据。
-- configure/ready 无 yield；gateway_dispatch 中的跨 Service call 可 yield。
skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
        elseif command == "ready" then
            skynet.retpack(query_service ~= nil and battle_mgr ~= nil)
        elseif command == "gateway_dispatch" then
            skynet.retpack(dispatch_gateway(payload))
        else
            error("unknown battle_dispatch command: " .. tostring(command))
        end
    end)
end)
