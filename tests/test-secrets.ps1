$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\harness.ps1"
. "$PSScriptRoot\..\scripts\secrets.ps1"

# 用临时 .env 隔离，绝不碰真实密钥文件
$TmpEnv = Join-Path (Join-Path $PSScriptRoot 'tmp-fixture') '.env'
if (Test-Path $TmpEnv) { Remove-Item $TmpEnv -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $TmpEnv) | Out-Null

function Get-EnvPathOverride { return $TmpEnv }

[void](Set-Secret -Name 'DEMO_KEY' -Value 'abc123')
Assert-True (Test-Path $TmpEnv) 'Set-Secret creates the env file'
Assert-Equal 'abc123' (Get-Secret -Name 'DEMO_KEY') 'Get-Secret reads back the value'

[void](Set-Secret -Name 'DEMO_KEY' -Value 'replaced')
Assert-Equal 'replaced' (Get-Secret -Name 'DEMO_KEY') 'Set-Secret overwrites an existing key'
$raw = Get-Content $TmpEnv -Raw
Assert-True ($raw -notmatch '(?m)^DEMO_KEY=abc123$') 'old value is gone, not appended'

Assert-False (Test-SecretPresent -Name 'NOPE') 'Test-SecretPresent false for missing key'
Assert-Equal $null (Get-Secret -Name 'NOPE') 'Get-Secret returns null for missing key'

# 空值不算存在：写错成 FOO= 时应被 doctor 判为缺失
[void](Set-Secret -Name 'BLANK' -Value '')
Assert-False (Test-SecretPresent -Name 'BLANK') 'empty value is treated as absent'

# UTF-8 无 BOM：BOM 会让第一行的键名变成 <BOM>KEY
$bytes = [System.IO.File]::ReadAllBytes($TmpEnv)
Assert-False ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'file has no BOM'

# 含 = 的值不能被截断（base64 类 key 常见尾部填充，键值只在第一个 = 处切）
[void](Set-Secret -Name 'EQ_KEY' -Value 'a=b=c')
Assert-Equal 'a=b=c' (Get-Secret -Name 'EQ_KEY') 'value containing equals survives round-trip'

Remove-Item (Split-Path $TmpEnv) -Recurse -Force
Exit-TestSummary
