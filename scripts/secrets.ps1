# .env 的唯一存放处 = OpenClaw 自己读的那份。密钥只应该存在一处。
#
# 为什么不是项目目录下的 .env：实测 `openclaw config validate` 只有在
# ~/.openclaw/.env 里定义了 ASSISTANT_API_KEY 时才停止告警 —— OpenClaw 只读它自己
# 那个位置。项目里再存一份就只有"两处手工同步"可选，而密钥同步必然漂移。
# 所以让 OpenClaw 读的那份成为唯一一份，项目目录不再存放密钥。
function Get-OpenClawEnvPath {
    return Join-Path (Join-Path $env:USERPROFILE '.openclaw') '.env'
}

function Get-EnvPath {
    # 测试通过预定义 Get-EnvPathOverride 注入 fixture 路径
    if (Get-Command 'Get-EnvPathOverride' -ErrorAction SilentlyContinue) {
        return Get-EnvPathOverride
    }
    return Get-OpenClawEnvPath
}

function Get-EnvMap {
    $path = Get-EnvPath
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in (Get-Content $path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        # 只在第一个 = 处切：base64 形态的 key 值本身可能含 =
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i)] = $t.Substring($i + 1)
    }
    return $map
}

function Set-Secret {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)
    $map = Get-EnvMap
    $map[$Name] = $Value
    $lines = @()
    foreach ($k in ($map.Keys | Sort-Object)) { $lines += "$k=$($map[$k])" }
    $path = Get-EnvPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)   # $false = 不写 BOM
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $enc)
    return $true
}

function Get-Secret {
    param([Parameter(Mandatory)][string]$Name)
    $map = Get-EnvMap
    if ($map.ContainsKey($Name)) { return $map[$Name] }
    return $null
}

function Test-SecretPresent {
    param([Parameter(Mandatory)][string]$Name)
    $v = Get-Secret -Name $Name
    return ($null -ne $v -and $v.Trim() -ne '')
}
