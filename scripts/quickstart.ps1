# 一键流程：缺什么补什么，已经好的就跳过。
# 桌面那个 微信助手.exe 只是启动壳，真逻辑全在这里 —— 保持只有一份。
param([switch]$SkipLogin)   # 验证前两步用；正式使用不要带这个开关
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts\secrets.ps1')
. (Join-Path $Root 'scripts\lib\checks.ps1')

function Say  { param($m) Write-Host "  $m" }
function Good { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Bad  { param($m) Write-Host "  ✗ $m" -ForegroundColor Red }
function Pause-Exit { param($code)
    Write-Host ""
    # 非交互（stdin 被重定向 / 自动化调用）时 RawUI.ReadKey 会抛异常或永久挂起，
    # 那种场景下直接结束，不要为了"暂停一下"卡住调用方。
    if ([Console]::IsInputRedirected) { exit $code }
    Write-Host '按任意键关闭本窗口' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    exit $code
}

Write-Host ""
Write-Host '  微信 AI 助手 · 一键启动' -ForegroundColor Cyan
Write-Host "  $($Root)" -ForegroundColor DarkGray
Write-Host ""

# ---------- 1. 装好并配好 ----------
Say '第 1 步 检查安装与配置…'
# 先只做三个轻量检查。只有真的缺东西才去跑 install.ps1 —— 后者会派生十几个
# node 进程，每次都跑会让双击后的窗口看起来像卡死（实测一分钟以上没动静）。
$installCheck = @((Check-NodeVersion), (Check-OpenClawInstalled), (Check-PluginEnabled))
$installBad = @($installCheck | Where-Object { -not $_.Ok })
if ($installBad.Count -gt 0) {
    Say '有缺项，正在补齐（这一步会慢一些，请稍候）…'
    # 必须用子进程调 install.ps1：它在失败分支里有 `exit 1`，同进程 & 调用会
    # 把整个一键流程一起带走，用户只看到一个闪退的窗口。
    $installScript = Join-Path $Root 'scripts\install.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript *> $null
    $installCheck = @((Check-NodeVersion), (Check-OpenClawInstalled), (Check-PluginEnabled))
    $installBad = @($installCheck | Where-Object { -not $_.Ok })
}
if ($installBad.Count -eq 0) { Good 'OpenClaw、微信通道插件、配置 就位' }
else { foreach ($b in $installBad) { Bad "$($b.Name)：$($b.Detail) → $($b.Fix)" }; Pause-Exit 1 }

# ---------- 2. 密钥 ----------
Say '第 2 步 模型密钥…'
if (Test-SecretPresent -Name 'ASSISTANT_API_KEY') {
    Good '密钥已在 ~/.openclaw/.env'
} else {
  # Read-Host 在 stdin 被重定向时不会"读到空"，而是继续等控制台输入并永久卡住
  # （实测卡了 7 分钟，日志停在提示行之后）。非交互场景直接判为跳过。
  if ([Console]::IsInputRedirected) {
    Warn '输入被重定向（非交互运行），无法提示录入密钥。跳过。'
  } else {
    Warn '还没有密钥。现在输入（屏幕上不会显示，也不会进命令历史）：'
    Write-Host '  如果没有 key：去 Command Code 后台开通，把 key 复制好再回来。' -ForegroundColor DarkGray
    Write-Host '  直接按回车 = 跳过（之后随时可以再运行本程序补填）。' -ForegroundColor DarkGray
    $secure = $null
    try { $secure = Read-Host '  粘贴 ASSISTANT_API_KEY（可留空跳过）' -AsSecureString } catch { }
    if ($null -ne $secure -and $secure.Length -gt 0) {
      $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
      try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
      [void](Set-Secret -Name 'ASSISTANT_API_KEY' -Value $plain.Trim())
      if (Test-SecretPresent -Name 'ASSISTANT_API_KEY') { Good '密钥已保存' } else { Bad '保存失败'; Pause-Exit 1 }
    } else {
      Warn '跳过密钥。没有它助手不会回答，其余步骤照常进行。'
    }
  }
}

# ---------- 3. 微信扫码授权（这一步真的只能你本人做） ----------
Say '第 3 步 微信授权…'
$chan = Check-ChannelConnected
if ($chan.Ok) {
    Good "已授权（$($chan.Detail)）"
} elseif ($SkipLogin) {
    Warn '带 -SkipLogin，跳过扫码。'
} else {
    Warn '需要你用微信扫一次二维码。下一步会在本窗口里显示二维码。'
    Write-Host '  手机 → 微信 → 右上角「+」→ 扫一扫' -ForegroundColor DarkGray
    Write-Host ""
    & openclaw channels login --channel openclaw-weixin
    if ($LASTEXITCODE -ne 0) {
        Bad "扫码流程退出码 $LASTEXITCODE。可稍后重试，或手动跑：openclaw channels login --channel openclaw-weixin"
    }
}

# ---------- 4. 网关必须在跑 ----------
Say '第 4 步 网关…'
# 实测教训：`gateway restart` 对从未安装的服务是空转且不报错，通道配置齐全、
# 凭据也在，但没有进程在收发微信 —— 全线静默失灵，而体检只会说"去扫码"。
if (-not (Check-GatewayRunning).Ok) {
    Say '网关服务不在运行，正在安装为开机任务（首次会建一个计划任务 OpenClaw Gateway）…'
    & openclaw gateway install 2>&1 | Select-Object -Last 3 | ForEach-Object { Say $_ }
    Start-Sleep -Seconds 8
    $g = Check-GatewayRunning
    if ($g.Ok) { Good "网关已运行（$($g.Detail)）" }
    else { Warn "网关仍未就绪：$($g.Detail) → $($g.Fix)" }
} else {
    Good '网关已在运行'
}

# ---------- 5. 结论 ----------
Say '第 5 步 体检结论'
Write-Host ""
$results = @((Check-NodeVersion), (Check-OpenClawInstalled), (Check-PluginEnabled),
             (Check-BotCredential), (Check-GatewayRunning), (Check-ChannelConnected),
             (Check-NetworkEgress), (Check-ApiKeyUsable), (Check-WorkspaceFiles))
$failed = @($results | Where-Object { -not $_.Ok })
foreach ($r in $results) {
    if ($r.Ok) { Write-Host ("  [OK]   {0,-14} {1}" -f $r.Name, $r.Detail) -ForegroundColor Green }
    else       { Write-Host ("  [FAIL] {0,-14} {1}" -f $r.Name, $r.Detail) -ForegroundColor Red }
}
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host '  全部就绪。现在打开手机微信，找到那个 Bot，发一句「你好」。' -ForegroundColor Green
    Write-Host '  等几秒是正常的，期间会显示"正在输入"。' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host '  提醒：这个助手跑在你这台电脑上，电脑关机或休眠时它不回应。' -ForegroundColor Yellow
    Pause-Exit 0
}
Write-Host "  还有 $($failed.Count) 项没就绪，先处理这条：" -ForegroundColor Yellow
Write-Host "    $($failed[0].Fix)" -ForegroundColor Yellow
Pause-Exit 1
