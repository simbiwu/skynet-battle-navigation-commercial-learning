--- 职责：加载 Battle 进程共享静态地图，并响应内部 QueryCell 查询消息。
--- 边界：Skynet Service；拥有独立 Lua State 和消息队列，不处理 TCP/Protobuf。
--- 输入/输出：Gateway dispatch payload + 已解码 request table -> response result record。
--- 生命周期：进程启动时创建一次；启动阶段加载 BMAP，运行期只读查询。
--- 不负责：不注册全局服务名、不代理第二课高频寻路、不保存动态单位。
local skynet = require "skynet"
local config = require "config.battle"
local query_logic = require "battle.navigation.query_logic"
local luapanda_debug = require "shared.debug.luapanda_debug"

--- 安装 Lua dispatch 并在成功加载地图后发布 READY；启动失败由 launcher 感知。
--- 查询 handler 不 yield；统一由 Battle Dispatch 负责向 Gateway 发送结果。
--- skynet.start 回调无参数；它拥有本 Service 的启动顺序，完成后不主动退出。
skynet.start(function()
    --- Query 是独立 Lua State，使用与 Gateway 不同的 LuaPanda port。
    luapanda_debug.start(8819)
    query_logic.start(config)

    --- 本 Service 只接受 Battle Dispatch 的本地查询调用。
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "ready" then
            skynet.retpack(true)
            return
        end
        if command == "shutdown" then
            skynet.retpack(true)
            skynet.exit()
            return
        end

        assert(command == "query_cell",
            "navigation_query only accepts query_cell")
        assert(type(payload) == "table", "query payload is required")

        local response = query_logic.query(
            assert(payload.request, "query request is required")
        )
        skynet.retpack(response)
    end)

    -- 收尾：Query Service 初始化完成后发布 READY 日志。
    skynet.error(
        "NAV_QUERY_READY address=",
        skynet.address(skynet.self()),
        " map=",
        config.map.id,
        " version=",
        config.map.version
    )
end)
