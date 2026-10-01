# 职责：调用唯一FlyWow源码的SDK构建入口，将生成程序集安装到课程Unity工程。
# 边界：FrameworkRoot显式指定开发源码；默认使用固定submodule，不维护第二份SDK实现。
# 生命周期：构建产物存放.downloads和Plugins；不启动Unity或Server，不修改源码。
param([string]$FrameworkRoot = "")
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $FrameworkRoot)
{
    $FrameworkRoot = Join-Path $repoRoot 'server/third_party/skynet-flywow'
}
$builder = Join-Path $FrameworkRoot 'clients/unity/build.ps1'
if (-not (Test-Path -LiteralPath $builder))
{
    throw "缺少FlyWow SDK构建入口，请指定 -FrameworkRoot：$builder"
}
& $builder -BuildDirectory (Join-Path $repoRoot '.downloads/gateway-sdk') -OutputDirectory (Join-Path $PSScriptRoot 'Assets/BattleNavigation/Plugins/FlyWow')
