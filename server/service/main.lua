-- 职责：创建 Query/Gateway 两个 Service，并显式注入它们之间的地址依赖。
-- 边界：Skynet Process Bootstrap Service；只负责生命周期接线和启动顺序。
-- 输入/输出：config/skynet.lua 启动本文件 -> 两个可运行的业务 Service。
-- 生命周期：完成接线后退出；已创建 Service 继续独立运行。
-- 不负责：不加载 BMAP、不监听端口、不执行查询或协议编解码。
local skynet = require "skynet"

-- Query 先完成地图加载，Gateway 再开始监听，避免端口就绪后查询依赖尚未可用。
skynet.start(function()
    local query_service = skynet.newservice("navigation_query")
    local gateway_service = skynet.newservice("navigation_gateway")
    assert(skynet.call(gateway_service, "lua", "start", query_service))

    skynet.error("NAV_SERVER_READY query=", skynet.address(query_service),
                 " gateway=", skynet.address(gateway_service))
    skynet.exit()
end)
