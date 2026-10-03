<#
  一键干净重部署
  ================================================================
  1. 列出并【删除】所有本项目相关的计划任务(含管理员所有的旧任务)
  2. 用当前最佳配置重新注册【一个】干净任务:
       动作 = wscript.exe "_task-run.vbs"  (零控制台)
       多实例 = IgnoreNew
       触发 = 21:05 / 21:15 / 21:25 (间隔 10 分钟)
       时限 = 15 分钟
  3. 清理陈旧残留(旧交付包 / 人工提示标记文件)
  4. 复核并打印结果

  用法(建议以管理员身份运行, 否则删不掉管理员所有的旧任务):
    powershell -ExecutionPolicy Bypass -File redeploy-clean.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
$rpt = New-Object System.Collections.Generic.List[string]
function W([string]$s, [string]$color = "Gray") { Write-Host $s -ForegroundColor $color; [void]$rpt.Add($s) }

W "==================== 一键干净重部署 ====================" "Cyan"
W ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
W ("管理员权限: " + $isAdmin) $(if ($isAdmin) { "Green" } else { "Yellow" })

# ---------- 1. 找到所有相关任务 ----------
W ""
W "---- 1. 现有项目相关任务 ----" "Cyan"
$all = Get-ScheduledTask -ErrorAction SilentlyContinue
$mine = @($all | Where-Object {
    $_.TaskName -like "*GZIST*" -or $_.TaskName -like "*查寝*" -or $_.TaskName -like "*签到*" -or
    ($_.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*wxwork-signin*" }) -or
    ($_.Actions | Where-Object { $_.Execute -and $_.Execute -like "*wscript*" -and $_.Arguments -like "*_task-run.vbs*" })
})
if ($mine.Count -eq 0) { W "  (没有找到相关任务)" } 
foreach ($t in $mine) {
    $arg = if ($t.Actions[0].Arguments) { $t.Actions[0].Arguments } else { "" }
    W ("  [{0}] {1}" -f $t.State, $t.TaskName)
    W ("        动作: {0} {1}" -f $t.Actions[0].Execute, $arg.Substring(0, [Math]::Min(70, $arg.Length)))
}

# ---------- 2. 全部删除 ----------
W ""
W "---- 2. 删除全部相关任务 ----" "Cyan"
$deleted = 0; $failed = @()
foreach ($t in $mine) {
    $n = $t.TaskName
    if ($t.State -eq "Running") { try { Stop-ScheduledTask -TaskName $n -ErrorAction Stop } catch { }; Start-Sleep -Milliseconds 700 }
    $ok = $false
    try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop; $ok = $true } catch { }
    if (-not $ok) {
        $o = schtasks /Delete /TN "$n" /F 2>&1
        if ($LASTEXITCODE -eq 0) { $ok = $true } else { $failed += "$n ($($o -join ' '))" }
    }
    if ($ok) { W ("  已删除: " + $n) "Green"; $deleted++ } else { W ("  删除失败: " + $n) "Red" }
}
W ("  共删除 {0} 个, 失败 {1} 个" -f $deleted, $failed.Count) $(if ($failed.Count) { "Yellow" } else { "Green" })
foreach ($f in $failed) { W ("    ! " + $f) "Red" }
if ($failed.Count -gt 0 -and -not $isAdmin) {
    W "  提示: 上面失败的属于管理员所有 —— 请以【管理员身份】重跑本脚本" "Yellow"
}

# ---------- 3. 清理陈旧残留 ----------
W ""
W "---- 3. 清理陈旧残留 ----" "Cyan"
# 3.1 旧交付包(只保留最新)
$zips = @(Get-ChildItem (Split-Path $Root -Parent) -Filter "签到查寝-交付版-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
if ($zips.Count -gt 1) {
    foreach ($z in $zips[1..($zips.Count - 1)]) {
        try { Remove-Item $z.FullName -Force -ErrorAction Stop; W ("  已删除旧交付包: " + $z.Name) "Green" } catch { W ("  删除失败: " + $z.Name) "Yellow" }
    }
} else { W "  (没有多余的交付包)" }
# 3.2 人工提示标记文件(旧的)
foreach ($m in @("需要人工登录.txt", "需要人工签到.txt")) {
    $p = Join-Path $Root $m
    if (Test-Path $p) { try { Remove-Item $p -Force -ErrorAction Stop; W ("  已清除旧标记: " + $m) "Green" } catch { } }
}
# 3.3 project 目录里由浏览器产生的临时目录(不删配置目录本身)
foreach ($d in @("edge-userdata-probe", "..\edge-userdata-probe")) {
    $p = Join-Path $Root $d
    if (Test-Path $p) { try { Remove-Item $p -Recurse -Force -ErrorAction Stop; W ("  已清除临时目录: " + $d) "Green" } catch { } }
}

# ---------- 4. 重新注册干净任务 ----------
W ""
W "---- 4. 重新注册干净任务 ----" "Cyan"
$installer = Join-Path $Root "install-task.ps1"
if (-not (Test-Path $installer)) { W "  !! 找不到 install-task.ps1" "Red" } else {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $installer 2>&1
    foreach ($l in $out) { W ("  " + $l) }
}

# ---------- 5. 复核 ----------
W ""
W "---- 5. 复核 ----" "Cyan"
$after = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like "*GZIST*" -or $_.TaskName -like "*查寝*" -or $_.TaskName -like "*签到*" -or
    ($_.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*wxwork-signin*" })
})
W ("  现有项目任务数: {0}" -f $after.Count) $(if ($after.Count -le 1) { "Green" } else { "Yellow" })
foreach ($t in $after) {
    $arg = if ($t.Actions[0].Arguments) { $t.Actions[0].Arguments } else { "" }
    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
    W ("  {0}" -f $t.TaskName) "White"
    W ("     Enabled={0}  State={1}" -f $t.Settings.Enabled, $t.State)
    W ("     动作: {0} {1}" -f $t.Actions[0].Execute, $arg)
    W ("     多实例: {0}   时限: {1}" -f $t.Settings.MultipleInstances, $t.Settings.ExecutionTimeLimit)
    W ("     触发: {0}" -f (($t.Triggers | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') }) -join ' / '))
    if ($info) { W ("     下次运行: {0}" -f $info.NextRunTime) }
}
$leftoverEdge = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine -like "*edge-userdata*" })
W ("  自动化 Edge 残留: {0} 个" -f $leftoverEdge.Count) $(if ($leftoverEdge.Count -eq 0) { "Green" } else { "Yellow" })

# ---------- 6. 报告 ----------
$rpt | Set-Content -Path (Join-Path $Root "重部署报告.txt") -Encoding UTF8
W ""
W "报告已写入: 重部署报告.txt" "Gray"
W "==================== 完成 ====================" "Cyan"
