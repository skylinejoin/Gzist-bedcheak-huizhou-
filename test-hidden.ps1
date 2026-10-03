<#
  隐藏模式测试(延迟10秒) —— 验证签到流程不打扰游戏/视频
  ================================================================
  用法: 双击 "7-测试隐藏模式(延迟10秒).bat"  或
        powershell -ExecutionPolicy Bypass -File test-hidden.ps1 -DelaySec 10

  流程: 倒计时 N 秒(你切到游戏全屏) -> 执行 daily-signin2.ps1(隐藏模式) -> 汇总
  观察点: 游戏是否被顶出全屏 / 鼠标是否自己动 / 焦点是否被抢
  说明: 当前不在考勤时段时会以退出码 8(已过晚归线)或 0(未点击)结束,
        属正常 —— 本测试验证的是"启动+判定+就位"全程不打扰。
#>
[CmdletBinding()]
param(
    [int]$DelaySec = 10
)
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  隐藏模式测试: {0} 秒后自动开始签到流程" -f $DelaySec) -ForegroundColor Cyan
Write-Host ""
Write-Host "  请现在切到【游戏 / 全屏视频】, 然后观察:" -ForegroundColor Yellow
Write-Host "    1. 游戏是否被顶出全屏 / 黑屏闪烁" -ForegroundColor Yellow
Write-Host "    2. 鼠标是否自己移动了" -ForegroundColor Yellow
Write-Host "    3. 输入法 / 焦点是否被抢走" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
for ($i = $DelaySec; $i -ge 1; $i--) {
    Write-Host ("    倒计时 {0} ..." -f $i) -ForegroundColor Green
    try { [console]::beep(760, 70) } catch { }
    Start-Sleep -Seconds 1
}
Write-Host ""
Write-Host "=== 开始执行签到流程（隐藏模式：窗口最小化创建且摆到屏幕外，全程不抢前台）===" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# ⚠️ 两个坑(2026-09-27 实测):
#   ① 直接 & powershell.exe / Start-Process 默认会弹出新控制台并抢焦点 —— 足以把全屏游戏踢出全屏;
#   ② Start-Process -Wait 会连"子进程的后代"一起等(Edge 一直开着 -> 结果文件要等你关掉 Edge 才写)。
#   正解: ProcessStartInfo + CreateNoWindow(完全不建控制台) + WaitForExit(只等流程本身)。
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $psExe
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root "daily-signin2.ps1")
$child = [System.Diagnostics.Process]::Start($psi)
$child.WaitForExit()          # 只等流程进程, 不等它启动的 Edge
$code = $child.ExitCode
$sw.Stop()

# 结果同时写文件 —— 静默启动(无控制台)时也能事后查看
$verdict = switch ($code) {
    8 { "已过晚归线（当前不在考勤时段，属正常，未点击）" }
    0 { "正常结束（非考勤时段不会点击，属正常）" }
    6 { "窗口几何异常 —— 请把日志发给助手" }
    7 { "定位未通过 —— 请把日志发给助手" }
    2 { "未找到自动化窗口 —— 请把日志发给助手" }
    3 { "等待人工登录超时" }
    default { "见 signin.log" }
}
$lines = @(
    "===== 隐藏模式测试结果 =====",
    ("时间:      " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
    ("耗时:      " + [int]$sw.Elapsed.TotalSeconds + " 秒"),
    ("退出码:    " + $code),
    ("判定:      " + $verdict),
    "",
    "【本次测试要你自己判断的三件事】",
    "  1. 游戏是否被顶出全屏/黑屏闪烁   -> 期望：没有",
    "  2. 鼠标是否自己移动了             -> 期望：没有",
    "  3. 输入法/焦点是否被抢走           -> 期望：没有",
    "",
    "详细日志: signin.log    截图存证: shots\ 目录",
    "若三项中任何一项被打破，请把本文件和 signin.log 发给助手。"
)
try { Set-Content -Path (Join-Path $Root "hidden-test-result.txt") -Value $lines -Encoding UTF8 } catch { }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  测试结束（耗时 {0}s，退出码 {1}）" -f [int]$sw.Elapsed.TotalSeconds, $code) -ForegroundColor Cyan
Write-Host ("  判定: {0}" -f $verdict) -ForegroundColor Yellow
Write-Host "  结果已写入 hidden-test-result.txt（静默运行时用记事本打开查看）" -ForegroundColor Yellow
Write-Host "  请核对：游戏是否被打断 / 鼠标是否自己动 / 焦点是否被抢（期望：都没有）" -ForegroundColor Yellow
Write-Host "  截图存证: shots\ 目录" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
