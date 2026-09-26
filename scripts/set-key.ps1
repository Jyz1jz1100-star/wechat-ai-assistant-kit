# 交互式录入 ASSISTANT_API_KEY。
#
# 存在的理由：让"把密钥写进配置"这件事不需要用户在命令行里明文敲 key。
# 命令行参数会进 shell 历史和进程列表，Read-Host -AsSecureString 不会。
# 也避免了在 install.ps1 / README 里嵌套 PowerShell 引号 —— 那种写法迟早出错。
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts\secrets.ps1')

function Set-SecretFromSecureString {
    param([string]$Name, [System.Security.SecureString]$SecureValue)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureValue)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { throw '输入为空，未写入' }
    return Set-Secret -Name $Name -Value $plain.Trim()
}

Write-Host "密钥会写入 $(Get-EnvPath)" -ForegroundColor Cyan
Write-Host "输入时屏幕不会显示，也不会留在命令历史里。" -ForegroundColor DarkGray

# Read-Host 在 stdin 被重定向时不会返回空，而是继续等控制台输入并永久卡住。
# 非交互调用必须给一句人话，而不是挂在那里。
if ([Console]::IsInputRedirected) {
    Write-Host '当前是非交互运行（输入被重定向），无法安全地提示录入密钥。' -ForegroundColor Red
    Write-Host '请在自己的终端窗口里直接运行本脚本。' -ForegroundColor Yellow
    exit 2
}

$secure = Read-Host '粘贴 ASSISTANT_API_KEY' -AsSecureString
[void](Set-SecretFromSecureString -Name 'ASSISTANT_API_KEY' -SecureValue $secure)

if (Test-SecretPresent -Name 'ASSISTANT_API_KEY') {
    Write-Host '已写入。再跑一次 scripts\doctor.ps1 确认「模型密钥」变绿。' -ForegroundColor Green
    exit 0
}
Write-Host '写入后仍读不到，出问题了。' -ForegroundColor Red
exit 1
