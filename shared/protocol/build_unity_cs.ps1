# 职责：从共享 navigation_query.proto 生成 Unity 编译使用的 C# 类型和稳定校验文件。
# 边界：离线 Build Script；读取 shared/protocol，写入 Unity 客户端生成代码与 shared 校验信息。
# 输入/输出：唯一协议源和固定 protoc -> NavigationQuery.cs 与其 SHA-256。
# 生命周期：协议源变更后由协议维护者显式执行；输出必须与协议源同一次提交。
# 不负责：不启动 Unity/Server、不修改 .meta、不从系统目录挑选任意 DLL。
param(
    [string]$Protoc = "",
    [string]$UnityOutput = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$versionsFile = Join-Path $PSScriptRoot "VERSIONS.env"
$protoFile = Join-Path $PSScriptRoot "navigation_query.proto"
$checksumDir = Join-Path $PSScriptRoot "generated/unity"

# 从 KEY=VALUE 版本清单读取一个必需值；缺失或重复语义由异常显式暴露。
function Get-PinnedVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $entry = Get-Content -LiteralPath $versionsFile -Encoding utf8 |
        Where-Object { $_ -match "^$([regex]::Escape($Name))=(.+)$" } |
        Select-Object -First 1
    if (-not $entry) {
        throw "版本清单缺少 $Name：$versionsFile"
    }
    return ($entry -split "=", 2)[1].Trim()
}

if ([string]::IsNullOrWhiteSpace($Protoc)) {
    $protocVersion = Get-PinnedVersion -Name "PROTOC_VERSION"
    $repositoryProtoc = Join-Path $repoRoot "server/third_party/protoc-$protocVersion/bin/protoc.exe"
    if (Test-Path -LiteralPath $repositoryProtoc -PathType Leaf) {
        $Protoc = $repositoryProtoc
    }
    else {
        $pathProtoc = Get-Command "protoc.exe" -ErrorAction SilentlyContinue
        if ($pathProtoc) {
            $Protoc = $pathProtoc.Source
        }
    }
}
if ([string]::IsNullOrWhiteSpace($UnityOutput)) {
    $UnityOutput = Join-Path $repoRoot "unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol"
}

if (-not (Test-Path -LiteralPath $Protoc -PathType Leaf)) {
    throw "找不到固定版本 protoc：$Protoc；可用 -Protoc 显式传入同版本可执行文件"
}
if (-not (Test-Path -LiteralPath $protoFile -PathType Leaf)) {
    throw "找不到共享协议源：$protoFile"
}

New-Item -ItemType Directory -Force -Path $UnityOutput | Out-Null
New-Item -ItemType Directory -Force -Path $checksumDir | Out-Null

$expectedProtocVersion = Get-PinnedVersion -Name "PROTOC_VERSION"
$actualProtocVersion = (& $Protoc --version).Trim()
if ($LASTEXITCODE -ne 0 -or $actualProtocVersion -ne "libprotoc $expectedProtocVersion") {
    throw "protoc 版本不匹配：expected=libprotoc $expectedProtocVersion actual=$actualProtocVersion"
}

& $Protoc `
    "--csharp_out=$UnityOutput" `
    "-I$PSScriptRoot" `
    $protoFile
if ($LASTEXITCODE -ne 0) {
    throw "protoc 生成 Unity C# 失败，退出码：$LASTEXITCODE"
}

$generatedFile = Join-Path $UnityOutput "NavigationQuery.cs"
if (-not (Test-Path -LiteralPath $generatedFile -PathType Leaf)) {
    throw "protoc 未生成预期文件：$generatedFile"
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $generatedFile).Hash.ToLowerInvariant()
$checksumFile = Join-Path $checksumDir "NavigationQuery.cs.sha256"
# 校验清单只记录文件名，保证不同机器和工作区得到相同文本。
[IO.File]::WriteAllText($checksumFile, "$hash  NavigationQuery.cs`n", [Text.UTF8Encoding]::new($false))
Write-Output "UNITY_PROTOBUF_CS_OK file=$generatedFile sha256=$hash"
