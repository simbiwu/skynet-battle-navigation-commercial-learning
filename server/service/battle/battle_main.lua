-- 职责：组装 Lesson 2 Battle Process 的 Query、Manager 与跨进程分发入口。
-- 边界：Server Runtime Composition Root；只注入 handle，不持有网络 fd。
-- 输入/输出：进程配置与已构建 Service -> READY 的 battle/battle_dispatch cluster 入口。
-- 生命周期：启动完成后本入口退出，子 Service 和 cluster listener 长驻。
-- 不负责：不解析 Protobuf、不执行 AI/A*、不保存客户端连接。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local sharedata = require "skynet.sharedata"
local battle_nav = require "flywow_navigation"
local process = require "config.battle"

-- 先等待地图和 Worker Pool 就绪，再向 Gateway 发布 cluster 入口。
-- 无参数/返回；会创建 Service、执行本地 call/cluster I/O 并 yield。
skynet.start(function()
    sharedata.new("battle.unit_profiles", process.unit_profiles)
    local profiles_loaded, profiles_error =
        battle_nav.load_navigation_profiles(process.navigation_profiles)
    assert(profiles_loaded,
           profiles_error and (profiles_error.code .. ": " .. profiles_error.message) or
               "load_navigation_profiles failed")

    local query_service = skynet.newservice("battle/navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))
    local mgr = skynet.newservice("battle/battle_mgr")
    assert(skynet.call(mgr, "lua", "ready"))
    local dispatcher = skynet.newservice("battle/battle_dispatch")
    assert(skynet.call(dispatcher, "lua", "configure", {
        query_service = query_service,
        battle_mgr = mgr,
    }))
    assert(skynet.call(dispatcher, "lua", "ready"))

    cluster.reload({
        [process.cluster.gateway_node] = process.cluster.gateway_address,
    })
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, dispatcher)
    local shutdown_coordinator =
        skynet.newservice("battle/shutdown_coordinator")
    assert(skynet.call(shutdown_coordinator, "lua", "configure", {
        query_service = query_service,
        battle_mgr = mgr,
        dispatcher = dispatcher,
    }))
    assert(skynet.call(shutdown_coordinator, "lua", "ready"))
    skynet.error("LESSON2_BATTLE_PROCESS_READY node=", process.cluster.service_name,
                 " query=", skynet.address(query_service),
                 " manager=", skynet.address(mgr),
                 " dispatch=", skynet.address(dispatcher),
                 " shutdown=", skynet.address(shutdown_coordinator))
    skynet.exit()
end)
