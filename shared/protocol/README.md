# 共享协议合同

本目录是 Unity 与 Server 协议的唯一来源。navigation_query.proto 定义线协议，VERSIONS.env 固定生成器与 Runtime 依赖，generated/ 保存各运行端需要的可发布生成物。

## 命令解析规则

协议文件头必须保留下面这套规则，新增命令也必须遵守：

1. 每个业务命令只在 enum CommandId 中定义一次。枚举名使用全大写下划线，枚举值是稳定的 Envelope.command 数值。
2. 枚举名按 QUERY_CELL 转换为 QueryCell，生成器要求存在同名前缀的 QueryCellRequest。
3. 如果存在 QueryCellResponse，该命令是请求-响应命令；如果没有 Response 消息，该命令就是单向请求。
4. 单向命令只定义 XxxRequest，不定义 XxxResponse。Server 解码并投递请求，业务处理完成后不发送业务响应。
5. 协议不使用 service、rpc、自定义 option 或 command_id 注释。Python 生成器只解析 CommandId 和消息名。
6. Unity 使用 protoc 生成消息和 CommandId；Server 使用同一份 proto 生成 Lua registry。两端不得手写第二份命令映射。

Envelope 固定包含 `protocol_version`、`command`、`request_id` 和 `body`。`request_id` 是 uint64 关联编号：普通请求由客户端生成并由 Server 原样回显；`0` 保留给无请求关联的主动消息。`body` 使用字段号 4。Gateway 的连接身份与跨 Service 路由字段属于 Server 内部消息，不放入 Envelope。

## 生成与调用

从仓库根目录执行：

```bash
python3 server/third_party/skynet-flywow/scripts/generate_gateway_registry.py   --proto shared/protocol/navigation_query.proto   --output server/lualib/gateway/protocol/navigation_registry.lua
```

这个脚本只负责把 CommandId、XxxRequest 和可选的 XxxResponse 转成 Server Gateway 的运行时索引；它不会生成 protobuf 消息代码，也不会启动服务。Server 启动时由 flywow_gateway 加载生成的 registry，按 Envelope.command 查找请求类型并决定是否允许响应。

Server descriptor 和 Unity C# 生成仍按以下顺序执行：

1. 修改 navigation_query.proto，并在不兼容变更时同步提升协议版本；
2. 在 WSL 执行 server/protocol/build_server_descriptor.sh；
3. 在 Windows PowerShell 执行 shared/protocol/build_unity_cs.ps1；
4. 运行 Server descriptor 检查和 Unity 编译/测试；
5. 将协议源、两端生成物和校验文件放在同一次提交中。

Server 部署端只需要拉取或安装这个已验证提交，不应在启动时自行生成另一份 descriptor。Unity 生成代码是客户端编译输入，也不能手工修改。
