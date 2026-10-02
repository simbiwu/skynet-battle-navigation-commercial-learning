-- 职责：把已经完成的 Battle result 以固定字段顺序写成可人工审查的 JSON Replay。
-- 边界：Server Debug/Replay Artifact；只在 battle_core.simulate 返回后执行 I/O。
-- 输入/输出：result table -> UTF-8 JSON 文件。
-- 生命周期：一次调用打开/关闭文件；不保存战斗状态。
-- 不负责：不参与权威结算，不在核心 simulate 内调用，不实现在线同步协议。
local M = {}

-- 把受控事件字符串编码为 JSON string；返回新字符串，不执行 I/O。
local function quote(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

-- 编码一个毫米制 WorldPosition；nil 编码为 JSON null。
local function position(p)
    if p == nil then return "null" end
    return string.format(
        '{"x_mm":%d,"y_mm":%d,"z_mm":%d}',
        p.x_mm, p.y_mm, p.z_mm)
end

-- 按数组顺序编码 Path 世界点；不使用 pairs，保证 artifact 字段顺序稳定。
local function points(value)
    local out = { "[" }
    for i, p in ipairs(value or {}) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = position(p)
    end
    out[#out + 1] = "]"
    return table.concat(out)
end

-- 以固定字段顺序编码一个权威事件；缺失的可选字段使用稳定默认值。
local function event(e)
    -- 字段顺序固定，缺失的可选字段写成 null/0，避免不同 Lua hash 顺序影响 artifact。
    return table.concat({
        "{",
        '"seq":', tostring(e.seq), ",",
        '"logic_ms":', tostring(e.logic_ms), ",",
        '"type":', quote(e.type), ",",
        '"unit_id":', tostring(e.unit_id or 0), ",",
        '"target_id":', tostring(e.target_id or 0), ",",
        '"attacker_id":', tostring(e.attacker_id or 0), ",",
        '"killer_id":', tostring(e.killer_id or 0), ",",
        '"damage":', tostring(e.damage or 0), ",",
        '"target_hp":', tostring(e.target_hp or 0), ",",
        '"speed_mm_per_sec":', tostring(e.speed_mm_per_sec or 0), ",",
        '"reason":', quote(e.reason or ""), ",",
        '"result":', quote(e.result or ""), ",",
        '"position":', position(e.position), ",",
        '"points":', points(e.points),
        "}"
    })
end

-- 编码完整 Battle result；返回 UTF-8 JSON 字符串，不读写文件。
function M.encode(result)
    local out = {
        "{",
        '"battle_id":', tostring(result.battle_id), ",",
        '"battle_version":', tostring(result.battle_version), ",",
        '"map_id":', tostring(result.map_id), ",",
        '"map_version":', tostring(result.map_version), ",",
        '"seed":', tostring(result.seed), ",",
        '"result":', quote(result.result), ",",
        '"end_logic_ms":', tostring(result.end_logic_ms), ",",
        '"events":[',
    }
    for i, e in ipairs(result.events) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = event(e)
    end
    out[#out + 1] = "]}"
    return table.concat(out)
end

-- 把 result 写到 path。成功返回 true；打开、写入或关闭失败返回 nil,error。
-- result 必须是已完成且结构合法的 Battle 结果；编码错误会抛出 Lua error。
-- 本函数执行同步文件 I/O，只能在 battle_core.simulate 已经返回以后调用。
function M.write(path, result)
    -- 数据准备：先完成编码，避免输入错误时留下空 Replay 文件。
    local json = M.encode(result)

    -- 持久化/消息发送：打开并写入 Replay 文件。
    local file, open_error = io.open(path, "wb")
    if file == nil then
        return nil, open_error
    end

    local ok, write_error = file:write(json, "\n")
    if ok == nil then
        file:close()
        return nil, write_error
    end

    -- 收尾：关闭文件并把关闭错误返回给调用方。
    local closed, close_error = file:close()
    if closed == nil then
        return nil, close_error
    end

    return true
end

return M
