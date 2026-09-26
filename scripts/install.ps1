# 一键装好并配好。可重复执行；已经对的部分会被跳过。
#
# 实测踩过的两个坑，都写进了这里的顺序：
#   1) 不要并发跑 npm 安装 —— 上一次重装与插件安装撞车，把 openclaw 的
#      内容哈希 chunk 撕开过（报 Cannot find module 'status-XXXX.mjs'）。
#      所以本脚本严格串行，且每步之后立刻验证。
#   2) npm 的 allow-scripts 会拦 openclaw/koffi 的安装脚本。实测不跑它们
#      也能用（version、插件安装、config validate 全通），因此本脚本
#      默认不放宽该策略 —— 放宽等于执行第三方安装期代码，需要用户同意。
# 用 Continue 而不是 Stop：PowerShell 会把原生命令写到 stderr 的内容当成
# terminating error。openclaw 在缺 key 时会往 stderr 打告警，用 Stop 会让脚本
# 在「plugins list」这种只读步骤上直接崩掉。失败判断一律改走显式 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts\secrets.ps1')

$OPENCLAW_VERSION = '2026.9.6'
$PLUGIN = '@tencent-weixin/openclaw-weixin'

function Step { param($m) Write-Host "`n→ $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
function Bad  { param($m) Write-Host "  ✗ $m" -ForegroundColor Red }

function Test-Command { param($exe) return [bool](Get-Command $exe -ErrorAction SilentlyContinue) }

Step '1/6 Node.js'
if (-not (Test-Command 'node')) { Bad 'node 不在 PATH，先装 Node LTS >= 22.13'; exit 1 }
Ok "node $((node --version))"

Step '2/6 OpenClaw'
if (Test-Command 'openclaw') {
  Ok "已安装：$((openclaw --version))"
} else {
  Write-Host "  npm install -g openclaw@$OPENCLAW_VERSION （约需数分钟，请勿中途再开一个安装）"
  & npm install -g "openclaw@$OPENCLAW_VERSION"
  if ($LASTEXITCODE -ne 0) { Bad 'npm 安装失败'; exit 1 }
  Ok "装好：$((openclaw --version))"
}

Step '3/6 微信通道插件'
$installed = (& openclaw plugins list 2>&1) -join "`n"
if ($installed -match 'openclaw-weixin') {
  Ok '已安装'
} else {
  & openclaw plugins install $PLUGIN
  if ($LASTEXITCODE -ne 0) { Bad "插件安装失败（退出码 $LASTEXITCODE）"; exit 1 }
  Ok '已安装'
}
& openclaw config set plugins.entries.openclaw-weixin.enabled true | Out-Null
Ok '已启用'

Step '4/6 下发配置（深合并 + 自动备份，幂等）'
& node (Join-Path $Root 'scripts\apply-config.mjs')
if ($LASTEXITCODE -ne 0) { Bad "apply-config 退出码 $LASTEXITCODE"; exit 1 }

Step '5/6 校验配置'
$v = (& openclaw config validate 2>&1) -join "`n"
if ($v -match 'Config valid') {
  Ok '配置有效'
  if ($v -match 'ASSISTANT_API_KEY') { Write-Host '  ! 还差密钥：见下面「录入密钥」' -ForegroundColor Yellow }
} else {
  Bad '配置校验未通过：'; Write-Host $v; exit 1
}

Step '6/6 密钥就位？'
if (Test-SecretPresent -Name 'ASSISTANT_API_KEY') {
  Ok 'ASSISTANT_API_KEY 已存在于 ~/.openclaw/.env'
} else {
  Bad 'ASSISTANT_API_KEY 未设置'
  # 提示里给绝对路径：用户终端的当前目录不一定是项目目录，
  # 相对路径会让人撞上「-File 形式参数的实际参数不存在」。
  $keyScript = Join-Path $Root 'scripts\set-key.ps1'
  Write-Host '  录入密钥（在你自己的终端里跑下面这条，输入时不回显、不进命令历史）：' -ForegroundColor Yellow
  Write-Host "      powershell -NoProfile -ExecutionPolicy Bypass -File `"$keyScript`"" -ForegroundColor Yellow
  Write-Host '  key 不要发给任何人，包括我。' -ForegroundColor Yellow
}

Step '体检'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\doctor.ps1')
Write-Host @'

最后一步需要你自己做（微信扫码，我没法代劳）：

    openclaw channels login --channel openclaw-weixin
    openclaw gateway restart

它会显示二维码 —— 用手机微信扫码并确认授权。之后在微信里给这个 Bot 发「你好」。
'@ -ForegroundColor Green
