# FlyWow Gateway 客户端程序集

由 `unity/BattleNavigation/build_gateway_sdk.ps1` 调用 FlyWow 独立构建入口生成：

- `FlyWow.Gateway.dll`：框架的 P-256/HKDF/HMAC 握手 SDK。
- `BouncyCastle.Cryptography.dll`：固定版本 2.6.2，下载包 SHA256 由框架脚本验证。
- `BouncyCastle.LICENSE.md`：依赖包提供的原许可证。

DLL 是生成物，不维护 SDK 源码副本。构建方法及协议兼容要求见 `docs/FLYWOW_GATEWAY_HANDSHAKE.md`。
