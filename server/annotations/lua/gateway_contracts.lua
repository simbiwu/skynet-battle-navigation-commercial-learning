---@meta

---@alias ServiceHandle integer
---@alias GatewayTransport "tcp"|"websocket"
---@alias GatewayCommand "QueryCell"|"RunAutoBattle"

---@class GatewayDispatch
---@field gateway_epoch string Gateway 实例身份；由 Gateway 生成，响应时原样带回。
---@field connection_id integer 逻辑连接编号；不是 fd，不能用于 Socket I/O。
---@field peer string 对端地址；只用于诊断和业务上下文。
---@field transport GatewayTransport 当前客户端传输类型。
---@field request_id integer 客户端请求编号；主动推送可使用0。
---@field command_id integer 生成 registry 中的 command id。
---@field command GatewayCommand 生成 registry 中的 command 名称。
---@field request table 已解码的业务请求；当前接收 Service 拥有。
---@field route_token string|nil Proxy 跨 Cluster 关联 token；仅由 Proxy 注入。

---@class GatewayDisconnect
---@field gateway_epoch string Gateway 实例身份。
---@field connection_id integer 逻辑连接编号。

---@class GatewayResponseMessage
---@field gateway_epoch string 必须匹配当前 Gateway 实例。
---@field connection_id integer 必须匹配仍存活的连接。
---@field command_id integer 使用 registry 的 response_type 编码。
---@field request_id integer 原请求编号；0表示已登记的主动推送。
---@field response table 业务 response record；由业务调用方拥有。

---@class GatewayProxyStart
---@field remote_node string Battle Cluster 节点名。
---@field remote_address string Battle Cluster 地址。

---@class GatewayBindOptions
---@field gateway_service ServiceHandle 当前 Gateway Service handle。

---@class BattleDispatchHandles
---@field query_service ServiceHandle Query Service handle。
---@field battle_mgr ServiceHandle BattleMgr Service handle。

---@class RunAutoBattleRequest
---@field scenario_id integer Server 允许的场景编号。

---@class BattleResultRecord
---@field ok boolean 是否形成可回推结果。
---@field response table|nil 成功时的协议 response record。
---@field error table|nil 失败时的稳定错误 record。
