$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\harness.ps1"
. "$PSScriptRoot\..\scripts\lib\checks.ps1"
. "$PSScriptRoot\..\scripts\doctor.ps1" -NoRun

function Fake-Result { param($N, $Ok) [PSCustomObject]@{ Name = $N; Ok = $Ok; Detail = 'd'; Fix = "fix-$N" } }

# 未知顺序名的检查必须按名字排序后再追加，否则 hashtable 的枚举顺序不保证，
# 下面 Results[0] 与 FirstFix 的断言会变成偶发通过、偶发失败的假测试。
$cases = [ordered]@{
  A = { Fake-Result 'A' $true }
  B = { Fake-Result 'B' $false }
  C = { Fake-Result 'C' $false }
}
$agg = Invoke-Doctor -Checks $cases
Assert-Equal 3 $agg.Results.Count  'aggregates every check'
Assert-Equal 2 $agg.Failed         'counts failures'
Assert-Equal 'fix-B' $agg.FirstFix 'first failing fix wins, not the last'
Assert-True $agg.Results[0].Ok     'deterministic order: A sorts before B and C'

$allOk = Invoke-Doctor -Checks ([ordered]@{ X = { Fake-Result 'X' $true } })
Assert-Equal 0 $allOk.Failed       'all-pass reports zero failures'
Assert-Equal '' $allOk.FirstFix    'all-pass has no fix to print'

# 已知的七个检查名必须按预设的运维顺序排前面（先环境后账号，用户按此顺序修最省事）
$known = [ordered]@{
  late  = { Fake-Result '人设文件' $true }
  early = { Fake-Result 'Node.js' $false }
}
$k = Invoke-Doctor -Checks $known
Assert-Equal 'Node.js' $k.Results[0].Name 'known check names are ordered, not insertion order'
Assert-Equal '人设文件' $k.Results[1].Name 'second known name keeps its slot'

# hashtable（非 ordered）也必须能用：调用方两种都可能传
$h = @{ one = { Fake-Result 'Node.js' $true } }
Assert-Equal 0 (Invoke-Doctor -Checks $h).Failed 'plain hashtable works too'
Exit-TestSummary
