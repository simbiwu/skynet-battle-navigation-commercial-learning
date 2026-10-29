--- 职责：把 FlyWow Gateway 已解码请求转发给 State Dispatch，并接收定向 StatePush。
--- 边界：Gateway OS 进程；不解释技能、Navigation 或权威状态。
--- 输入/输出：Gateway record 和断线事件 -> Cluster；Battle record -> Gateway 发送。
--- ownership：组合根注入 Gateway handle；网络 fd 仍由 FlyWow Gateway 独占。
local skynet = require "skynet.manager"
local cluster = require "skynet.cluster"
local state_sync_config = require "config.state_sync"
local flywow_result = require "flywow_result"

local module_state =
{
    gateway_service_handle         = nil, -- 组合根绑定的本地 Gateway Service；仅用于投递响应和关闭连接。
    shutdown_coordinator_handle    = nil, -- 唯一被授权关闭本 Proxy 的本地 Service。
}

--- 把 Gateway 请求或断线通知异步转发到 State Dispatch；只记录 Cluster 投递异常。
---@param command string State Dispatch 接受的稳定命令名，例如 send_data 或 disconnect。
---@param payload table Gateway 生成的已解码 record；本函数只借用并转交。
---@return boolean Cluster 投递是否被接受；不表示 Battle 已处理业务消息。
local function forward(command, payload)
    local call_ok, call_error = pcall(
        cluster.send,
        state_sync_config.battle_node,
        "@state_dispatch",
        command,
        payload
    )
    if not call_ok then
        skynet.error("STATE_PROXY_FORWARD_FAILED ", tostring(call_error))
    end
    return call_ok
end

skynet.start(function()
    --- 跨 Service 合同：start/bind/shutdown 返回 FlyWowResult；数据转发在同步 call 时返回投递结果。
    ---@param session integer Skynet RPC session；0 表示异步 send，没有可回复的调用方。
    ---@param source integer 当前命令发送方的 Service handle，用于验证 Gateway 所属身份。
    ---@param command string Proxy 接受的跨 Service 控制或数据命令。
    ---@param payload any 对应命令的消息 record；异步请求由发送方固定字段合同。
    skynet.dispatch("lua", function(session, source, command, payload)
        if command == "start" then
            local setup_ok, setup_error = pcall(function()
                cluster.reload({
                    [state_sync_config.battle_node] = state_sync_config.battle_address,
                    [state_sync_config.gateway_node] = state_sync_config.gateway_address,
                })
                cluster.open(state_sync_config.gateway_node, 64)
                cluster.register("state_proxy", skynet.self())
            end)
            if not setup_ok then
                skynet.retpack(flywow_result.failure("STATE_CLUSTER_SETUP_FAILED", tostring(setup_error)))
                return
            end

            local call_ok, battle_ready = pcall(
                cluster.call,
                state_sync_config.battle_node,
                "@state_dispatch",
                "ready"
            )
            if not call_ok or battle_ready ~= true then
                local failure = call_ok and "Battle Dispatch is not ready" or tostring(battle_ready)
                skynet.retpack(flywow_result.failure("STATE_BATTLE_NOT_READY", failure))
                return
            end
            skynet.name(".state_proxy", skynet.self())
            skynet.retpack(flywow_result.success())
        elseif command == "bind" then
            if module_state.gateway_service_handle ~= nil or type(payload) ~= "table" or
                type(payload.gateway) ~= "number" or math.type(payload.gateway) ~= "integer" or payload.gateway <= 0 then
                skynet.retpack(flywow_result.failure("STATE_GATEWAY_BIND_INVALID", "Gateway binding is invalid"))
                return
            end
            module_state.gateway_service_handle = payload.gateway
            skynet.retpack(flywow_result.success())
        elseif command == "set_shutdown_coordinator" then
            if module_state.shutdown_coordinator_handle ~= nil or
                type(payload) ~= "number" or math.type(payload) ~= "integer" or payload ~= source then
                skynet.retpack(flywow_result.failure(
                    "STATE_SHUTDOWN_COORDINATOR_INVALID",
                    "shutdown coordinator must configure itself once"
                ))
                return
            end
            module_state.shutdown_coordinator_handle = source
            skynet.retpack(flywow_result.success())
        elseif command == "shutdown" then
            if module_state.shutdown_coordinator_handle == nil or source ~= module_state.shutdown_coordinator_handle then
                skynet.retpack(flywow_result.failure("STATE_SHUTDOWN_SOURCE_INVALID", "untrusted shutdown caller"))
                return
            end
            skynet.retpack(flywow_result.success())
            skynet.exit()
        elseif command == "send_data" then
            if module_state.gateway_service_handle == nil or type(payload) ~= "table" or
                type(payload.data) ~= "table" then
                if session ~= 0 then
                    skynet.retpack(flywow_result.failure("STATE_DATA_INVALID", "Gateway data is unavailable or malformed"))
                else
                    skynet.error("STATE_DATA_INVALID")
                end
                return
            end
            if source == module_state.gateway_service_handle then
                if not forward("send_data", payload) then
                    if session ~= 0 then
                        skynet.retpack(flywow_result.failure(
                            "STATE_BATTLE_DELIVERY_FAILED",
                            "Cluster rejected Battle delivery"
                        ))
                    end
                    return
                end
            else
                local gateway_delivery = skynet.send(
                    module_state.gateway_service_handle,
                    "lua",
                    "send_data",
                    payload
                ) -- Skynet 本地投递接受标记；异步成功不表示客户端已经收到。
                if gateway_delivery == nil then
                    if session ~= 0 then
                        skynet.retpack(flywow_result.failure(
                            "STATE_GATEWAY_DELIVERY_FAILED",
                            "Skynet rejected Gateway delivery"
                        ))
                    else
                        skynet.error("STATE_GATEWAY_DELIVERY_FAILED")
                    end
                    return
                end
            end
            if session ~= 0 then
                skynet.retpack(flywow_result.success())
            end
        elseif command == "gateway_disconnect" then
            if module_state.gateway_service_handle == nil or source ~= module_state.gateway_service_handle then
                if session ~= 0 then
                    skynet.retpack(flywow_result.failure("STATE_DISCONNECT_SOURCE_INVALID", "untrusted disconnect source"))
                else
                    skynet.error("STATE_DISCONNECT_SOURCE_INVALID")
                end
                return
            end
            if not forward("disconnect", payload) then
                if session ~= 0 then
                    skynet.retpack(flywow_result.failure(
                        "STATE_BATTLE_DISCONNECT_DELIVERY_FAILED",
                        "Cluster rejected Battle disconnect notification"
                    ))
                end
                return
            end
            if session ~= 0 then
                skynet.retpack(flywow_result.success())
            end
        else
            if session ~= 0 then
                skynet.retpack(flywow_result.failure(
                    "STATE_PROXY_COMMAND_UNKNOWN",
                    "unknown state proxy command: " .. tostring(command)
                ))
            else
                skynet.error("STATE_PROXY_COMMAND_UNKNOWN ", tostring(command))
            end
        end
    end)
end)
