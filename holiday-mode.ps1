<#
  假期模式 / 恢复模式 一键切换
  ================================================================
  用法:
    powershell -ExecutionPolicy Bypass -File holiday-mode.ps1 -Off    # 假期: 停用自动签到(可逆)
    powershell -ExecutionPolicy Bypass -File holiday-mode.ps1 -On     # 回校: 恢复自动签到
    powershell -ExecutionPolicy Bypass -File holiday-mode.ps1 -Status # 只看状态

  为什么需要它(见交付说明的使用边界):
    定位注入用的是【宿舍坐标】。人若离开学校, 自动签到 = 伪造在场, 属违纪记录。
    所以【离校前必须停用每日任务】, 回校后再恢复。

  2026-10-01 修正:
    - 任务在【计划程序库里的安全描述符】可能要求提权(即使任务文件本身可写) -> 被拒时自动提权重试一次;
    - 旧版在失败时仍打印"✅ 已开启"(报告 bug) -> 现在一律【复核真实状态】后才下结论。
#>
[CmdletBinding()]
param(
    [switch]$Off,
    [switch]$On,
    [switch]$Status
)
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
function W([string]$s, [string]$c = "Gray") { Write-Host $s -ForegroundColor $c }

$idNow = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object System.Security.Principal.WindowsPrincipal($idNow)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-MyTasks {
    return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like "*GZIST*" -or $_.TaskName -like "*查寝*" -or $_.TaskName -like "*签到*" -or
        ($_.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*wxwork-signin*" })
    })
}
function Get-Enabled([string]$name) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t) { return [bool]$t.Settings.Enabled }
    return $null
}

$mine = Get-MyTasks
if ($mine.Count -eq 0) { W "没有找到本项目任务（可能已被删除；回校后双击 3-注册每日自动签到.bat 重新创建）" "Yellow"; exit 0 }

W "==================== 本项目计划任务 ====================" "Cyan"
foreach ($t in $mine) {
    $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
    W ("  [{0}] Enabled={1}  {2}" -f $t.State, $t.Settings.Enabled, $t.TaskName) "White"
    W ("       触发: {0}" -f (($t.Triggers | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') }) -join ' / '))
    if ($i) { W ("       上次: {0}   下次: {1}" -f $i.LastRunTime, $i.NextRunTime) }
}

if ($Status) {
    $en = @($mine | Where-Object { $_.Settings.Enabled }).Count
    W ""
    if ($en -eq 0) { W "当前状态: 假期模式（已停用，不会自动签到）" "Green" } else { W "当前状态: 正常模式（$en 个任务启用中，会按 21:05/21:15/21:25 自动签到）" "Yellow" }
    exit 0
}

$wantEnable = [bool]$On
function Try-Set([string]$name, [bool]$enable) {
    try {
        if ($enable) { Enable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null }
        return $true
    } catch { }
    $verb = if ($enable) { "/ENABLE" } else { "/DISABLE" }
    $o = schtasks /Change /TN "$name" $verb 2>&1
    return ($LASTEXITCODE -eq 0)
}

W ""
W ("---- " + $(if ($wantEnable) { "恢复自动签到" } else { "开启假期模式(停用)" }) + " ----") "Cyan"
$denied = @()
foreach ($t in $mine) {
    if ($wantEnable -eq [bool]$t.Settings.Enabled) { W ("  已是目标状态, 跳过: " + $t.TaskName); continue }
    if ($t.State -eq "Running") { Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 700 }
    $ok = Try-Set $t.TaskName $wantEnable
    $nowEn = Get-Enabled $t.TaskName
    if ($nowEn -eq $wantEnable) { W ("  已" + $(if ($wantEnable) { "启用" } else { "停用" }) + ": " + $t.TaskName) "Green" }
    else { $denied += $t.TaskName; W ("  被拒(需要管理员权限): " + $t.TaskName) "Yellow" }
}

if ($denied.Count -gt 0 -and -not $isElevated) {
    W "  正在发起一次提权重试(请在 UAC 窗口点【是】)..." "Yellow"
    try {
        $swArg = if ($wantEnable) { "-On" } else { "-Off" }
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -PassThru -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath, $swArg
        )
        $p.WaitForExit(120000) | Out-Null
    } catch { W ("  自动提权失败: " + $_.Exception.Message) "Red" }
}

# ---- 只按【真实状态】下结论 ----
W ""
W "---- 复核(以真实状态为准) ----" "Cyan"
$bad = @()
foreach ($t in (Get-MyTasks)) {
    $en = Get-Enabled $t.TaskName
    W ("  {0,-32} Enabled={1}" -f $t.TaskName, $en) "White"
    if ($wantEnable) { if ($en -ne $true) { $bad += $t.TaskName } }
    else { if ($en -ne $false) { $bad += $t.TaskName } }
}
W ""
if ($bad.Count -eq 0) {
    if ($wantEnable) { W "✅ 已恢复自动签到（今晚 21:05 起生效；请确认人已在宿舍）" "Green" }
    else { W "✅ 假期模式已生效：自动签到不会再运行（任务定义保留，回校可一键恢复）" "Green"; W "   回校后双击 14-恢复自动签到(回校).bat" "Yellow" }
    exit 0
} else {
    W "❌ 操作未生效的任务: $($bad -join ', ')" "Red"
    W "   请【以管理员身份】运行本脚本重试，或手动在 taskschd.msc 中：任务计划程序库 -> 右键该任务 -> 禁用/启用" "Yellow"
    exit 1
}
