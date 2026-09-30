-- 职责：加载 Battle 进程共享静态地图，并响应内部 QueryCell 查询消息。
-- 边界：Skynet Service；拥有独立 Lua State 和消息队列，不处理 TCP/Protobuf。
-- 输入/输出：Gateway dispatch payload + 已解码 request table -> response result record。
-- 生命周期：进程启动时创建一次；启动阶段加载 BMAP，运行期只读查询。
-- 不负责：不注册全局服务名、不代理第二课高频寻路、不保存动态单位。
local skynet = require "skynet"
local config = require "config.game"
local query_logic = require "battle.navigation.query_logic"
local luapanda_debug = require "shared.debug.luapanda_debug"

-- 安装 Lua dispatch 并在成功加载地图后发布 READY；启动失败由 launcher 感知。
-- 本 Service 的 gateway_dispatch handler 内部不 yield，响应 record 由 skynet.retpack 复制发送。
-- skynet.start 回调无参数；它拥有本 Service 的启动顺序，完成后不主动退出。
skynet.start(function()
    -- Query 是独立 Lua State，使用与 Gateway 不同的 LuaPanda port。
    luapanda_debug.start(8819)
    query_logic.start(config)

    -- _session/_source 是 Skynet 消息元数据；command 是 dispatch 名称；payload 是 Gateway 已解码的请求上下文。
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "ready" then
            -- 只有完成 query_logic.start 并注册 dispatch 后，main 才会收到 ready。
            skynet.retpack(true)
            return
        end
        assert(command == "gateway_dispatch", "navigation_query only accepts gateway_dispatch")
        assert(type(payload) == "table", "gateway dispatch payload is required")
        assert(payload.command == "QueryCell", "unsupported navigation command: " .. tostring(payload.command))
        local response = query_logic.query(assert(payload.request, "query request is required"))
        -- Gateway 只识别稳定 result record；业务 Service 不接触 Socket、frame 或 Protobuf bytes。
        skynet.retpack({ ok = true, response = response })
    end)

    skynet.error("NAV_QUERY_READY address=", skynet.address(skynet.self()),
                 " map=", config.map.id, " version=", config.map.version)
end)
