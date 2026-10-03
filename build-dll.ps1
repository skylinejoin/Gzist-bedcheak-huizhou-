<#
  构建 Win32 辅助类 DLL（一次性, 构建期）
  ================================================================
  为什么需要它:
    主脚本原本用 Add-Type -TypeDefinition 在【运行时】编译 C# —— PowerShell 5.1 会为此派生
    csc.exe(一个控制台进程), 这是整个流程里唯一的控制台子进程, 也是"可能闪出控制台窗口"的
    最后一点理论可能。改成加载【构建期预编译】的 DLL 后, 运行期不再派生任何编译器。

  用法(在本目录执行一次即可):
    powershell -ExecutionPolicy Bypass -File build-dll.ps1

  产物:
    Gzist.Win32.dll   —— 主脚本会用【内存加载】方式载入它
                        (读成 byte[] 再 Assembly.Load, 以绕过部分盘符被 .NET 视为
                         "远程位置"而拒绝 Add-Type -Path 的限制 / HRESULT 0x80131515)

  说明: 若你不想构建 DLL, 主脚本也能自动回退到【源码编译】(gzist-win32.cs),
        功能完全相同, 只是那一次运行会派生 csc.exe。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$cs  = Join-Path $Root "gzist-win32.cs"
$dll = Join-Path $Root "Gzist.Win32.dll"

if (-not (Test-Path $cs)) { throw "找不到 gzist-win32.cs" }

$csc = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "找不到 .NET Framework 的 csc.exe（需要 .NET Framework 4.x）" }

Write-Host "编译器: $csc"
$out = & $csc /nologo /target:library /out:"$dll" /r:System.Drawing.dll /r:System.Windows.Forms.dll "$cs" 2>&1
if (Test-Path $dll) {
    Write-Host ("构建成功: Gzist.Win32.dll ({0:N1} KB)" -f ((Get-Item $dll).Length / 1KB)) -ForegroundColor Green
} else {
    Write-Host "构建失败:" -ForegroundColor Red
    $out | ForEach-Object { Write-Host "  $_" }
    exit 1
}
