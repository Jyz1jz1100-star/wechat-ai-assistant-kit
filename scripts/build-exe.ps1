# 把桌面 exe 重新编译一份。改了 quickstart.ps1 之后**不需要**重跑这个 ——
# exe 只是启动壳，不含逻辑；只有在项目搬家或第一次创建快捷方式时才跑。
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Desktop = [Environment]::GetFolderPath('Desktop')
$ExeName = '微信助手.exe'
$ExePath = Join-Path $Desktop $ExeName

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "找不到系统自带的 C# 编译器：$csc" }

# 项目路径在编译时烤进 exe，所以这个构建脚本必须是路径的唯一来源，
# 不要手工维护一份写死路径的 .cs —— 那会和现场漂移。
$cs = @"
using System;
using System.Diagnostics;
using System.IO;

class Launcher {
    static int Main() {
        string root = @"$Root";
        string ps = Path.Combine(root, "scripts", "quickstart.ps1");
        if (!File.Exists(ps)) {
            Console.WriteLine("找不到 " + ps);
            Console.WriteLine("项目可能搬家了。重新生成一次桌面图标：");
            Console.WriteLine("  powershell -ExecutionPolicy Bypass -File `" + Path.Combine(root, "scripts", "build-exe.ps1") + "`");
            Console.WriteLine();
            Console.WriteLine("按任意键关闭");
            Console.ReadKey();
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
            Console.ReadKey();
            return 98;
        }
    }
}
"@

$stage = Join-Path $env:TEMP ('wechat-launcher-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$csPath = Join-Path $stage 'Launcher.cs'
[System.IO.File]::WriteAllText($csPath, $cs, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "编译 → $ExePath"
& $csc /nologo /target:exe /out:"$ExePath" "$csPath" 2>&1 | ForEach-Object { Write-Host $_ }
$code = $LASTEXITCODE
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

if ($code -ne 0) { throw "编译失败（csc 退出码 $code）" }
Write-Host "已生成：$ExePath" -ForegroundColor Green
Write-Host '双击它即可。第一次可能弹 Windows SmartScreen 拦一下：点「更多信息」→「仍要运行」。' -ForegroundColor Yellow
Write-Host '它不含任何逻辑，只是打开项目里的 scripts\quickstart.ps1。' -ForegroundColor DarkGray
