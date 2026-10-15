--- Frame/State共用的短期Battle凭据；不依赖Gateway、账号或网络。
--- 凭据在Battle存活期间保持稳定，避免恢复回包丢失后客户端失去唯一凭据。
local M = {}
--- 创建32字节随机凭据；同步文件I/O，无Skynet yield；失败抛错，由组装层收敛。
---@return string 仅交给授权客户端；不得写入Replay或日志。
function M.create()
    local file = assert(io.open("/dev/urandom", "rb"))
    local bytes = file:read(32)
    file:close()
    assert(bytes and #bytes == 32, "TOKEN_IO")
    return bytes
end
--- 对合法长度凭据逐字节累计比较，不在秘密内容首个差异处提前退出。
---@param a string|nil 请求提供的字节。
---@param b string|nil Battle持有的字节；只读、不I/O、不yield。
---@return boolean 是否为同一凭据。
function M.equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= 32 or #b ~= 32 then
        return false
    end
    local diff = 0
    for i = 1, 32 do
        diff = diff | (a:byte(i) ~ b:byte(i))
    end
    return diff == 0
end
return M
