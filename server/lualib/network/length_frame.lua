-- 职责：实现 4-byte Big Endian 长度头的打包与增量拆包。
-- 边界：Server Runtime Library；payload 对本模块是不透明 bytes。
-- 输入/输出：payload 或累计 buffer -> frame，或一个 payload + 剩余 buffer。
-- 生命周期：无状态模块；返回字符串均由调用协程持有。
-- 不负责：不解析 Protobuf、不访问 Socket、不执行业务查询。
local M = {}

-- 将 0..2^32-1 的整数编码成 4-byte Big Endian；越界时抛错。
local function u32be(value)
    assert(value >= 0 and value <= 0xffffffff, "uint32 length out of range")
    local b1 = math.floor(value / 0x1000000) % 0x100
    local b2 = math.floor(value / 0x10000) % 0x100
    local b3 = math.floor(value / 0x100) % 0x100
    local b4 = value % 0x100
    return string.char(b1, b2, b3, b4)
end

-- 从至少 4 bytes 的字符串读取 Big Endian uint32；调用方保证输入长度。
local function read_u32be(bytes)
    local a, b, c, d = bytes:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- 给 payload 添加长度头；超过 max_frame_bytes 时抛错，避免无界发送。
function M.pack(payload, max_frame_bytes)
    assert(#payload <= max_frame_bytes, "frame too large")
    return u32be(#payload) .. payload
end

-- 从累计 buffer 拆出至多一个 frame。
-- 成功返回 payload,rest；半包返回 nil,原 buffer；坏长度返回 false,message。
function M.unpack(buffer, max_frame_bytes)
    if #buffer < 4 then
        return nil, buffer
    end
    local payload_size = read_u32be(buffer:sub(1, 4)) -- 当前帧 payload byte 数。
    if payload_size > max_frame_bytes then
        return false, "frame too large"
    end
    if #buffer < 4 + payload_size then
        return nil, buffer
    end
    return buffer:sub(5, 4 + payload_size), buffer:sub(5 + payload_size)
end

return M
