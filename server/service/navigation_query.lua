-- 职责：拥有第一课静态地图查询入口，并响应 Gateway 发来的 QueryCell 消息。
-- 边界：Skynet Service；拥有独立 Lua State 和消息队列，不处理 TCP/Protobuf。
-- 输入/输出：Lua 协议 query_cell + request table -> response table。
-- 生命周期：进程启动时创建一次；启动阶段加载 BMAP，运行期只读查询。
-- 不负责：不注册全局服务名、不代理第二课高频寻路、不保存动态单位。
local skynet = require "skynet"
local config = require "config.game"
local query_logic = require "navigation.query_logic"
local luapanda_debug = require "debug.luapanda_debug"

-- 安装 Lua dispatch 并在成功加载地图后发布 READY；启动失败由 launcher 感知。
-- 本 Service 的 query_cell handler 内部不 yield，响应 table 由 skynet.pack 复制发送。
skynet.start(function()
    -- Query 是独立 Lua State，使用与 Gateway 不同的 LuaPanda port。
    luapanda_debug.start("query")
    query_logic.start(config)

    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command ~= "query_cell" then
            error("unknown navigation_query command: " .. tostring(command))
        end
        local response = query_logic.query(assert(payload, "query payload is required"))
        skynet.ret(skynet.pack(response))
    end)

    skynet.error("NAV_QUERY_READY address=", skynet.address(skynet.self()),
                 " map=", config.map.id, " version=", config.map.version)
end)
