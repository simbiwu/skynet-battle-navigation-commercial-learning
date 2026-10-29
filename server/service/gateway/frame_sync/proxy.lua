--- 职责：把FlyWow Gateway已解码请求转发给Frame Dispatch，并接收定向FramePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet  = require "skynet.manager"
local cluster = require "skynet.cluster"
local frame_sync_config = require "config.frame_sync"
local flywow_result = require "flywow_result"
local module_state =
{
    gateway_service_handle = nil, -- 组合根绑定的本地 Gateway Service，只由此 Proxy 投递消息。
    shutdown_coordinator_handle = nil, -- 唯一被授权关闭 Proxy 的本进程 Service。
    diagnostics =
    {
    client_messages_to_battle  = 0, -- 从 FlyWow Gateway 向 Battle 转交的已解码消息数。
    disconnects_to_battle      = 0, -- 向 Battle 转交的断线事件数。
    battle_messages_to_gateway = 0, -- 从 Battle 转交给 FlyWow Gateway 的响应或推送数。
    cluster_send_errors        = 0, -- 同步 cluster.send 调用抛出的错误数。
    },
}

--- 将 Gateway 请求或断线通知异步送到 Frame Dispatch，并更新对应诊断计数。
---@param command string Frame Dispatch 接受的 send_data 或 disconnect 命令。
---@param payload table Gateway 生成并由当前回调借用的消息 record。
---@return boolean Cluster API 未抛错返回 true；失败已记录并返回 false。
local function forward(command, payload)
    if command == "disconnect" then
        module_state.diagnostics.disconnects_to_battle = module_state.diagnostics.disconnects_to_battle + 1
    else
        module_state.diagnostics.client_messages_to_battle = module_state.diagnostics.client_messages_to_battle + 1
    end

    local ok, err = pcall(cluster.send, frame_sync_config.battle_node,
        "@frame_dispatch", command, payload)
    if not ok then
        module_state.diagnostics.cluster_send_errors = module_state.diagnostics.cluster_send_errors + 1
        skynet.error("FRAME_PROXY_FORWARD_FAILED ", tostring(err))
    end
end

skynet.start(function()
    skynet.info_func(function()
        return
        {
            gateway_bound              = module_state.gateway_service_handle ~= nil,
            gateway_handle             = module_state.gateway_service_handle and skynet.address(module_state.gateway_service_handle) or "unbound",
            gateway_node               = frame_sync_config.gateway_node,
            battle_node                = frame_sync_config.battle_node,
            client_messages_to_battle  = module_state.diagnostics.client_messages_to_battle,
            disconnects_to_battle      = module_state.diagnostics.disconnects_to_battle,
            battle_messages_to_gateway = module_state.diagnostics.battle_messages_to_gateway,
            cluster_send_errors        = module_state.diagnostics.cluster_send_errors,
        }
    end)

    --- 跨 Service 合同：start/bind/shutdown 返回 FlyWowResult；异步数据命令仅在同步 call 时回传结果。
    ---@param session integer Skynet RPC session；0 表示异步 send，没有可回复的调用方。
    ---@param source integer 当前命令发送方的 Service handle，用于验证 Gateway 所属身份。
    ---@param command string Proxy 接受的跨 Service 控制或数据命令。
    ---@param payload any 对应命令的消息 record；异步请求由发送方固定字段合同。
    skynet.dispatch("lua", function(session, source, command, payload)
        if command == "start" then
            local setup_ok, setup_error = pcall(function()
                cluster.reload({
                    [frame_sync_config.battle_node] = frame_sync_config.battle_address,
                    [frame_sync_config.gateway_node] = frame_sync_config.gateway_address,
                })
                cluster.open(frame_sync_config.gateway_node, 64)
                cluster.register("frame_proxy", skynet.self())
            end)
            if not setup_ok then
                skynet.retpack(flywow_result.failure("FRAME_CLUSTER_SETUP_FAILED", tostring(setup_error)))
                return
            end

            local ready_ok, ready = pcall(
                cluster.call,
                frame_sync_config.battle_node,
                "@frame_dispatch",
                "ready"
            )
            if not ready_ok or ready ~= true then
                local failure = ready_ok and "Battle Dispatch is not ready" or tostring(ready)
                skynet.retpack(flywow_result.failure("FRAME_BATTLE_NOT_READY", failure))
                return
            end
            skynet.name(".frame_proxy", skynet.self())
            skynet.retpack(flywow_result.success())
        elseif command == "bind" then
            if module_state.gateway_service_handle ~= nil or type(payload) ~= "table" or
                type(payload.gateway) ~= "number" or math.type(payload.gateway) ~= "integer" or payload.gateway <= 0 then
                skynet.retpack(flywow_result.failure("FRAME_GATEWAY_BIND_INVALID", "Gateway binding is invalid"))
                return
            end
            module_state.gateway_service_handle = payload.gateway
            skynet.retpack(flywow_result.success())
        elseif command == "set_shutdown_coordinator" then
            if module_state.shutdown_coordinator_handle ~= nil or
                type(payload) ~= "number" or math.type(payload) ~= "integer" or payload ~= source then
                skynet.retpack(flywow_result.failure(
                    "FRAME_SHUTDOWN_COORDINATOR_INVALID",
                    "shutdown coordinator must configure itself once"
                ))
                return
            end
            module_state.shutdown_coordinator_handle = source
            skynet.retpack(flywow_result.success())
        elseif command == "shutdown" then
            if module_state.shutdown_coordinator_handle == nil or source ~= module_state.shutdown_coordinator_handle then
                skynet.retpack(flywow_result.failure("FRAME_SHUTDOWN_SOURCE_INVALID", "untrusted shutdown caller"))
                return
            end
            skynet.retpack(flywow_result.success())
            skynet.exit()
        elseif command == "send_data" then
            if module_state.gateway_service_handle == nil or type(payload) ~= "table" or
                type(payload.data) ~= "table" then
                local failure = flywow_result.failure("FRAME_DATA_INVALID", "Gateway data is unavailable or malformed")
                if session ~= 0 then
                    skynet.retpack(failure)
                else
                    skynet.error("FRAME_DATA_INVALID")
                end
                return
            end
            if source == module_state.gateway_service_handle then
                if not forward("send_data", payload) then
                    if session ~= 0 then
                        skynet.retpack(flywow_result.failure(
                            "FRAME_BATTLE_DELIVERY_FAILED",
                            "Cluster rejected Battle delivery"
                        ))
                    end
                    return
                end
            else
                -- FlyWow Gateway 支持无请求关联的定向 FramePush；跨实例会重验 epoch/id。
                module_state.diagnostics.battle_messages_to_gateway =
                    module_state.diagnostics.battle_messages_to_gateway + 1
                local gateway_delivery = skynet.send(
                    module_state.gateway_service_handle,
                    "lua",
                    "send_data",
                    payload
                ) -- Skynet 本地投递接受标记；异步成功不表示客户端已经收到。
                if gateway_delivery == nil then
                    if session ~= 0 then
                        skynet.retpack(flywow_result.failure(
                            "FRAME_GATEWAY_DELIVERY_FAILED",
                            "Skynet rejected Gateway delivery"
                        ))
                    else
                        skynet.error("FRAME_GATEWAY_DELIVERY_FAILED")
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
                    skynet.retpack(flywow_result.failure("FRAME_DISCONNECT_SOURCE_INVALID", "untrusted disconnect source"))
                else
                    skynet.error("FRAME_DISCONNECT_SOURCE_INVALID")
                end
                return
            end
            forward("disconnect", payload)
            if session ~= 0 then
                skynet.retpack(flywow_result.success())
            end
        else
            if session ~= 0 then
                skynet.retpack(flywow_result.failure(
                    "FRAME_PROXY_COMMAND_UNKNOWN",
                    "unknown frame proxy command: " .. tostring(command)
                ))
            else
                skynet.error("FRAME_PROXY_COMMAND_UNKNOWN ", tostring(command))
            end
        end
    end)
end)
