# 跑全部测试。
#
# 为什么要有这个包装：Git Bash 下 `powershell -File tests\x.ps1` 的反斜杠会被
# 当成转义吃掉，路径直接错；而控制台默认代码页是 GBK，中文输出全是乱码。
# 两个坑都在这里一次性挡掉。
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$files = @(Get-ChildItem -Path (Join-Path $Root 'tests') -Filter 'test-*.ps1' -File |
           Sort-Object Name)
if ($files.Count -eq 0) { Write-Host 'tests/ 下没有 test-*.ps1' -ForegroundColor Yellow; exit 1 }

$failed = @()
foreach ($f in $files) {
    Write-Host ""
    Write-Host "=== $($f.Name) ===" -ForegroundColor Cyan
    # 用 & 调用而非 -File，避开反斜杠路径被 shell 吞掉的问题
    & $f.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $f.Name }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "全部测试通过（$($files.Count) 个文件）" -ForegroundColor Green
    exit 0
}
Write-Host "失败 $($failed.Count)/$($files.Count)：$($failed -join ', ')" -ForegroundColor Red
exit 1
