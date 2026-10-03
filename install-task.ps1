<#
  注册/卸载每日自动签到的计划任务
  用法（在普通 PowerShell 窗口里运行即可，不需要管理员）:
    安装(默认 21:05): powershell -ExecutionPolicy Bypass -File install-task.ps1
    改时间:           powershell -ExecutionPolicy Bypass -File install-task.ps1 -At "21:20"
    卸载:             powershell -ExecutionPolicy Bypass -File install-task.ps1 -Remove
    立即测试:         powershell -ExecutionPolicy Bypass -File install-task.ps1 -RunNow

  为什么默认 21:05 而不是 21:00 整点:
    1. 签到窗口 21:00~23:40(23:30~23:59 算晚归)，不必卡整点
    2. 21:00 整点可能有大量学生同时签到，系统繁忙 -> 避开
    3. 21:05 时按钮已激活，脚本无需等待，全流程约 20 秒
    4. 距晚归线(23:30)仍有 2 小时 25 分，即使重试也极安全
    脚本本身会在按钮未激活时等待(最多 6 分钟)，所以任何时间都不会误点。
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$RunNow,
    # 每日触发时间，默认 21:05（避开整点高峰，且无需等待开窗）
    [string]$At = "21:05"
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot 在某些调用方式下可能为空 —— 加兜底，否则 Join-Path 会报
# "无法将参数绑定到参数 Path，因为该参数是空值"。（2026-09-26 踩到的坑）
$Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) {
    if ($MyInvocation.MyCommand.Path) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($Root)) { throw "无法确定脚本目录，请用 -File 方式运行本脚本" }

Write-Host "脚本目录: $Root" -ForegroundColor DarkGray

$TaskName  = "GZIST-智能查寝自动签到"
# 【2026-09-28 修复】老任务文件的所有者是 BUILTIN\Administrators, 当前用户只有 Read 权限,
#   非提升权限下 Register-ScheduledTask -Force 会 "Access is denied"。
#   解法: 首选名注册失败就改用【由当前用户创建的新名字】(这类任务归自己所有, 以后都能改)。
$TaskNameAlt = "GZIST-智能查寝自动签到-v2"
$NameCandidates = @($TaskName, $TaskNameAlt)
# 主脚本：daily-signin2.ps1（单会话版）
#   旧版要开两次浏览器（探测 + 签到），耗时且会撞"配置目录被占用"。
#   新版只开一次浏览器，在同一会话里完成: 判断登录态 -> 必要时等人工登录 -> 注入定位 -> 点击签到。
$ScriptFn  = Join-Path $Root "daily-signin2.ps1"

if (-not (Test-Path $ScriptFn)) { throw "找不到签到脚本: $ScriptFn" }
Write-Host "签到脚本: $ScriptFn" -ForegroundColor DarkGray

if ($Remove) {
    $any = $false
    foreach ($nm in $NameCandidates) {
        try {
            if (Get-ScheduledTask -TaskName $nm -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $nm -Confirm:$false -ErrorAction Stop
                Write-Host "已删除计划任务: $nm" -ForegroundColor Green
                $any = $true
            }
        } catch {
            Write-Host "删除失败: $nm -> $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  （该任务可能属于管理员所有, 需要以管理员身份运行本脚本才能删除）" -ForegroundColor Yellow
        }
    }
    if (-not $any) { Write-Host "没有找到可删除的任务（可能已清理）" -ForegroundColor Yellow }
    exit 0
}

if ($RunNow) {
    $runName = $null
    foreach ($nm in $NameCandidates) {
        $t = Get-ScheduledTask -TaskName $nm -ErrorAction SilentlyContinue
        if ($t) { $runName = $nm; break }
    }
    if (-not $runName) { Write-Host "未找到任务, 请先注册" -ForegroundColor Red; exit 1 }
    Write-Host "立即执行一次: $runName" -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $runName
    Start-Sleep -Seconds 3
    Get-ScheduledTaskInfo -TaskName $runName |
        Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime | Format-List
    exit 0
}

# ---- 构建动作 ----
# 【2026-09-29 关键修复】任务动作改为 wscript.exe + _task-run.vbs。
#   实测教训: 直接用 powershell.exe -WindowStyle Hidden 作为任务动作时, 控制台仍会闪出
#   (双实例时更明显 —— 用户看到 2 个 PowerShell 窗口并被踢出全屏游戏)。
#   wscript.exe 是 GUI 进程、天生没有控制台, 它再以隐藏方式拉起 PowerShell -> 全程零窗口。
$taskVbs = Join-Path $Root "_task-run.vbs"
if (-not (Test-Path $taskVbs)) { throw "缺少任务运行器: $taskVbs (应为 wscript 用的零控制台启动器)" }
$wsExe = "$env:SystemRoot\System32\wscript.exe"
$action = New-ScheduledTaskAction -Execute $wsExe -Argument ('"{0}"' -f $taskVbs) -WorkingDirectory $Root

# 每天触发（默认 21:05）
# 【2026-09-27 加固】多次触发 = 保险: 主脚本每次运行都会先查"今日是否已签到",
#   已签到会立即 exit 0 退出 —— 因此多触发几次是幂等安全的, 能把"一次失败就漏签"变成"三次机会"。
# 【2026-09-29 用户要求】后面两次提前, 间隔统一 10 分钟: $At / +10min / +20min
$base = [datetime]::ParseExact($At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$at2 = $base.AddMinutes(10).ToString('HH:mm')
$at3 = $base.AddMinutes(20).ToString('HH:mm')
$t1 = New-ScheduledTaskTrigger -Daily -At $At
$t2 = New-ScheduledTaskTrigger -Daily -At $at2
$t3 = New-ScheduledTaskTrigger -Daily -At $at3
$triggers = @($t1, $t2, $t3)
$triggerText = "$At / $at2 / $at3"

# 关键设置（决定成败）:
#  - 必须"仅在用户登录时运行"(Interactive)，否则无法操作桌面、也无法获得前台焦点
#  - 允许在电池供电时启动、不要因为空闲就停止
#  - 失败自动重试: 每 5 分钟重试, 最多 3 次(与多次触发叠加成多重保险)
#  - 【2026-09-27 修正】MultipleInstances 用 Parallel 而非 IgnoreNew:
#      实测 21:05 那次若卡住未退出, IgnoreNew 会让 21:25/21:50 的重试被直接忽略 -> 漏签。
#      Parallel 下新实例总会启动; 新实例开头的"关闭旧 Edge"会让旧实例 CDP 失效,
#      旧实例读到空页面文字 -> 判定"未激活" -> 不会误点, 安全退出。
#  - ExecutionTimeLimit 15 分钟(正常 1~3 分钟): 卡住的实例被强制结束, 不会占着拖到下一次触发。
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

$registered = $null
$lastErr = ""
$idNow = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object System.Security.Principal.WindowsPrincipal($idNow)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

function Grant-SelfTaskAcl([string]$taskName) {
    # 【2026-09-30】把任务文件的所有权/写权限授予当前用户, 以后改任务就不需要每次提权了。
    #   背景: 以管理员身份注册出来的任务, 文件 Owner=BUILTIN\Administrators, 当前用户只有 Read ->
    #         之后非提权下 Register-ScheduledTask -Force 会 Access denied(这正是任务名被搞成 -v2 的根源)。
    try {
        $tf = Join-Path $env:SystemRoot "System32\Tasks\$taskName"
        if (Test-Path $tf) {
            $me = "$env:USERDOMAIN\$env:USERNAME"
            & icacls "$tf" /grant "${me}:(R,W,D)" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host "  已授予你自己对任务文件的写权限(以后改任务无需提权)" -ForegroundColor DarkGray }
        }
    } catch { }
}

# ---------- 首选: 直接注册(同用户拥有时无需提权) ----------
try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
        -Description "每晚多次自动签到（$triggerText，间隔10分钟，已签到则自动跳过；无窗口运行不打扰前台）" `
        -Force -ErrorAction Stop | Out-Null
    $registered = $TaskName
} catch {
    $lastErr = $_.Exception.Message
    Write-Host "  直接注册失败: $lastErr" -ForegroundColor Yellow
}

# ---------- 失败且未提权 -> 自动提权重试(一次 UAC), 不再另起任务名 ----------
if (-not $registered -and -not $isElevated) {
    Write-Host "  当前任务由管理员拥有 -> 自动发起一次提权重注册(请在 UAC 窗口点【是】)..." -ForegroundColor Yellow
    try {
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -PassThru -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath
        )
        $p.WaitForExit(120000) | Out-Null
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) { $registered = $TaskName; Write-Host "  提权重注册成功: $TaskName" -ForegroundColor Green }
    } catch {
        Write-Host "  自动提权失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($registered) { Grant-SelfTaskAcl $registered }

if (-not $registered) {
    Write-Host "创建失败: $lastErr" -ForegroundColor Red
    Write-Host ""
    Write-Host "两种解决办法（任选其一）:" -ForegroundColor Yellow
    Write-Host "  A. 以管理员身份运行本脚本（右键 PowerShell -> 以管理员身份运行）:" -ForegroundColor Yellow
    Write-Host "       powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Gray
    Write-Host "  B. 用图形界面创建:" -ForegroundColor Yellow
    Write-Host "       1. Win+R 输入 taskschd.msc 回车"
    Write-Host "       2. 右侧「创建任务」(不要用「创建基本任务」)"
    Write-Host "       3. 常规页: 选中「只在用户登录时运行」"
    Write-Host "       4. 触发器页: 新建 -> 每天 -> $At （可再加 $at2 / $at3 两次, 间隔10分钟）"
    Write-Host "       5. 操作页: 新建 -> 程序或脚本填 powershell.exe"
    Write-Host "          添加参数填: -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptFn`""
    Write-Host "       6. 设置页: 勾选「如果任务失败，按以下频率重新启动」"
    exit 1
}

$TaskName = $registered
Write-Host "计划任务已创建: $TaskName" -ForegroundColor Green
Write-Host "  触发时间: $triggerText （每 10 分钟一次，已签到会自动跳过）" -ForegroundColor Cyan
if ($TaskName -eq $TaskNameAlt) {
    Write-Host "  说明: 原名称 [$($NameCandidates[0])] 的任务属于管理员所有(无写权限), 已自动改用本名称。" -ForegroundColor DarkGray
    Write-Host "        如需清理旧任务, 用管理员身份运行: install-task.ps1 -Remove" -ForegroundColor DarkGray
}

Write-Host ""
Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State | Format-List
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "下次运行时间: $($info.NextRunTime)" -ForegroundColor Cyan
Write-Host ""
Write-Host "提示: 手动跑一次验证时用:" -ForegroundColor Yellow
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$ScriptFn`" -WaitLoginMin 2"
