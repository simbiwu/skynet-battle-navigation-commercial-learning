# 职责：从 WSL 唯一 FlyWow 源构建离线 UPM 包，并接入指定 Windows Unity 工程。
# 边界：开发工具；只更新该工程 manifest 和显式产物目录，不启动 Editor 或发布版本。
# 输入：Linux 框架路径、WSL 发行版、Unity 工程；输出：内容标识归档及相对包依赖。
# 生命周期：一次性构建；失败立即停止，不下载依赖、不修改固定 submodule gitlink。
param(
    [Parameter(Mandatory = $true)][string]$FlyWowRoot,
    [string]$Distribution = 'Ubuntu',
    [string]$ProjectPath,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ([string]::IsNullOrWhiteSpace($ProjectPath))
{
    $ProjectPath = Join-Path $repositoryRoot 'unity/BattleNavigation'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory))
{
    $OutputDirectory = Join-Path $repositoryRoot '.tmp/navigation-packages'
}
$projectRoot = [IO.Path]::GetFullPath($ProjectPath)
$artifactRoot = [IO.Path]::GetFullPath($OutputDirectory)
$manifestPath = Join-Path $projectRoot 'Packages/manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf))
{
    throw "Unity manifest 不存在：$manifestPath"
}

# 显式参数直接交给 wsl.exe；不拼接 shell 命令，也不维护源码副本。
$linuxOutput = & wsl.exe --distribution $Distribution --exec wslpath -u $artifactRoot
if ($LASTEXITCODE -ne 0)
{
    throw '无法转换产物路径'
}
$linuxArtifact = & wsl.exe --distribution $Distribution --exec python3 "$FlyWowRoot/navigation/tools/package_unity.py" --output $linuxOutput
if ($LASTEXITCODE -ne 0)
{
    throw 'FlyWow Navigation 安装包构建失败'
}
$windowsArtifact = & wsl.exe --distribution $Distribution --exec wslpath -w $linuxArtifact
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $windowsArtifact -PathType Leaf))
{
    throw '安装包路径无效'
}

# UPM 的 file: 相对路径以 Packages 为起点；避免写入开发机绝对路径。
$packagesUri = [Uri]([IO.Path]::GetFullPath((Join-Path $projectRoot 'Packages')) + [IO.Path]::DirectorySeparatorChar)
$artifactUri = [Uri]([IO.Path]::GetFullPath($windowsArtifact))
if ($packagesUri.Scheme -ne $artifactUri.Scheme -or $packagesUri.Host -ne $artifactUri.Host)
{
    throw '工程与产物必须能形成同一文件系统中的相对路径'
}
$relative = [Uri]::UnescapeDataString($packagesUri.MakeRelativeUri($artifactUri).ToString())
if ([Uri]::IsWellFormedUriString($relative, [UriKind]::Absolute))
{
    throw '无法为 UPM 形成相对路径，请把产物放到工程所在磁盘'
}
# 使用框架工具以 UTF-8/LF、两空格 JSON 排版原子更新 manifest。
$linuxManifest = & wsl.exe --distribution $Distribution --exec wslpath -u $manifestPath
if ($LASTEXITCODE -ne 0)
{
    throw '无法转换 Unity manifest 路径'
}
$updatedArtifact = & wsl.exe --distribution $Distribution --exec python3 "$FlyWowRoot/navigation/tools/package_unity.py" --output $linuxOutput --manifest $linuxManifest
if ($LASTEXITCODE -ne 0)
{
    throw 'Unity manifest 更新失败'
}
Write-Output "FLYWOW_NAVIGATION_CONNECTED package=$windowsArtifact"
