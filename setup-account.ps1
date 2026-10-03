<#
  首次配置向导 —— 录入账号并验证全自动登录
  ================================================================
  给使用者(甲方)的一次性上手向导:
    步骤A  打开自动化 Edge 登录页 -> 使用者手动输入【自己的】账号密码验证码登录
           (关键: Edge 弹出「保存密码?」时务必点【保存】—— 之后的全自动全靠它)
    步骤B  向导自动验证全自动链路: 登出 -> 自动填充 -> 验证码识别 -> 登录成功

  说明: 每日计划任务的注册是【独立的可选步骤】, 需要时运行 install-task.ps1,
        本向导不代办。

  安全说明:
    - 账号密码只存在【使用者本机 Edge 的密码管理器】里, 项目文件不含任何账号
    - 向导只检查输入框「是否有值」, 从不读取/记录密码
    - 验证阶段绝不点击签到按钮
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
$Root   = $PSScriptRoot
$CfgFn  = Join-Path $Root "config.json"
$UADir  = Join-Path $Root "edge-userdata"
$RptFn  = Join-Path $Root "setup-account-result.txt"
Remove-Item $RptFn -Force -ErrorAction SilentlyContinue
# 日志写入: 互斥锁 + 重试 + 静默降级(项目在微信目录等受监视路径时文件可能被短暂锁住)
$script:LogMutex = New-Object System.Threading.Mutex($false, "GZIST-log-setup")
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
# 快速失败: 配置文件必须在, 否则后续全链路无意义
if (-not (Test-Path $CfgFn)) {
    Write-Host "!! 找不到 config.json —— 请确认解压完整(交付包内应包含该文件)" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $CfgFn -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg) {
    Write-Host "!! config.json 内容无效, 向导终止" -ForegroundColor Red
    exit 1
}
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

# ---------- 登录辅助(与 daily-signin2 v3 一致) ----------
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
  try { return c.toDataURL('image/png'); } catch(e) { return 'ERR:' + e.message; }
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

# ================= 向导主流程 =================
Log "=============================================="
Log " 首次配置向导 —— 录入账号并验证全自动登录"
Log "=============================================="
Write-Host ""
Write-Host "  本向导做两件事:" -ForegroundColor Cyan
Write-Host "    A. 打开登录页, 你手动登录【你自己的】账号" -ForegroundColor Cyan
Write-Host "       (Edge 询问【保存密码?】时务必点【保存】!)" -ForegroundColor Yellow
Write-Host "    B. 自动验证: 登出->自动填充->验证码识别->登录" -ForegroundColor Cyan
Write-Host "    ※ 每日任务注册是独立步骤: 需要时运行 install-task.ps1" -ForegroundColor DarkGray
Write-Host ""

$Edge = $cfg.edgePath
if (-not (Test-Path $Edge)) { $Edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
# 关闭占用配置目录的旧实例
try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
} catch { }

$dbgPort = 9337
$vw = $cfg.viewport
Log "步骤A: 打开登录页..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Edge
$psi.UseShellExecute = $false
$psi.Arguments = "--remote-debugging-port=$dbgPort --user-data-dir=`"$UADir`" " +
                 "--no-first-run --no-default-browser-check --disable-features=Translate " +
                 "--window-size=$($vw.width),$($vw.height) --window-position=60,40 " +
                 "--force-device-scale-factor=1 --user-agent=`"$($cfg.userAgent)`" --app=`"$($cfg.url)`""
$proc = [System.Diagnostics.Process]::Start($psi)
Log "  PID=$($proc.Id)"

# 连 CDP
$cdpOk = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/version" -TimeoutSec 3 -ErrorAction Stop; $cdpOk = $true; break } catch { }
}
if (-not $cdpOk) { Log "!! 调试端口未就绪, 向导终止"; exit 1 }
$page = $null
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Milliseconds 600
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

# 等待: 登录表单(未登录) 或 已进学工系统(已登录)
$inForm = $false; $alive = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 900
    $st = Eval-Js "(function(){return {u:location.href, n:document.querySelectorAll('input').length, r:document.readyState}})()"
    if ($st -and $st.n -ge 2 -and $st.r -eq "complete") { $inForm = $true; break }
    if ($st -and ($st.u -match "xsfw\.gzist\.edu\.cn/xsfw/")) { $alive = $true; break }
}
$st2 = Eval-Js "(function(){return location.href})()"
if ($st2 -match "xsfw\.gzist\.edu\.cn/xsfw/") { $alive = $true; $inForm = $false }

if (-not $inForm -and -not $alive) { Log "!! 60s 内未检测到登录页或学工系统, 向导终止"; exit 2 }

if ($alive) {
    Log "  当前已有登录态, 跳过手动登录, 直接进入自动验证"
} else {
    # ---- 步骤A: 等使用者手动登录(最长 10 分钟) ----
    Log "  登录页已就绪 —— 请在弹出的 Edge 窗口里登录【你自己的】账号:"
    Write-Host ""
    Write-Host "  ┌────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  1. 输入账号密码                                │" -ForegroundColor Yellow
    Write-Host "  │  2. 输入验证码, 点【登 录】                      │" -ForegroundColor Yellow
    Write-Host "  │  3. Edge 弹出【保存密码?】时 务必 点【保 存】    │" -ForegroundColor Yellow
    Write-Host "  └────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""
    Log "  等待你完成登录(最长 10 分钟, 只检查是否到达学工系统, 不读取任何输入)..."
    $manualOk = $false
    $swM = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swM.Elapsed.TotalMinutes -lt 10) {
        Start-Sleep -Seconds 3
        $u = Eval-Js "(function(){return location.href})()"
        if ($u -match "xsfw\.gzist\.edu\.cn/xsfw/") { $manualOk = $true; break }
        # 浏览器被关掉就终止
        try {
            $still = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                     Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" }
            if (-not $still) { Log "!! 浏览器已被关闭, 向导终止"; exit 3 }
        } catch { }
    }
    if (-not $manualOk) { Log "!! 10 分钟内未完成登录, 向导终止(可重新运行)"; exit 3 }
    Log "  登录成功 ✓ (等待 $([int]$swM.Elapsed.TotalSeconds)s)"
    Start-Sleep -Seconds 3
}

# ---- 步骤B: 全自动验证(登出->自动填充->识别->登录) ----
Log ""
Log "步骤B: 验证全自动登录(登出会话 -> 自动填充 -> 验证码识别)..."
[void](Send-Cdp "Page.navigate" @{ url = "https://ids.gzist.edu.cn/lyuapServer/logout" })
# 登出完成轮询(不再死等 6s)
$swO = [System.Diagnostics.Stopwatch]::StartNew()
while ($swO.Elapsed.TotalSeconds -lt 6) {
    Start-Sleep -Milliseconds 250
    $u = Eval-Js "(function(){return location.href + ' | ' + document.readyState})()"
    if ($u -match "logout" -and $u -match "complete") { break }
}
[void](Send-Cdp "Page.navigate" @{ url = $cfg.url })

$inForm = $false
$swV = [System.Diagnostics.Stopwatch]::StartNew()
$stable = 0
while ($swV.Elapsed.TotalSeconds -lt 40) {
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
# 登出后仍可能直接进学工系统 -> 密码可能没保存成功
$st3 = Eval-Js "(function(){return location.href})()"
if (-not $inForm) {
    if ($st3 -match "xsfw\.gzist\.edu\.cn/xsfw/") {
        Log "!! 登出后仍直接进入学工系统 —— 会话未失效, 验证无法进行"
        Log "   (这不算失败; 全自动链路会在下次会话自然失效时生效)"
        Log "   建议: 明天白天再运行一次 test-autologin.ps1 做验证"
    } else {
        Log "!! 未检测到登录表单, 验证中断"
    }
    if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
    exit 0
}
Log "  会话已登出, 登录表单出现 -> 验证自动填充与识别..."

$autoOk = $false
$formOk = $false
$swF = [System.Diagnostics.Stopwatch]::StartNew()
while ($swF.Elapsed.TotalSeconds -lt 30) {
    Start-Sleep -Milliseconds 300
    if (Test-FormReady) { $formOk = $true; break }
}
if (-not $formOk) {
    Log "!! 表单未就绪"
} else {
    $filled = $false
    foreach ($afTry in 1..3) {
        [void](Invoke-ClickEl "#userName")
        $swA = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swA.Elapsed.TotalSeconds -lt 3) {
            Start-Sleep -Milliseconds 300
            if (Test-CredFilled) { $filled = $true; break }
        }
        if ($filled) { break }
    }
    if (-not $filled) {
        Log "!! 自动填充未生效 —— 很可能刚才 Edge 询问保存密码时点了【不保存】/直接关闭了弹窗"
        Write-Host ""
        Write-Host "  处理办法(二选一):" -ForegroundColor Yellow
        Write-Host "   1. 重新运行本向导, 手动登录时在 Edge 弹窗点【保存】" -ForegroundColor Yellow
        Write-Host "   2. 或在 Edge 设置 -> 个人资料 -> 密码, 手动添加该网站的账号密码" -ForegroundColor Yellow
    } else {
        Log "  自动填充 ✓ -> 验证码识别循环"
        $capMaxTry = 8
        $confThr = 0.55
        if ($cfg.'_自动登录' -and $cfg.'_自动登录'.PSObject.Properties.Name -contains "验证码最大尝试") { $capMaxTry = [int]$cfg.'_自动登录'.验证码最大尝试 }
        if ($cfg.'_自动登录' -and $cfg.'_自动登录'.PSObject.Properties.Name -contains "置信度阈值") { $confThr = [double]$cfg.'_自动登录'.置信度阈值 }
        $tryN = 0
        while ($tryN -lt $capMaxTry -and -not $autoOk) {
            $tryN++
            $du = Invoke-ExtractLoginCaptcha
            if (-not $du -or $du -like "ERR:*" -or $du -eq "WAIT") {
                Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 600; continue
            }
            $r = Invoke-SolveDataUrl $du
            if (-not $r.ok -or $r.minScore -lt $confThr) {
                Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 600; continue
            }
            Log "  [$tryN/$capMaxTry] 识别: $($r.expr) = $($r.ans)"
            [void](Invoke-ClickEl "#captcha")
            Start-Sleep -Milliseconds 250
            [void](Send-Cdp "Input.insertText" @{ text = $r.ans })
            Start-Sleep -Milliseconds 250
            [void](Invoke-ClickLoginBtn)
            $swL = [System.Diagnostics.Stopwatch]::StartNew()
            while ($swL.Elapsed.TotalSeconds -lt 10) {
                Start-Sleep -Milliseconds 500
                $loc = Eval-Js "(function(){return location.host + ' | ' + document.title})()"
                if ($loc -match "xsfw\.gzist\.edu\.cn|个人查寝") { $autoOk = $true; break }
            }
            if ($autoOk) { break }
            Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 900
        }
    }
}

Log ""
Log "=============================================="
if ($autoOk) {
    Log " 验证通过 ✓✓ —— 你的账号已具备全自动登录能力"
    Log "=============================================="
    Log " 配置完成!"
    Log "   · 账号密码已保存在本机 Edge 密码管理器(项目文件中不含)"
    Log "   · 需要启用每日 21:05 自动签到时, 运行: install-task.ps1"
    Log "   · 随时可演练/体检: test-autologin.ps1"
    Start-Sleep -Seconds 2
    if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
    Start-Sleep -Seconds 1
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    exit 0
} else {
    Log " 验证未通过 —— 见上方日志"
    Log "=============================================="
    Log " Edge 窗口保持打开。请检查:"
    Log "  1. 是否在 Edge 保存密码弹窗点了【保存】"
    Log "  2. 重新运行本向导可重试"
    if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
    exit 4
}
