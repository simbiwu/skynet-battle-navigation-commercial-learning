-- 职责：集中声明导航查询 Server 的监听、协议和静态地图启动参数。
-- 边界：Server Runtime Config；由各 Service 在自己的 Lua State 中只读加载。
-- 输入/输出：无运行时输入 -> 一张进程配置 table。
-- 生命周期：每个 Lua State 由 require 缓存一份；启动完成后不得修改。
-- 不负责：不加载地图、不打开端口、不保存连接或战斗动态状态。
return {
    host = "127.0.0.1",          -- TCP 监听地址；开发环境默认只允许本机访问。
    port = 19001,                 -- TCP 监听端口，合法范围 1..65535。
    protocol_version = 1,        -- Envelope 兼容版本。
    query_cell_command = 1001,   -- QueryCell 命令号。
    max_frame_bytes = 64 * 1024, -- 单个 Envelope 最大 byte 数，限制接收内存。
    map = {
        id = 1001,                       -- BMAP Header 和协议共用的 uint32 地图 ID。
        version = 1,                     -- 必须与 BMAP Header 一致。
        bmap = "maps/battle_1001.bmap", -- 相对 Server 工作目录的地图资产路径。
    },
}
