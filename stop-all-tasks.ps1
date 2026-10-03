<#
  停用/删除本项目的所有计划任务
  ================================================================
  用法:
    powershell -ExecutionPolicy Bypass -File stop-all-tasks.ps1          # 停用(可随时恢复, 推荐)
    powershell -ExecutionPolicy Bypass -File stop-all-tasks.ps1 -Remove  # 彻底删除任务
    powershell -ExecutionPolicy Bypass -File stop-all-tasks.ps1 -List    # 只看状态, 不改动

  说明:
    - 「停用」只是把任务设为 Disabled, 之后双击 3-注册每日自动签到.bat 即可重新启用。
    - 「删除」会把任务定义一并移除, 之后同样可以重新注册。
    - 本脚本只处理本项目相关任务(GZIST-* 或动作里指向本项目目录的任务), 不碰系统任务。
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$List
)
$ErrorActionPreference = "Continue"
Write-Host ""
Write-Host "==== 本项目计划任务 ====" -ForegroundColor Cyan

$mine = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like "*GZIST*" -or $_.TaskName -like "*查寝*" -or $_.TaskName -like "*签到*" -or
    ($_.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*wxwork-signin*" })
})
if ($mine.Count -eq 0) {
    Write-Host "未找到本项目任务（可能已清理干净）" -ForegroundColor Yellow
    exit 0
}

foreach ($t in $mine) {
    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
    Write-Host ("  [{0}]  {1}" -f $t.State, $t.TaskName) -ForegroundColor White
    Write-Host ("       动作: {0}" -f $t.Actions[0].Arguments) -ForegroundColor DarkGray
    if ($info) { Write-Host ("       下次运行: {0}" -f $info.NextRunTime) -ForegroundColor DarkGray }
}
if ($List) { exit 0 }

Write-Host ""
$okCount = 0
foreach ($t in $mine) {
    $n = $t.TaskName
    # 正在运行 -> 先停
    if ($t.State -eq "Running") {
        try { Stop-ScheduledTask -TaskName $n -ErrorAction Stop; Write-Host "  已停止运行中的实例: $n" -ForegroundColor Yellow } catch { }
        Start-Sleep -Milliseconds 800
    }
    if ($Remove) {
        try {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop
            Write-Host "  已删除: $n" -ForegroundColor Green
            $okCount++
            continue
        } catch {
            # 退回 schtasks 删除
            $o = schtasks /Delete /TN "$n" /F 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host "  已删除(schtasks): $n" -ForegroundColor Green; $okCount++ }
            else { Write-Host "  删除失败: $n -> $($o -join ' ')" -ForegroundColor Red }
            continue
        }
    }
    # 停用
    try {
        Disable-ScheduledTask -TaskName $n -ErrorAction Stop | Out-Null
        Write-Host "  已停用: $n" -ForegroundColor Green
        $okCount++
    } catch {
        $o = schtasks /Change /TN "$n" /DISABLE 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "  已停用(schtasks): $n" -ForegroundColor Green; $okCount++ }
        else { Write-Host "  停用失败: $n -> $($o -join ' ')" -ForegroundColor Red }
    }
}

Write-Host ""
Write-Host "==== 复核 ====" -ForegroundColor Cyan
foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like "*GZIST*" -or $_.TaskName -like "*查寝*" -or $_.TaskName -like "*签到*" -or
        ($_.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*wxwork-signin*" })
    })) {
    Write-Host ("  {0,-28} {1}" -f $t.TaskName, $t.State) -ForegroundColor White
}
Write-Host ""
if ($okCount -gt 0) {
    Write-Host "完成($okCount 个)。" -ForegroundColor Green
    if (-not $Remove) {
        Write-Host "要重新启用: 双击 3-注册每日自动签到.bat" -ForegroundColor Gray
    } else {
        Write-Host "要重新启用: 双击 3-注册每日自动签到.bat（会重新创建任务）" -ForegroundColor Gray
    }
} else {
    Write-Host "没有改动任何任务。" -ForegroundColor Yellow
}
Write-Host ""
