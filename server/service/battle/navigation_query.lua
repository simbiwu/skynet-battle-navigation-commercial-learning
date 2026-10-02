--- 职责：加载 Battle 进程共享静态地图，并响应内部 QueryCell 查询消息。
--- 边界：Skynet Service；拥有独立 Lua State 和消息队列，不处理 TCP/Protobuf。
--- 输入/输出：Gateway dispatch payload + 已解码 request table -> response result record。
--- 生命周期：进程启动时创建一次；启动阶段加载 BMAP，运行期只读查询。
--- 不负责：不注册全局服务名、不代理第二课高频寻路、不保存动态单位。
local skynet = require "skynet"
local endpoint = require "gateway.endpoint"
local config = require "config.battle"
local query_logic = require "battle.navigation.query_logic"
local luapanda_debug = require "shared.debug.luapanda_debug"

--- 安装 Lua dispatch 并在成功加载地图后发布 READY；启动失败由 launcher 感知。
--- 查询 handler 不 yield；外部 Gateway send 用 endpoint 回复，Battle 内部 call 用 retpack 返回。
--- skynet.start 回调无参数；它拥有本 Service 的启动顺序，完成后不主动退出。
skynet.start(function()
    --- Query 是独立 Lua State，使用与 Gateway 不同的 LuaPanda port。
    luapanda_debug.start(8819)
    query_logic.start(config)

    --- _session/_source 是 Skynet 消息元数据；command 是 dispatch 名称；payload 是 Gateway 已解码的请求上下文。
    --- session integer 0表示 Gateway 的单向 send；非0表示本地 call。
    --- source ServiceHandle Gateway 或 BattleDispatch 的发送方 handle。
    --- command "ready"|"gateway_dispatch"|"gateway_disconnect"
    --- payload GatewayDispatch|nil 已解码的 Gateway 请求上下文。
    ---@param session integer 0表示 Gateway 的单向 send；非0表示本地 call。
    ---@param source ServiceHandle Gateway 或 BattleDispatch 的发送方 handle。
    ---@param command "ready"|"gateway_dispatch"|"gateway_disconnect"
    ---@param payload GatewayDispatch|nil 已解码的 Gateway 请求上下文。
    skynet.dispatch("lua", function(session, source, command, payload)
        if command == "ready" then
            --- 只有完成 query_logic.start 并注册 dispatch 后，main 才会收到 ready。
            skynet.retpack(true)
            return
        end
        if command == "gateway_disconnect" then return end
        assert(command == "gateway_dispatch", "navigation_query only accepts gateway_dispatch")
        assert(type(payload) == "table", "gateway dispatch payload is required")
        assert(payload.command == "QueryCell", "unsupported navigation command: " .. tostring(payload.command))
        local response = query_logic.query(assert(payload.request, "query request is required"))
        --- 业务查询只产生响应 table；接入分支处理返回路径，不接触 Socket、frame 或 Protobuf bytes。
        if session == 0 then
            --- 直接接入 FlyWow 的单向消息：少量接入代码完成独立响应。
            local context = endpoint.new({ gateway_service = source, request = payload })
            assert(context:reply(response))
        else
            --- Battle Dispatch 的内部本地查询合同保留，不涉及客户端读取等待。
            skynet.retpack({ ok = true, response = response })
        end
    end)

    skynet.error("NAV_QUERY_READY address=", skynet.address(skynet.self()),
                 " map=", config.map.id, " version=", config.map.version)
end)
