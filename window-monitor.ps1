<#
  窗口侦探监视器（零窗口）
  ================================================================
  用途: 在 21:00~21:35 之间以 50ms 采样盯着桌面, 记录【任何新出现的可见窗口】
        以及新生的控制台类进程(powershell/conhost/csc/wscript), 用来一锤定音地判断
        "那一下弹窗到底是不是自动化造成的、是哪个进程、第几秒"。

  零窗口保证:
    - 由 15-架设窗口监视器(零窗口).vbs 用 wscript 以隐藏方式拉起(无控制台);
    - 枚举窗口用的是【预编译 DLL】Gzist.Win32.dll(内存加载), 不做运行时 C# 编译 → 不派生 csc;
    - 自身不再启动任何其它进程。

  用法:
    powershell -ExecutionPolicy Bypass -File window-monitor.ps1 [-Minutes 40]
  输出:
    监控报告-yyyyMMdd-HHmmss.txt   (与脚本同目录)
#>
[CmdletBinding()]
param(
    [int]$Minutes = 40
)
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rptFn = Join-Path $Root "监控报告-$stamp.txt"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function W([string]$s) {
    try { [System.IO.File]::AppendAllText($rptFn, $s + "`r`n", [System.Text.UTF8Encoding]::new($true)) } catch { }
}

# ---- 加载预编译 DLL(内存加载, 不派生编译器) ----
$dll = Join-Path $Root "Gzist.Win32.dll"
try {
    $bytes = [System.IO.File]::ReadAllBytes($dll)
    [void][System.Reflection.Assembly]::Load($bytes)
} catch {
    W ("[错误] 无法加载 Gzist.Win32.dll: " + $_.Exception.Message)
    exit 1
}

W "==================== 窗口侦探监视器 ===================="
W ("开始时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"))
W ("采样间隔: 50ms    监视时长: $Minutes 分钟")
W ("本机时间: 触发点为 21:05 / 21:15 / 21:25")
W ""

function SnapWins {
    $r = @()
    foreach ($h in [DW]::AllVisibleTitled()) {
        $r += ("{0}|{1}" -f [int][DW]::PidOf($h), [DW]::Title($h))
    }
    return $r
}

$base = SnapWins
W ("基线可见窗口 " + $base.Count + " 个:")
foreach ($b in $base) { W ("    " + $b.Split('|')[1] + "   [" + $b.Split('|')[0] + "]") }
W ""

$knownWins = $base
$knownProcs = @{}
foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $knownProcs[$p.Id] = $p.ProcessName }
$winHits = 0; $procHits = 0; $lastProc = 0.0
$deadline = $Minutes * 60

while ($sw.Elapsed.TotalSeconds -lt $deadline) {
    Start-Sleep -Milliseconds 50
    # 1) 窗口采样
    foreach ($w in @((SnapWins) | Where-Object { $knownWins -notcontains $_ })) {
        $parts = $w.Split('|', 2)
        $pidW = [int]$parts[0]
        $pname = try { (Get-Process -Id $pidW -ErrorAction Stop).ProcessName } catch { '?' }
        $winHits++
        W ("{0,9:N2}s  [新窗口] {1}    ← 进程 {2} (PID {3})" -f $sw.Elapsed.TotalSeconds, (Get-Date -Format "HH:mm:ss.fff"), $parts[1], $pname, $pidW)
        W ("             ^^^ 若这个进程是 powershell/conhost/csc/wscript, 就说明是自动化侧造成的")
        $knownWins += $w
    }
    # 2) 进程采样(每 0.5 秒)
    if ($sw.Elapsed.TotalSeconds - $lastProc -ge 0.5) {
        $lastProc = $sw.Elapsed.TotalSeconds
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
            if (-not $knownProcs.ContainsKey($p.Id)) {
                $knownProcs[$p.Id] = $p.ProcessName
                if ($p.ProcessName -match 'powershell|conhost|csc|wscript|mshta|msedge') {
                    $procHits++
                    W ("{0,9:N2}s  [新进程] {1} (PID {2})" -f $sw.Elapsed.TotalSeconds, $p.ProcessName, $p.Id)
                }
            }
        }
    }
}

W ""
W "==================== 结论 ===================="
W ("结束时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"))
W ("监视时长: " + [int]$sw.Elapsed.TotalSeconds + " 秒")
W ("新窗口次数: $winHits")
W ("控制台类新进程次数: $procHits")
if ($winHits -eq 0) {
    W "判定: 全程 0 个新窗口 —— 自动化没有产生任何窗口（弹窗问题确认解决）"
} else {
    W "判定: 出现了新窗口, 请查看上面每一行的【进程名】来归属来源:"
    W "      · powershell / conhost / csc / wscript  → 自动化侧造成"
    W "      · explorer / 其它应用                  → 与自动化无关"
}
W "=============================================="
