param([switch]$NoRun)

$script:DoctorRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:DoctorRoot 'scripts\lib\checks.ps1')

function Invoke-Doctor {
    # IDictionary 而非 [hashtable]：调用方常传 [ordered]@{}，那是 OrderedDictionary，
    # 声明成 [hashtable] 会在参数绑定阶段直接报错。
    param([System.Collections.IDictionary]$Checks)

    $results = @()
    foreach ($name in $Checks.Keys) { $results += & $Checks[$name] }

    # 固定展示顺序：先环境后账号后内容 —— 用户按这个顺序修最省事，
    # 而不是按调用方的插入顺序（hashtable 的顺序本来就不保证）。
    $order = @('Node.js', 'OpenClaw', '微信通道插件', 'Bot 授权凭据', '网关在运行',
               '微信通道已连', '出网连通', '模型密钥', '人设文件')
    $known = @()
    $rest = @()
    foreach ($r in $results) {
        if ($order -contains $r.Name) { $known += $r } else { $rest += $r }
    }
    $known = @($known | Sort-Object { $order.IndexOf($_.Name) })
    # 未知名字的按名字排，保证结果确定；否则测试与终端输出都会偶发漂移
    $rest = @($rest | Sort-Object Name)
    $sorted = @($known) + @($rest)

    $failed = @($sorted | Where-Object { -not $_.Ok })
    $firstFix = ''
    if ($failed.Count -gt 0) { $firstFix = $failed[0].Fix }
    return [PSCustomObject]@{ Results = $sorted; Failed = $failed.Count; FirstFix = $firstFix }
}

if ($NoRun) { return }   # 测试用：只定义函数，不执行体检

# 控制台默认代码页是 GBK，不设 UTF-8 的话中文体检结论全是乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$map = [ordered]@{
    node       = { Check-NodeVersion }
    openclaw   = { Check-OpenClawInstalled }
    plugin     = { Check-PluginEnabled }
    credential = { Check-BotCredential }
    gateway    = { Check-GatewayRunning }
    channel    = { Check-ChannelConnected }
    egress     = { Check-NetworkEgress }
    apikey     = { Check-ApiKeyUsable }
    workspace  = { Check-WorkspaceFiles }
}

Write-Host "微信助手体检  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
$agg = Invoke-Doctor -Checks $map
foreach ($r in $agg.Results) {
    if ($r.Ok) { Write-Host ("  [OK]   {0,-14} {1}" -f $r.Name, $r.Detail) -ForegroundColor Green }
    else       { Write-Host ("  [FAIL] {0,-14} {1}" -f $r.Name, $r.Detail) -ForegroundColor Red }
}
Write-Host ""
if ($agg.Failed -eq 0) {
    Write-Host "全部通过。用手机微信给 Bot 发一句「你好」试试。" -ForegroundColor Green
    exit 0
}
Write-Host "$($agg.Failed) 项失败。先修这一项：" -ForegroundColor Yellow
Write-Host "  $($agg.FirstFix)" -ForegroundColor Yellow
Write-Host "修完再跑一次本脚本。" -ForegroundColor Yellow
exit 1
