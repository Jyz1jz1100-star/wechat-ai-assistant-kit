# 编码守卫：防止 .ps1 被重新存成 UTF-8 无 BOM。
#
# 为什么需要这个测试：PowerShell 5.1 在读取无 BOM 的 .ps1 时按 ANSI(GBK) 解码，
# 中文注释的字节序列会吞掉紧随其后的代码行 —— 语法不报错，功能静默消失。
# 这个 bug 曾被 $global:QoderHarness 未创建才暴露出来。任何编辑器重存都可能复现，
# 所以把它做成测试而不是靠人记。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\harness.ps1"

$Root = Split-Path -Parent $PSScriptRoot
$Bom = @(0xEF, 0xBB, 0xBF)

$ps1 = @(Get-ChildItem -Path $Root -Filter '*.ps1' -Recurse -File |
         Where-Object { $_.FullName -notmatch '\\node_modules\\' })
Assert-True ($ps1.Count -ge 1) '至少找到一个 .ps1 可供检查'

foreach ($f in $ps1) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq $Bom[0] -and $b[1] -eq $Bom[1] -and $b[2] -eq $Bom[2])
    Assert-True $hasBom ("$($f.Name) 是 UTF-8 with BOM")
}

# .env 必须无 BOM：BOM 会把第一行的键名变成 <BOM>KEY，静默读不到
. (Join-Path $Root 'scripts\secrets.ps1')
$Env = Get-OpenClawEnvPath
if (Test-Path $Env) {
    $b = [System.IO.File]::ReadAllBytes($Env)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq $Bom[0] -and $b[1] -eq $Bom[1] -and $b[2] -eq $Bom[2])
    Assert-False $hasBom '.env 必须无 BOM（否则第一个键名被污染）'
}

Exit-TestSummary
