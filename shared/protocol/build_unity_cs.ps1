# 职责：按共享传输信封和课程独立 schema 生成 Unity C# 类型及 SHA-256 校验文件。
# 边界：Windows Unity 生成入口；读取 shared/protocol，写入 Unity 协议源码目录和 generated/unity。
# 输入：wire_header.proto，以及 Lesson 1、Lesson 2、Lesson 3 帧同步/状态同步各自的一份业务 schema。
# 输出：Protocol/Shared、Protocol/Lesson01、Protocol/Lesson02、Protocol/Lesson03FrameSync、
#       Protocol/Lesson03StateSync 下的 C# 文件；generated/unity 下的相对路径 hash 文件。
# 调用：在 Windows PowerShell 执行 .\\shared\\protocol\\build_unity_cs.ps1；
#       可用 -Protoc 指定固定版本 protoc.exe，用 -UnityOutput 指定 Scripts/Protocol 输出目录。
# 生命周期：任一协议源变化后运行；Unity Editor 自行维护新文件 .meta，不在此脚本手写/删除 .meta。
# 失败语义：protoc 缺失、版本不符、任一输出缺失或 hash 失败都会中止，避免误报生成成功。
# 维护说明：新增/移除课程只修改下面 $protocolInputs 清单；生成、校验和旧文件清理由统一算法处理。
# 不负责：不启动 Unity/Server，不生成 Server descriptor，不同步 Windows 与 WSL 工作区。
param(
    [string]$Protoc = "",
    [string]$UnityOutput = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$versionsFile = Join-Path $PSScriptRoot "VERSIONS.env"
$checksumRoot = Join-Path $PSScriptRoot "generated/unity"

# 课程输入白名单：每条只包含一份 schema，避免同名 Navigation.cs 输出互相覆盖。
# Header 单独生成；四个业务 schema 均保有自己的 protobuf namespace。
$protocolInputs = @(
    @{ Proto = "wire_header.proto"; OutputDirectory = "Shared"; ExpectedFile = "WireHeader.cs" },
    @{ Proto = "lesson_01/navigation.proto"; OutputDirectory = "Lesson01"; ExpectedFile = "Navigation.cs" },
    @{ Proto = "lesson_02/navigation.proto"; OutputDirectory = "Lesson02"; ExpectedFile = "Navigation.cs" },
    @{ Proto = "lesson_03/frame_sync.proto"; OutputDirectory = "Lesson03FrameSync"; ExpectedFile = "FrameSync.cs" },
    @{ Proto = "lesson_03/state_sync.proto"; OutputDirectory = "Lesson03StateSync"; ExpectedFile = "StateSync.cs" }
)

# 从版本清单读取固定工具版本；除显式参数外优先使用仓库内置 protoc。
function Get-PinnedVersion {
    param([Parameter(Mandatory = $true)][string]$Name)
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
foreach ($entry in $protocolInputs) {
    $protoPath = Join-Path $PSScriptRoot $entry.Proto
    if (-not (Test-Path -LiteralPath $protoPath -PathType Leaf)) {
        throw "找不到课程协议源：$protoPath"
    }
}

$expectedProtocVersion = Get-PinnedVersion -Name "PROTOC_VERSION"
$actualProtocVersion = (& $Protoc --version).Trim()
if ($LASTEXITCODE -ne 0 -or $actualProtocVersion -ne "libprotoc $expectedProtocVersion") {
    throw "protoc 版本不匹配：expected=libprotoc $expectedProtocVersion actual=$actualProtocVersion"
}

# 先确保输出根目录存在；每个课程输出到独立子目录，防止同 basename 覆盖。
New-Item -ItemType Directory -Force -Path $UnityOutput | Out-Null
New-Item -ItemType Directory -Force -Path $checksumRoot | Out-Null
foreach ($entry in $protocolInputs) {
    $protoPath = Join-Path $PSScriptRoot $entry.Proto
    $relativeOutput = $entry.OutputDirectory
    $targetDirectory = Join-Path $UnityOutput $relativeOutput
    $checksumDirectory = Join-Path $checksumRoot $relativeOutput
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $checksumDirectory | Out-Null

    # 每个 protoc 调用只接收一份 schema，输入路径相对协议根，保留课程层次。
    & $Protoc "-I$PSScriptRoot" "--csharp_out=$targetDirectory" $protoPath
    if ($LASTEXITCODE -ne 0) {
        throw "protoc 生成失败：$protoPath，退出码：$LASTEXITCODE"
    }

    $generatedFile = Join-Path $targetDirectory $entry.ExpectedFile
    if (-not (Test-Path -LiteralPath $generatedFile -PathType Leaf)) {
        throw "protoc 未生成预期文件：$generatedFile"
    }

    # sidecar 路径与 C# 相对路径相同，审计时可直接对应所属课程。
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $generatedFile).Hash.ToLowerInvariant()
    $checksumFile = Join-Path $checksumDirectory "$($entry.ExpectedFile).sha256"
    $checksumText = "$hash  $($entry.ExpectedFile)" + [char]10
    [IO.File]::WriteAllText($checksumFile, $checksumText, [Text.UTF8Encoding]::new($false))
}

# 旧版单体输出属于生成物；只删除根目录旧 .cs，不触碰 Unity Editor 管理的 .meta。
foreach ($legacyName in @("NavigationQuery.cs", "Common.cs", "Navigation.cs", "FrameSync.cs", "StateSync.cs")) {
    $legacyFile = Join-Path $UnityOutput $legacyName
    if (Test-Path -LiteralPath $legacyFile -PathType Leaf) {
        Remove-Item -LiteralPath $legacyFile
    }
    $legacyChecksum = Join-Path $checksumRoot "$legacyName.sha256"
    if (Test-Path -LiteralPath $legacyChecksum -PathType Leaf) {
        Remove-Item -LiteralPath $legacyChecksum
    }
}
$published = $protocolInputs | ForEach-Object { "$($_.OutputDirectory)/$($_.ExpectedFile)" }
Write-Output "UNITY_PROTOBUF_CS_OK files=$($published -join ',')"
