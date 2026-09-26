# 七个体检判定。真逻辑集中在此，便于在没有 OpenClaw / 没有微信登录态的机器上
# 用注入的假外部命令做单元测试。
$script:ChecksRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $script:ChecksRoot 'scripts\secrets.ps1')

function Get-ModelEndpoint {
    # 服务商不写死：从仓库的 config/openclaw.patch.json 取第一个 provider 的 baseUrl，
    # 拼出 /models 当探测地址。换 OpenRouter / DashScope / 自建网关都不用改脚本。
    if (Get-Command 'Get-ModelEndpointOverride' -ErrorAction SilentlyContinue) {
        return Get-ModelEndpointOverride
    }
    $blank = @{ Base = ''; Models = ''; Key = ''; ApiKeyVar = 'ASSISTANT_API_KEY' }
    $patchFile = Join-Path $script:ChecksRoot 'config\openclaw.patch.json'
    if (-not (Test-Path $patchFile)) { return $blank }
    try {
        $j = (Get-Content $patchFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $blank }
    $names = @($j.models.providers.PSObject.Properties.Name)
    if ($names.Count -eq 0) { return $blank }
    $key = $names[0]
    $raw = $j.models.providers.$key.baseUrl
    if (-not $raw) { return $blank }
    $base = $raw.TrimEnd('/')
    return @{ Base = $base; Models = ($base + '/models'); Key = $key; ApiKeyVar = 'ASSISTANT_API_KEY' }
}

function Invoke-External {
    param([string]$File, [string[]]$CmdArgs = @())
    if (Get-Command 'Invoke-ExternalOverride' -ErrorAction SilentlyContinue) {
        return Invoke-ExternalOverride -File $File -CmdArgs $CmdArgs
    }
    # 命令根本不存在时，`& $File` 是抛 CommandNotFoundException，而不是返回非零退出码。
    # 不先挡这一步的话，"OpenClaw 没装" 会被误报成 "当前版本  低于 2026.3.22"，
    # 把用户往完全错的方向引。Missing 标记让上层能给出正确结论。
    if (-not (Get-Command $File -ErrorAction SilentlyContinue)) {
        return @{ ExitCode = 127; Out = ''; Err = "找不到命令 $File"; Missing = $true }
    }
    try {
        $out = & $File @CmdArgs 2>&1
        return @{ ExitCode = $LASTEXITCODE; Out = ($out -join "`n"); Err = ''; Missing = $false }
    } catch {
        return @{ ExitCode = 1; Out = ''; Err = $_.Exception.Message; Missing = $false }
    }
}

function Compare-Version {
    param([string]$Left, [string]$Right)
    function Get-Parts([string]$v) {
        $nums = @()
        foreach ($seg in (($v -replace '^[^0-9]*', '') -split '\.')) {
            $clean = ($seg -replace '[^0-9].*$', '')
            $n = 0
            if ($clean -ne '' -and [int]::TryParse($clean, [ref]$n)) { $nums += $n } else { $nums += 0 }
        }
        while ($nums.Count -lt 3) { $nums += 0 }
        return $nums
    }
    $a = Get-Parts $Left
    $b = Get-Parts $Right
    for ($i = 0; $i -lt 3; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

function Test-MissingCommand {
    param($r)
    return [bool]($r.Missing -eq $true)
}

function New-CheckResult {
    param([string]$Name, [bool]$Ok, [string]$Detail, [string]$Fix)
    return [PSCustomObject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Fix = $Fix }
}

function Check-NodeVersion {
    $Floor = '22.13.0'
    $r = Invoke-External -File 'node' -CmdArgs @('--version')
    if ((Test-MissingCommand $r) -or $r.ExitCode -ne 0) {
        return New-CheckResult 'Node.js' $false 'node 不在 PATH' "安装 Node LTS >= $Floor"
    }
    if ((Compare-Version -Left $r.Out.Trim() -Right $Floor) -lt 0) {
        return New-CheckResult 'Node.js' $false "当前 $($r.Out.Trim())，低于 $Floor" "升级 Node 到 >= $Floor"
    }
    return New-CheckResult 'Node.js' $true $r.Out.Trim() ''
}

function Check-OpenClawInstalled {
    $Floor = '2026.3.22'
    $r = Invoke-External -File 'openclaw' -CmdArgs @('--version')
    if ((Test-MissingCommand $r) -or $r.ExitCode -ne 0) {
        return New-CheckResult 'OpenClaw' $false 'openclaw 不在 PATH（没装，不是版本过旧）' 'npm install -g openclaw'
    }
    if ((Compare-Version -Left $r.Out.Trim() -Right $Floor) -lt 0) {
        return New-CheckResult 'OpenClaw' $false "当前 $($r.Out.Trim())，低于 $Floor" 'npm install -g openclaw@latest'
    }
    return New-CheckResult 'OpenClaw' $true $r.Out.Trim() ''
}

function Check-PluginEnabled {
    $r = Invoke-External -File 'openclaw' -CmdArgs @('config', 'get', 'plugins.entries.openclaw-weixin.enabled')
    if (Test-MissingCommand $r) {
        return New-CheckResult '微信通道插件' $false 'openclaw 不在 PATH，先装 OpenClaw' 'npm install -g openclaw'
    }
    $v = $r.Out.Trim().ToLower()
    if ($r.ExitCode -eq 0 -and $v -eq 'true') {
        return New-CheckResult '微信通道插件' $true 'enabled' ''
    }
    return New-CheckResult '微信通道插件' $false "config get 得到 [$v]" `
        'openclaw plugins install "@tencent-weixin/openclaw-weixin" 然后 openclaw config set plugins.entries.openclaw-weixin.enabled true'
}

function Get-BotAccountDir {
    # 可注入：否则测试结果取决于"这台机器恰好扫过码没有"，开发机与干净机器结论不同。
    if (Get-Command 'Get-BotAccountDirOverride' -ErrorAction SilentlyContinue) {
        return Get-BotAccountDirOverride
    }
    return Join-Path $env:USERPROFILE '.openclaw\openclaw-weixin\accounts'
}

function Check-BotCredential {
    # 扫码成功后插件会把凭据写到 ~/.openclaw/openclaw-weixin/accounts/*.json。
    # 这是不依赖网关是否在跑的独立证据 —— 用户扫过码但网关没装时，
    # 单看 channels status 会说不出到底哪一环断了。
    $dir = Get-BotAccountDir
    $files = @()
    if (Test-Path $dir) { $files = @(Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) }
    if ($files.Count -gt 0) {
        return New-CheckResult 'Bot 授权凭据' $true "$($files.Count) 个账号已扫码授权" ''
    }
    return New-CheckResult 'Bot 授权凭据' $false "accounts 目录里没有凭据（$dir）" `
        'openclaw channels login --channel openclaw-weixin   （用手机微信扫码）'
}

function Check-GatewayRunning {
    # 实测踩过的坑：`gateway restart` 对从未安装过的服务是空转，不报错。
    # 于是通道配置齐全、凭据也在，但没有任何进程在收发微信消息 —— 全线静默失灵。
    $r = Invoke-External -File 'openclaw' -CmdArgs @('health')
    if (Test-MissingCommand $r) {
        return New-CheckResult '网关在运行' $false 'openclaw 不在 PATH' 'npm install -g openclaw'
    }
    $out = $r.Out
    if ($out -match '(?i)still starting') {
        return New-CheckResult '网关在运行' $false '正在启动中（等十几秒再复查）' 'openclaw gateway restart'
    }
    if ($out -match '(?i)Gateway event loop') {
        return New-CheckResult '网关在运行' $true ((($out -split "`n") | Where-Object { $_ -match 'event loop' } | Select-Object -First 1)).Trim() ''
    }
    if ($out -match '(?i)not running|unavailable|no gateway') {
        return New-CheckResult '网关在运行' $false '网关服务没在跑' 'openclaw gateway install   （首次安装并启动为计划任务）'
    }
    return New-CheckResult '网关在运行' $false (($out -split "`n")[0]) 'openclaw gateway install'
}

function Check-ChannelConnected {
    $r = Invoke-External -File 'openclaw' -CmdArgs @('channels', 'status', '--probe')
    if (Test-MissingCommand $r) {
        return New-CheckResult '微信通道已连' $false 'openclaw 不在 PATH，先装 OpenClaw' 'npm install -g openclaw'
    }
    # 只看 weixin 那一行。整段输出里匹配 \bOK\b 会被别的通道的字样或
    # gateway 告警误触发；把一堆无关告警原样甩给用户也没意义。
    $line = ''
    foreach ($l in ($r.Out -split "`n")) { if ($l -match 'openclaw-weixin') { $line = $l.Trim(); break } }
    if ($line -eq '') { $line = '输出里没有 openclaw-weixin 通道行' }

    # 关键区分：网关不可达时，probe 只念配置文件（输出含 config-only），
    # 那一行永远不会有 running/connected。此时"去扫码"是错误诊断 ——
    # 用户已经扫过码了，真正缺的是网关服务。曾经就把人卡在这一条上。
    if ($r.Out -match '(?i)config-only|requires credentials before opening') {
        return New-CheckResult '微信通道已连' $false '网关不可达，probe 只读到配置（不是没扫码）' `
            '先修「网关在运行」这一项：openclaw gateway install'
    }
    $connected = ($line -match '(?i)(connected|running|\bOK\b)') -and ($line -notmatch '(?i)not connected|failed|error')
    if ($connected) { return New-CheckResult '微信通道已连' $true $line '' }
    if (-not (Check-BotCredential).Ok) {
        return New-CheckResult '微信通道已连' $false $line `
            'openclaw channels login --channel openclaw-weixin   （用手机微信扫码）'
    }
    return New-CheckResult '微信通道已连' $false $line 'openclaw gateway restart'
}

function Check-NetworkEgress {
    # 只测两个必须可达的域名，好把「微信侧不通」和「模型侧不通」分开。
    # 必须走 Invoke-External，否则测试会在离线机器上真发网络请求。
    $ep = Get-ModelEndpoint
    $targets = @(@{ N = '微信 iLink'; U = 'https://ilinkai.weixin.qq.com/' })
    if ($ep.Models) { $targets += @{ N = '模型端点'; U = $ep.Models } }
    $bad = @()
    foreach ($t in $targets) {
        $r = Invoke-External -File 'curl.exe' -CmdArgs @(
            '-s', '-o', 'NUL', '-m', '15', '--noproxy', '*', '-w', '%{http_code}', $t.U)
        # 任何 HTTP 响应码（含 401/403/404）都证明链路通；只有空或 000 才是网络问题
        if ($r.Out -notmatch '^[1-5]\d\d$') { $bad += "$($t.N) 无响应" }
    }
    if ($bad.Count -eq 0) { return New-CheckResult '出网连通' $true '微信与模型端点均可达' '' }
    return New-CheckResult '出网连通' $false ($bad -join '； ') `
        '本方案全程出站连接，不开任何入站端口。检查代理/TUN 是否拦了这两个域名，或临时关代理再试'
}

function Check-ApiKeyUsable {
    $ep = Get-ModelEndpoint
    $varName = $ep.ApiKeyVar
    if (-not (Test-SecretPresent -Name $varName)) {
        return New-CheckResult '模型密钥' $false ".env 中没有 $varName" `
            '跑 scripts\set-key.ps1 录入（输入不回显、不进命令历史）；不要在任何命令行参数里明文传 key'
    }
    if (-not $ep.Models) {
        return New-CheckResult '模型密钥' $false 'config/openclaw.patch.json 里没有可用的 provider baseUrl' `
            '在 models.providers 下填一个 OpenAI 兼容的 baseUrl'
    }
    $k = Get-Secret -Name $varName
    $r = Invoke-External -File 'curl.exe' -CmdArgs @(
        '-s', '-o', 'NUL', '-m', '20', '--noproxy', '*', '-w', '%{http_code}',
        '-H', "Authorization: Bearer $k",
        '-H', 'User-Agent: wechat-assistant-doctor/1.0',
        $ep.Models)
    # 任何分支都不得把 $k 放进 Detail
    if ($r.Out -eq '200') { return New-CheckResult '模型密钥' $true "GET /models 200 ($($ep.Base))" '' }
    if ($r.Out -eq '401' -or $r.Out -eq '403') {
        return New-CheckResult '模型密钥' $false "GET /models $($r.Out)（key 无效、额度用尽，或 UA 被拦）" `
            '到服务商后台确认 key 状态与额度'
    }
    if ($r.Out -eq '404') {
        # 有些兼容端点不提供 /models。这里必须诚实说"验不了"，
        # 不能因为没报错就当密钥有效。
        return New-CheckResult '模型密钥' $false 'GET /models 404：该端点没有 /models 路由，密钥状态无法自动验证' `
            '直接在微信里发一句试试；能答就是好的'
    }
    return New-CheckResult '模型密钥' $false "GET /models 返回 [$($r.Out)]" '先看「出网连通」一项'
}

function Check-WorkspaceFiles {
    $need = @('SOUL.md', 'USER.md', 'AGENTS.md')
    $ws = Join-Path $script:ChecksRoot 'workspace'
    $missing = @()
    foreach ($f in $need) { if (-not (Test-Path (Join-Path $ws $f))) { $missing += $f } }
    if ($missing.Count -eq 0) { return New-CheckResult '人设文件' $true "三个文件齐 ($ws)" '' }
    return New-CheckResult '人设文件' $false "缺少 $($missing -join ', ') 于 $ws" '写入 workspace 下的 SOUL.md / USER.md / AGENTS.md'
}
