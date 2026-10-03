<#
  检查最近一次签到运行的结果
  ================================================================
  用法: powershell -ExecutionPolicy Bypass -File verify-run.ps1
         powershell -ExecutionPolicy Bypass -File verify-run.ps1 -All

  判断依据:
    1. 读取 signin.log 里最近一次运行的日志
    2. 找最新一次运行的截图
    3. 分析【签到按钮】区域的颜色:
         灰色 RGB(178,181,182)  -> 未激活/未响应
         其他颜色(绿/蓝/红)      -> 按钮状态已改变 => 点击生效
    4. 给出结论与后续建议
#>
[CmdletBinding()]
param(
    [switch]$All
)

$ErrorActionPreference = "Continue"
$Root    = $PSScriptRoot
$LogFn   = Join-Path $Root "signin.log"
$ShotDir = Join-Path $Root "shots"

Add-Type -AssemblyName System.Drawing

function Write-Head($t) { Write-Host ""; Write-Host "===== $t =====" -ForegroundColor Cyan }

# ---------- 1. 日志 ----------
Write-Head "最近一次运行日志"
if (Test-Path $LogFn) {
    $lines = Get-Content $LogFn -Encoding UTF8
    # 从最后一个 "开始" 标记起
    $startIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match "====.*开始.*====") { $startIdx = $i; break }
    }
    if ($startIdx -ge 0) {
        $runLines = $lines[$startIdx..($lines.Count-1)]
        $runLines | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  (未找到运行记录)"
    }
} else {
    Write-Host "  日志文件不存在: $LogFn"
}

# ---------- 2. 截图 ----------
Write-Head "截图文件"
$shots = @()
if (Test-Path $ShotDir) {
    $shots = Get-ChildItem $ShotDir -Filter "*.png" |
             Sort-Object LastWriteTime -Descending
}
if ($shots.Count -eq 0) {
    Write-Host "  没有截图" -ForegroundColor Yellow
    exit 1
}

# 按时间分组: 文件名前缀 yyyyMMdd-HHmmss
$prefixes = $shots | ForEach-Object { ($_.Name -split '-')[0..1] -join '-' } | Select-Object -Unique
$latestPrefix = $prefixes | Select-Object -First 1
Write-Host "  最新一组时间戳: $latestPrefix"
$latestShots = $shots | Where-Object { $_.Name -like "$latestPrefix*" }
$latestShots | ForEach-Object { Write-Host ("    {0}  ({1}KB)" -f $_.Name, [int]($_.Length/1024)) }

# 找点击后的截图(全屏)
$afterShot = $latestShots | Where-Object { $_.Name -like "*after-*" } | Select-Object -First 1
if (-not $afterShot) {
    Write-Host ""
    Write-Host "  未找到 after-* 截图(点击后) —— 可能脚本在点击前就退出了" -ForegroundColor Yellow
    $preShot = $latestShots | Where-Object { $_.Name -like "*01-loaded*" -and $_.Name -notlike "*full*" } | Select-Object -First 1
    if ($preShot) { Write-Host "  参考点击前截图: $($preShot.Name)" }
    exit 2
}
Write-Host ""
Write-Host "  分析点击后截图: $($afterShot.Name)" -ForegroundColor White

# ---------- 3. 定位按钮并分析颜色 ----------
$bmp = New-Object System.Drawing.Bitmap($afterShot.FullName)
Write-Host "  图尺寸: $($bmp.Width)x$($bmp.Height)"

# 按钮在屏幕上的大致位置: 窗口(60,40) + 网页(121~294, 384~563)
# 先扫描确定实际位置(避免标题栏高度差异)
$gray = @{R=178;G=181;B=182}
function Is-Gray($p) {
    return ([math]::Abs($p.R-$gray.R) -le 8 -and [math]::Abs($p.G-$gray.G) -le 8 -and [math]::Abs($p.B-$gray.B) -le 8)
}

# 在窗口区域内逐行找最宽的灰色段(即按钮直径所在行)
$best = $null
for ($y = 40; $y -lt [math]::Min(1000, $bmp.Height); $y += 4) {
    $xs = @()
    for ($x = 60; $x -lt 500; $x += 2) {
        if (Is-Gray $bmp.GetPixel($x,$y)) { $xs += $x }
    }
    if ($xs.Count -gt 30) {
        $w = $xs[-1] - $xs[0]
        if ($null -eq $best -or $w -gt $best.W) {
            $best = [pscustomobject]@{ Y=$y; X0=$xs[0]; X1=$xs[-1]; W=$w }
        }
    }
}

Write-Host ""
if ($best) {
    Write-Host "  发现灰色圆形区域: 最宽行 Y=$($best.Y)  X $($best.X0)~$($best.X1)  宽=$($best.W)" -ForegroundColor White
    Write-Host "  >>> 按钮仍是【灰色】= 未激活或点击未生效" -ForegroundColor Yellow
    Write-Host "      (若运行时间在 21:00-23:40 之间，则说明点击没被页面接受)" -ForegroundColor Yellow
    $verdict = "灰色-未生效"
} else {
    # 没有灰色圆 => 按钮颜色变了 => 点击生效
    Write-Host "  未发现灰色圆形按钮 => 按钮颜色已改变" -ForegroundColor Green
    # 采样原按钮中心区域的颜色
    $cx = 60 + 208; $cy = 40 + 474
    $found = $false
    foreach ($dy in 0,-20,20,-40,40) {
        foreach ($dx in 0,-20,20,-40,40) {
            $x = $cx + $dx; $y = $cy + $dy
            if ($x -ge 0 -and $y -ge 0 -and $x -lt $bmp.Width -and $y -lt $bmp.Height) {
                $p = $bmp.GetPixel($x,$y)
                if (-not ($p.R -gt 240 -and $p.G -gt 240 -and $p.B -gt 240)) {
                    Write-Host ("    按钮区域采样 ({0},{1}) RGB=({2},{3},{4})" -f $x,$y,$p.R,$p.G,$p.B) -ForegroundColor Green
                    $found = $true
                    break
                }
            }
        }
        if ($found) { break }
    }
    $verdict = "已变色-疑似生效"
}
$bmp.Dispose()

# ---------- 4. 结论 ----------
Write-Head "结论"
Write-Host "  最新运行: $latestPrefix"
Write-Host "  按钮状态: $verdict" -ForegroundColor $(if($verdict -like "已变色*"){"Green"}else{"Yellow"})
Write-Host ""
Write-Host "  截图请人工确认(重点看有没有'签到成功'字样或错误提示):" -ForegroundColor White
$latestShots | Where-Object { $_.Name -like "*01-loaded*" -or $_.Name -like "*after-*" } |
    ForEach-Object { Write-Host "    $($_.FullName)" }
Write-Host ""
Write-Host "  把这些截图发给助手分析，即可判断签到是否真正成功。" -ForegroundColor Cyan
