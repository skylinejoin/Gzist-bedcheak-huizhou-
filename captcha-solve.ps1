<#
  算式验证码识别器 v2（连通域分割 + 多字体模板匹配 + 磁盘缓存 + 孔洞破平手）
  ================================================================
  v2 改动（2026-09-26 晚, 按用户要求提高精度/优化时长）:
    1. LockBits 整图读取替代逐像素 GetPixel —— 热求解 3.7s -> ~0.3s
    2. 模板磁盘缓存 templates.cache —— 冷启动 20s -> ~0.3s（字体/尺寸/算法版本变更自动重建）
    3. 自适应中点阈值: 字形与模板统一按「前景-背景灰度中点」二值化,
       消除旧版(字形lum<245 vs 模板lum<128)掩码偏肥问题 -> Jaccard 判别力更强
    4. 孔洞数破平手: 8=2孔/6,9,0=1孔, top1-top2 分差小且同为形近数字时用拓扑结构裁决
    5. 第三渲染尺寸 44px, 模板覆盖更细
  公共 API 不变: Invoke-CaptchaSolve(Bitmap) -> @{ok; expr; ans; minScore; minMargin; glyphs}
  失败语义不变: 识别不可信返回 ok=$false, 调用方应刷新重试, 绝不瞎填。
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ---------- 字符集与字体 ----------
$script:Charset   = @('0','1','2','3','4','5','6','7','8','9','*','+','-','=')
$script:FontNames = @(
    "Arial", "Arial Bold", "Times New Roman", "Times New Roman Bold",
    "Courier New", "Courier New Bold", "Verdana", "Tahoma", "Georgia",
    "Trebuchet MS", "Calibri", "Cambria", "Segoe UI", "Microsoft Sans Serif",
    "Comic Sans MS", "Impact", "Arial Narrow", "Book Antiqua", "Century Gothic",
    "Garamond", "Rockwell", "Sylfaen"
)
$script:FontSizes  = @(22, 34, 44)
$script:BoxW = 40; $script:BoxH = 40
$script:AlgoVer = "v2-20260926"

# 孔洞数期望(仅用于数字形近破平手; 4 因开/闭口两种字体形态不参与)
$script:HoleExpect = @{ '0' = 1; '6' = 1; '8' = 2; '9' = 1 }

# ---------- LockBits 灰度提取 ----------
function Get-LumBytes([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($w * $h * 4)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    [void]$bmp.UnlockBits($data)
    $lum = New-Object byte[] ($w * $h)
    $j = 0
    for ($i = 0; $i -lt $lum.Length; $i++) {
        # Format32bppArgb 小端: B,G,R,A
        $lum[$i] = [byte]((0.299 * $raw[$j + 2]) + (0.587 * $raw[$j + 1]) + (0.114 * $raw[$j]))
        $j += 4
    }
    return ,$lum    # ⚠️ 逗号包裹: 防止 PS 把 byte[] 展开成管道上的单个元素
}

# ---------- 掩码工具 ----------
function New-Mask([int]$w, [int]$h) { return @{ w = $w; h = $h; bits = New-Object bool[] ($w * $h); count = 0 } }

function Set-MaskBit($m, [int]$x, [int]$y, [bool]$v) {
    $i = $y * $m.w + $x
    if ($v -and -not $m.bits[$i]) { $m.count++ }
    if (-not $v -and $m.bits[$i]) { $m.count-- }
    $m.bits[$i] = $v
}

# 自适应中点阈值: thr = min + (255-min)/2 —— 字形与模板统一「50% 边缘」语义
function Get-AdaptiveThreshold($lum, [int]$offset, [int]$w, [int]$h, [int]$stride) {
    $min = 255
    for ($y = 0; $y -lt $h; $y++) {
        $row = $offset + $y * $stride
        for ($x = 0; $x -lt $w; $x++) {
            $v = $lum[$row + $x]
            if ($v -lt $min) { $min = $v }
        }
    }
    return [int]($min + (255 - $min) / 2)
}

function Get-MaskFromLum($lum, [int]$offset, [int]$w, [int]$h, [int]$stride, [int]$thr) {
    $m = New-Mask $w $h
    for ($y = 0; $y -lt $h; $y++) {
        $row = $offset + $y * $stride
        for ($x = 0; $x -lt $w; $x++) {
            if ($lum[$row + $x] -lt $thr) { Set-MaskBit $m $x $y $true }
        }
    }
    return $m
}

# 保持纵横比缩放掩码到 BoxW x BoxH(居中, 90% 边距)
function Convert-MaskToBox($m) {
    $out = New-Mask $script:BoxW $script:BoxH
    if ($m.count -eq 0) { return $out }
    $minX = $m.w; $minY = $m.h; $maxX = -1; $maxY = -1
    for ($y = 0; $y -lt $m.h; $y++) {
        for ($x = 0; $x -lt $m.w; $x++) {
            if ($m.bits[$y * $m.w + $x]) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return $out }
    $cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1
    $scale = [Math]::Min(($script:BoxW * 0.9) / $cw, ($script:BoxH * 0.9) / $ch)
    $dw = [Math]::Max(1, [int][Math]::Round($cw * $scale))
    $dh = [Math]::Max(1, [int][Math]::Round($ch * $scale))
    $ox = [int](($script:BoxW - $dw) / 2); $oy = [int](($script:BoxH - $dh) / 2)
    for ($y = 0; $y -lt $dh; $y++) {
        $sy = [Math]::Min($ch - 1, [int]($y / $scale))
        for ($x = 0; $x -lt $dw; $x++) {
            $sx = [Math]::Min($cw - 1, [int]($x / $scale))
            if ($m.bits[($minY + $sy) * $m.w + ($minX + $sx)]) { Set-MaskBit $out ($ox + $x) ($oy + $y) $true }
        }
    }
    return $out
}

function Get-Jaccard($a, $b) {
    $inter = 0; $uni = 0
    $n = $a.w * $a.h
    $ab = $a.bits; $bb = $b.bits
    for ($i = 0; $i -lt $n; $i++) {
        $x = $ab[$i]; $y = $bb[$i]
        if ($x -and $y) { $inter++ }
        if ($x -or $y) { $uni++ }
    }
    if ($uni -eq 0) { return 0.0 }
    return $inter / $uni
}

# 孔洞数: 从紧裁掩码边界泛洪背景, 未触及的背景连通区 = 孔(面积过滤)
function Get-HoleCount($m) {
    if ($m.count -eq 0) { return 0 }
    $w = $m.w; $h = $m.h
    $seen = New-Object bool[] ($w * $h)
    $stack = New-Object System.Collections.Generic.Stack[int]
    # 边界背景入栈
    for ($x = 0; $x -lt $w; $x++) {
        # ⚠️ PS 数组字面量陷阱: @(0, $h - 1) 会被解析成 ((0,$h) - 1) —— 逗号比减号绑定更紧
        foreach ($y in @(0, ($h - 1))) {
            $i = $y * $w + $x
            if (-not $m.bits[$i] -and -not $seen[$i]) { $seen[$i] = $true; $stack.Push($i) }
        }
    }
    for ($y = 0; $y -lt $h; $y++) {
        foreach ($x in @(0, ($w - 1))) {
            $i = $y * $w + $x
            if (-not $m.bits[$i] -and -not $seen[$i]) { $seen[$i] = $true; $stack.Push($i) }
        }
    }
    while ($stack.Count -gt 0) {
        $i = $stack.Pop()
        $cx = $i % $w; $cy = [int]($i / $w)
        foreach ($d in @(-1, 1, -$w, $w)) {
            $j = $i + $d
            if ($j -lt 0 -or $j -ge ($w * $h)) { continue }
            if ($d -eq -1 -and $cx -eq 0) { continue }
            if ($d -eq 1 -and $cx -eq ($w - 1)) { continue }
            if ($seen[$j] -or $m.bits[$j]) { continue }
            $seen[$j] = $true
            $stack.Push($j)
        }
    }
    # 剩余背景 = 孔, 按面积聚类
    $holes = 0
    $minArea = [Math]::Max(6, [int]($m.count * 0.06))
    for ($start = 0; $start -lt ($w * $h); $start++) {
        if ($seen[$start] -or $m.bits[$start]) { continue }
        $area = 0
        $stack.Push($start); $seen[$start] = $true
        while ($stack.Count -gt 0) {
            $i = $stack.Pop(); $area++
            $cx = $i % $w; $cy = [int]($i / $w)
            foreach ($d in @(-1, 1, -$w, $w)) {
                $j = $i + $d
                if ($j -lt 0 -or $j -ge ($w * $h)) { continue }
                if ($d -eq -1 -and $cx -eq 0) { continue }
                if ($d -eq 1 -and $cx -eq ($w - 1)) { continue }
                if ($seen[$j] -or $m.bits[$j]) { continue }
                $seen[$j] = $true
                $stack.Push($j)
            }
        }
        if ($area -ge $minArea) { $holes++ }
    }
    return $holes
}

# ---------- 模板: 构建 / 磁盘缓存 ----------
$script:CacheFn = Join-Path $PSScriptRoot "templates.cache"

function Get-CacheVersionHash {
    $s = $script:AlgoVer + "|" + ($script:FontNames -join ',') + "|" + ($script:FontSizes -join ',') + "|" + $script:BoxW + "x" + $script:BoxH
    $h = 0
    foreach ($ch in $s.ToCharArray()) { $h = (($h * 31) + [int]$ch) % 2147483647 }
    return $h
}

function ConvertFrom-BoxedToBytes($m) {
    # 40x40 位图 -> 200 字节
    $bytes = New-Object byte[] ([int]($script:BoxW * $script:BoxH / 8))
    for ($y = 0; $y -lt $script:BoxH; $y++) {
        for ($x = 0; $x -lt $script:BoxW; $x++) {
            if ($m.bits[$y * $script:BoxW + $x]) {
                $bi = $y * $script:BoxW + $x
                $bytes[[int]($bi / 8)] = $bytes[[int]($bi / 8)] -bor (1 -shl ($bi % 8))
            }
        }
    }
    return ,$bytes   # ⚠️ 逗号包裹: 防止 byte[] 被展开(曾导致缓存文件只有 16KB/应 195KB)
}

function ConvertFrom-BytesToBoxed($bytes) {
    $m = New-Mask $script:BoxW $script:BoxH
    for ($bi = 0; $bi -lt ($script:BoxW * $script:BoxH); $bi++) {
        if (($bytes[[int]($bi / 8)] -band (1 -shl ($bi % 8))) -ne 0) {
            $m.bits[$bi] = $true; $m.count++
        }
    }
    return $m
}

# ---------- popcount 位运算匹配(比逐 bool 比较快 ~8 倍) ----------
$script:PopTab = $null
function Init-PopTab {
    if ($script:PopTab) { return }
    $tab = New-Object byte[] 256
    for ($i = 0; $i -lt 256; $i++) {
        $n = 0; $v = $i
        while ($v -gt 0) { $n += ($v -band 1); $v = $v -shr 1 }
        $tab[$i] = $n
    }
    $script:PopTab = $tab
}
function Get-PackedPop($bytes) {
    Init-PopTab
    $p = 0
    foreach ($b in $bytes) { $p += $script:PopTab[$b] }
    return $p
}
function Get-JaccardPacked($gBytes, [int]$gPop, $tBytes, [int]$tPop) {
    # 快速拒绝: min/max 比值即 Jaccard 上限
    $hi = if ($gPop -gt $tPop) { $gPop } else { $tPop }
    if ($hi -eq 0) { return 0.0 }
    $lo = if ($gPop -gt $tPop) { $tPop } else { $gPop }
    if (($lo / $hi) -lt 0.5) { return 0.0 }
    $inter = 0
    for ($i = 0; $i -lt 200; $i++) {
        $x = $gBytes[$i] -band $tBytes[$i]
        if ($x -ne 0) { $inter += $script:PopTab[$x] }
    }
    $uni = $gPop + $tPop - $inter
    if ($uni -eq 0) { return 0.0 }
    return $inter / $uni
}

function Build-Templates {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($ch in $script:Charset) {
        foreach ($fn in $script:FontNames) {
            foreach ($pt in $script:FontSizes) {
                try {
                    $fs = if ($fn -like "* Bold") { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
                    $face = $fn -replace ' Bold$', ''
                    $font = New-Object System.Drawing.Font($face, $pt, $fs)
                    $size = [System.Windows.Forms.TextRenderer]::MeasureText($ch, $font)
                    $w = $size.Width + 8; $h = $size.Height + 8
                    $bmp = New-Object System.Drawing.Bitmap($w, $h)
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.Clear([System.Drawing.Color]::White)
                    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
                    $g.DrawString($ch, $font, [System.Drawing.Brushes]::Black, 4, 4)
                    $g.Dispose(); $font.Dispose()
                    $lum = Get-LumBytes $bmp
                    $bmp.Dispose()
                    $thr = Get-AdaptiveThreshold $lum 0 $w $h $w
                    $mask = Get-MaskFromLum $lum 0 $w $h $w $thr
                    if ($mask.count -gt 0) {
                        $boxed = Convert-MaskToBox $mask
                        [void]$list.Add(@{ ch = $ch; font = "$fn@$pt"; mask = $boxed })
                    }
                } catch { }
            }
        }
    }
    return $list
}

function Save-TemplateCache($list) {
    try {
        Init-PopTab
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([byte[]](0x47,0x43,0x50,0x54,0x33,0x00))   # "GCPT3": 内嵌 pop, 加载零计算
        $bw.Write([int](Get-CacheVersionHash))
        $bw.Write([int]$list.Count)
        foreach ($t in $list) {
            $bw.Write([string]$t.ch)
            $bw.Write([string]$t.font)
            $packed = [byte[]](ConvertFrom-BoxedToBytes $t.mask)
            $bw.Write($packed)
            $pop = 0
            foreach ($b in $packed) { $pop += $script:PopTab[$b] }
            $bw.Write([int]$pop)
        }
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($script:CacheFn, $ms.ToArray())
        $bw.Dispose(); $ms.Dispose()
        return $true
    } catch {
        Write-Host "[cache-save-FAIL] $($_.Exception.Message)"
        return $false
    }
}

function Load-TemplateCache {
    try {
        if (-not (Test-Path $script:CacheFn)) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($script:CacheFn)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $br = New-Object System.IO.BinaryReader($ms)
        $magic = $br.ReadBytes(6)
        if (($magic[0] -ne 0x47) -or ($magic[1] -ne 0x43) -or ($magic[2] -ne 0x50) -or ($magic[3] -ne 0x54)) { $br.Close(); return $null }
        if ($magic[4] -ne 0x33) { $br.Close(); return $null }   # 只认 GCPT3
        $ver = $br.ReadInt32()
        if ($ver -ne (Get-CacheVersionHash)) { $br.Close(); return $null }
        $n = $br.ReadInt32()
        $list = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $n; $i++) {
            $ch = $br.ReadString()
            $font = $br.ReadString()
            $bits = $br.ReadBytes([int]($script:BoxW * $script:BoxH / 8))
            $pop = $br.ReadInt32()
            [void]$list.Add(@{ ch = $ch; font = $font; bits = $bits; pop = $pop })
        }
        $br.Close(); $ms.Dispose()
        if ($list.Count -eq 0) { return $null }
        return $list
    } catch {
        Write-Host "[cache-load-FAIL] $($_.Exception.Message) @ 行$($_.InvocationInfo.ScriptLineNumber)"
        return $null
    }
}

function Get-Templates {
    if ($script:TplCache) { return $script:TplCache }
    Init-PopTab
    $list = Load-TemplateCache
    if ($null -eq $list) {
        $list = Build-Templates
        [void](Save-TemplateCache $list)
    }
    # 统一为位压缩格式: bytes(200B) + pop(墨水像素数) —— 匹配走位运算
    # ⚠️ 哈希表键检查必须用方括号索引: PSObject.Properties 不枚举哈希表的用户键
    # GCPT3 起缓存内嵌 pop -> 加载零计算(旧版每条逐字节计数, 924 条要 15~25s)
    $cache = @{}
    foreach ($t in $list) {
        $bytes = $null; $pop = 0
        if ($null -ne $t['bits']) {
            $bytes = [byte[]]$t['bits']
        } else {
            $bytes = [byte[]](ConvertFrom-BoxedToBytes $t['mask'])
        }
        if ($null -ne $t['pop']) { $pop = [int]$t['pop'] } else { $pop = Get-PackedPop $bytes }
        if (-not $cache.ContainsKey($t.ch)) { $cache[$t.ch] = New-Object System.Collections.Generic.List[object] }
        [void]$cache[$t.ch].Add(@{ ch = $t.ch; font = $t.font; bytes = $bytes; pop = $pop })
    }
    $script:TplCache = $cache
    return $cache
}

# ---------- 连通域 -> 字符序列 ----------
function Get-GlyphsFromLum($lum, [int]$w, [int]$h, [int]$lumThr) {
    # 连通域(4邻接, ink = lum < lumThr)
    $visited = New-Object bool[] ($w * $h)
    $stack = New-Object System.Collections.Generic.Stack[int]
    $comps = New-Object System.Collections.Generic.List[object]
    $total = $w * $h
    for ($start = 0; $start -lt $total; $start++) {
        if ($lum[$start] -ge $lumThr -or $visited[$start]) { continue }
        $stack.Push($start); $visited[$start] = $true
        $pix = New-Object System.Collections.Generic.List[int]
        while ($stack.Count -gt 0) {
            $i = $stack.Pop(); $pix.Add($i)
            $cx = $i % $w; $cy = [int]($i / $w)
            foreach ($d in @(-1, 1, -$w, $w)) {
                $j = $i + $d
                if ($j -lt 0 -or $j -ge $total) { continue }
                if ($d -eq -1 -and $cx -eq 0) { continue }
                if ($d -eq 1 -and $cx -eq ($w - 1)) { continue }
                if ($visited[$j] -or $lum[$j] -ge $lumThr) { continue }
                $visited[$j] = $true
                $stack.Push($j)
            }
        }
        if ($pix.Count -ge 6) {
            $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
            foreach ($i in $pix) {
                $cx = $i % $w; $cy = [int]($i / $w)
                if ($cx -lt $minX) { $minX = $cx }
                if ($cx -gt $maxX) { $maxX = $cx }
                if ($cy -lt $minY) { $minY = $cy }
                if ($cy -gt $maxY) { $maxY = $cy }
            }
            [void]$comps.Add(@{ minX = $minX; minY = $minY; maxX = $maxX; maxY = $maxY; n = $pix.Count })
        }
    }
    if ($comps.Count -eq 0) { return @() }
    # 按 minX 排序(必须脚本块+强转: Sort-Object 直接对哈希表属性会排错)
    $sorted = @($comps | Sort-Object -Property { [int]$_.minX })
    $glyphs = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($c in $sorted) {
        if ($null -eq $cur) { $cur = @{ minX = $c.minX; minY = $c.minY; maxX = $c.maxX; maxY = $c.maxY }; continue }
        if ($c.minX -le $cur.maxX - 1) {
            if ($c.maxX -gt $cur.maxX) { $cur.maxX = $c.maxX }
            if ($c.minY -lt $cur.minY) { $cur.minY = $c.minY }
            if ($c.maxY -gt $cur.maxY) { $cur.maxY = $c.maxY }
        } else {
            [void]$glyphs.Add($cur)
            $cur = @{ minX = $c.minX; minY = $c.minY; maxX = $c.maxX; maxY = $c.maxY }
        }
    }
    if ($null -ne $cur) { [void]$glyphs.Add($cur) }
    # 相邻字形间隙过小 -> 合并(处理 0/8 封闭字断裂)
    $gapThr = [Math]::Max(6, [int]($w * 0.025))
    $mergedGl = New-Object System.Collections.Generic.List[object]
    foreach ($g in $glyphs) {
        if ($mergedGl.Count -gt 0) {
            $prev = $mergedGl[$mergedGl.Count - 1]
            if (($g.minX - $prev.maxX) -le $gapThr) {
                if ($g.maxX -gt $prev.maxX) { $prev.maxX = $g.maxX }
                if ($g.minY -lt $prev.minY) { $prev.minY = $g.minY }
                if ($g.maxY -gt $prev.maxY) { $prev.maxY = $g.maxY }
                continue
            }
        }
        [void]$mergedGl.Add(@{ minX = $g.minX; minY = $g.minY; maxX = $g.maxX; maxY = $g.maxY })
    }
    # 每字形: 自适应中点阈值提取掩码 -> 标准化
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($gl in $mergedGl) {
        $gw = $gl.maxX - $gl.minX + 1; $gh = $gl.maxY - $gl.minY + 1
        $off = $gl.minY * $w + $gl.minX
        $thr = Get-AdaptiveThreshold $lum $off $gw $gh $w
        $mask = Get-MaskFromLum $lum $off $gw $gh $w $thr
        [void]$out.Add(@{ x = $gl.minX; w = $gw; h = $gh; raw = $mask; boxed = (Convert-MaskToBox $mask) })
    }
    return $out
}

# ---------- 识别主入口 ----------
function Invoke-CaptchaSolve([System.Drawing.Bitmap]$bmp) {
    try {
        $tpl = Get-Templates
        $w = $bmp.Width; $h = $bmp.Height
        $lum = Get-LumBytes $bmp
        # 全局粗阈值只用于分割(找组件), 每字形内部再做自适应细阈值
        $glyphs = @(Get-GlyphsFromLum $lum $w $h 245)
        if ($glyphs.Count -lt 3 -or $glyphs.Count -gt 6) {
            return @{ ok = $false; reason = "字符数异常($($glyphs.Count))" }
        }
        $chars = New-Object System.Collections.Generic.List[object]
        foreach ($g in $glyphs) {
            # 字形一次性位压缩; 匹配走 popcount 位运算
            $gBytes = ConvertFrom-BoxedToBytes $g.boxed
            $gPop = [int]$g.boxed['count']
            $perChar = @{}
            foreach ($ch in $script:Charset) {
                if (-not $tpl.ContainsKey($ch)) { continue }
                $bs = 0.0
                foreach ($t in $tpl[$ch]) {
                    $s = Get-JaccardPacked $gBytes $gPop $t.bytes $t.pop
                    if ($s -gt $bs) { $bs = $s }
                }
                $perChar[$ch] = $bs
            }
            $ranked = @($perChar.GetEnumerator() | Sort-Object -Property { [double]$_.Value } -Descending)
            $bestCh = $ranked[0].Key; $bestS = [double]$ranked[0].Value
            $secondS = if ($ranked.Count -gt 1) { [double]$ranked[1].Value } else { 0.0 }
            # 孔洞数破平手: top1/top2 同为形近数字且分差小 -> 拓扑裁决
            if (($ranked.Count -gt 1) -and (($bestS - $secondS) -lt 0.06)) {
                $c1 = [string]$ranked[0].Key; $c2 = [string]$ranked[1].Key
                if ($script:HoleExpect.ContainsKey($c1) -and $script:HoleExpect.ContainsKey($c2)) {
                    $holes = Get-HoleCount $g.boxed
                    $e1 = [int]$script:HoleExpect[$c1]; $e2 = [int]$script:HoleExpect[$c2]
                    if (($e1 -ne $holes) -and ($e2 -eq $holes)) {
                        $tmpS = $bestS; $bestS = $secondS; $secondS = $tmpS; $bestCh = $c2
                    }
                }
            }
            [void]$chars.Add(@{ ch = $bestCh; score = $bestS; margin = ($bestS - $secondS) })
        }
        $expr = ($chars | ForEach-Object { $_.ch }) -join ''
        $m = [regex]::Match($expr, '^(\d)([+\-*])(\d)=?$')
        if (-not $m.Success) {
            return @{ ok = $false; reason = "结构不匹配"; expr = $expr; detail = ($chars | ForEach-Object { "$($_.ch):$([Math]::Round($_.score,2))" }) -join ' ' }
        }
        $minScore = 1.0; $minMargin = 1.0
        for ($i = 0; $i -lt 4; $i++) {
            if ($i -lt $chars.Count) {
                if ($chars[$i].score -lt $minScore) { $minScore = $chars[$i].score }
                if ($chars[$i].margin -lt $minMargin) { $minMargin = $chars[$i].margin }
            }
        }
        $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[3].Value
        $ans = switch ($m.Groups[2].Value) {
            '+' { $a + $b }
            '-' { $a - $b }
            '*' { $a * $b }
        }
        return @{ ok = $true; expr = "$a$($m.Groups[2].Value)$b"; ans = [string]$ans; minScore = [Math]::Round($minScore, 3); minMargin = [Math]::Round($minMargin, 3); glyphs = $expr }
    } catch {
        return @{ ok = $false; reason = "异常: $($_.Exception.Message)" }
    }
}

# ---------- 测试模式: 直接运行本脚本即对样本自测(含计时) ----------
if ($MyInvocation.InvocationName -ne '.') {
    $dir = Join-Path $PSScriptRoot "shots\captcha"
    if (-not (Test-Path $dir)) { $dir = Join-Path (Split-Path $PSScriptRoot -Parent) "shots\captcha" }
    $truth = @{
        "sample-01.png" = "5*9"; "sample-02.png" = "0*5"; "sample-03.png" = "5+6"
        "sample-04.png" = "9*2"; "sample-05.png" = "5+9"; "sample-06.png" = "6+0"
        "sample-07.png" = "4*6"; "sample-08.png" = "8*6"; "sample-09.png" = "9*2"
        "sample-10.png" = "5+0"; "sample-11.png" = "7*1"; "sample-12.png" = "2*8"
    }
    $hit = 0; $tot = 0; $tsum = 0
    Get-ChildItem $dir -Filter "sample-*.png" | Sort-Object Name | ForEach-Object {
        $tot++
        $bmp = New-Object System.Drawing.Bitmap($_.FullName)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { $r = Invoke-CaptchaSolve $bmp } catch { $r = @{ ok = $false; reason = "EXC: $($_.Exception.Message)" } }
        $sw.Stop(); $tsum += $sw.ElapsedMilliseconds
        $bmp.Dispose()
        $name = $_.Name
        $t = $truth[$name]
        $okFlag = if ($t -and $r.ok -and $r.expr -eq $t) { "OK" } else { "X" }
        if ($okFlag -eq "OK") { $hit++ }
        $got = if ($r.ok) { "$($r.expr)=$($r.ans) score=$($r.minScore)" } else { "失败($($r.reason)) $($r.detail)" }
        ("{0}  真值={1,-5} 识别={2,-24} {3} ({4}ms)" -f $name, $t, $got, $okFlag, $sw.ElapsedMilliseconds) | Write-Host
    }
    ""
    "命中 $hit / $tot   平均 $([int]($tsum / [Math]::Max(1,$tot))) ms/张"
}
