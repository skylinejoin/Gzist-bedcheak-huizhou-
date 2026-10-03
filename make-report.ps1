<#
  生成签到结果自检报告 (HTML)
  ================================================================
  用法: powershell -ExecutionPolicy Bypass -File make-report.ps1
        （运行后会打开 report.html）

  报告内容:
    1. 最近一次运行的日志
    2. 自动分析: 签到按钮颜色变化(点击前 vs 点击后)
    3. 所有相关截图(点击可放大)
    4. 明确的成功/失败结论

  为什么需要它:
    PrintWindow 抓的窗口截图不含浏览器弹窗，全屏截图才有。
    人工比对太麻烦，故自动汇总。
#>
[CmdletBinding()]
param(
    [switch]$NoOpen
)

$ErrorActionPreference = "Continue"
$Root    = $PSScriptRoot
$LogFn   = Join-Path $Root "signin.log"
$ShotDir = Join-Path $Root "shots"
$OutFn   = Join-Path $Root "report.html"

Add-Type -AssemblyName System.Drawing

function HtmlEnc($s) {
    if ($null -eq $s) { return "" }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

# ---------- 收集日志 ----------
$runLog = @()
$runTime = "(无记录)"
if (Test-Path $LogFn) {
    $lines = Get-Content $LogFn -Encoding UTF8
    $startIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match "====.*开始.*====") { $startIdx = $i; break }
    }
    if ($startIdx -ge 0) {
        $runLog = $lines[$startIdx..($lines.Count-1)]
        if ($runLog[0] -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $runTime = $Matches[1] }
    }
}

# ---------- 收集截图 ----------
$allShots = @()
if (Test-Path $ShotDir) {
    $allShots = Get-ChildItem "$ShotDir\*.png" | Sort-Object LastWriteTime
}
# 归并出"最近一次运行"的截图
# 注意: 一次运行会横跨多个时间戳前缀(如 140525 / 140535)，
#       所以不能按前缀严格分组 —— 要按【时间接近度】归并（踩过的坑）。
$latestShots = @()
$runWindowMin = 15
if ($allShots.Count -gt 0) {
    $cand = @($allShots | Sort-Object LastWriteTime -Descending)
    $kept = @()
    $lastT = $null
    foreach ($s in $cand) {
        if ($null -eq $lastT) { $kept += $s; $lastT = $s.LastWriteTime; continue }
        if ((($lastT) - $s.LastWriteTime).TotalMinutes -le $runWindowMin) {
            $kept += $s; $lastT = $s.LastWriteTime
        } else { break }
    }
    $latestShots = @($kept | Sort-Object LastWriteTime)
}
$latestKey = if ($latestShots.Count -gt 0) { $latestShots[0].LastWriteTime.ToString('HH:mm') } else { "(无)" }

# ---------- 分析按钮颜色 ----------
function Analyze-Button($file) {
    try {
        $bmp = New-Object System.Drawing.Bitmap($file)
        # 窗口区域 (60,40)-(490,940)；按钮预期在窗口内 (100~320, 360~590)
        $x0 = 60 + 100; $x1 = [math]::Min($bmp.Width-1, 60+320)
        $y0 = 40 + 360; $y1 = [math]::Min($bmp.Height-1, 40+590)
        $gray = 0; $other = 0; $tally = @{}
        for ($y = $y0; $y -le $y1; $y += 4) {
            for ($x = $x0; $x -le $x1; $x += 4) {
                $p = $bmp.GetPixel($x,$y)
                if ($p.R -gt 235 -and $p.G -gt 235 -and $p.B -gt 235) { continue }
                $k = "{0},{1},{2}" -f ([int]($p.R/8)*8),([int]($p.G/8)*8),([int]($p.B/8)*8)
                $tally[$k] = ($tally[$k] + 1)
                if ([math]::Abs($p.R-178) -le 12 -and [math]::Abs($p.G-181) -le 12 -and [math]::Abs($p.B-182) -le 12) { $gray++ } else { $other++ }
            }
        }
        $bmp.Dispose()
        $tot = $gray + $other
        if ($tot -eq 0) { return $null }
        $ratio = [math]::Round(100*$gray/$tot,1)
        $state = if ($ratio -gt 75) { "灰色-未激活" } elseif ($ratio -lt 25) { "彩色-已激活" } else { "混合" }
        $top = $tally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        return [pscustomobject]@{ 状态=$state; 灰色占比=$ratio; 采样=$tot; 主色=$(if($top){$top.Key}else{"n/a"}) }
    } catch { return $null }
}

$preFile  = $latestShots | Where-Object { $_.Name -like "*01-loaded-full*" } | Select-Object -First 1
$postFile = $latestShots | Where-Object { $_.Name -like "*after-*" } | Select-Object -First 1
$preA  = if ($preFile)  { Analyze-Button $preFile.FullName }  else { $null }
$postA = if ($postFile) { Analyze-Button $postFile.FullName } else { $null }

# ---------- 结论 ----------
$verdict = "无法判定"; $vcolor = "#b8860b"; $vreason = ""
if ($preA -and $postA) {
    if ($postA.状态 -eq "彩色-已激活" -and $preA.状态 -eq "灰色-未激活") {
        $verdict = "疑似签到成功"; $vcolor = "#1a7f37"
        $vreason = "按钮由【灰色-未激活】变为【彩色-已激活】，说明点击被页面接受"
    } elseif ($postA.状态 -eq "灰色-未激活" -and $preA.状态 -eq "灰色-未激活") {
        $verdict = "按钮无变化"; $vcolor = "#b8860b"
        $vreason = "点击前后按钮都是灰色。可能原因: 点击未生效 / 未到考勤时段 / 按钮激活后不变色"
    } else {
        $verdict = "状态异常，需人工看图"; $vcolor = "#b8860b"
        $vreason = "点击前=$($preA.状态)($($preA.灰色占比)%)  点击后=$($postA.状态)($($postA.灰色占比)%)"
    }
} elseif (-not $postFile) {
    $verdict = "没有点击后的截图"; $vcolor = "#c00"
    $vreason = "脚本可能在点击前就退出了 —— 请看下方日志找原因"
} else {
    $vreason = "截图分析失败"
}

# 日志里的关键词
$keyLog = $runLog | Where-Object { $_ -match "ERROR|WARN|失败|未就绪|点击|按钮状态|结果:" }

# ---------- 生成 HTML ----------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">')
[void]$sb.AppendLine('<title>查寝签到 自检报告</title>')
[void]$sb.AppendLine('<style>')
[void]$sb.AppendLine('body{font-family:"Microsoft YaHei",system-ui,sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px;line-height:1.6}')
[void]$sb.AppendLine('h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 10px;color:#9ad;border-bottom:1px solid #2a2f3a;padding-bottom:6px}')
[void]$sb.AppendLine('.card{background:#171a21;border:1px solid #2a2f3a;border-radius:10px;padding:16px;margin:12px 0}')
[void]$sb.AppendLine('.verdict{font-size:20px;font-weight:700;padding:16px;border-radius:10px;background:#171a21;border-left:6px solid ' + $vcolor + ';color:' + $vcolor + '}')
[void]$sb.AppendLine('.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px}')
[void]$sb.AppendLine('img{max-width:100%;border-radius:8px;border:1px solid #2a2f3a;cursor:zoom-in;display:block}')
[void]$sb.AppendLine('pre{background:#0b0d11;border:1px solid #2a2f3a;border-radius:8px;padding:12px;overflow:auto;font-size:12px;max-height:420px;white-space:pre-wrap;word-break:break-all}')
[void]$sb.AppendLine('.k{color:#8a94a6;font-size:13px}.v{font-size:15px;font-weight:600}')
[void]$sb.AppendLine('.row{display:flex;gap:28px;flex-wrap:wrap}.col{min-width:150px}')
[void]$sb.AppendLine('.bad{color:#ff6b6b}.good{color:#4ade80}.warn{color:#fbbf24}')
[void]$sb.AppendLine('.cap{font-size:12px;color:#8a94a6;margin-top:6px}')
[void]$sb.AppendLine('</style></head><body>')
[void]$sb.AppendLine('<h1>智能查寝 · 自动签到自检报告</h1>')
[void]$sb.AppendLine("<div class='k'>生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; 运行批次: $(HtmlEnc $runTime)</div>")

[void]$sb.AppendLine("<div class='verdict'>$verdict<div style='font-size:13px;font-weight:400;color:#c9d1d9;margin-top:8px'>$(HtmlEnc $vreason)</div></div>")

# 关键指标
[void]$sb.AppendLine('<h2>关键指标</h2><div class="card"><div class="row">')
[void]$sb.AppendLine("<div class='col'><div class='k'>点击前按钮</div><div class='v'>$(if($preA){HtmlEnc $preA.状态}else{'无截图'})</div><div class='k'>$(if($preA){"灰色占比 $($preA.灰色占比)%  主色 $($preA.主色)"})</div></div>")
[void]$sb.AppendLine("<div class='col'><div class='k'>点击后按钮</div><div class='v'>$(if($postA){HtmlEnc $postA.状态}else{'无截图'})</div><div class='k'>$(if($postA){"灰色占比 $($postA.灰色占比)%  主色 $($postA.主色)"})</div></div>")
$hasClick = ($runLog | Where-Object { $_ -match "点击【签到按钮】" }).Count
$hasRefill = ($runLog | Where-Object { $_ -match "第 \d+ 次尝试" }).Count
$hasErr = ($runLog | Where-Object { $_ -match "\[ERROR\]" }).Count
[void]$sb.AppendLine("<div class='col'><div class='k'>执行点击</div><div class='v'>$(if($hasClick -gt 0){"<span class='good'>是 ($hasClick 次)</span>"}else{"<span class='bad'>否</span>"})</div><div class='k'>重试轮次 $hasRefill</div></div>")
[void]$sb.AppendLine("<div class='col'><div class='k'>错误行数</div><div class='v'>$(if($hasErr -eq 0){"<span class='good'>0</span>"}else{"<span class='bad'>$hasErr</span>"})</div></div>")
[void]$sb.AppendLine('</div></div>')

# 截图
[void]$sb.AppendLine('<h2>截图</h2><div class="grid">')
if ($latestShots.Count -eq 0) {
    [void]$sb.AppendLine('<div class="card">没有截图</div>')
} else {
    foreach ($s in $latestShots) {
        $rel = "shots/" + $s.Name
        [void]$sb.AppendLine("<div class='card'><img src='$(HtmlEnc $rel)' onclick=`"window.open(this.src)`"><div class='cap'>$(HtmlEnc $s.Name) · $([int]($s.Length/1024))KB · $($s.LastWriteTime.ToString('HH:mm:ss'))</div></div>")
    }
}
[void]$sb.AppendLine('</div>')

# 关键日志
[void]$sb.AppendLine('<h2>关键日志（含 ERROR/WARN/点击/按钮状态）</h2><div class="card"><pre>')
if ($keyLog.Count -eq 0) { [void]$sb.AppendLine('(无关键日志)') }
else { foreach ($l in $keyLog) { [void]$sb.AppendLine((HtmlEnc $l)) } }
[void]$sb.AppendLine('</pre></div>')

# 完整日志
[void]$sb.AppendLine('<h2>完整运行日志</h2><div class="card"><pre>')
if ($runLog.Count -eq 0) { [void]$sb.AppendLine('(无日志)') }
else { foreach ($l in $runLog) { [void]$sb.AppendLine((HtmlEnc $l)) } }
[void]$sb.AppendLine('</pre></div>')

[void]$sb.AppendLine('</body></html>')

$sb.ToString() | Set-Content -Path $OutFn -Encoding UTF8
Write-Host "报告已生成: $OutFn" -ForegroundColor Green
Write-Host "  运行批次: $runTime"
Write-Host "  结论: $verdict" -ForegroundColor Cyan
Write-Host "  $vreason"
Write-Host "  截图数: $($latestShots.Count)"

if (-not $NoOpen) {
    Start-Process $OutFn
}
