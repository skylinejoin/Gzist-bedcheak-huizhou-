<#
  headless(=完全无窗口) 可行性探针  v2
  ================================================================
  阶段1: 用【真实配置目录】验证 headless 下 CDP 可用 / 页面能渲染 / 用户桌面是否出现窗口
  阶段2: 用【影子配置目录】(复制密码库, 但不带 cookie) 逼出登录页,
         在 headless 下点击账号框, 验证 Edge 自动填充是否有效
         —— 这一阶段完全不碰你的真实登录态(影子目录用完即删)

  全程没有任何窗口(headless 不建窗口), 可以开着游戏放心跑。
  结果同时打印到控制台并写入 _ov\headless-probe-result.txt
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $Root "config.json"))) { $Root = $PSScriptRoot }
$cfg = Get-Content (Join-Path $Root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Edge = $cfg.edgePath
if (-not (Test-Path $Edge)) { $Edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
$UADir = Join-Path $Root "edge-userdata"
$report = New-Object System.Collections.Generic.List[string]
function Say($m) { Write-Host $m; [void]$report.Add($m) }
function Save-Report { $report | Set-Content (Join-Path $PSScriptRoot "headless-probe-result.txt") -Encoding UTF8 }

function Kill-AutoEdge([string]$dir) {
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$dir*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 1200
    } catch { }
}
function Get-UserDesktopEdgeWinCount {
    return @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count
}

# ---------- CDP 精简客户端 ----------
$script:Ws = $null; $script:Mid = 0
function Conn([string]$u) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    try { [void]$ws.ConnectAsync([Uri]$u, $ct).Wait(12000) } catch { return $null }
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return $null }
    return $ws
}
function Recv([int]$tmo = 12000) {
    if ($null -eq $script:Ws) { return $null }
    $ct = [System.Threading.CancellationToken]::None
    $ms = New-Object System.IO.MemoryStream
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $tmo) {
        $buf = New-Object byte[] 262144
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
        $task = $script:Ws.ReceiveAsync($seg, $ct)
        $rem = $tmo - $sw.ElapsedMilliseconds; if ($rem -lt 500) { $rem = 500 }
        if (-not $task.Wait([int]$rem)) { return $null }
        $res = $task.Result
        [void]$ms.Write($buf, 0, $res.Count)
        if ($res.EndOfMessage) { break }
    }
    if ($ms.Length -eq 0) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}
function Cdp([string]$m, [hashtable]$p = @{}) {
    if ($null -eq $script:Ws) { return $null }
    $script:Mid++
    $myId = $script:Mid
    $payload = @{ id = $myId; method = $m; params = $p } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ct = [System.Threading.CancellationToken]::None
    try { [void]$script:Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(8000) } catch { return $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $t = Recv -tmo (15000 - $sw.ElapsedMilliseconds)
        if ($null -eq $t) { break }
        try { $o = $t | ConvertFrom-Json } catch { continue }
        if ($o.PSObject.Properties.Name -contains "id" -and $o.id -eq $myId) { return $o }
    }
    return $null
}
function Js([string]$e) {
    $r = Cdp "Runtime.evaluate" @{ expression = $e; returnByValue = $true }
    if ($r -and $r.result -and $r.result.result) { return $r.result.result.value }
    return $null
}
function Start-Headless([string]$profileDir, [int]$port, [string]$url) {
    $a = "--headless=new --remote-debugging-port=$port --user-data-dir=`"$profileDir`" " +
         "--no-first-run --no-default-browser-check --disable-features=Translate " +
         "--window-size=$($cfg.viewport.width),$($cfg.viewport.height) " +
         "--force-device-scale-factor=1 --user-agent=`"$($cfg.userAgent)`" --app=`"$url`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Edge
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.Arguments = $a
    return [System.Diagnostics.Process]::Start($psi)
}
function Wait-CdpPage([int]$port, [int]$timeoutSec) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cdp = $false; $page = $null
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        Start-Sleep -Milliseconds 500
        if (-not $cdp) {
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 2 -ErrorAction Stop; $cdp = $true } catch { }
        } else {
            try {
                $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
                $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.url -notlike '*devtools*' }) | Select-Object -First 1
                if ($page) { break }
            } catch { }
        }
    }
    return @{ cdp = $cdp; page = $page; sec = [int]$sw.Elapsed.TotalSeconds }
}

Say "===== 阶段1: headless 基本可用性(真实配置目录) ====="
Kill-AutoEdge $UADir
$port1 = 9341
$proc = Start-Headless $UADir $port1 $cfg.url
Say "已启动 headless Edge PID=$($proc.Id)（无任何窗口）"
$r1 = Wait-CdpPage $port1 40
Say "① CDP 就绪 = $($r1.cdp)  (耗时 $($r1.sec)s)"
$winCount = Get-UserDesktopEdgeWinCount
Say "   用户桌面带窗口的 Edge 进程数 = $winCount  (headless 期望 0)"
if (-not $r1.cdp -or $null -eq $r1.page) {
    Say "==> headless 起不来, 方案不可行(需要换别的思路)"
    Save-Report
    Kill-AutoEdge $UADir
    exit 1
}
$script:Ws = Conn $r1.page.webSocketDebuggerUrl
Say "② 已连页面: $($r1.page.url)"
if ($cfg.'_定位注入' -and $cfg.'_定位注入'.启用) {
    $gi = $cfg.'_定位注入'
    [void](Cdp "Emulation.setGeolocationOverride" @{ latitude = [double]$gi.纬度; longitude = [double]$gi.经度; accuracy = [int]$gi.精度米 })
    [void](Cdp "Browser.grantPermissions" @{ permissions = @("geolocation"); origin = "https://xsfw.gzist.edu.cn" })
}
$txt = ""
$swT = [System.Diagnostics.Stopwatch]::StartNew()
while ($swT.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 800
    $txt = Js "(function(){return document.body?document.body.innerText.replace(/\s+/g,' '):''})()"
    if ($txt -and ($txt -match "点击签到" -or $txt -match "密码" -or $txt -match "登录")) { break }
}
Say "③ 页面渲染文字: $(if ($txt -and $txt.Length -gt 150) { $txt.Substring(0,150) } else { $txt })"
Say "   视口: $(Js "(function(){return innerWidth+'x'+innerHeight})()")"
Kill-AutoEdge $UADir

# ---------------- 阶段2: 影子配置目录测自动填充 ----------------
Say ""
Say "===== 阶段2: headless 下 Edge 自动填充是否有效(影子目录, 不动真实登录态) ====="
$shadow = Join-Path $env:TEMP "gzist-shadow-profile"
try { if (Test-Path $shadow) { Remove-Item $shadow -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
New-Item -ItemType Directory -Force -Path $shadow | Out-Null
$copied = @()
# 密码库在 <user-data-dir>\Default\ 下; Local State 在根目录
$srcList = @(
    @{ s = (Join-Path $UADir "Local State");                  d = (Join-Path $shadow "Local State") },
    @{ s = (Join-Path $UADir "Default\Login Data");          d = (Join-Path $shadow "Default\Login Data") },
    @{ s = (Join-Path $UADir "Default\Login Data-journal");  d = (Join-Path $shadow "Default\Login Data-journal") },
    @{ s = (Join-Path $UADir "Default\Preferences");         d = (Join-Path $shadow "Default\Preferences") },
    @{ s = (Join-Path $UADir "Default\Login Data For Account"); d = (Join-Path $shadow "Default\Login Data For Account") }
)
foreach ($x in $srcList) {
    if (Test-Path $x.s) {
        try {
            $dd = Split-Path $x.d -Parent
            if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
            Copy-Item $x.s $x.d -Force
            $copied += (Split-Path $x.s -Leaf)
        } catch { }
    }
}
Say "已复制到影子目录: $(if ($copied.Count) { $copied -join ', ' } else { '(无 —— 说明密码库不在这里, 无法测)' })"
if ($copied -notcontains "Login Data") {
    Say "==> 没拿到密码库文件, 阶段2 跳过"
    Save-Report
    exit 0
}
$svc = [uri]::EscapeDataString($cfg.url)
$loginUrl = "https://ids.gzist.edu.cn/lyuapServer/login?service=$svc"
$port2 = 9343
$proc2 = Start-Headless $shadow $port2 $loginUrl
Say "已启动 headless Edge(影子目录) PID=$($proc2.Id)"
$r2 = Wait-CdpPage $port2 40
Say "① CDP 就绪 = $($r2.cdp)"
if (-not $r2.cdp -or $null -eq $r2.page) { Say "==> 影子目录下 headless 起不来"; Save-Report; Kill-AutoEdge $shadow; exit 1 }
$script:Ws = Conn $r2.page.webSocketDebuggerUrl
Say "② 页面: $($r2.page.url)"
$hasUser = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 700
    $hasUser = Js "(function(){return !!document.querySelector('#userName')})()"
    if ($hasUser -eq $true) { break }
}
Say "③ 是否出现登录表单(#userName) = $hasUser"
$filled = $false
if ($hasUser -eq $true) {
    $pt = Js "(function(){var e=document.querySelector('#userName');if(!e)return null;var r=e.getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
    for ($i = 1; $i -le 3; $i++) {
        if ($pt) {
            [void](Cdp "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $pt.x; y = $pt.y })
            Start-Sleep -Milliseconds 80
            [void](Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $pt.x; y = $pt.y; button = "left"; clickCount = 1 })
            Start-Sleep -Milliseconds 80
            [void](Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $pt.x; y = $pt.y; button = "left"; clickCount = 1 })
        }
        Start-Sleep -Milliseconds 1500
        $uLen = Js "(function(){var e=document.querySelector('#userName');return e?e.value.length:-1})()"
        $pLen = Js "(function(){var e=document.querySelector('#password');return e?e.value.length:-1})()"
        Say "   第 $i 次点击账号框后: 账号长度=$uLen  密码长度=$pLen"
        if ($uLen -gt 0 -and $pLen -gt 0) { $filled = $true; break }
    }
    Say ""
    if ($filled) {
        Say "==> 【结论】headless 下自动填充可用  -> 登录态失效时也能全自动且零窗口"
    } else {
        Say "==> 【结论】headless 下自动填充不可用 -> 登录态失效的那晚需要另想办法"
    }
} else {
    Say "==> 登录表单没出现, 阶段2 无法判定"
}
Save-Report
Kill-AutoEdge $shadow
try { Remove-Item $shadow -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Say ""
Say "结果已写入: $(Join-Path $PSScriptRoot 'headless-probe-result.txt')"
