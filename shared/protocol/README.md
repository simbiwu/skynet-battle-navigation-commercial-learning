# 共享协议合同

本目录是 Unity 与 Server 协议的唯一来源。`navigation_query.proto` 定义线协议，`VERSIONS.env` 固定生成器与 Runtime 依赖，`generated/` 保存各运行端需要的可发布生成物。

更新顺序：

1. 修改 `navigation_query.proto`，并在不兼容变更时同步提升协议版本；
2. 在 WSL 执行 `server/protocol/build_server_descriptor.sh`；
3. 在 Windows PowerShell 执行 `shared/protocol/build_unity_cs.ps1`；
4. 运行 Server descriptor 检查和 Unity 编译/测试；
5. 将协议源、两端生成物和校验文件放在同一次提交中。

Server 部署端只需要拉取或安装这个已验证提交，不应在启动时自行生成另一份 descriptor。Unity 生成代码是客户端编译输入，也不能手工修改。
