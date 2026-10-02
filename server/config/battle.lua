-- 职责：Battle 运行配置；供 Battle Service 通过 require config.battle 读取。
-- 边界：Server Runtime；只保存地图、Cluster 和 Battle 运行参数。
-- 使用：修改配置后重启 Battle 进程；启动入口使用同目录的 battle_process.lua。
-- 不负责：不设置 start、luaservice、lua_path 等 Skynet 进程启动参数。
return {
    map = {
        id = 1001,                                           -- BMAP Header 中的业务地图 ID。
        version = 1,                                         -- 地图版本；必须与 BMAP Header 和发布合同一致。
        bmap = "../shared/navigation/battle_1001/battle_1001.bmap", -- 已发布 BMAP 路径；相对 Server 工作目录。
    },
    cluster = {
        local_listen = 2528,                                 -- Battle Cluster 监听端口；Gateway 连接此端口。
        service_name = "battle_dispatch",                    -- Gateway 发起请求的 Cluster Service 名。
        gateway_node = "gateway",                            -- Gateway Cluster 节点名；Battle 回推使用。
        gateway_address = "127.0.0.1:2527",                 -- Gateway Cluster 地址；格式为 host:port。
        gateway_proxy_service = "gateway_proxy",             -- Gateway 接收 Battle 结果的 Service 名。
        max_clients = 64,                                    -- Battle Cluster 连接上限。
    },
}
