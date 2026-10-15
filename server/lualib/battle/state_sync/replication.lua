--- 复制仅处理已提交的不可变状态；不驱动模拟、不编码网络字节。
local M = {}
local function equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if not equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end
local function difference(current, baseline)
    local old, changed, removed, present = {}, {}, {}, {}
    for _, v in ipairs(baseline) do
        old[v.instance_id] = v
    end
    for _, v in ipairs(current) do
        present[v.instance_id] = true
        if not equal(v, old[v.instance_id]) then
            changed[#changed + 1] = v
        end
    end
    for _, v in ipairs(baseline) do
        if not present[v.instance_id] then
            removed[#removed + 1] = v.instance_id
        end
    end
    return changed, removed
end
--- baseline为该客户端明确确认的完整快照；缺失时返回当前全量，不猜测增量。
function M.delta(current, baseline)
    if not baseline then
        return current
    end
    local v = {}
    for k, value in pairs(current) do
        v[k] = value
    end
    v.base_seq = baseline.snapshot_seq
    v.units, v.removed_units = difference(current.units, baseline.units)
    v.bolts, v.removed_bolts = difference(current.bolts, baseline.bolts)
    return v
end
return M
