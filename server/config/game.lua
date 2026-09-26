-- 职责：集中声明导航查询 Server 的静态地图和业务启动参数。
-- 边界：Server Runtime Config；由 navigation_query Service 在自己的 Lua State 中只读加载。
-- 输入/输出：无运行时输入 -> 一张业务地图配置 table。
-- 生命周期：Service 启动时读取一次；启动完成后不得修改。
-- 不负责：不加载 Gateway 监听配置、不打开端口、不保存连接或战斗动态状态。
return {
    map = {
        id = 1001,                       -- BMAP Header 中的业务地图 ID；必须大于 0。
        version = 1,                     -- 必须与 BMAP Header 一致。
        -- 由 Unity Authoring 生成并经 Git 发布；Server 只消费已提交版本。
        bmap = "../shared/navigation/battle_1001/battle_1001.bmap",
    },
}
