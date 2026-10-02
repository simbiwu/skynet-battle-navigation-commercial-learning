---@meta

---@param service ServiceHandle 目标 Service handle。
---@param typename string Skynet 消息协议名，当前通常为"lua"。
---@param command string Service dispatch command。
---@param ... any command 的具名参数或 record。
---@return any ... call 对端 retpack 的结果；调用可能 yield。
function skynet.call(service, typename, command, ...) end

---@param service ServiceHandle 目标 Service handle。
---@param typename string Skynet 消息协议名，当前通常为"lua"。
---@param command string Service dispatch command。
---@param ... any command 的具名参数或 record。
---@return boolean|nil 是否接纳发送；不表示远端业务完成。
function skynet.send(service, typename, command, ...) end

---@param typename string 要注册的 Skynet 消息协议名。
---@param dispatch fun(session: integer, source: ServiceHandle, ...: any) 消息处理函数；参数来自协议 unpack。
function skynet.dispatch(typename, dispatch) end

---@param ... any 返回值 record；只能用于 call 请求对应的 dispatch。
function skynet.retpack(...) end

---@param func fun() 后台协程入口；可能调用 sleep/yield。
function skynet.fork(func) end

---@param ticks integer Skynet tick 数，当前基线为10ms/tick。
function skynet.sleep(ticks) end

---@return integer 当前 Service handle。
function skynet.self() end

---@return integer 当前高精度时间片/实例辅助值。
function skynet.hpc() end
