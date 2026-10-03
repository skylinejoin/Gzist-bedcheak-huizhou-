<#
  模板训练器 —— 从标注语料提取「真实验证码字形」模板
  ================================================================
  用法:
    powershell -ExecutionPolicy Bypass -File train-templates.ps1 -Dir <批次目录> [-Apply]

  语料格式(文件名即标注, 由 login-probe.ps1 预标注 + 人工核对):
    NNNN_<expr编码>.png     例: 0012_5t9.png  (= 5*9)
    编码: * -> t, + -> p, - -> m ; 识别失败的为 u (训练时跳过)

  流程:
    1. 逐图分割字形, 按「表达式位序」自动获得每个字形的字符标签(无需人工逐字标注)
    2. 留出 25% 图像作验证集, 其余进训练集
    3. 训练集字形按字符聚类去重(相似度>=0.93 视为同变体), 每字符最多保留 -Keep 个真实验体
    4. 验证集上对比: 真实模板 vs 现有合成模板 的准确率与速度
    5. 默认只产出 templates-real.cache 供审阅; 加 -Apply 才替换正式 templates.cache
#>
[CmdletBinding()]
param(
    [string]$Dir = "",
    [string]$Out = "",
    [int]$Keep = 10,
    [double]$Novelty = 0.93,
    [switch]$Apply
)
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
if (-not $Dir) { $Dir = Join-Path $Root "shots\captcha" }
if (-not $Out) { $Out = Join-Path $Root "templates-real.cache" }
Add-Type -AssemblyName System.Drawing
. (Join-Path $Root "captcha-solve.ps1")
Init-PopTab

$Decode = @{ 't' = '*'; 'p' = '+'; 'm' = '-' }

# ---------- 1. 收集标注语料 ----------
$files = @(Get-ChildItem $Dir -Filter "*.png" -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) { "目录无 png: $Dir"; exit 1 }
$samples = New-Object System.Collections.Generic.List[object]
$skipped = 0
foreach ($f in $files) {
    if ($f.Name -notmatch '^(\d+)_([0-9ptmpu]{3,4})\.png$') { $skipped++; continue }
    $enc = $Matches[2]
    if ($enc -match 'u') { $skipped++; continue }   # 识别失败未标注
    $label = -join ($enc.ToCharArray() | ForEach-Object { if ($Decode.ContainsKey([string]$_)) { $Decode[[string]$_] } else { $_ } })
    [void]$samples.Add(@{ fn = $f.FullName; name = $f.Name; label = $label })
}
"语料: $($samples.Count) 张标注 / $($files.Count) 个文件 (跳过 $skipped)"
if ($samples.Count -lt 8) { "标注样本太少(至少 8 张), 请先用 login-probe.ps1 -Samples 200 采集"; exit 1 }

# ---------- 2. 分割 + 位序对齐 ----------
$trainSet = New-Object System.Collections.Generic.List[object]
$testSet  = New-Object System.Collections.Generic.List[object]
$idx = 0
$segFail = 0
foreach ($s in $samples) {
    $idx++
    $isTest = (($idx % 4) -eq 0)   # 25% 留出
    try {
        $bmp = New-Object System.Drawing.Bitmap($s.fn)
        $lum = Get-LumBytes $bmp
        $glyphs = @(Get-GlyphsFromLum $lum $bmp.Width $bmp.Height 245)
        $bmp.Dispose()
    } catch { $glyphs = @() }
    $expect = $s.label.Length + 1   # '=' 字形
    if ($glyphs.Count -ne $expect) { $segFail++; continue }
    $item = @{ fn = $s.name; label = $s.label; glyphs = $glyphs }
    if ($isTest) { [void]$testSet.Add($item) } else { [void]$trainSet.Add($item) }
}
"分割成功: 训练 $($trainSet.Count) / 验证 $($testSet.Count) (分割失败 $($segFail) 张)"
if ($trainSet.Count -lt 6) { "有效训练样本不足"; exit 1 }

# ---------- 3. 训练集 -> 真实变体收集 + 贪心去重 ----------
# 字形位序: label 的 3 个字符 + 最后 1 个 '=' 字形 —— 四个都要收进变体!
$variants = @{}
foreach ($item in $trainSet) {
    $lab = $item.label.ToCharArray()
    for ($i = 0; $i -lt $lab.Length; $i++) {
        $ch = [string]$lab[$i]
        $boxed = Convert-MaskToBox $item.glyphs[$i].raw
        $bytes = ConvertFrom-BoxedToBytes $boxed
        if (-not $variants.ContainsKey($ch)) { $variants[$ch] = New-Object System.Collections.Generic.List[object] }
        [void]$variants[$ch].Add(@{ ch = $ch; src = $item.fn; mask = $boxed; bytes = $bytes; pop = (Get-PackedPop $bytes) })
    }
    # 第 4 个字形 = '='
    $boxedEq = Convert-MaskToBox $item.glyphs[$lab.Length].raw
    $bytesEq = ConvertFrom-BoxedToBytes $boxedEq
    if (-not $variants.ContainsKey('=')) { $variants['='] = New-Object System.Collections.Generic.List[object] }
    [void]$variants['='].Add(@{ ch = '='; src = $item.fn; mask = $boxedEq; bytes = $bytesEq; pop = (Get-PackedPop $bytesEq) })
}
# 贪心保留"新颖"变体: 与已保留集合的最大相似度 < Novelty 才收
$kept = @{}
foreach ($ch in ($variants.Keys | Sort-Object)) {
    $keptList = New-Object System.Collections.Generic.List[object]
    foreach ($v in $variants[$ch]) {
        $novel = $true
        foreach ($k in $keptList) {
            if ((Get-JaccardPacked $v.bytes $v.pop $k.bytes $k.pop) -ge $Novelty) { $novel = $false; break }
        }
        if ($novel) {
            [void]$keptList.Add($v)
            if ($keptList.Count -ge $Keep) { break }
        }
    }
    $kept[$ch] = $keptList
}
"真实模板变体统计:"
foreach ($ch in ($kept.Keys | Sort-Object)) { "  '$ch' : $($kept[$ch].Count) 个变体" }

# ---------- 4. 写真实模板缓存(未 Apply 前写到 -Out) ----------
$realList = New-Object System.Collections.Generic.List[object]
foreach ($ch in $kept.Keys) {
    foreach ($v in $kept[$ch]) { [void]$realList.Add(@{ ch = $ch; font = "real:" + $v.src; mask = $v.mask }) }
}
$saveFnBackup = $script:CacheFn
$script:CacheFn = $Out
$okSave = Save-TemplateCache $realList
$script:CacheFn = $saveFnBackup
if ($okSave) { "真实模板缓存已写: $Out ($(($kept.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum) 条)" }
else { "!! 缓存写入失败"; exit 1 }

# ---------- 5. 验证集对比: 真实模板 vs 合成模板 ----------
function Test-Accuracy($cache, $set) {
    $hit = 0; $ms = 0
    foreach ($item in $set) {
        $bmp = New-Object System.Drawing.Bitmap((Join-Path $Dir $item.fn))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lum = Get-LumBytes $bmp
        $glyphs = @(Get-GlyphsFromLum $lum $bmp.Width $bmp.Height 245)
        $expr = ""
        foreach ($g in $glyphs) {
            $best = '?'; $bs = 0.0
            $gBytes = ConvertFrom-BoxedToBytes $g.boxed
            $gPop = $g.boxed['count']
            foreach ($ch in $cache.Keys) {
                foreach ($t in $cache[$ch]) {
                    $s = Get-JaccardPacked $gBytes $gPop $t.bytes $t.pop
                    if ($s -gt $bs) { $bs = $s; $best = $ch }
                }
            }
            $expr += $best
        }
        $sw.Stop(); $ms += $sw.ElapsedMilliseconds
        $bmp.Dispose()
        if ($expr -eq ($item.label + "=")) { $hit++ }
    }
    return @{ hit = $hit; ms = $ms }
}

$realCache = @{}
foreach ($ch in $kept.Keys) {
    $realCache[$ch] = New-Object System.Collections.Generic.List[object]
    foreach ($v in $kept[$ch]) {
        $b = ConvertFrom-BoxedToBytes $v.mask
        [void]$realCache[$ch].Add(@{ bytes = $b; pop = Get-PackedPop $b })
    }
}
$rReal = Test-Accuracy $realCache $testSet

# 合成模板对照(项目根的正式缓存)
$saveFnBackup2 = $script:CacheFn
$script:CacheFn = Join-Path $Root "templates.cache"
$synList = Load-TemplateCache
$script:CacheFn = $saveFnBackup2
$rSyn = $null
if ($synList) {
    $synCache = @{}
    foreach ($t in $synList) {
        if (-not $synCache.ContainsKey($t.ch)) { $synCache[$t.ch] = New-Object System.Collections.Generic.List[object] }
        [void]$synCache[$t.ch].Add(@{ bytes = $t.bits; pop = Get-PackedPop $t.bits })
    }
    $rSyn = Test-Accuracy $synCache $testSet
}

"=== 验证集对比 ($($testSet.Count) 张) ==="
"真实模板: 命中 $($rReal.hit)/$($testSet.Count)   平均 $([int]($rReal.ms / [Math]::Max(1,$testSet.Count))) ms/张"
if ($rSyn) { "合成模板: 命中 $($rSyn.hit)/$($testSet.Count)   平均 $([int]($rSyn.ms / [Math]::Max(1,$testSet.Count))) ms/张" }

if ($Apply) {
    Copy-Item $Out (Join-Path $Root "templates.cache") -Force
    "已替换正式 templates.cache ✓"
} else {
    "审阅无误后加 -Apply 重新运行即可替换正式模板缓存"
}
