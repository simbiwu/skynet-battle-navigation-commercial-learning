-- 职责：校验 QueryCell 业务请求并同步调用 Native 静态地图查询。
-- 边界：Server Runtime Library；只由 navigation_query Service 持有和调用。
-- 输入/输出：QueryCellRequest table -> 新的 QueryCellResponse table。
-- 生命周期：game config 在 start 时保存一次；响应归当前消息协程所有。
-- 不负责：不处理 TCP、不执行跨 Service call、不做寻路、不保存动态单位。
local skynet = require "skynet"
local battle_nav = require "battle_nav"

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

-- 加载并核对唯一静态 BMAP；options 是当前 Service 的只读 game config。
-- 本函数执行一次文件 I/O 和 Native 分配；失败抛错阻止 Service 对外就绪。
function M.start(options)
    assert(config == nil, "navigation query logic already started")
    config = assert(options)
    local loaded, err = battle_nav.load_map(config.map.bmap)
    assert(loaded, err and (err.code .. ": " .. err.message) or "load_map failed")
    assert(loaded.map_id == config.map.id, "BMAP map_id does not match config")
    assert(loaded.map_version == config.map.version,
           "BMAP map_version does not match config")
end

-- 校验地图身份与 WorldPosition(mm)，随后同步查询 immutable GridMap。
-- 本函数不 yield、不执行文件 I/O、不修改共享地图；Native 异常收敛为响应错误。
function M.query(request)
    if type(request) ~= "table" or type(request.map_id) ~= "number" or
       type(request.map_version) ~= "number" or
       type(request.position) ~= "table" then
        return result_error("BAD_REQUEST", "missing map identity or position")
    end
    if request.map_id ~= config.map.id then
        return result_error("MAP_NOT_FOUND", "map is not loaded")
    end
    if request.map_version ~= config.map.version then
        return result_error("MAP_VERSION_MISMATCH", "map version mismatch")
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
