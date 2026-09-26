-- 职责：集中声明导航查询 Server 的监听、协议和静态地图启动参数。
-- 边界：Server Runtime Config；由各 Service 在自己的 Lua State 中只读加载。
-- 输入/输出：无运行时输入 -> 一张进程配置 table。
-- 生命周期：每个 Lua State 由 require 缓存一份；启动完成后不得修改。
-- 不负责：不加载地图、不打开端口、不保存连接或战斗动态状态。
return {
    host = "127.0.0.1",              -- 第一课默认只绑定本机；显式修改后才暴露到其他网卡。
    port = 19001,                     -- Navigation Gateway TCP 端口。
    backlog = 128,                    -- listen backlog；不是最大在线连接数。
    tcp_nodelay = true,               -- 小请求/响应优先减少 Nagle 延迟。
    max_clients = 1024,               -- 单个课程 Gateway 的连接上限。
    max_inflight_per_connection = 32, -- 防止单连接无限流水请求堆积跨 Service call。
    write_warning_close_kb = 1024,    -- Skynet write buffer warning 达到该值时主动断开慢连接。

    protocol_version = 1,             -- Envelope 兼容版本。
    query_cell_command = 1001,        -- QueryCell 命令号。
    -- skynet.netpack 的 framing 固定为 2-byte Big Endian uint16 length。
    -- netpack.pack 对 payload >= 0x10000 直接报错，因此业务上限固定为 65535 bytes。
    max_frame_bytes = 0xffff,

    -- 由 shared/protocol 发布的 Server descriptor；相对 server/ 运行目录解析。
    protocol_descriptor = "../shared/protocol/generated/server/navigation_query.pb",

    map = {
        id = 1001,                       -- BMAP Header 和协议共用的 uint32 地图 ID。
        version = 1,                     -- 必须与 BMAP Header 一致。
        -- 由 Unity Authoring 生成并经 Git 发布；Server 只消费已提交版本。
        bmap = "../shared/navigation/battle_1001/battle_1001.bmap",
    },
}
