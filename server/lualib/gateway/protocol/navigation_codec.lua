-- 职责：保留旧导航 Protobuf codec 实现，供历史实现对照；当前运行链不加载它。
-- 边界：Gateway 专属遗留 Lua 模块；只处理 Protobuf bytes，不处理 TCP framing。
-- 输入/输出：Lua table <-> Protobuf bytes。
-- 生命周期：当前 Gateway Runtime 不 require；历史代码按需在当前 Lua State 加载 descriptor。
-- 不负责：不打开 Socket、不调用地图、不吞掉解码错误。
local pb = require "pb"

local M = {}
M.ENVELOPE = ".battle.navigation.v1.Envelope"
M.REQUEST = ".battle.navigation.v1.QueryCellRequest"
M.RESPONSE = ".battle.navigation.v1.QueryCellResponse"

-- 从 path 读取并注册当前 Lua State 的 descriptor。
-- path 相对 Server 工作目录；文件 I/O 或格式错误直接抛错并阻止 Service 就绪。
function M.load_descriptor(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a") -- 当前 descriptor 的完整 bytes，由本次调用临时持有。
    file:close()
    assert(pb.load(bytes), "cannot load protobuf descriptor: " .. path)
end

-- 将 Envelope 元数据和已编码 body 组合成 bytes；参数均归调用方，返回新字符串。
function M.encode_envelope(command, body, version)
    return assert(pb.encode(M.ENVELOPE, {
        protocol_version = version,
        command = command,
        body = body,
    }))
end

-- 解码一个完整 Envelope；malformed bytes 抛错，由 Gateway 的 pcall 隔离连接错误。
function M.decode_envelope(bytes)
    return assert(pb.decode(M.ENVELOPE, bytes))
end

-- 解码 QueryCellRequest body；失败抛错，不返回半成品 table。
function M.decode_query_request(bytes)
    return assert(pb.decode(M.REQUEST, bytes))
end

-- 编码已经完成业务校验的 QueryCellResponse；返回新 bytes 字符串。
function M.encode_query_response(value)
    return assert(pb.encode(M.RESPONSE, value))
end

return M
