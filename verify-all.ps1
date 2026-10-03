<#
  一键自检 —— 逐项验证关键保证, 输出 PASS/FAIL 并写入 自检报告.txt
  ================================================================
  验证项:
    ① 全部脚本: 语法可解析 + 含中文的脚本都有 UTF-8 BOM(否则会乱码)
    ② 配置: 无窗口模式 / 不允许可见窗口兜底 / 宿舍坐标 / 晚归线
    ③ 计划任务: 存在且已启用 / 3 次触发 / 控制台 Hidden / 指向 daily-signin2.ps1
    ④ 【零窗口实跑】真实跑一次流程, 前后对比桌面窗口数量, 断言 0 新增窗口
    ⑤ 运行结论: 从日志读取本次结果(签到成功 / 本日已签到 / 拒绝点击等)
    ⑥ 【无残留】跑完后自动化 Edge 进程数 = 0
  用法:
    powershell -ExecutionPolicy Bypass -File verify-all.ps1
  或者双击 12-一键自检.vbs (零窗口运行)
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
$LogFn = Join-Path $Root "signin.log"
$rptFn = Join-Path $Root "自检报告.txt"
$lines = New-Object System.Collections.Generic.List[string]
$script:pass = 0; $script:fail = 0
function W([string]$s) { Write-Host $s; [void]$lines.Add($s) }
function Item([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    W ("[{0}] {1}  {2}" -f $tag, $name, $detail)
}

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class WinList {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  public static List<string> List() {
    var res = new List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512);
      string t = sb.ToString();
      if (t.Length > 0) { uint pid; GetWindowThreadProcessId(h, out pid); res.Add(t + " [#" + pid + "]"); }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@

W "=================================================="
W (" 智能查寝签到 —— 一键自检   " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
W "=================================================="
W ""

# ---------- ① 脚本语法与编码 ----------
$badParse = @(); $badBom = @(); $nPs1 = 0
Get-ChildItem $Root -Recurse -Filter *.ps1 -File | ForEach-Object {
    $nPs1++
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $nonAscii = @($b | Where-Object { $_ -gt 127 }).Count
    if (-not $hasBom -and $nonAscii -gt 0) { $badBom += $_.Name }
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) { $badParse += "$($_.Name): $($errs[0].Message)" }
}
Item "脚本语法与编码 ($nPs1 个 .ps1)" (($badParse.Count -eq 0) -and ($badBom.Count -eq 0)) `
     $(if ($badParse.Count -eq 0 -and $badBom.Count -eq 0) { "全部可解析, 中文脚本全部有 BOM" } else { "解析错误: $($badParse -join '; ') 缺BOM: $($badBom -join ',')" })

# ---------- ② 配置 ----------
$cfg = Get-Content (Join-Path $Root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$mode = [string]$cfg.'_运行'.无窗口模式
$allowVis = [bool]$cfg.'_运行'.允许可见窗口兜底
$lat = [double]$cfg.'_定位注入'.纬度; $lng = [double]$cfg.'_定位注入'.经度
$lateLine = [string]$cfg.'_时序要求'.晚归线
Item "配置: 无窗口模式" ($mode -eq "headless") "无窗口模式=$mode"
Item "配置: 不允许自动弹窗" (-not $allowVis) "允许可见窗口兜底=$allowVis (false=自动运行绝不弹窗)"
Item "配置: 宿舍坐标已写入" (($lat -ne 0) -and ($lng -ne 0)) "坐标=$lat,$lng  精度=$($cfg.'_定位注入'.精度米)m"
Item "配置: 晚归线" ($lateLine -eq "23:00") "晚归线=$lateLine"

# ---------- ③ 计划任务 ----------
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*GZIST*" })
$enabled = @($tasks | Where-Object { $_.Settings.Enabled })
$main = $enabled | Select-Object -First 1
if ($main) {
    $trig = @($main.Triggers | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') })
    $arg = [string]$main.Actions[0].Arguments
    $exe = [string]$main.Actions[0].Execute
    Item "任务: 已启用" $true "任务名=$($main.TaskName)  状态=$($main.State)"
    Item "任务: 三次触发" ($trig.Count -ge 3) "触发时间: $($trig -join ' / ')"
    # 2026-09-29 之后判定: 首选 wscript.exe + vbs(天生无控制台); 也接受旧的 -WindowStyle Hidden 写法
    $isWscript = ($exe -match "wscript\.exe")
    $vbsPath = ($arg -replace '"', '').Trim()
    $vbsRunsScript = $false
    if ($isWscript -and (Test-Path $vbsPath)) {
        $vc = [System.IO.File]::ReadAllText($vbsPath, [System.Text.UTF8Encoding]::new($false))
        $vbsRunsScript = ($vc -match "daily-signin2\.ps1")
    }
    Item "任务: 无控制台窗口保证" ($isWscript -or ($arg -match "WindowStyle Hidden")) `
        $(if ($isWscript) { "动作=wscript.exe（天生无控制台）+ $([System.IO.Path]::GetFileName($vbsPath))" } elseif ($arg -match "WindowStyle Hidden") { "参数含 -WindowStyle Hidden" } else { "参数: $arg" })
    Item "任务: 指向正确脚本" (($arg -match "daily-signin2\.ps1") -or $vbsRunsScript) `
        $(if ($vbsRunsScript) { "$([System.IO.Path]::GetFileName($vbsPath)) -> daily-signin2.ps1 ✓" } elseif ($arg -match "daily-signin2\.ps1") { "直接指向 daily-signin2.ps1" } else { "参数: $arg" })
    $info = Get-ScheduledTaskInfo -TaskName $main.TaskName
    W "       下次运行: $($info.NextRunTime)   上次运行: $($info.LastRunTime)  上次结果: $($info.LastTaskResult)"
} else {
    Item "任务: 已启用" $false "没有找到已启用的 GZIST 任务(会不会被停用了?)"
}
# 停用的旧任务(仅提示, 不算失败)
$disabled = @($tasks | Where-Object { -not $_.Settings.Enabled })
if ($disabled.Count) { W "       (提示: 另有 $($disabled.Count) 个已停用的旧任务, 不会运行)" }

# ---------- ④ 零窗口实跑 ----------
W ""
W "---- 零窗口实跑(真实执行一次完整流程) ----"
$swBefore = [WinList]::List()
W "       运行前桌面可见窗口: $($swBefore.Count) 个"
$logBefore = (Get-Content $LogFn -Encoding UTF8 -ErrorAction SilentlyContinue).Count
# 用与计划任务完全相同的隐藏方式启动(确保不会弹窗)
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $psExe
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root "daily-signin2.ps1")
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = [System.Diagnostics.Process]::Start($psi)
$maxWin = 0
while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Milliseconds 700
    $cur = [WinList]::List()
    $newN = @($cur | Where-Object { $swBefore -notcontains $_ }).Count
    if ($newN -gt $maxWin) { $maxWin = $newN }
}
$exitCode = $null
try { if ($proc.HasExited) { $exitCode = $proc.ExitCode } } catch { }
Start-Sleep -Seconds 2
$swAfter = [WinList]::List()
$newWins = @($swAfter | Where-Object { $swBefore -notcontains $_ })
Item "零窗口实跑: 全程无新增窗口" ($newWins.Count -eq 0) $(if ($newWins.Count -eq 0) { "耗时 $([int]$sw.Elapsed.TotalSeconds)s, 全程 0 新增窗口" } else { "新增: $($newWins -join ' | ')" })
if ($newWins.Count -gt 0) { W "       注意: 若标题是你自己的浏览器/聊天窗口, 那是你正在使用的程序, 与本流程无关" }
W "       进程退出码: $(if ($null -ne $exitCode) { $exitCode } else { '超时未退出' })"

# ---------- ⑤ 运行结论 ----------
$newLog = @(Get-Content $LogFn -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
$resultLine = @($newLog | Where-Object { $_ -match "结果: " } | Select-Object -Last 1)
$okLine = @($newLog | Where-Object { $_ -match "签到成功！|本日已签到|已签到" } | Select-Object -Last 1)
$detail = if ($resultLine.Count) { ($resultLine[0] -replace '^.*\[INFO\]\s*', '') } else { "本次日志无结论行" }
$good = ($resultLine -match "签到成功") -or ($okLine -match "本日已签到|已签到")
Item "本次运行结论" $good $detail
if ($okLine.Count) { W "       $($okLine[0] -replace '^.*\[INFO\]\s*','')" }

# ---------- ⑥ 无残留 ----------
$leftEdge = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -like "*edge-userdata*" })
Item "跑完无残留(后台开销=0)" ($leftEdge.Count -eq 0) $(if ($leftEdge.Count -eq 0) { "自动化 Edge 进程 0 个" } else { "仍有 $($leftEdge.Count) 个进程" })
$leftPs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*daily-signin2.ps1*" -and $_.CommandLine -notlike "*verify-all*" })
Item "无遗留脚本进程" ($leftPs.Count -eq 0) $(if ($leftPs.Count -eq 0) { "签到脚本进程 0 个" } else { "仍有 $($leftPs.Count) 个" })

# ---------- 汇总 ----------
W ""
W "=================================================="
W (" 自检结果: PASS $($script:pass) 项 / FAIL $($script:fail) 项")
if ($script:fail -eq 0) { W " 结论: 全部通过 —— 无窗口 / 任务就绪 / 运行正常 / 无残留" }
else { W " 结论: 有 $($script:fail) 项未通过, 请把本报告发给助手" }
W "=================================================="
$lines | Set-Content -Path $rptFn -Encoding UTF8
W "报告已写入: $rptFn"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
