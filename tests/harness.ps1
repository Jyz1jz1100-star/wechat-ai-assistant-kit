# 极简断言计数器。PowerShell 5.1 兼容，不依赖 Pester。
#
# 用 $global: 而非 $script:：harness.ps1 是被点源（dot-source）进测试脚本的，
# 而定义在此的函数在运行时，$script: 会解析到「调用方脚本」的作用域而不是这里的
# $Harness hashtable，于是 $Harness.Passed++ 报「找不到属性 Passed」。
# 每个测试都是独立 powershell 进程，$global: 不会跨进程污染。
$global:QoderHarness = @{ Passed = 0; Failed = 0; Failures = @() }

function Get-TestResult { return $global:QoderHarness }

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    $h = $global:QoderHarness
    if ($Expected -eq $Actual) {
        $h.Passed = $h.Passed + 1
        Write-Host "  ok   $Label" -ForegroundColor DarkGreen
    } else {
        $h.Failed = $h.Failed + 1
        $h.Failures = $h.Failures + "$Label :: expected [$Expected] got [$Actual]"
        Write-Host "  FAIL $Label :: expected [$Expected] got [$Actual]" -ForegroundColor Red
    }
}

function Assert-True  { param($Actual, [string]$Label);  Assert-Equal $true  $Actual $Label }
function Assert-False { param($Actual, [string]$Label);  Assert-Equal $false $Actual $Label }

function Exit-TestSummary {
    $r = Get-TestResult
    Write-Host ""
    if ($r.Failed -eq 0) {
        Write-Host "PASS  $($r.Passed) checks" -ForegroundColor Green
        exit 0
    }
    Write-Host "FAIL  $($r.Failed) of $($r.Passed + $r.Failed) checks" -ForegroundColor Red
    foreach ($f in $r.Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
