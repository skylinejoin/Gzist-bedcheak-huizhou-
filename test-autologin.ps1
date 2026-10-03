<#
  全自动登录 端到端演练（不碰签到按钮）
  ================================================================
  目的: 在人守着的时候, 用正式配置目录(edge-userdata)把 v3 自动登录完整走一遍:
        先访问 CAS logout 让登录态失效 -> 打开查寝页 -> 等登录表单 ->
        自动填充(Edge 已存凭据) -> 验证码本地识别 -> 提交 -> 验证跳转成功。

  安全性:
    - 演练【只做登录】: 成功后落在学工系统页面即结束, 不会点击签到按钮。
    - 登出只影响自动化配置目录的会话(不碰你手机/其他浏览器的登录)。
    - 若自动登录失败, 窗口保持打开让你手动登录一次即可恢复, 不影响今晚 21:05 任务
      (届时会话已重新建立; 即使没建立, 主脚本也有同样的人工兜底)。

  用法:
    powershell -ExecutionPolicy Bypass -File test-autologin.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
$Root    = $PSScriptRoot
$CfgFn   = Join-Path $Root "config.json"
$UADir   = Join-Path $Root "edge-userdata"
$RptFn   = Join-Path $Root "autologin-test-result.txt"
Remove-Item $RptFn -Force -ErrorAction SilentlyContinue
# 日志写入: 互斥锁 + 重试 + 静默降级(受监视目录下文件可能被短暂锁住)
$script:LogMutex = New-Object System.Threading.Mutex($false, "GZIST-log-test")
function Log($m) {
    $l = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    Write-Host $l
    $acquired = $false
    try {
        for ($i = 0; $i -lt 5; $i++) {
            try { if ($script:LogMutex.WaitOne(200)) { $acquired = $true; break } } catch { }
            Start-Sleep -Milliseconds 120
        }
        Add-Content -Path $RptFn -Value $l -Encoding UTF8 -ErrorAction Stop
    } catch { } finally {
        if ($acquired) { try { $script:LogMutex.ReleaseMutex() } catch { } }
    }
}
if (-not (Test-Path $CfgFn)) {
    Write-Host "!! 找不到 config.json —— 请确认解压完整(交付包内应包含该文件)" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $CfgFn -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.Drawing
. (Join-Path $Root "captcha-solve.ps1")

# ---------- CDP 客户端 ----------
$script:Cdp = @{ Ws = $null; MsgId = 0 }
function Connect-Cdp([string]$wsUrl) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    [void]$ws.ConnectAsync([Uri]$wsUrl, $ct).Wait(12000)
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return $null }
    return $ws
}
function Receive-CdpMsg([int]$timeoutMs = 15000) {
    if ($null -eq $script:Cdp.Ws) { return $null }
    $ct = [System.Threading.CancellationToken]::None
    $ms = New-Object System.IO.MemoryStream
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $buf = New-Object byte[] 262144
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
        $task = $script:Cdp.Ws.ReceiveAsync($seg, $ct)
        $remain = $timeoutMs - $sw.ElapsedMilliseconds
        if ($remain -lt 500) { $remain = 500 }
        if (-not $task.Wait([int]$remain)) { return $null }
        $res = $task.Result
        [void]$ms.Write($buf, 0, $res.Count)
        if ($res.EndOfMessage) { break }
    }
    if ($ms.Length -eq 0) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}
function Send-Cdp([string]$method, [hashtable]$params = @{}) {
    if ($null -eq $script:Cdp.Ws) { return $null }
    $script:Cdp.MsgId++
    $myId = $script:Cdp.MsgId
    $payload = @{ id = $myId; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ct = [System.Threading.CancellationToken]::None
    try { [void]$script:Cdp.Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(8000) }
    catch { return $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000) {
        $txt = Receive-CdpMsg -timeoutMs (20000 - $sw.ElapsedMilliseconds)
        if ($null -eq $txt) { break }
        try { $obj = $txt | ConvertFrom-Json } catch { continue }
        if ($obj.PSObject.Properties.Name -contains "id" -and $obj.id -eq $myId) { return $obj }
    }
    return $null
}
function Eval-Js([string]$expr) {
    $r = Send-Cdp "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
    if ($r -and $r.result -and $r.result.result) { return $r.result.result.value }
    return $null
}

# ---------- 登录辅助(与 daily-signin2 v3 完全一致的逻辑) ----------
function Invoke-ClickEl([string]$sel) {
    $r = Eval-Js "(function(){var e=document.querySelector('$sel');if(!e)return null;var r=e.getBoundingClientRect();if(!(r.width>0&&r.height>0))return null;return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
    if ($r) {
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $r.x; y = $r.y })
        Start-Sleep -Milliseconds 120
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
        Start-Sleep -Milliseconds 90
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
    }
    return $r
}
function Test-FormReady {
    $v = Eval-Js "(function(){var u=document.querySelector('#userName'),p=document.querySelector('#password');if(!u||!p)return 0;var ru=u.getBoundingClientRect(),rp=p.getBoundingClientRect();return (ru.width>0&&rp.width>0)?1:0})()"
    return ($v -eq 1)
}
function Test-CredFilled {
    $v = Eval-Js "(function(){var u=document.querySelector('#userName'),p=document.querySelector('#password');return {u:(u?u.value.length:-1),p:(p?p.value.length:-1)}})()"
    return ($v -and $v.u -gt 0 -and $v.p -gt 0)
}
function Invoke-ClickLoginBtn {
    $r = Eval-Js "(function(){var b=[].filter.call(document.querySelectorAll('button'),function(x){return (x.innerText||'').replace(/\s+/g,'')==='登录'})[0];if(!b)b=document.querySelector('button.ant-btn-primary');if(!b)return null;var r=b.getBoundingClientRect();if(!(r.width>0))return null;return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
    if ($r) {
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
        Start-Sleep -Milliseconds 90
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
    }
    return $r
}
function Invoke-ExtractLoginCaptcha {
    $js = @'
(function(){
  var img = document.querySelector('img[src^="data:image"]');
  if (!img) {
    var rx=236, ry=302, rw=118, rh=40;
    [].some.call(document.querySelectorAll('img'), function(el){
      var r = el.getBoundingClientRect();
      if (Math.round(r.x)===rx && Math.round(r.y)===ry && Math.round(r.width)===rw && Math.round(r.height)===rh) { img = el; return true; }
      return false;
    });
  }
  if (!img) return null;
  if (!img.naturalWidth) return 'WAIT';
  var c=document.createElement('canvas'); var s=4;
  c.width=img.naturalWidth*s; c.height=img.naturalHeight*s;
  var ctx=c.getContext('2d'); ctx.imageSmoothingEnabled=false;
  ctx.drawImage(img,0,0,c.width,c.height);
  try { return c.toDataURL('image/png'); } catch(e) { return 'ERR:'+e.message; }
})()
'@
    return Eval-Js $js
}
function Invoke-RefreshLoginCaptcha {
    $r = Eval-Js "(function(){var i=document.querySelector('img[src^=`"data:image`"]');if(!i)return null;var r=i.getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
    if ($r) {
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
        Start-Sleep -Milliseconds 80
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
    }
    [void](Eval-Js "(function(){var i=document.querySelector('img[src^=`"data:image`"]');if(i){try{i.dispatchEvent(new MouseEvent('click',{bubbles:true}))}catch(e){}}})()")
}
function Invoke-SolveDataUrl([string]$dataUrl) {
    try {
        $b64 = $dataUrl -replace '^data:image/png;base64,', ''
        $bytes = [Convert]::FromBase64String($b64)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $bmp = New-Object System.Drawing.Bitmap($ms)
        $r = Invoke-CaptchaSolve $bmp
        $bmp.Dispose(); $ms.Dispose()
        return $r
    } catch {
        return @{ ok = $false; reason = "异常: $($_.Exception.Message)" }
    }
}

# ================= 演练主流程 =================
Log "===== 全自动登录演练开始（只登录, 不签到） ====="
$Edge = $cfg.edgePath
if (-not (Test-Path $Edge)) { $Edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
# 关闭占用配置目录的旧实例
try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
} catch { }

$vw = $cfg.viewport
$vwcfg = $cfg.'_定位注入'
$dbgPort = 9337
Log "步骤1: 启动 Edge(正式配置目录) -> 先访问 CAS 登出使登录态失效..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Edge
$psi.UseShellExecute = $false
$psi.Arguments = "--remote-debugging-port=$dbgPort --user-data-dir=`"$UADir`" " +
                 "--no-first-run --no-default-browser-check --disable-features=Translate " +
                 "--window-size=$($vw.width),$($vw.height) --window-position=60,40 " +
                 "--force-device-scale-factor=1 --user-agent=`"$($cfg.userAgent)`" --app=`"https://ids.gzist.edu.cn/lyuapServer/logout`""
$proc = [System.Diagnostics.Process]::Start($psi)
Log "  PID=$($proc.Id)"

# 连 CDP（120ms 盲轮询, 端口一开立即走, 不做首延迟）
$cdpOk = $false
$swC = [System.Diagnostics.Stopwatch]::StartNew()
while ($swC.Elapsed.TotalMilliseconds -lt 20000) {
    Start-Sleep -Milliseconds 120
    try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/version" -TimeoutSec 2 -ErrorAction Stop; $cdpOk = $true; break } catch { }
}
if (-not $cdpOk) { Log "!! 调试端口未就绪"; exit 1 }
$page = $null
while ($swC.Elapsed.TotalSeconds -lt 25) {
    Start-Sleep -Milliseconds 200
    try {
        $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/list" -TimeoutSec 5
        $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "*devtools*" })
        $page = $pages | Where-Object { $_.url -match "gzist\.edu\.cn" } | Select-Object -First 1
        if (-not $page) { $page = $pages | Select-Object -First 1 }
        if ($page) { break }
    } catch { }
}
if (-not $page) { Log "!! 未找到页面目标"; exit 1 }
$raw = Connect-Cdp $page.webSocketDebuggerUrl
if ($raw -is [System.Array]) { $raw = $raw | Where-Object { $_ -is [System.Net.WebSockets.ClientWebSocket] } | Select-Object -First 1 }
if ($null -eq $raw) { Log "!! CDP 连接失败"; exit 1 }
$script:Cdp.Ws = $raw
Log "  CDP 已连接"

# 登出完成轮询(不再死等 6s): URL 出现 logout 且文档加载完成即走, 上限 6s
$swO = [System.Diagnostics.Stopwatch]::StartNew()
while ($swO.Elapsed.TotalSeconds -lt 6) {
    Start-Sleep -Milliseconds 250
    $u = Eval-Js "(function(){return location.href + ' | ' + document.readyState})()"
    if ($u -match "logout" -and $u -match "complete") { break }
}
[void](Send-Cdp "Page.navigate" @{ url = $cfg.url })
Log "步骤2: 已导航到查寝页, 等待跳转结果..."

# 判断: 出现登录表单 = 登录态已失效(可演练); 直接进入学工系统 = 登录态仍有效(演练不成立)
# 300ms 快轮询 + 连续两次同态防抖(防止捕捉到跳转中间态)
$inForm = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stable = 0
while ($sw.Elapsed.TotalSeconds -lt 40) {
    Start-Sleep -Milliseconds 300
    $st = Eval-Js "(function(){return {u:location.href, n:document.querySelectorAll('input').length, r:document.readyState}})()"
    if ($st -and $st.n -ge 2 -and $st.r -eq "complete") {
        $stable++
        if ($stable -ge 2) { $inForm = $true; break }
    } else {
        $stable = 0
    }
    if ($st -and ($st.u -match "xsfw\.gzist\.edu\.cn/xsfw/")) { break }
}
$alive = $false
$st2 = Eval-Js "(function(){return location.href})()"
if ($st2 -match "xsfw\.gzist\.edu\.cn/xsfw/") { $alive = $true }

if ($alive -and -not $inForm) {
    Log "!! 登录态仍然有效(登出未生效或跳过了登录页) —— 本次演练不成立, 会话未受影响"
    Log "   可稍后重试; 不影响任何功能。"
    if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
    exit 0
}
if (-not $inForm) {
    Log "!! 40s 内既未见学工系统也未见登录表单 —— 请看窗口人工检查"
    if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
    exit 2
}
Log "  登录表单已出现(登录态已失效, 演练成立), 等待 $([int]$sw.Elapsed.TotalSeconds)s"

# ===== 自动登录(与 v3 主脚本一致) =====
$loginOk = $false
$capMaxTry = 8
$confThr = 0.55
$formOk = $false
$swF = [System.Diagnostics.Stopwatch]::StartNew()
while ($swF.Elapsed.TotalSeconds -lt 30) {
    Start-Sleep -Milliseconds 300
    if (Test-FormReady) { $formOk = $true; break }
}
if (-not $formOk) {
    Log "!! 30s 内表单未就绪"
} else {
    Log "  表单就绪($([int]$swF.Elapsed.TotalSeconds)s) -> 触发 Edge 自动填充..."
    $filled = $false
    foreach ($afTry in 1..3) {
        [void](Invoke-ClickEl "#userName")
        # 轮询代替固定等待: 填充即走, 上限 3s
        $swA = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swA.Elapsed.TotalSeconds -lt 3) {
            Start-Sleep -Milliseconds 300
            if (Test-CredFilled) { $filled = $true; break }
        }
        if ($filled) { break }
        Log "  自动填充第 $afTry 次未生效(仅查长度, 不读值)"
    }
    if (-not $filled) {
        Log "!! Edge 未自动填充账号密码 —— 这是全自动链路中唯一未经真机验证的环节"
        Log "   请在打开的窗口里手动点一下账号框观察: 是否点击后自动填充?"
    } else {
        Log "  账号密码已自动填充 ✓ -> 验证码识别循环"
        $tryN = 0
        while ($tryN -lt $capMaxTry -and -not $loginOk) {
            $tryN++
            $du = Invoke-ExtractLoginCaptcha
            if (-not $du -or $du -like "ERR:*" -or $du -eq "WAIT") {
                Log "  [$tryN/$capMaxTry] 验证码图提取失败($du) -> 刷新重试"
                Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 1000; continue
            }
            $r = Invoke-SolveDataUrl $du
            if (-not $r.ok -or $r.minScore -lt $confThr) {
                $det = if ($r.ok) { "置信度低($($r.minScore))" } else { $r.reason }
                Log "  [$tryN/$capMaxTry] 识别不可信($det) -> 换一张, 绝不瞎填"
                Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 1000; continue
            }
            Log "  [$tryN/$capMaxTry] 识别: $($r.expr) = $($r.ans)（置信度 $($r.minScore)）"
            [void](Invoke-ClickEl "#captcha")
            Start-Sleep -Milliseconds 250
            [void](Send-Cdp "Input.insertText" @{ text = $r.ans })
            Start-Sleep -Milliseconds 250
            [void](Invoke-ClickLoginBtn)
            $swL = [System.Diagnostics.Stopwatch]::StartNew()
            while ($swL.Elapsed.TotalSeconds -lt 10) {
                Start-Sleep -Milliseconds 500
                $loc = Eval-Js "(function(){return location.host + ' | ' + document.title})()"
                if ($loc -match "xsfw\.gzist\.edu\.cn|个人查寝") { $loginOk = $true; break }
            }
            if ($loginOk) { break }
            Log "  [$tryN/$capMaxTry] 提交后未跳转(验证码可能不对)"
            Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 900
        }
    }
}

Log "==================== 演练结果 =================="
if ($loginOk) {
    Log "结果: 全自动登录成功 ✓✓（会话已恢复, 今晚 21:05 任务不受影响）"
    Log "     演练到此结束 —— 没有也不会点击签到按钮。"
} else {
    Log "结果: 自动登录未成功（exit 3）"
    Log "     Edge 窗口保持打开 —— 请手动完成一次登录恢复会话;"
    Log "     把本文件($RptFn)内容发给助手分析。"
}
if (-not $loginOk) { exit 3 }
# 收尾: 关闭浏览器(会话已建立, cookie 已存盘)
Start-Sleep -Seconds 2
if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
Start-Sleep -Seconds 1
try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Log "浏览器已关闭。演练完成。"
exit 0
