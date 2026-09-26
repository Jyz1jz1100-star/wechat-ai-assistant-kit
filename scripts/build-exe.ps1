# 生成"可移植"的桌面/仓库内启动器 微信助手.exe。
#
# 为什么必须可移植：旧版把项目绝对路径烤进 exe，作者机器上编出来的东西
# 换台机器就只会报"找不到 quickstart.ps1"，等于没法分发给别人。
# 现在改成：exe 从自己所在目录往上找 scripts\quickstart.ps1，
# 所以把它放在仓库根目录，用户解压到任何位置双击都能用。
param(
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $Root '微信助手.exe' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "找不到系统自带的 C# 编译器：$csc" }

# 不写死任何用户路径：只靠 AppContext.BaseDirectory 向上探测。
$cs = @"
using System;
using System.IO;
using System.Diagnostics;

class Launcher {
    static void Pause() {
        Console.WriteLine();
        Console.WriteLine("按任意键关闭本窗口");
        try { Console.ReadKey(); } catch { }
    }

    // 从 exe 自身所在目录逐级向上找 scripts\quickstart.ps1
    static string FindScript() {
        try {
            DirectoryInfo dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (int i = 0; i < 8 && dir != null; i++, dir = dir.Parent) {
                string cand = Path.Combine(dir.FullName, "scripts", "quickstart.ps1");
                if (File.Exists(cand)) return cand;
            }
        } catch { }
        return null;
    }

    static int Main() {
        string ps = FindScript();
        if (ps == null) {
            Console.WriteLine("找不到 scripts\\quickstart.ps1");
            Console.WriteLine("请确认本文件（微信助手.exe）放在项目根目录里，");
            Console.WriteLine("和 scripts 文件夹同级。");
            Pause();
            return 97;
        }
        try {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\"";
            psi.UseShellExecute = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        } catch (Exception e) {
            Console.WriteLine("启动失败：" + e.Message);
            Pause();
            return 98;
        }
    }
}
"@

$stage = Join-Path $env:TEMP ('wx-launcher-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$csPath = Join-Path $stage 'Launcher.cs'
[System.IO.File]::WriteAllText($csPath, $cs, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "编译 → $Out"
& $csc /nologo /target:exe /out:"$Out" "$csPath" 2>&1 | ForEach-Object { Write-Host $_ }
$code = $LASTEXITCODE
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
if ($code -ne 0) { throw "编译失败（csc 退出码 $code）" }

$bytes = (Get-Item $Out).Length
Write-Host "已生成：$Out（$([math]::Round($bytes/1024,1)) KB）" -ForegroundColor Green
Write-Host '它不含任何逻辑，只负责找到同项目的 scripts\quickstart.ps1 并运行。' -ForegroundColor DarkGray
Write-Host '注意：无签名 exe，别人首次双击可能遇到 SmartScreen 或杀软拦截。' -ForegroundColor Yellow
