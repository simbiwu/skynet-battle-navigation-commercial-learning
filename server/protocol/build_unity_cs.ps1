# 职责：把 navigation_query.proto 生成 Unity 编译所需的 C# 类型。
# 边界：离线 Build Script；不修改协议，不运行 Unity。
# 输入/输出：协议源文件 -> Unity Generated 目录中的 C# 文件。
param(
    [string]$Protoc = "protoc.exe",
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$UnityGenerated = "Assets/Generated/Protocol"
)

$ErrorActionPreference = "Stop"
$protoDir = Join-Path $Root "protocol"
$outDir = Join-Path $Root $UnityGenerated
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
& $Protoc `
  "--csharp_out=$outDir" `
  "-I$protoDir" `
  (Join-Path $protoDir "navigation_query.proto")
if ($LASTEXITCODE -ne 0) { throw "protoc failed: $LASTEXITCODE" }
Write-Output "UNITY_PROTOBUF_CS_OK $outDir"
