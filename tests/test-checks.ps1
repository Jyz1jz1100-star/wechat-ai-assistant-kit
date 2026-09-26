$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\harness.ps1"
. "$PSScriptRoot\..\scripts\secrets.ps1"
. "$PSScriptRoot\..\scripts\lib\checks.ps1"

# ---- Compare-Version：不能按字符串比（字符串序里 '22.9' > '22.13' 会判错）----
Assert-Equal -1 (Compare-Version -Left '22.12.0' -Right '22.13.0') '22.12 < 22.13'
Assert-Equal -1 (Compare-Version -Left '22.9.0'  -Right '22.13.0') 'numeric not lexicographic'
Assert-Equal  0 (Compare-Version -Left '22.13.0' -Right '22.13.0') 'equal'
Assert-Equal  1 (Compare-Version -Left 'v24.19.0' -Right '22.13.0') 'v prefix stripped'
Assert-Equal -1 (Compare-Version -Left 'abc' -Right '22.13.0') 'garbage sorts low and does not throw'

# ---- 让 Check-ApiKeyUsable 与真实 .env 无关，否则开发者机器上有 key 时会发真网络请求 ----
$global:TestEnvPath = Join-Path $PSScriptRoot 'definitely-absent.env'
function Get-EnvPathOverride { return $global:TestEnvPath }

# ---- 用假的外部命令驱动 Check-* ----
# 封装的参数名一律用 -CmdArgs。PowerShell 的 $Args 是自动变量，
# 把参数命名成 Args 会与它冲突，注入的假函数永远收不到参数。
$script:Fake = @{}
function Invoke-ExternalOverride {
    param([string]$File, [string[]]$CmdArgs = @())
    $key = "$File " + ($CmdArgs -join ' ')
    if ($script:Fake.ContainsKey($key)) { return $script:Fake[$key] }
    # curl 的参数串很长且易变，允许只按 URL 后缀注册假值
    foreach ($k in $script:Fake.Keys) {
        if ($k -ne '' -and $key.EndsWith($k)) { return $script:Fake[$k] }
    }
    return @{ ExitCode = 127; Out = ''; Err = "unfaked: $key" }
}
function Set-Fake { param($Key, $ExitCode, $Out)
    $script:Fake[$Key] = @{ ExitCode = $ExitCode; Out = $Out; Err = '' } }

# Node：floor 必须是 22.13.0（spec 逐字）
Set-Fake 'node --version' 0 'v22.13.0'
Assert-True (Check-NodeVersion).Ok 'node 22.13.0 passes'
Set-Fake 'node --version' 0 'v22.12.9'
$c = Check-NodeVersion
Assert-False $c.Ok 'node 22.12.9 fails'
Assert-True ($c.Fix -match '22\.13') 'failure names the required floor'
Set-Fake 'node --version' 1 ''
Assert-False (Check-NodeVersion).Ok 'missing node fails'

# OpenClaw：runtime 下限 2026.3.22
Set-Fake 'openclaw --version' 0 '2026.9.6'
Assert-True (Check-OpenClawInstalled).Ok 'openclaw 2026.9.6 passes'
Set-Fake 'openclaw --version' 0 '2026.3.21'
Assert-False (Check-OpenClawInstalled).Ok 'openclaw below runtime floor fails'
Set-Fake 'openclaw --version' 1 ''
Assert-False (Check-OpenClawInstalled).Ok 'openclaw absent fails'

# 插件启用：config get 返回 true 才算启用
Set-Fake 'openclaw config get plugins.entries.openclaw-weixin.enabled' 0 'true'
Assert-True (Check-PluginEnabled).Ok 'plugin enabled'
Set-Fake 'openclaw config get plugins.entries.openclaw-weixin.enabled' 0 'false'
Assert-False (Check-PluginEnabled).Ok 'plugin disabled fails'
Set-Fake 'openclaw config get plugins.entries.openclaw-weixin.enabled' 1 ''
Assert-False (Check-PluginEnabled).Ok 'plugin config unreadable fails'

# 通道：status --probe 里出现 OK 才算连上
# 通道：probe 里 weixin 行出现 running/connected 才算连上
Set-Fake 'openclaw channels status --probe' 0 '- openclaw-weixin deadbeef1234-im-bot: enabled, configured, running, in:1m ago'
Assert-True (Check-ChannelConnected).Ok 'running counts as connected'
Set-Fake 'openclaw channels status --probe' 0 '- openclaw-weixin default: connected'
Assert-True (Check-ChannelConnected).Ok 'connected wording counts as ok'
# 回归用（实测 doctor 真遇到过的形态）：别的通道说 OK、或 gateway 告警里带 OK
# 字样，都不能让本通道被误判为已连接；Detail 也必须只留 weixin 那一行。
Set-Fake 'openclaw channels status --probe' 0 "telegram OK connected`ngateway auth OK`n- openclaw-weixin default: enabled, configured"
$c = Check-ChannelConnected
Assert-False $c.Ok "another channel's OK must not be read as weixin connected"
Assert-True ($c.Detail -match 'openclaw-weixin') 'detail stays on the weixin line instead of the whole blob'

# ---- 最重要的一条回归：用户已经扫过码、但网关没装 ----
# 实测事故：这时 probe 只会输出 config-only，旧实现一律给出"去扫码"，
# 让一个早已完成的人反复扫同一个码。诊断必须指向网关，而不是扫码。
Set-Fake 'openclaw channels status --probe' 0 ("gateway channels.status requires credentials before opening a websocket`n" +
                                              "Gateway auth unavailable; showing config-only status.`n" +
                                              '- openclaw-weixin default: enabled, configured')
Set-Fake 'openclaw health' 0 'Gateway is not running'
$global:BotDirWithCred = Join-Path $PSScriptRoot 'fixture-accounts'
New-Item -ItemType Directory -Force -Path $global:BotDirWithCred | Out-Null
[System.IO.File]::WriteAllText((Join-Path $global:BotDirWithCred 'abc-im-bot.json'), '{}')
function Get-BotAccountDirOverride { return $global:BotDirWithCred }

$c = Check-ChannelConnected
Assert-False $c.Ok 'config-only probe output is not evidence of a live channel'
# 守的是"给出的修法"，不是措辞 —— Detail 里那句「不是没扫码」本身就是否定说明，
# 用 -notmatch '扫码' 去禁它会把正确的解释一起禁掉。
Assert-True ($c.Fix -notmatch 'channels login') 'fix must not send an already-scanned user to scan again'
Assert-True ($c.Fix -match 'gateway') 'fix points at the gateway'
Assert-True ($c.Detail -match '不是没扫码') 'detail says explicitly that this is not a scan problem'

# ---- 凭据与网关两个独立证据 ----
Assert-True (Check-BotCredential).Ok 'credential file on disk is detected'
$c = Check-GatewayRunning
Assert-False $c.Ok 'gateway not running fails'
Assert-True ($c.Fix -match 'gateway install') 'fix says install, because restart on a missing service is a silent no-op'
Set-Fake 'openclaw health' 0 'Gateway event loop: ok max=33ms'
Assert-True (Check-GatewayRunning).Ok 'event loop line means the gateway is live'
Set-Fake 'openclaw health' 0 'Gateway is still starting (phase: waiting for Gateway listener).'
$c = Check-GatewayRunning
Assert-False $c.Ok 'still-starting is reported as not ready yet'
Assert-True ($c.Detail -match '启动中') 'and told the user in plain words to wait'
Remove-Item $global:BotDirWithCred -Recurse -Force
function Get-BotAccountDirOverride { return (Join-Path $PSScriptRoot 'definitely-absent-accounts') }
$c = Check-BotCredential
Assert-False $c.Ok 'no credential file fails'
Assert-True ($c.Fix -match 'channels login') 'missing credential does point at scanning'

# 出网：任何 HTTP 响应码（含 401/403）都算链路通；只有空/000 才是网络问题
Set-Fake 'https://ilinkai.weixin.qq.com/'                0 '200'
# 体检不再写死服务商，测试必须自己注入端点，否则取决于仓库 patch.json 的内容
function Get-ModelEndpointOverride {
    return @{ Base = 'https://api.example.test/v1'; Models = 'https://api.example.test/v1/models'; Key = 'myprovider'; ApiKeyVar = 'ASSISTANT_API_KEY' }
}

Set-Fake 'https://api.example.test/v1/models' 0 '401'
Assert-True (Check-NetworkEgress).Ok 'egress passes when both hosts answer any HTTP code'
Set-Fake 'https://ilinkai.weixin.qq.com/'                0 '000'
$c = Check-NetworkEgress
Assert-False $c.Ok 'egress fails when a host gives no HTTP code'
Assert-True ($c.Fix.Length -gt 0) 'egress failure names a fix'
Set-Fake 'https://ilinkai.weixin.qq.com/'                0 '200'

# 密钥：先验缺失，再验存在时的不同返回码
Assert-False (Check-ApiKeyUsable).Ok 'no ASSISTANT_API_KEY fails'
$global:TestEnvPath = Join-Path $PSScriptRoot 'fixture-with-key.env'
[void](Set-Secret -Name 'ASSISTANT_API_KEY' -Value 'fake-key-for-tests-only')
Set-Fake 'https://api.example.test/v1/models' 0 '200'
Assert-True (Check-ApiKeyUsable).Ok 'key present + 200 passes'
Set-Fake 'https://api.example.test/v1/models' 0 '401'
$c = Check-ApiKeyUsable
Assert-False $c.Ok 'key present + 401 fails'
Assert-True ($c.Detail -notmatch 'fake-key-for-tests-only') 'failure detail never echoes the key'
Remove-Item $global:TestEnvPath -Force
$global:TestEnvPath = Join-Path $PSScriptRoot 'definitely-absent.env'

# 工作区：三个提示词文件必须都在
# 三件套已写入，此处由红转绿。负向路径仍被上面的通用断言覆盖
# （任意 Check 失败时必须给出可行动的 Fix）。
$c = Check-WorkspaceFiles
Assert-True $c.Ok 'SOUL/USER/AGENTS present'
Assert-True ($c.Detail -match 'workspace') 'detail names the workspace dir'

# 命令"不存在"与命令"执行失败"是两回事：`& $File` 遇到不存在的命令是抛异常，
# 早期实现把它当非零退出码处理，于是 doctor 把「OpenClaw 没装」报成
# 「当前版本 低于 2026.3.22」—— 错误诊断会让人往错方向修很久。
function Set-FakeMissing { param($Key)
    $script:Fake[$Key] = @{ ExitCode = 127; Out = ''; Err = '找不到命令'; Missing = $true } }

Set-FakeMissing 'openclaw --version'
$c = Check-OpenClawInstalled
Assert-False $c.Ok 'openclaw not installed fails'
Assert-True  ($c.Detail -match '没装') 'reports as not installed'
Assert-False ($c.Detail -match '2026\.3\.22') 'must NOT claim a version-floor problem when nothing is installed'
Set-FakeMissing 'openclaw config get plugins.entries.openclaw-weixin.enabled'
$c = Check-PluginEnabled
Assert-False ($c.Detail -match '得到 \[\]') 'plugin check must not report an empty config value when openclaw is absent'
Set-FakeMissing 'openclaw channels status --probe'
$c = Check-ChannelConnected
Assert-False ($c.Detail -eq '') 'channel check still explains itself when openclaw is absent'

# 还原成"已安装"形态，让后面的通用断言在正常语境下跑
Set-Fake 'openclaw --version' 0 '2026.9.6'
Set-Fake 'openclaw config get plugins.entries.openclaw-weixin.enabled' 0 'true'
Set-Fake 'openclaw channels status --probe' 0 'openclaw-weixin  OK  bot=ilink_x'

# 每个 Check 都必须给出可行动的 Fix，否则 doctor 的输出对用户没有价值
foreach ($fn in 'Check-NodeVersion','Check-OpenClawInstalled','Check-PluginEnabled',
                'Check-BotCredential','Check-GatewayRunning','Check-ChannelConnected',
                'Check-NetworkEgress','Check-ApiKeyUsable','Check-WorkspaceFiles') {
    $r = & $fn
    Assert-True ($r.Name.Length -gt 0) "$fn sets Name"
    Assert-True ($r.PSObject.Properties.Name -contains 'Ok') "$fn exposes Ok"
    Assert-True ($r.PSObject.Properties.Name -contains 'Detail') "$fn exposes Detail"
    # 只在失败时断言 Fix 非空 —— 通过的检查项 Fix 本就该是空串
    if (-not $r.Ok) { Assert-True ($r.Fix.Length -gt 0) "$fn names an actionable fix when it fails" }
}
Exit-TestSummary
