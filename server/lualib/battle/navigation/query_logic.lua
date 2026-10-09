-- 职责：校验 QueryCell 业务请求并同步调用 Native 静态地图查询。
-- 边界：Server Runtime Library；只由 navigation_query Service 持有和调用。
-- 输入/输出：QueryCellRequest table -> 新的 QueryCellResponse table。
-- 生命周期：game config 在 start 时保存一次；响应归当前消息协程所有。
-- 不负责：不处理 TCP、不执行跨 Service call、不做寻路、不保存动态单位。
local skynet = require "skynet"
-- Navigation 首次接入说明：
-- 源码入口：third_party/skynet-flywow/navigation/lualib/flywow_navigation.lua。
-- 首次构建从 Server 根目录执行 ./scripts/linux/run_server.sh build；
-- 它调用 FlyWow/scripts/build_flywow.sh，生成
-- third_party/skynet-flywow/build/native/flywow_navigation_native.so。
-- battle_process.lua 明确配置 lua_path、lua_cpath 和 cpath；
-- 前者定位 Lua Wrapper，后两者定位 Native 模块，不生成额外路径配置文件。
-- require 先加载 Wrapper，再由 Wrapper require flywow_navigation_native。
local battle_nav = require "flywow_navigation"

local M = {}
local config -- 当前 Query Service 私有的只读配置；start 成功后不再替换。

local RESULT = {
    OK = 1,
    MAP_NOT_FOUND = 2,
    MAP_VERSION_MISMATCH = 3,
    OUT_OF_BOUNDS = 4,
    NOT_WALKABLE = 5,
    BAD_REQUEST = 6,
    INTERNAL_ERROR = 7,
}

-- 将 Native 稳定错误名转换成协议错误；返回的新 table 归调用协程所有。
local function result_error(code, message)
    return {
        result = RESULT[code] or RESULT.INTERNAL_ERROR,
        message = message or "",
    }
end

-- 启动时先发布完整 Profile 表，再主动加载配置中的全部地图。
-- 每张地图完成校验后进入进程 Registry；任一失败都会阻止 Service 就绪。
function M.start(options)
    -- 参数/状态检查：Query Logic 只能初始化一次。
    assert(config == nil, "navigation query logic already started")
    config = assert(options)
    assert(type(config.maps) == "table" and #config.maps > 0,
           "at least one navigation map must be configured")

    local loaded_map_ids = {}
    for _, path in ipairs(config.maps) do
        local loaded, err = battle_nav.load_map(path)
        assert(loaded, err and (err.code .. ": " .. err.message) or "load_map failed")
        assert(loaded_map_ids[loaded.map_id] == nil,
               "duplicate map_id in startup navigation maps")
        loaded_map_ids[loaded.map_id] = true
    end
end

-- 由 Native Registry 按 map_id 查询当前地图，并校验请求的资产 map_version。
-- 请求成功时响应仍回传协议中的 map_id/map_version，保持网络合同不变。
function M.query(request)
    if type(request) ~= "table" or type(request.map_id) ~= "number" or
       type(request.map_version) ~= "number" or
       type(request.position) ~= "table" then
        return result_error("BAD_REQUEST", "missing map identity or position")
    end

    local ok, value, err = pcall(
        battle_nav.query_cell,
        request.map_id,
        request.map_version,
        request.position)
    if not ok then
        skynet.error("battle_nav.query_cell panic: ", value)
        return result_error("INTERNAL_ERROR", "native query failed")
    end
    if not value then
        return result_error(err.code or "INTERNAL_ERROR", err.message)
    end

    return {
        result = RESULT.OK,
        message = "",
        map_id = request.map_id,
        map_version = request.map_version,
        grid_x = value.grid_x,
        grid_z = value.grid_z,
        cell_height_mm = value.cell_height_mm,
        area = value.area,
        clearance = value.clearance,
    }
end

return M
