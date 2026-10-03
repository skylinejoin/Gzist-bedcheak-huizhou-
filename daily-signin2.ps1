<#
  每日签到（单会话版）
  ================================================================
  v2 改动（2026-09-26，按用户要求）:
    旧版: 探测登录态(开浏览器) -> 关闭 -> 再开浏览器签到   <- 开两次，浪费时间
    新版: 只启动一次 -> 在同一个会话里判断登录态、等待人工登录、注入定位、点击签到

  v3 改动（2026-09-26，用户解除「不做验证码识别」边界后升级为全自动）:
    登录态失效时不再等人: CDP 驱动自动登录
      - 账号密码: 真实点击账号框触发 Edge 已存凭据自动填充（脚本只查长度, 绝不读取值）
      - 验证码:   提取图片 -> captcha-solve.ps1 本地模板匹配识别算式 -> 求值填入
      - 识别不可信/提交未跳转 -> 刷新验证码重试(默认最多 8 次), 绝不瞎填
      - 任何环节失败 -> 回落 v2 人工登录兜底
    签到弹窗验证码: 出现时同样自动识别（DOM 未经实测, 最佳努力 + 人工兜底）

  流程:
    1. 启动 Edge(自动化配置) 打开查寝页
    2. 轮询窗口标题判断登录态
         ├─ 已登录  -> 直接继续
         └─ 未登录  -> 自动登录(自动填充+验证码识别) -> 成功原地继续 / 失败转人工
    3. 在【同一窗口】注入定位(CDP) -> 等页面就绪
    4. 等按钮激活 -> 点击 -> 读页面文字确认 -> 截图存证
    5. 汇总

  用法:
    powershell -ExecutionPolicy Bypass -File daily-signin2.ps1
    powershell -ExecutionPolicy Bypass -File daily-signin2.ps1 -WaitLoginMin 30
#>
[CmdletBinding()]
param(
    # 等待人工登录的最长分钟数
    [int]$WaitLoginMin = 30
)

$ErrorActionPreference = "Continue"
$Root     = $PSScriptRoot
$LogFn    = Join-Path $Root "signin.log"
$ShotDir  = Join-Path $Root "shots"
$UADir    = Join-Path $Root "edge-userdata"
$ConfigFn = Join-Path $Root "config.json"
if (-not (Test-Path $ShotDir)) { New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null }

# ---------- 配置 ----------
if (-not (Test-Path $ConfigFn)) { Write-Host "找不到 config.json"; exit 1 }
$cfg = Get-Content $ConfigFn -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------- 验证码识别器（v3: 本地模板匹配, 无外部依赖） ----------
# (此处只加载函数; Log 在下方定义, 加载结果由主流程开始后的第一条 Log 记录)
$CaptchaFn = Join-Path $Root "captcha-solve.ps1"
$script:CaptchaLoaded = $false
if (Test-Path $CaptchaFn) {
    . $CaptchaFn    # dot-source 只加载函数; 其内置自测模式在 dot-source 时不触发
    $script:CaptchaLoaded = $true
}

$UseSound = $false
if ($cfg.'_提示' -and $cfg.'_提示'.启用声音) { $UseSound = [bool]$cfg.'_提示'.启用声音 }

# 隐藏模式(2026-09-27 二次修正): 全程不抢前台、不动鼠标、不弹窗。
#   窗口策略: 【屏内 (60,40) + 压到 Z 序最底层 + 不激活】
#     · 屏幕外方案已被实测否决: Chromium 会把 --window-position 钳制回屏内(启动闪现),
#       且屏幕外渲染被节流(1s -> 15s), 兜底升格又把窗口搬到屏幕上 -> 用户看到两次弹窗。
#     · 屏内 + 最底层: 渲染快(1s), 全屏游戏仍盖在上面, 不抢焦点也不挡画面。
#   备注: 若确实想回到屏幕外(并接受渲染变慢), 把 屏幕外隐藏 设为 true。
$script:Hidden = $true
if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "隐藏模式")) {
    $script:Hidden = [bool]$cfg.'_运行'.隐藏模式
}
$script:Offscreen = $false
if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "屏幕外隐藏")) {
    $script:Offscreen = [bool]$cfg.'_运行'.屏幕外隐藏
}
# 隐藏桌面(2026-09-27 最终方案): Edge 的窗口建在另一个桌面, 用户桌面【完全不会出现窗口】。
#   这是唯一能避免"独占全屏游戏被踢出全屏"的办法 —— 最小化创建/压到最底层都挡不住窗口出现本身。
#   自动化全程走 CDP(与桌面无关), 因此功能不受影响; 若隐藏桌面不可用会自动回退普通方式。
$script:HiddenDesktop = $true
if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "隐藏桌面")) {
    $script:HiddenDesktop = [bool]$cfg.'_运行'.隐藏桌面
}
$script:NoWindow = $false    # true = 本次运行 Edge 窗口不在用户桌面(无需窗口句柄)
# 屏幕外模式下的坐标(仅在 屏幕外隐藏=true 时使用)
$script:HiddenPosX = -2000
$script:HiddenPosY = 40
if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "隐藏窗口位置")) {
    $hp = $cfg.'_运行'.隐藏窗口位置
    if ($hp.PSObject.Properties.Name -contains "x") { $script:HiddenPosX = [int]$hp.x }
    if ($hp.PSObject.Properties.Name -contains "y") { $script:HiddenPosY = [int]$hp.y }
}

# 日志写入: 互斥锁 + 重试 + 静默降级
# 教训(2026-09-26 甲方现场): 项目解压在微信接收目录时, 微信/杀毒会短暂锁住 signin.log,
#   Add-Content 直接抛 IOException 刷屏。日志失败绝不能影响签到主流程。
$script:LogMutex = New-Object System.Threading.Mutex($false, "GZIST-signin-log")

# ---------- 单实例守卫(2026-09-29 实测新增) ----------
# 教训: 21:05 那次计划任务同时起了【两个实例】(21:05:02 与 21:05:04), 两个进程抢同一个浏览器页面,
#       导致验证码提交"未跳转"、登录失败, 而且弹出 2 个 PowerShell 窗口。
# 现在: 任何原因(任务重复触发/手动与自动撞车)导致的第二个实例都会立即退出, 绝不互相干扰。
try {
    $mSingle = New-Object System.Threading.Mutex($false, "GZIST-signin-single")
    $gotSingle = $false
    try { $gotSingle = $mSingle.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $gotSingle = $true }
    if (-not $gotSingle) {
        Write-Host "已有另一个签到实例在运行 —— 本次直接退出（避免互相干扰）" -ForegroundColor Yellow
        try { Add-Content -Path (Join-Path $PSScriptRoot "signin.log") -Encoding UTF8 -Value ("{0} [WARN] 已有另一个实例在运行, 本次退出" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) } catch { }
        exit 0
    }
    $script:RunMutex = $mSingle
} catch { }
function Log($m) {
    $l = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), "INFO", $m
    Write-Host $l
    if (-not $LogFn) { return }
    $acquired = $false
    try {
        for ($i = 0; $i -lt 5; $i++) {
            try { if ($script:LogMutex.WaitOne(200)) { $acquired = $true; break } } catch { }
            Start-Sleep -Milliseconds 120
        }
        Add-Content -Path $LogFn -Value $l -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 日志写不进去(文件被锁/目录消失) -> 静默放弃, 控制台已有输出
    } finally {
        if ($acquired) { try { $script:LogMutex.ReleaseMutex() } catch { } }
    }
}

if ($script:CaptchaLoaded) { Log "已加载验证码识别器: captcha-solve.ps1 ✓" }
else { Log "未找到 captcha-solve.ps1 —— 自动登录不可用, 验证码需人工输入" "WARN" }

# ---------- 结束即清理(2026-09-28): 关闭自动化浏览器, 不留任何常驻开销 ----------
# 用户要求: 跑完必须把后台浏览器关掉, 不能有隐藏的内存/CPU 占用。
function Stop-AutoBrowser {
    param([switch]$Quiet)
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" })
        if ($procs.Count -eq 0) {
            if (-not $Quiet) { Log "  收尾: 无需关闭的浏览器进程（已无残留）" }
            return 0
        }
        foreach ($x in $procs) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
        # 最多等 4 秒确认退出
        $swC = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swC.Elapsed.TotalSeconds -lt 4) {
            Start-Sleep -Milliseconds 300
            $left = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                      Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" })
            if ($left.Count -eq 0) { break }
            foreach ($x in $left) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        $still = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" })
        if (-not $Quiet) {
            if ($still.Count -eq 0) { Log "  收尾: 已关闭自动化浏览器 $($procs.Count) 个进程 —— 无残留, 无后台开销 ✓" }
            else { Log "  收尾: 仍有 $($still.Count) 个进程未退出（下次运行会再清理）" "WARN" }
        }
        return $still.Count
    } catch { return -1 }
}
# 任何退出路径(含所有 exit N)都会触发: 保证不留后台浏览器
try {
    $uadirLit = $UADir.Replace("'", "''")
    $cleanupAction = [scriptblock]::Create(@"
try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { `$_.CommandLine -and `$_.CommandLine -like '*$uadirLit*' } |
        ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
"@)
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action $cleanupAction
} catch { }


function Alert-User {
    param([string]$Title, [string]$Message)
    if ($UseSound) {
        try { 1..3 | ForEach-Object { [console]::beep(1000, 220); Start-Sleep -Milliseconds 100 } } catch { }
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host " $Title" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
    foreach ($line in $Message -split "`n") { Write-Host "  $line" -ForegroundColor Yellow }
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host ""
}

# ---------- Win32 ----------
Add-Type -AssemblyName System.Drawing

# ================= Win32 辅助类加载(2026-09-30 结构性加固) =================
# 原实现用 Add-Type -TypeDefinition 在【运行时】编译 C#; PS 5.1 会为此派生 csc.exe(控制台进程),
# 这是整个流程里唯一的控制台子进程, 也是"可能冒出控制台窗口"的最后一点理论可能。
# 现改为: 直接加载【构建期预编译】的 Gzist.Win32.dll —— 纯程序集加载, 不派生任何编译器。
# 于是运行期间只会派生 msedge.exe(GUI/headless) —— 控制台窗口在物理上无从产生。
# 若 DLL 缺失或被安全软件拦截, 自动回退到 gzist-win32.cs 源码编译(功能不变, 仅该次会派生 csc)。
$script:DllPath = Join-Path $PSScriptRoot "Gzist.Win32.dll"
$script:CsPath  = Join-Path $PSScriptRoot "gzist-win32.cs"
$script:Win32Mode = "none"
if (Test-Path $script:DllPath) {
    try {
        # 从【内存】加载: 某些盘符(E:)会被 .NET 视为"远程位置"而拒绝 Add-Type -Path(0x80131515),
        # 读成字节数组再 Assembly.Load 可绕过该路径信任检查。
        $asmBytes = [System.IO.File]::ReadAllBytes($script:DllPath)
        [void][System.Reflection.Assembly]::Load($asmBytes)
        $script:Win32Mode = "DLL(内存加载)"
    } catch {
        Write-Host "预编译 DLL 加载失败($($_.Exception.Message)), 回退源码编译" -ForegroundColor Yellow
        if (Test-Path $script:CsPath) { Add-Type -Path $script:CsPath -ReferencedAssemblies "System.Drawing", "System.Windows.Forms"; $script:Win32Mode = "源码编译(回退)" }
        else { throw "缺少 Gzist.Win32.dll / gzist-win32.cs" }
    }
} elseif (Test-Path $script:CsPath) {
    Add-Type -Path $script:CsPath -ReferencedAssemblies "System.Drawing", "System.Windows.Forms"
    $script:Win32Mode = "源码编译(无DLL)"
} else {
    throw "缺少 Gzist.Win32.dll / gzist-win32.cs —— 无法加载 Win32 辅助类"
}
try { Log ("  Win32 辅助类加载方式: " + $script:Win32Mode) } catch { }
[DW]::SetProcessDPIAware() | Out-Null

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
    $txt = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    [void]$ms.Dispose()
    return $txt
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
function Get-PageText {
    return (Eval-Js "(function(){var t=document.body?document.body.innerText:'';return t.replace(/\s+/g,' ');})()")
}

# ---------- 自动登录辅助（v3, 2026-09-26） ----------
# 原则: 账号密码走 Edge 已存凭据的自动填充, 脚本【只检查长度, 绝不读取/记录值】;
#       验证码本地识别, 识别不可信就刷新重试, 绝不瞎填; 任何环节失败转人工兜底。
function Invoke-ClickEl([string]$sel) {
    # CDP 真实鼠标事件点击元素中心(可信手势, 能触发浏览器自动填充下拉)
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
    # 登录按钮: 优先按文字「登 录」找(CSS module 类名带哈希, 不可依赖), 兜底按主色类名
    $r = Eval-Js "(function(){var b=[].filter.call(document.querySelectorAll('button'),function(x){return (x.innerText||'').replace(/\s+/g,'')==='登录'})[0];if(!b)b=document.querySelector('button.ant-btn-primary');if(!b)return null;var r=b.getBoundingClientRect();if(!(r.width>0))return null;return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
    if ($r) {
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
        Start-Sleep -Milliseconds 90
        [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $r.x; y = $r.y; button = "left"; clickCount = 1 })
    }
    return $r
}
function Invoke-ExtractLoginCaptcha {
    # 登录页验证码图: src 是 data URL; 按 src 特征找, 按位置(236,302 118x40)兜底
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
    # 刷新: 真实点击验证码图中心(React onClick), 再补一次 JS 事件兜底
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

# ---------- 点击方式阶梯(2026-09-27 加固: 页面是 iPhone UA, 按钮可能只认触摸事件) ----------
function Invoke-CdpMouseAt([int]$x, [int]$y) {
    [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $x; y = $y })
    Start-Sleep -Milliseconds 60
    [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $x; y = $y; button = "left"; clickCount = 1 })
    Start-Sleep -Milliseconds 60
    [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $x; y = $y; button = "left"; clickCount = 1 })
}
function Invoke-CdpTouchAt([int]$x, [int]$y) {
    # 触摸点击: 先启用触摸仿真, 再派发 touchStart/touchEnd(可信事件)
    [void](Send-Cdp "Emulation.setTouchEmulationEnabled" @{ enabled = $true; maxTouchPoints = 1 })
    Start-Sleep -Milliseconds 80
    [void](Send-Cdp "Input.dispatchTouchEvent" @{ type = "touchStart"; touchPoints = @(@{ x = $x; y = $y }) })
    Start-Sleep -Milliseconds 70
    [void](Send-Cdp "Input.dispatchTouchEvent" @{ type = "touchEnd"; touchPoints = @() })
    Start-Sleep -Milliseconds 80
}
# 轮询是否已出现成功字样: 成功返回页面文字, 否则 $null
function Get-SignSuccessText([int]$timeoutSec) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        Start-Sleep -Milliseconds 500
        $t = Get-PageText
        if ($t) {
            foreach ($k in $kws) { if ($t -match [regex]::Escape($k)) { return $t } }
        }
    }
    return $null
}
function Invoke-HandleSignCaptcha {
    # 签到【弹窗】验证码(出现频率低, DOM 未经实测 —— 最佳努力, 失败即返回 false 由人工兜底)
    # 返回 true = 已填入答案并点了弹窗内的确认按钮
    $js = @'
(function(){
  var imgs=[].filter.call(document.querySelectorAll('img'),function(im){
    var r=im.getBoundingClientRect();
    if(!(r.width>=40&&r.width<=220&&r.height>=16&&r.height<=90)) return false;
    var s=im.src||'';
    return s.indexOf('data:image')===0 || /captcha|yzm|verify/i.test(s) || /captcha|yzm|verify/i.test(im.className||'');
  });
  if(!imgs.length) return null;
  var im=imgs[imgs.length-1];
  var box=im.closest('div[class*="modal"],div[class*="Modal"],div[class*="dialog"],div[class*="popup"],div[role="dialog"]') || im.parentElement;
  var inp=null, p=im.parentElement;
  while(p && !inp && p!==document.body){ inp=p.querySelector('input[type="text"],input:not([type])'); p=p.parentElement; }
  if(!inp) return null;
  var btn=null;
  var scope=box||document;
  var bs=[].filter.call(scope.querySelectorAll('button'),function(b){var t=(b.innerText||'').replace(/\s+/g,'');return t==='确定'||t==='确认'||t==='提交'});
  if(bs.length) btn=bs[bs.length-1];
  if(!btn) return null;
  var ri=im.getBoundingClientRect(), rn=inp.getBoundingClientRect(), rb=btn.getBoundingClientRect();
  return { ix:Math.round(ri.x), iy:Math.round(ri.y), iw:Math.round(ri.width), ih:Math.round(ri.height),
           nw:im.naturalWidth, nh:im.naturalHeight,
           nx:Math.round(rn.x+rn.width/2), ny:Math.round(rn.y+rn.height/2),
           bx:Math.round(rb.x+rb.width/2), by:Math.round(rb.y+rb.height/2) };
})()
'@
    $m = Eval-Js $js
    if (-not $m) { return $false }
    # 提取图 -> 识别
    $du = Eval-Js @"
(function(){
  var img=document.querySelector('img');
  var imgs=[].filter.call(document.querySelectorAll('img'),function(im){var r=im.getBoundingClientRect();return Math.round(r.x)===$($m.ix)&&Math.round(r.y)===$($m.iy);});
  img=imgs[0]; if(!img||!img.naturalWidth) return null;
  var c=document.createElement('canvas'); var s=4;
  c.width=img.naturalWidth*s; c.height=img.naturalHeight*s;
  var ctx=c.getContext('2d'); ctx.imageSmoothingEnabled=false;
  ctx.drawImage(img,0,0,c.width,c.height);
  try { return c.toDataURL('image/png'); } catch(e) { return null; }
})()
"@
    if (-not $du) { return $false }
    $r = Invoke-SolveDataUrl $du
    if (-not $r.ok) { Log "  弹窗验证码识别失败: $($r.reason)" "WARN"; return $false }
    Log "  弹窗验证码识别: $($r.expr) = $($r.ans)"
    # React 兼容填值(原生 setter + input 事件)
    $okSet = Eval-Js @"
(function(){
  var imgs=[].filter.call(document.querySelectorAll('img'),function(im){var r=im.getBoundingClientRect();return Math.round(r.x)===$($m.ix)&&Math.round(r.y)===$($m.iy);});
  var im=imgs[0]; if(!im) return 0;
  var p=im.parentElement, inp=null;
  while(p && !inp && p!==document.body){ inp=p.querySelector('input[type="text"],input:not([type])'); p=p.parentElement; }
  if(!inp) return 0;
  var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
  setter.call(inp,'$($r.ans)');
  inp.dispatchEvent(new Event('input',{bubbles:true}));
  return 1;
})()
"@
    if ($okSet -ne 1) { return $false }
    Start-Sleep -Milliseconds 300
    [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $m.bx; y = $m.by; button = "left"; clickCount = 1 })
    Start-Sleep -Milliseconds 80
    [void](Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $m.bx; y = $m.by; button = "left"; clickCount = 1 })
    return $true
}

# ================= 主流程 =================
$script:done = $false          # 是否确认签到成功
$script:clicked = $false       # 是否执行过点击
Log "==================== 每日签到（单会话版）开始 ===================="
Log "目标: $($cfg.url)"

# ---- 步骤 1: 启动一次浏览器 ----
$Edge = $cfg.edgePath
if (-not (Test-Path $Edge)) { $Edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }

# ---- 步骤 0(预热复用判定): 21:00 预热任务(prewarm.ps1)已备好浏览器+页面时直接复用 ----
# 复用条件: prewarm.flag 存在且 <20 分钟 + 配置目录 Edge 进程仍在运行
# 复用收益: 跳过 Edge 启动 + 跳转渲染等待(约 10-15s)
$reuse = $false
$prewarmPids = @()
$flagFn = Join-Path $Root "prewarm.flag"
try {
    if (Test-Path $flagFn) {
        $flagAgeMin = ((Get-Date) - (Get-Item $flagFn).LastWriteTime).TotalMinutes
        $running = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                     Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" })
        if ($flagAgeMin -le 20 -and $running.Count -gt 0) {
            $reuse = $true
            $prewarmPids = @($running | ForEach-Object { [int]$_.ProcessId })
            Log "  检测到 $([int]$flagAgeMin) 分钟前的预热实例 -> 复用（跳过启动与跳转等待）"
        }
    }
} catch { }
Remove-Item $flagFn -Force -ErrorAction SilentlyContinue   # flag 一次性消费(无论是否复用)

if (-not $reuse) {
    # 关闭占用配置目录的旧实例（不影响已保存的登录态）
    try {
        $old = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
               Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" }
        if ($old) {
            Log "关闭占用配置目录的旧 Edge 进程: $(($old.ProcessId) -join ',')"
            foreach ($o in $old) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
            # 轮询等进程退出(通常 <1s), 上限 3s
            $swK = [System.Diagnostics.Stopwatch]::StartNew()
            while ($swK.Elapsed.TotalSeconds -lt 3) {
                Start-Sleep -Milliseconds 200
                $left = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" }
                if (-not $left) { break }
            }
        }
    } catch { }

    Log "步骤1: 启动 Edge（只启动这一次）..."
    $vw = $cfg.viewport
    $dbgPort = 9337
    if ($cfg.'_定位注入' -and $cfg.'_定位注入'.调试端口) { $dbgPort = [int]$cfg.'_定位注入'.调试端口 }
    # 窗口坐标从配置读（安全闸门1 会用同一个值校验，避免两处硬编码不一致）
    $winX = 60; $winY = 40
    if ($cfg.'_窗口位置') {
        if ($cfg.'_窗口位置'.PSObject.Properties.Name -contains "x") { $winX = [int]$cfg.'_窗口位置'.x }
        if ($cfg.'_窗口位置'.PSObject.Properties.Name -contains "y") { $winY = [int]$cfg.'_窗口位置'.y }
    }
    # ---- 有效窗口位置 ----
    # 默认(推荐): 屏内配置位置(60,40) + Z序最底层 + 不激活 —— 渲染快且不打扰;
    # 若 屏幕外隐藏=true: 用屏幕外坐标(会被 Chromium 钳制、渲染变慢, 一般不推荐)。
    $effX = $winX; $effY = $winY
    if ($script:Hidden -and $script:Offscreen) { $effX = $script:HiddenPosX; $effY = $script:HiddenPosY }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Edge
    $psi.UseShellExecute = $false
    # 隐藏模式: 以【最小化】方式创建窗口 + 追加 --start-minimized 双保险。
    #   新窗口默认会抢焦点并可能把全屏游戏踢出全屏 —— 最小化创建不会激活。
    $launchMinimized = $false
    $minFlag = ""
    if ($script:Hidden) {
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
        $launchMinimized = $true
        $minFlag = "--start-minimized "
    }
    $psi.Arguments = "--remote-debugging-port=$dbgPort --user-data-dir=`"$UADir`" " +
                     "--no-first-run --no-default-browser-check --disable-features=Translate " +
                     "--disable-background-timer-throttling --disable-backgrounding-occluded-windows " +
                     "--disable-renderer-backgrounding " +
                     "$minFlag--window-size=$($vw.width),$($vw.height) --window-position=$effX,$effY " +
                     "--force-device-scale-factor=1 --user-agent=`"$($cfg.userAgent)`" --app=`"$($cfg.url)`""
    # ================= 启动阶梯(2026-09-28 重构) =================
    # 实测结论: Chromium 在非默认桌面上跑不起来(进程 5~13s 内自行退出, CDP 永不通),
    #   所以"隐藏桌面"方案作废; 40s 回退又会把窗口开到用户桌面上 -> 就是那次弹窗。
    # 新策略: ① headless(Chromium 原生【无任何窗口】模式) 为主
    #         ② 失败才试隐藏桌面
    #         ③ 仍失败 -> 若允许可见窗口才开窗口, 否则【提醒你手动签】, 绝不偷偷弹窗
    $script:AllowVisible = $false
    if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "允许可见窗口兜底")) {
        $script:AllowVisible = [bool]$cfg.'_运行'.允许可见窗口兜底
    }
    if ($env:GZIST_ALLOW_VISIBLE -eq "1") { $script:AllowVisible = $true }   # 手动运行时由 .bat 设置
    $launchMode = "headless"
    if ($cfg.'_运行' -and ($cfg.'_运行'.PSObject.Properties.Name -contains "无窗口模式")) {
        $launchMode = [string]$cfg.'_运行'.无窗口模式
    }

    function Start-HiddenEdge([string]$mode) {
        # 返回 @{ pid; kind } ; kind = headless / desktops / visible / failed
        if ($mode -eq "headless") {
            $a = $psi.Arguments -replace '--start-minimized ', '' -replace '--window-position=[\d\-,]+ ', ''
            $p2 = New-Object System.Diagnostics.ProcessStartInfo
            $p2.FileName = $Edge
            $p2.UseShellExecute = $false
            $p2.CreateNoWindow = $true
            $p2.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $p2.Arguments = "--headless=new " + $a
            try { $pr = [System.Diagnostics.Process]::Start($p2); return @{ pid = [int]$pr.Id; kind = "headless" } }
            catch { return @{ pid = 0; kind = "failed" } }
        }
        if ($mode -eq "desktops") {
            $hdPid = 0
            try { $hdPid = [DW]::LaunchOnHiddenDesktop($Edge, $psi.Arguments, "GZIST-AutoDesk") } catch { $hdPid = -1 }
            if ($hdPid -gt 0) { return @{ pid = [int]$hdPid; kind = "desktops" } }
            return @{ pid = 0; kind = "failed" }
        }
        try { $pr = [System.Diagnostics.Process]::Start($psi); return @{ pid = [int]$pr.Id; kind = "visible" } }
        catch { return @{ pid = 0; kind = "failed" } }
    }

    $script:LaunchKind = "none"
    $script:TriedModes = @()
    $order = @()
    switch ($launchMode) {
        "隐藏桌面" { $order = @("desktops", "headless") }
        "可见窗口" { $order = @("visible") }
        default    { $order = @("headless", "desktops") }
    }
    foreach ($m in $order) {
        $r = Start-HiddenEdge $m
        $script:TriedModes += $m
        if ($r.pid -gt 0) {
            $script:LaunchPid = $r.pid
            $script:LaunchKind = $r.kind
            switch ($r.kind) {
                "headless" { $script:NoWindow = $true; Log "  已用【headless 无窗口模式】启动 PID=$($r.pid) —— 不创建任何窗口" }
                "desktops" { $script:NoWindow = $true; Log "  已启动到【隐藏桌面】PID=$($r.pid)" }
                "visible"  { $script:NoWindow = $false; Log "  PID=$($r.pid)  窗口位置=$effX,$effY  尺寸=$($vw.width)x$($vw.height)（最小化创建, 不抢焦点）" }
            }
            break
        }
        Log "  启动方式 [$m] 失败 -> 尝试下一种" "WARN"
    }
    if ($script:LaunchKind -eq "none") {
        if ($script:AllowVisible) {
            Log "  全部无窗口方式失败, 按配置允许可见窗口 -> 用可见方式启动" "WARN"
            $r = Start-HiddenEdge "visible"
            if ($r.pid -gt 0) { $script:LaunchPid = $r.pid; $script:LaunchKind = "visible"; $script:NoWindow = $false }
        }
        if ($script:LaunchKind -eq "none") {
            Log "!! 无法以任何方式启动浏览器 —— 本次放弃（不弹窗）" "WARN"
            try {
                Set-Content -Path (Join-Path $Root "需要人工签到.txt") -Encoding UTF8 -Value @(
                    ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
                    "无法以无窗口方式启动浏览器，本次未签到。",
                    "请手动双击 2-立即签到一次.bat 完成签到（手动运行允许开窗口）。"
                )
            } catch { }
            try { 1..6 | ForEach-Object { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 450 } } catch { }
            exit 9
        }
    }
} else {
    $dbgPort = 9337
    if ($cfg.'_定位注入' -and $cfg.'_定位注入'.调试端口) { $dbgPort = [int]$cfg.'_定位注入'.调试端口 }
    $winX = 60; $winY = 40
    if ($cfg.'_窗口位置') {
        if ($cfg.'_窗口位置'.PSObject.Properties.Name -contains "x") { $winX = [int]$cfg.'_窗口位置'.x }
        if ($cfg.'_窗口位置'.PSObject.Properties.Name -contains "y") { $winY = [int]$cfg.'_窗口位置'.y }
    }
    # 复用预热实例: 位置规则同上; 预热实例也是隐藏桌面启动的 -> 无需窗口句柄
    $effX = $winX; $effY = $winY
    if ($script:Hidden -and $script:Offscreen) { $effX = $script:HiddenPosX; $effY = $script:HiddenPosY }
    if ($script:HiddenDesktop) { $script:NoWindow = $true }
}

# ---- 步骤 2: 找窗口 + 连接 CDP ----
# 【关键】只认【使用我们配置目录的 Edge 进程】的窗口。
#   反面教训: 之前用标题匹配(含 "Microsoft Edge")会抓到你自己的浏览器窗口或别的 Edge 窗口，
#   导致后续截图/点击全部作用在错误的窗口上。（2026-09-26 修复）
Log "步骤2: 定位窗口并连接调试端口..."

# 【优化】优先用"我们刚启动的 PID"找窗口 —— 零外部依赖、最快、且天然不会抓错。
#   WMI 只作兜底（它在受限环境下可能被拒绝访问）。
#
# ⚠️ 2026-09-26 踩坑: 必须保证 $pidsPreferred 是【扁平】的 int 数组。
#    若写成 @() 再 += 一个"返回数组的函数"，会变成嵌套数组(Object[] 套 int[])，
#    此时 $arr -contains $pid 恒为 False —— 会让整条窗口识别链全部失效。
#    验证: @(,@(1,2)) -contains 1  =>  False
function Get-ProfilePids {
    $ids = New-Object System.Collections.ArrayList
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -like "*$UADir*") { [void]$ids.Add([int]$p.ProcessId) }
        }
    } catch { }
    return $ids.ToArray()      # 始终返回扁平的 int[]
}

# 扁平初始化(不用 += 拼接函数返回值)
$pidsPreferred = New-Object System.Collections.ArrayList
if ($proc -and $proc.Id) { [void]$pidsPreferred.Add([int]$proc.Id) }
# 预热复用时: 种子 = 预热实例的 PID 列表
foreach ($pp in $prewarmPids) {
    $dup = $false
    foreach ($x in $pidsPreferred) { if ([int]$x -eq [int]$pp) { $dup = $true; break } }
    if (-not $dup) { [void]$pidsPreferred.Add([int]$pp) }
}

function Test-PidInList {
    # ⚠️ 参数名绝不能用 $Pid —— 那是 PowerShell 内置只读变量，赋值会抛
    #    "Cannot overwrite variable Pid because it is read-only or constant"。（已踩两次）
    param($List, [int]$ProcId)
    foreach ($x in $List) { if ([int]$x -eq $ProcId) { return $true } }
    return $false
}

# 【2026-09-26 深夜 重构】窗口定位 / CDP 端口 / 页面目标 三件事合并进【同一个轮询循环】,
#   谁先就绪谁先就位, 互不阻塞 —— 旧版是三段串行等待(窗口 45s 上限 -> CDP 20s -> 页面 15s),
#   即便各项都很快, 串行也白白多等 1-2 个轮询周期。
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$h = [IntPtr]::Zero
$wmiUsed = $false
$allWins = @()
$cdpOk = $false
$page = $null
while ($sw.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 200
    # (1) 窗口定位
    if ($h -eq [IntPtr]::Zero) {
        $allWins = [DW]::AllVisibleTitled()
        # ① 启动 PID / 预热 PID 优先(最快最准)
        if ($pidsPreferred.Count -gt 0) {
            foreach ($w in $allWins) {
                if (Test-PidInList $pidsPreferred ([int][DW]::PidOf($w))) { $h = $w; Log "  经 PID 命中窗口"; break }
            }
            # ② WMI 兜底(3s 后仍无窗口才查一次)
            if ($h -eq [IntPtr]::Zero -and -not $wmiUsed -and $sw.Elapsed.TotalSeconds -ge 3) {
                $wmiUsed = $true
                $fromWmi = Get-ProfilePids
                if ($fromWmi.Count -gt 0) {
                    Log "  经 WMI 找到配置目录进程 $($fromWmi.Count) 个: $(($fromWmi | ForEach-Object { $_ }) -join ',')"
                    foreach ($x in $fromWmi) { if (-not (Test-PidInList $pidsPreferred ([int]$x))) { [void]$pidsPreferred.Add([int]$x) } }
                } else {
                    Log "  WMI 未找到（可能不可用），转为按标题识别本窗口" "WARN"
                }
            }
            if ($h -eq [IntPtr]::Zero) {
                foreach ($w in $allWins) {
                    if (Test-PidInList $pidsPreferred ([int][DW]::PidOf($w))) { $h = $w; break }
                }
            }
        }
        # ③ 标题兜底(6s 后仍无窗口才启用, 仅匹配学工系统相关标题)
        if ($h -eq [IntPtr]::Zero -and $sw.Elapsed.TotalSeconds -ge 6) {
            foreach ($w in $allWins) {
                $tt = [DW]::Title($w)
                if ($tt -match "gzist\.edu\.cn|身份认证管理平台|安全中心|个人查寝") { $h = $w; Log "  经标题兜底命中窗口"; break }
            }
        }
    }
    # (2) CDP 端口就绪
    if (-not $cdpOk) {
        try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/version" -TimeoutSec 2 -ErrorAction Stop; $cdpOk = $true } catch { }
    } elseif ($null -eq $page) {
        # (3) 页面目标
        try {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/list" -TimeoutSec 5
            $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "*devtools*" })
            # 【收紧】优先选学工系统/认证页的目标；避免多页面时选错
            $page = $pages | Where-Object { $_.url -match "gzist\.edu\.cn" } | Select-Object -First 1
            if (-not $page) { $page = $pages | Select-Object -First 1 }
            if ($page -and $pages.Count -gt 1) { Log "  调试端口有 $($pages.Count) 个页面目标，已选中: $($page.url)" }
        } catch { }
    }
    # 窗口 + 端口 + 页面 三者齐备 -> 退出循环(无窗口模式不需要窗口句柄)
    if (($h -ne [IntPtr]::Zero -or $script:NoWindow) -and $cdpOk -and $null -ne $page) { break }

    # ============ 【失败切换】(2026-09-28 重构) ============
    # 无窗口模式起不来时的判定: ① 启动进程已退出 -> 立刻切换(实测 ~5-13s 就会自行退出)
    #                            ② 或 30s 仍无 CDP/页面 -> 切换
    # 切换顺序: 换另一种无窗口方式 -> 都不行则按配置决定(允许可见窗口 / 提醒你手动签, 绝不偷偷弹窗)
    if ($script:NoWindow -and (-not $cdpOk -or $null -eq $page)) {
        $pidAlive = $false
        if ($script:LaunchPid -gt 0) { $pidAlive = (@(Get-Process -Id $script:LaunchPid -ErrorAction SilentlyContinue).Count -gt 0) }
        $giveUp = (-not $pidAlive) -or ($sw.Elapsed.TotalSeconds -ge 30)
        if ($giveUp) {
            Log "  [$($script:LaunchKind)] 起不来（进程存活=$pidAlive, 已等 $([int]$sw.Elapsed.TotalSeconds)s）-> 换下一种方式" "WARN"
            # 清掉失败实例, 避免占用配置目录
            try {
                Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 1200
            } catch { }
            # 选下一种未试过的无窗口方式
            $next = $null
            foreach ($m in @("headless", "desktops")) {
                if ($script:TriedModes -notcontains $m) { $next = $m; break }
            }
            if ($next) {
                $script:TriedModes += $next
                $r2 = Start-HiddenEdge $next
                if ($r2.pid -gt 0) {
                    $script:LaunchPid = $r2.pid; $script:LaunchKind = $r2.kind
                    Log "  已改用 [$next] 启动 PID=$($r2.pid)"
                    $cdpOk = $false; $page = $null; $sw.Restart()
                }
            } elseif ($script:AllowVisible) {
                Log "  所有无窗口方式均失败, 按配置允许可见窗口 -> 用可见方式启动（会短暂打扰前台）" "WARN"
                $r3 = Start-HiddenEdge "visible"
                if ($r3.pid -gt 0) {
                    $script:LaunchPid = $r3.pid; $script:LaunchKind = "visible"; $script:NoWindow = $false
                    $cdpOk = $false; $page = $null; $sw.Restart()
                }
            } else {
                Log "!! 无窗口方式全部失败, 且配置不允许可见窗口 —— 本次不签到（绝不弹窗）" "WARN"
                try {
                    Set-Content -Path (Join-Path $Root "需要人工签到.txt") -Encoding UTF8 -Value @(
                        ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
                        "无法以无窗口方式启动浏览器，本次未签到。",
                        "请手动双击 2-立即签到一次.bat 完成签到（手动运行允许可见窗口）。"
                    )
                } catch { }
                try { 1..6 | ForEach-Object { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 450 } } catch { }
                if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
                exit 9
            }
        }
    }
}
if ($h -eq [IntPtr]::Zero -and -not $script:NoWindow) {
    Log "未能定位到自动化窗口 —— 放弃" "WARN"
    exit 2
}
if ($script:NoWindow) {
    Log "  [$($script:LaunchKind) 无窗口模式] 无需窗口句柄: CDP 已连(端口 $dbgPort), 页面目标已就位 —— 你的桌面上没有任何窗口"
}
Log "  窗口 HWND=$h PID=$(if ($h -ne [IntPtr]::Zero) { [DW]::PidOf($h) } else { 'n/a(隐藏桌面)' })"
# 隐藏模式: 先"非激活还原"(SW_SHOWNOACTIVATE), 再摆位 —— 全程不激活。
#   ⚠️ 隐藏桌面模式不做任何摆位: 那个桌面上没有用户, 摆位毫无意义, 而且拿不到句柄。
if ($script:Hidden -and -not $script:NoWindow) {
    $vw0 = $cfg.viewport
    $rp = [DW]::Rect($h)
    if ([DW]::IsMinimized($h) -or $rp[0] -le -30000) {
        [DW]::ShowNoActivateOnly($h)          # 还原显示, 但不激活
        Start-Sleep -Milliseconds 150
    }
    if ($script:Offscreen) {
        [void][DW]::ShowNoActivateAt($h, $effX, $effY, [int]$vw0.width, [int]$vw0.height)
        Start-Sleep -Milliseconds 250
        Log "  [隐藏模式] 窗口已摆到屏幕外 $effX,$effY（未抢前台）: $([DW]::RectStr($h))"
    } else {
        # 屏内 + 压到 Z 序最底层 + 不激活: 渲染不再被节流, 全屏游戏仍盖在它上面
        [void][DW]::ShowNoActivateAtBottom($h, $effX, $effY, [int]$vw0.width, [int]$vw0.height)
        Start-Sleep -Milliseconds 250
        Log "  [隐藏模式] 窗口已在 $effX,$effY 显示并压到 Z 序最底层（SWP_NOACTIVATE+HWND_BOTTOM, 未抢前台）: $([DW]::RectStr($h))"
    }
}
if ($page) {
    $raw = Connect-Cdp $page.webSocketDebuggerUrl
    if ($raw -is [System.Array]) { $raw = $raw | Where-Object { $_ -is [System.Net.WebSockets.ClientWebSocket] } | Select-Object -First 1 }
    if ($null -ne $raw) {
        $script:Cdp.Ws = $raw
        Log "  CDP 已连接: $($page.url)"
        # 记录页面视口尺寸: 隐藏桌面下窗口尺寸不确定, 而按钮定位已改为 DOM 特征优先,
        #   这里留痕便于事后核对布局是否正常(2026-09-27 加固)
        $vpNow = Eval-Js "(function(){return innerWidth+'x'+innerHeight+' dpr='+devicePixelRatio})()"
        if ($vpNow) { Log "  页面视口: $vpNow" }
    }
}
if (-not $cdpOk -or $null -eq $script:Cdp.Ws) { Log "  调试端口/页面未就绪（定位注入将不可用）" "WARN" }

# ---- 步骤 2.5: 【关键优化】页面加载前就注入定位 ----
# 为什么: 若等页面加载完再注入，就必须刷新页面才能生效 —— 等于加载两次，
#   实测浪费约 25 秒(首次加载 14s + 刷新等待 11s)。
#   注入是浏览器级设置，对后续导航持续有效，因此提前注入即可，
#   页面自然加载完就带着正确坐标，无需刷新。（2026-09-26 优化）
$geoOn = ($cfg.'_定位注入' -and $cfg.'_定位注入'.启用)
$injectedEarly = $false
$needReload = $false
if ($geoOn -and $null -ne $script:Cdp.Ws) {
    $gi = $cfg.'_定位注入'
    $r = Send-Cdp "Emulation.setGeolocationOverride" @{
        latitude = [double]$gi.纬度; longitude = [double]$gi.经度; accuracy = [int]$gi.精度米
    }
    if ($r -and $r.result) {
        $injectedEarly = $true
        Log "步骤2.5: 定位已在页面加载前注入（无需刷新）: $($gi.纬度), $($gi.经度)"
        [void](Send-Cdp "Browser.grantPermissions" @{ permissions = @("geolocation"); origin = "https://xsfw.gzist.edu.cn" })
    } else {
        Log "步骤2.5: 提前注入失败，稍后兜底注入" "WARN"
    }
}

# ---- 步骤 3: 判断登录态（在同一会话里） ----
# 关键: 打开页面时会先经过 CAS 登录页(ids.gzist.edu.cn)，这是【正常的跳转过程】，
#   不能一看到登录页就判定"需要登录" —— 那样会白等用户操作。
#   正确做法: 先给 CAS 自动跳转一个宽限期(GraceSec)，只有跳转完成后仍是登录页，
#   才判定为"需要人工登录"。（2026-09-26 优化: 旧版 2 秒就下结论）
$graceSec = 30
Log "步骤3: 判断登录态（观察 CAS 跳转，宽限 ${graceSec}s）..."
$loginOk = $false
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$lastLogged = ""
$formSince = $null
while ($sw2.Elapsed.TotalSeconds -lt $graceSec) {
    Start-Sleep -Milliseconds 500
    # 优化(2026-09-26 深夜): 单次 Eval 同时取 URL 与表单状态(减半 CDP 往返)
    # 判定顺序 = URL(最早最准) > 表单持续 4s 可见(判失效) > 窗口标题(兜底)
    if ($null -ne $script:Cdp.Ws) {
        $st = Eval-Js "(function(){var u=location.href,f=0,a=document.querySelector('#userName'),b=document.querySelector('#password');if(a&&b&&a.getBoundingClientRect().width>0&&b.getBoundingClientRect().width>0)f=1;return {u:u,f:f}})()"
        if ($st) {
            if ($st.u -match "xsfw\.gzist\.edu\.cn/xsfw/") { $loginOk = $true; break }
            if ($st.f -eq 1) {
                if ($null -eq $formSince) { $formSince = $sw2.Elapsed.TotalSeconds }
                elseif (($sw2.Elapsed.TotalSeconds - $formSince) -ge 4) {
                    Log ("  登录表单渲染后 {0}s 仍无跳转 -> 判定会话失效（提前结束宽限，省 {1}s）" -f 4, [int]($graceSec - $sw2.Elapsed.TotalSeconds))
                    break
                }
            } else {
                $formSince = $null
            }
        }
    }
    # 兜底: 窗口标题(CDP 不可用时仍能工作)
    $t = [DW]::Title($h)
    if ($t -match "xsfw\.gzist\.edu\.cn" -or $t -match "个人查寝") { $loginOk = $true; break }
    if ($t -ne $lastLogged) {
        Log ("  [{0,2}s] {1}" -f [int]$sw2.Elapsed.TotalSeconds, $t)
        $lastLogged = $t
    }
}
if (-not $loginOk) {
    # 宽限期结束仍在登录页/中间页 -> 确认需要人工登录
    $t = [DW]::Title($h)
    Log "  宽限 ${graceSec}s 后仍停在: $t"
    Log "  登录态: 需要人工登录"
}
if ($loginOk) { Log "  登录态: 有效 ✓（CAS 自动完成跳转，耗时 $([int]$sw2.Elapsed.TotalSeconds)s）" }

# 【数据采集】记录每次运行的登录态，用于摸清真实失效规律
# 背景: 目前只知道"21:52 有效 / 次日 09:00 失效"，不足以断定是固定 11 小时。
#       用户提到手机企业微信可长期保持登录 -> 失效机制可能不是简单的时间常数。
#       持续记录后可画出真实的存活曲线。
try {
    $histFn = Join-Path $Root "session-history.csv"
    if (-not (Test-Path $histFn)) {
        "时间,登录态,判定耗时秒,窗口标题" | Set-Content -Path $histFn -Encoding UTF8
    }
    $stateTxt = if ($loginOk) { "有效" } else { "需登录" }
    $titleNow = ([DW]::Title($h)) -replace '"','""' -replace ',','，'
    ('{0},{1},{2},"{3}"' -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $stateTxt, [int]$sw2.Elapsed.TotalSeconds, $titleNow) |
        Add-Content -Path $histFn -Encoding UTF8
    Log "  已记录登录态到 session-history.csv: $stateTxt"
} catch { Log "  写登录态历史失败: $($_.Exception.Message)" "WARN" }

# ---- 步骤 4: 未登录 -> 先尝试全自动登录(v3), 失败回落原人工等待（不重启浏览器） ----
if (-not $loginOk) {
    # 隐藏模式: 不抢前台(自动填充由 CDP 可信点击触发); 非隐藏模式才抢前台
    if (-not $script:Hidden) {
        [DW]::ForceForeground($h) | Out-Null
    } else {
        Log "  [隐藏模式] 不抢前台, 自动填充走 CDP 可信点击"
    }

    # ===== v3 全自动登录: 账号密码走 Edge 自动填充, 验证码本地识别 =====
    $autoLoginOn = $false
    $capMaxTry = 8
    $confThr = 0.55
    if ($cfg.'_自动登录') {
        $autoLoginOn = $true
        if ($cfg.'_自动登录'.PSObject.Properties.Name -contains "启用") { $autoLoginOn = [bool]$cfg.'_自动登录'.启用 }
        if ($cfg.'_自动登录'.PSObject.Properties.Name -contains "验证码最大尝试") { $capMaxTry = [int]$cfg.'_自动登录'.验证码最大尝试 }
        if ($cfg.'_自动登录'.PSObject.Properties.Name -contains "置信度阈值") { $confThr = [double]$cfg.'_自动登录'.置信度阈值 }
    }
    $autoAvailable = ($autoLoginOn -and $null -ne $script:Cdp.Ws -and (Get-Command Invoke-CaptchaSolve -ErrorAction SilentlyContinue))
    if ($autoAvailable) {
        Log "  【全自动登录】账号密码=Edge自动填充, 验证码=本地识别（最多 $capMaxTry 次）"
        # 4.1 等登录表单就绪
        $formOk = $false
        $swF = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swF.Elapsed.TotalSeconds -lt 30) {
            Start-Sleep -Milliseconds 300
            if (Test-FormReady) { $formOk = $true; break }
        }
        if (-not $formOk) {
            Log "  30s 内未见登录表单" "WARN"
        } else {
            Log "  登录表单就绪（等待 $([int]$swF.Elapsed.TotalSeconds)s）"
            # 4.2 触发 Edge 自动填充: 真实点击账号框（只查长度, 绝不读取值）
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
                Log "  自动填充第 $afTry 次未生效（鼠标点击）"
            }
            # 升级①: 触摸点击(页面是 iPhone UA; 触摸事件可能才是有效手势)
            if (-not $filled) {
                for ($tt = 1; $tt -le 2 -and -not $filled; $tt++) {
                    $ur = Eval-Js "(function(){var e=document.querySelector('#userName');if(!e)return null;var r=e.getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()"
                    if ($ur) {
                        Log "  升级尝试: 触摸点击账号框（第 $tt 次）"
                        Invoke-CdpTouchAt $ur.x $ur.y
                        $swA2 = [System.Diagnostics.Stopwatch]::StartNew()
                        while ($swA2.Elapsed.TotalSeconds -lt 3) {
                            Start-Sleep -Milliseconds 300
                            if (Test-CredFilled) { $filled = $true; break }
                        }
                    }
                }
            }
            # 升级②: 允许时才抢前台(Edge 自动填充下拉通常需要窗口获得系统焦点)
            if (-not $filled -and -not $script:Hidden) {
                Log "  升级尝试: 抢前台后点击账号框"
                [DW]::ForceForeground($h) | Out-Null
                Start-Sleep -Milliseconds 400
                [void](Invoke-ClickEl "#userName")
                $swA3 = [System.Diagnostics.Stopwatch]::StartNew()
                while ($swA3.Elapsed.TotalSeconds -lt 3) {
                    Start-Sleep -Milliseconds 300
                    if (Test-CredFilled) { $filled = $true; break }
                }
            } elseif (-not $filled -and $script:Hidden) {
                $fgAllow = $true
                if ($cfg.'_自动登录' -and ($cfg.'_自动登录'.PSObject.Properties.Name -contains "允许抢前台兜底")) {
                    $fgAllow = [bool]$cfg.'_自动登录'.允许抢前台兜底
                }
                if ($fgAllow) {
                    Log "  升级尝试: 后台手势均未触发自动填充 -> 短暂抢前台一次（会打断前台程序）" "WARN"
                    [DW]::ForceForeground($h) | Out-Null
                    Start-Sleep -Milliseconds 400
                    [void](Invoke-ClickEl "#userName")
                    $swA3 = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($swA3.Elapsed.TotalSeconds -lt 3) {
                        Start-Sleep -Milliseconds 300
                        if (Test-CredFilled) { $filled = $true; break }
                    }
                    if ($filled) { Log "  抢前台后自动填充成功 ✓" }
                } else {
                    Log "  按配置禁止抢前台兜底, 直接转人工" "WARN"
                }
            }
            if (-not $filled) {
                Log "  Edge 未自动填充账号密码" "WARN"
            } else {
                Log "  账号密码已由 Edge 自动填充 ✓"
                # 4.3 验证码识别 + 提交循环
                $tryN = 0
                while ($tryN -lt $capMaxTry -and -not $loginOk) {
                    $tryN++
                    $du = Invoke-ExtractLoginCaptcha
                    if (-not $du -or $du -like "ERR:*" -or $du -eq "WAIT") {
                        Log "  [$tryN/$capMaxTry] 验证码图提取失败($du) -> 刷新重试"
                        Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 600; continue
                    }
                    $swS = [System.Diagnostics.Stopwatch]::StartNew()
                    $r = Invoke-SolveDataUrl $du
                    $swS.Stop()
                    if (-not $r.ok -or $r.minScore -lt $confThr) {
                        $det = if ($r.ok) { "置信度低($($r.minScore))" } else { $r.reason }
                        Log "  [$tryN/$capMaxTry] 识别不可信($det) -> 换一张, 绝不瞎填"
                        Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 600; continue
                    }
                    Log "  [$tryN/$capMaxTry] 识别: $($r.expr) = $($r.ans)（置信度 $($r.minScore)/余量 $($r.minMargin)/含缓存加载 $([int]$swS.ElapsedMilliseconds)ms）"
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
                    Invoke-RefreshLoginCaptcha; Start-Sleep -Milliseconds 600
                }
                if ($loginOk) { Log "  自动登录成功 ✓（第 $tryN 次尝试）" }
                else { Log "  自动登录未成功 -> 转人工兜底" "WARN" }
            }
        }
    }

    if ($loginOk) {
        # 自动登录成功后重找窗口句柄（同窗口导航句柄一般不变; 与人工路径同等保险）
        # 2026-09-26 深夜: 死等 2s -> 0.5s(重找本身不依赖该等待)
        Start-Sleep -Milliseconds 500
        $pidsAuto = Get-ProfilePids
        if ($pidsAuto.Count -gt 0) {
            foreach ($w in [DW]::AllVisibleTitled()) {
                if (-not (Test-PidInList $pidsAuto ([int][DW]::PidOf($w)))) { continue }
                $t = [DW]::Title($w)
                if ($t -match "xsfw\.gzist\.edu\.cn" -or $t -match "个人查寝") { $h = $w; break }
            }
        }
    }

    if (-not $loginOk) {
    # 隐藏模式: 需要人工登录时, 把窗口从屏幕外临时移回可见位置(仍不抢前台, 由你点击切换)
    if ($script:Hidden) {
        $vwH = $cfg.viewport
        if ($script:NoWindow) {
            if (-not $script:AllowVisible) {
                # 无窗口模式 + 不允许可见窗口: 绝不弹窗, 只提醒你手动签
                Log "!! 需要人工登录, 但当前为无窗口模式且不允许可见窗口 —— 不弹窗, 转人工" "WARN"
                try {
                    Set-Content -Path (Join-Path $Root "需要人工登录.txt") -Encoding UTF8 -Value @(
                        ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
                        "自动登录未完成（无窗口模式下无法弹出登录窗口）。",
                        "请手动双击 2-立即签到一次.bat，在弹出的窗口里完成登录（含验证码）。",
                        "登录时如 Edge 提示保存密码，请选择【保存】——之后即可恢复全自动。"
                    )
                    Log "  已写入提醒文件: 需要人工登录.txt"
                } catch { }
                try { 1..6 | ForEach-Object { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 450 } } catch { }
                if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
                exit 3
            }
            # 允许可见窗口 -> 结束无窗口实例, 在你的桌面重开可见窗口供你登录
            Log "  [$($script:LaunchKind)] 需人工登录 -> 在用户桌面重开可见窗口（无窗口实例将被关闭）" "WARN"
            try {
                Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$UADir*" } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 1500
            } catch { }
            try {
                $psiV = New-Object System.Diagnostics.ProcessStartInfo
                $psiV.FileName = $Edge
                $psiV.UseShellExecute = $false
                $psiV.Arguments = "--remote-debugging-port=$dbgPort --user-data-dir=`"$UADir`" " +
                                  "--no-first-run --no-default-browser-check --disable-features=Translate " +
                                  "--disable-background-timer-throttling --disable-backgrounding-occluded-windows " +
                                  "--disable-renderer-backgrounding " +
                                  "--window-size=$($vwH.width),$($vwH.height) --window-position=$winX,$winY " +
                                  "--force-device-scale-factor=1 --user-agent=`"$($cfg.userAgent)`" --app=`"$($cfg.url)`""
                $procV = [System.Diagnostics.Process]::Start($psiV)
                $script:NoWindow = $false
                $swV = [System.Diagnostics.Stopwatch]::StartNew()
                $hNew = [IntPtr]::Zero
                while ($swV.Elapsed.TotalSeconds -lt 20 -and $hNew -eq [IntPtr]::Zero) {
                    Start-Sleep -Milliseconds 300
                    foreach ($w in [DW]::AllVisibleTitled()) {
                        if ([int][DW]::PidOf($w) -eq [int]$procV.Id) { $hNew = $w; break }
                    }
                }
                if ($hNew -ne [IntPtr]::Zero) {
                    $h = $hNew
                    [DW]::ShowNoActivateOnly($h) | Out-Null
                    Start-Sleep -Milliseconds 200
                    [void][DW]::ShowNoActivateAt($h, $winX, $winY, [int]$vwH.width, [int]$vwH.height)
                    Log "  已在你的桌面打开窗口 $winX,$winY（未抢前台）—— 请切到它完成登录"
                } else { Log "  重开可见窗口失败（可手动运行 2-立即签到一次.bat）" "WARN" }
                try {
                    $targets2 = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/list" -TimeoutSec 5
                    $pg2 = @($targets2 | Where-Object { $_.type -eq 'page' -and $_.url -notlike '*devtools*' }) | Select-Object -First 1
                    if ($pg2) {
                        if ($null -ne $script:Cdp.Ws) { try { [void]$script:Cdp.Ws.Dispose() } catch { } }
                        $raw2 = Connect-Cdp $pg2.webSocketDebuggerUrl
                        if ($raw2 -is [System.Array]) { $raw2 = $raw2 | Where-Object { $_ -is [System.Net.WebSockets.ClientWebSocket] } | Select-Object -First 1 }
                        if ($null -ne $raw2) { $script:Cdp.Ws = $raw2; Log "  CDP 已重连(可见窗口)" }
                    }
                } catch { }
            } catch { Log "  重开可见窗口异常: $($_.Exception.Message)" "WARN" }
        } else {
            [void][DW]::ShowNoActivateAt($h, $winX, $winY, [int]$vwH.width, [int]$vwH.height)
            Log "  [隐藏模式] 需人工登录 -> 窗口已移回可见位置 $winX,$winY（未抢前台）"
        }
        # 控制台在计划任务里是隐藏的 -> 用【非侵入】方式提醒: 提示音 + 标记文件(绝不弹窗抢焦点)
        #   否则自动登录失败会被静默忽略, 那一晚就漏签了。
        try {
            $markerFn = Join-Path $Root "需要人工登录.txt"
            Set-Content -Path $markerFn -Encoding UTF8 -Value @(
                ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
                "自动登录未能完成，需要你手动登录一次（自动化窗口已移到屏幕 (60,40)）。",
                "登录时如 Edge 提示保存密码，请选择【保存】——之后即可恢复全自动。",
                "登录成功并确认签到后，删除本文件即可。"
            )
            Log "  已写入提醒文件: 需要人工登录.txt"
        } catch { }
        try { 1..6 | ForEach-Object { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 450 } } catch { }
    }
    Alert-User -Title "需要你登录（输入验证码）" -Message @"
浏览器窗口已打开登录页。

  1. 账号密码点一下输入框会自动填充
  2. 输入【验证码】
  3. 点【登 录】

登录成功后脚本会自动继续（无需重开窗口），
最长等待 $WaitLoginMin 分钟。
"@
    Log "  等待你登录（最长 $WaitLoginMin 分钟）..."
    $dl = (Get-Date).AddMinutes($WaitLoginMin)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Seconds 4
        # 重新找窗口：登录过程中窗口句柄可能变。
        # 同样按【配置目录的进程】限定，避免抓到别的 Edge 窗口。
        # 注意: 用 Test-PidInList 而非 -contains —— 后者在数组嵌套时会失效。
        $pids = Get-ProfilePids
        if ($pids.Count -gt 0) {
            foreach ($w in [DW]::AllVisibleTitled()) {
                if (-not (Test-PidInList $pids ([int][DW]::PidOf($w)))) { continue }
                $t = [DW]::Title($w)
                if ($t -match "xsfw\.gzist\.edu\.cn" -or $t -match "个人查寝") { $h = $w; $loginOk = $true; break }
            }
        }
        if ($loginOk) { break }
        $left = [int]($dl - (Get-Date)).TotalSeconds
        if ($left % 60 -lt 6) { Log "    仍在等待登录... 剩余约 $([int]($left/60)) 分钟" }
    }
    if (-not $loginOk) {
        Log "  等待超时 —— 本次放弃" "WARN"
        Alert-User -Title "登录等待超时" -Message "未检测到登录成功。`n若需补签，请在 23:00 前重跑本脚本。"
        if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
        exit 3
    }
    }
    Log "  检测到登录成功 ✓（继续使用同一窗口）"
    Start-Sleep -Milliseconds 800   # 2026-09-26 深夜: 3s -> 0.8s, 页面就绪由步骤6轮询兜底
}

# ---- 步骤 5: 兜底注入（正常情况下已在步骤 2.5 提前注入） ----
if ($geoOn -and -not $injectedEarly) {
    if ($null -eq $script:Cdp.Ws) {
        # 登录后可能换了页面目标，重连一次
        try {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$dbgPort/json/list" -TimeoutSec 5
            $page = $targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "*devtools*" } | Select-Object -First 1
            if ($page) {
                $raw = Connect-Cdp $page.webSocketDebuggerUrl
                if ($raw -is [System.Array]) { $raw = $raw | Where-Object { $_ -is [System.Net.WebSockets.ClientWebSocket] } | Select-Object -First 1 }
                $script:Cdp.Ws = $raw
            }
        } catch { }
    }
    if ($null -ne $script:Cdp.Ws) {
        Log "步骤5: 兜底注入定位..."
        $gi = $cfg.'_定位注入'
        $r = Send-Cdp "Emulation.setGeolocationOverride" @{
            latitude = [double]$gi.纬度; longitude = [double]$gi.经度; accuracy = [int]$gi.精度米
        }
        if ($r -and $r.result) {
            Log "  定位注入成功: $($gi.纬度), $($gi.经度) —— 需刷新才生效"
            [void](Send-Cdp "Browser.grantPermissions" @{ permissions = @("geolocation"); origin = "https://xsfw.gzist.edu.cn" })
            $needReload = $true
        } else { Log "  定位注入失败" "WARN" }
    } else { Log "步骤5: CDP 未连接，跳过定位注入" "WARN" }
} elseif ($geoOn) {
    Log "步骤5: 定位已在加载前注入，无需处理 ✓"
} else { Log "步骤5: 定位注入未启用" }

# ---- 步骤 6: 等页面就绪 ----
# 判据收紧: 必须出现【页面业务内容】(班级/签到)，不能只看窗口标题里的"个人查寝"。
#   2026-09-26 踩到的坑: 旧判据匹配到标题就通过，导致在尚未渲染的页面上操作。
Log "步骤6: 等页面就绪（判据: 出现业务内容）..."
$sw3 = [System.Diagnostics.Stopwatch]::StartNew()
$ready = $false
$promoted = $false
$hashFixed = 0
$reloaded = $false
$shellRetry = 0     # 「只渲染出外壳」时的重载重试计数(2026-09-28 新增)
while ($sw3.Elapsed.TotalSeconds -lt 75) {
    Start-Sleep -Milliseconds 500   # 2026-09-26 深夜: 800->500ms
    $txt = Get-PageText
    if ($txt -and $txt -match "查寝时间段" -and $txt -match "点击签到") { $ready = $true; break }
    if ($txt -and $txt -match "无需重复签到") { $ready = $true; break }

    # ★★★ 2026-09-27 21:05 实测的关键修复: 自动登录成功后 URL 会丢掉路由 hash。
    #   CAS 跳转把 service 参数重建后, 只回到 .../index.do (没有 #/xscq/grcq),
    #   于是 SPA 只渲染出外壳「个人查寝」, 永远不出现签到卡片 -> 流程(正确地)拒绝点击 -> 漏签。
    #   修法: 发现 hash 缺失就补回路由; 若 20s 后仍未就绪, 再整页跳转到完整地址。
    if ($sw3.Elapsed.TotalSeconds -ge 3 -and $script:Cdp.Ws) {
        $urlNow = Eval-Js "location.href"
        # ⚠️ 只在【业务页 xsfw.gzist.edu.cn】上做路由修复。若此刻还停在认证页(ids.gzist.edu.cn)
        #    或跳转中间态, 绝不能改它的 hash —— 那会干扰 CAS 登录跳转本身。
        if ($urlNow -and $urlNow -match "xsfw\.gzist\.edu\.cn" -and $urlNow -notmatch [regex]::Escape("#/xscq/grcq")) {
            if ($hashFixed -eq 0) {
                $hashFixed = 1
                Log "  !! URL 缺少路由 hash（SPA 不会渲染签到卡片）: $urlNow"
                [void](Eval-Js "location.hash = '#/xscq/grcq'; 1")
                Log "  已补回路由 hash: #/xscq/grcq"
                Start-Sleep -Milliseconds 700
                continue
            } elseif ($hashFixed -eq 1 -and $sw3.Elapsed.TotalSeconds -ge 25 -and -not $reloaded) {
                $hashFixed = 2; $reloaded = $true
                Log "  补 hash 后仍未就绪 -> 整页跳转到完整地址重载"
                $fullUrl = [string]$cfg.url
                [void](Eval-Js ("location.href = '" + $fullUrl + "'; 1"))
                Start-Sleep -Milliseconds 1200
                continue
            }
        } elseif ($urlNow -and $urlNow -notmatch "xsfw\.gzist\.edu\.cn" -and $sw3.Elapsed.TotalSeconds -ge 40) {
            # 40s 还停在非业务页(例如认证页没跳回来) -> 主动跳到业务页完整地址
            Log "  40s 仍停在非业务页, 主动跳转到业务页: $urlNow" "WARN"
            $fullUrl = [string]$cfg.url
            [void](Eval-Js ("location.href = '" + $fullUrl + "'; 1"))
            Start-Sleep -Milliseconds 1200
        }
    }

    # 【2026-09-28 21:50 实测新增】"只有外壳"卡壳的自动恢复。
    #   现象: URL 带 hash、readyState=complete、接口全 200, 但页面只渲染出「个人查寝」外壳,
    #         永不出现签到卡片(该页面依赖百度地图 SDK 初始化后才渲染卡片, SDK 偶发卡住)。
    #   实测 21:50 那次就这样空等了 75s, 之后还会再白等最多 6 分钟。
    #   恢复办法: 重载一次(与定位修正同一招, 实测有效), 最多 2 次; 仍不行则提前放弃, 不空等。
    if ($shellRetry -lt 2 -and $txt -and $txt -notmatch "点击签到" `
            -and $sw3.Elapsed.TotalSeconds -ge (10 + $shellRetry * 15)) {
        $shellRetry++
        Log "  页面只渲染出外壳（无签到卡片，疑似百度地图 SDK 卡住）-> 第 $shellRetry 次重载重试" "WARN"
        [void](Send-Cdp "Page.reload" @{ ignoreCache = $true })
        Start-Sleep -Milliseconds 1500
        continue
    }
    if ($shellRetry -ge 2 -and $txt -and $txt -notmatch "点击签到" -and $sw3.Elapsed.TotalSeconds -ge 45) {
        Log "  两次重载后仍只有外壳 -> 提前放弃本轮页面等待（不再空等 6 分钟）" "WARN"
        break
    }

    # 兜底(仅屏幕外模式): 屏幕外窗口会被 Chromium 判为"被遮挡"而节流渲染(1s -> 15s),
    #   15s 仍未就绪 -> 把窗口搬回屏内(仍不抢前台)。默认屏内模式不走这里。
    if (-not $promoted -and $script:Offscreen -and $sw3.Elapsed.TotalSeconds -ge 15) {
        $promoted = $true
        $vwP = $cfg.viewport
        [void][DW]::ShowNoActivateAtBottom($h, $winX, $winY, [int]$vwP.width, [int]$vwP.height)
        $effX = $winX; $effY = $winY
        Log "  [隐藏模式] 屏幕外渲染被节流 -> 窗口回到屏内 $winX,$winY（最底层, 未抢前台）"
        Start-Sleep -Milliseconds 400
    }
}
if ($ready) {
    Log "  页面就绪(耗时 $([int]$sw3.Elapsed.TotalSeconds)s)"
    Log "  页面文字: $(if($txt.Length -gt 220){$txt.Substring(0,220)}else{$txt})"
} else {
    Log "  页面未就绪（仍继续尝试）" "WARN"
    $urlEnd = Eval-Js "location.href"
    Log "  当前 URL : $urlEnd"
    Log "  当前文字: $(if($txt -and $txt.Length -gt 150){$txt.Substring(0,150)}else{$txt})"
}

# 兜底: 若步骤5 才注入，则刷新一次让定位生效（正常路径不会走到）
if ($needReload -and $null -ne $script:Cdp.Ws) {
    [void](Send-Cdp "Page.reload" @{ ignoreCache = $true })
    Log "  刷新页面让定位生效（轮询等待）..."
    $sw4 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw4.Elapsed.TotalSeconds -lt 75) {
        Start-Sleep -Milliseconds 500
        $txt = Get-PageText
        if ($txt -and $txt -match "查寝时间段" -and $txt -match "点击签到") { break }
    }
    Log "  刷新完成(耗时 $([int]$sw4.Elapsed.TotalSeconds)s)"
    Log "  刷新后页面文字: $(if($txt -and $txt.Length -gt 220){$txt.Substring(0,220)}else{$txt})"
}

# ---- 步骤 6.5: 定位判定修正（2026-09-28 实测修复）----
# 现象: headless 页面 1 秒就加载完, 站点可能在我们的定位注入【生效之前】就完成了一次定位判定
#       并缓存结果 -> 页面显示「当前不在考勤范围, 请回到宿舍再试试 重新定位」-> 流程正确拒绝点击 -> 漏签。
# 实测证据(见仓库 Issues/提交记录): 注入本身是成功的(getCurrentPosition 返回注入值),
#       只是站点用的是加载时那次判定的缓存; 【注入后强制重载一次】即可让站点用注入坐标重新判定,
#       重载后页面文字变为「你已进入考勤登记范围」✓
$geoFix = 0
while ($geoFix -lt 2 -and $txt -match "不在考勤范围" -and $null -ne $script:Cdp.Ws) {
    $geoFix++
    Log "  !! 页面显示「不在考勤范围」-> 注入后重载一次让站点重新判定（第 $geoFix 次）" "WARN"
    [void](Send-Cdp "Page.reload" @{ ignoreCache = $true })
    $swG = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swG.Elapsed.TotalSeconds -lt 40) {
        Start-Sleep -Milliseconds 700
        $txt = Get-PageText
        if ($txt -and $txt -match "点击签到") { break }
    }
    if ($txt -match "已进入考勤登记范围") {
        Log "  重载后($([int]$swG.Elapsed.TotalSeconds)s): 已进入考勤登记范围 ✓ 定位判定修正成功"
        break
    }
    Log "  重载后($([int]$swG.Elapsed.TotalSeconds)s): 仍不在考勤范围" "WARN"
    # 兜底: 用 CDP 可信鼠标点击页面的「重新定位」再试
    if ($geoFix -lt 2) {
        $reloc = Eval-Js "(function(){var els=document.querySelectorAll('a,button,div,span');for(var i=0;i<els.length;i++){var t=(els[i].innerText||'').replace(/\s+/g,'');if(t==='重新定位'){var r=els[i].getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}}return null})()"
        if ($reloc) {
            Log "  兜底: CDP 可信点击页面「重新定位」按钮 ($($reloc.x),$($reloc.y))"
            Invoke-CdpMouseAt $reloc.x $reloc.y
            Start-Sleep -Seconds 4
            $txt = Get-PageText
            if ($txt -match "已进入考勤登记范围") { Log "  重新定位后: 已进入考勤登记范围 ✓"; break }
            if ($txt -match "不在考勤范围") { Log "  重新定位后: 仍不在考勤范围" "WARN" }
        }
    }
}

# 定位校验结论
# 注意: 先刷新 $txt —— 步骤6 之后页面可能已变化，用旧文字做安全判断会有风险。
# （2026-09-26 修正: 原来直接复用步骤6 的 $txt，可能过期）
$txtFresh = Get-PageText
if ($txtFresh) { $txt = $txtFresh }
if ($txt -match "不在考勤范围") { Log "  !! 页面显示「不在考勤范围」—— 定位校验未通过" "WARN" }
elseif ($txt -match "已进入考勤登记范围") { Log "  定位校验通过 ✓" }
elseif ($txt -match "非考勤时段") { Log "  定位校验: 非考勤时段，页面不显示范围提示（正常）" }
else { Log "  定位校验: 页面未含范围提示文字" "WARN" }

# ---- 步骤 7: 点击签到 ----
$signPt = $null
if ($cfg.clicks -and $cfg.clicks.'签到按钮') { $signPt = $cfg.clicks.'签到按钮' }
if ($null -eq $signPt) { Log "配置缺【签到按钮】"; exit 5 }

# 已签到检查
# 只认专用短语 —— 通用子串可能被无关文字命中，导致误判"已签到"而漏签。
# 2026-09-26 晚: 实测成功页显示「签到成功 返回」, 加入该变体（此前误报"未确认成功"）。
$kws = @("无需重复签到","您已签到成功","签到成功")
$kwsRe = ($kws | ForEach-Object { [regex]::Escape($_) }) -join "|"
if ($txt -match $kwsRe) { Log ">>> 本日已签到，无需再签"; exit 0 }

# ---- 安全闸门 0: 晚归线守卫（最先执行）----
# 配置里的保守口径是「晚归线 23:00」（页面标注 23:30 算晚归，但不采用）。
# 若脚本在晚归线之后才运行，签到会留下【晚归记录】—— 那比不签更糟。
# 因此超时直接放弃，宁可漏签也不制造晚归。（2026-09-26 补漏）
$lateLine = "23:00"
if ($cfg.'_时序要求' -and $cfg.'_时序要求'.晚归线) { $lateLine = [string]$cfg.'_时序要求'.晚归线 }
try {
    $deadline = [datetime]::ParseExact(
        (Get-Date).ToString("yyyy-MM-dd") + " " + $lateLine, "yyyy-MM-dd HH:mm",
        [System.Globalization.CultureInfo]::InvariantCulture)
} catch {
    $deadline = (Get-Date).Date.AddHours(23)
    Log "  晚归线配置解析失败，回退为 23:00" "WARN"
}
if ((Get-Date) -ge $deadline) {
    Log "!! 已过晚归线 $lateLine（当前 $((Get-Date).ToString('HH:mm'))) —— 放弃签到，避免留下晚归记录" "WARN"
    Log "   若确需补签请人工确认后果后再手动处理" "WARN"
    exit 8
}
# 跨午夜修正(2026-09-27): 查寝窗口是 21:00~23:40。若在 00:00~20:59 运行,
#   上面"今天的 23:00 还没到"会让守卫失效, 白等一整轮(实测 01:00 白跑 6 分钟)。
#   这里明确: 不在窗口内就直接退出(页面本来也不会激活按钮)。
$nowH = (Get-Date).Hour
if ($nowH -lt 21 -and $nowH -ge 0) {
    Log "!! 当前 $((Get-Date).ToString('HH:mm')) 不在考勤时段(21:00~23:40) —— 放弃签到" "WARN"
    Log "   (任务应在 21:05 运行; 若为手动测试, 该结果属正常)" "WARN"
    exit 8
}
Log "  晚归线守卫通过（截止 $lateLine，剩余 $([int]($deadline - (Get-Date)).TotalMinutes) 分钟）"

# ---- 安全闸门 1: 窗口几何校验 ----
# 坐标点击完全依赖窗口位置/尺寸。若窗口不在预期位置(被移动、最大化、异常)，
# 计算出的屏幕坐标就会错位 -> 可能点到别处。
# 【隐藏桌面模式跳过】: 那种模式下窗口在另一个桌面, 拿不到句柄; 而且点击走 CDP【页面坐标】,
#   与窗口位置/尺寸完全无关(屏幕坐标 $sx/$sy 只在最后兜底的屏幕鼠标点击里用到)。
$vw2 = $cfg.viewport
if ($script:NoWindow) {
    Log "  安全闸门1: 隐藏桌面模式, 跳过窗口几何校验（CDP 点击用页面坐标，与窗口位置无关）"
    $r0 = @($effX, $effY, [int]$vw2.width, [int]$vw2.height)
} else {
$r0 = [DW]::Rect($h)
if ($r0[2] -le 0 -or $r0[3] -le 0) {
    Log "!! 窗口矩形无效 ($([DW]::RectStr($h))) —— 放弃点击" "WARN"
    exit 6
}
# 期望位置: 隐藏模式 = 屏幕外位置($effX,$effY); 否则 = 配置的可见位置
$expL = $effX; $expT = $effY
if ([math]::Abs($r0[0] - $expL) -gt 8 -or [math]::Abs($r0[1] - $expT) -gt 8) {
    Log "!! 窗口位置异常: 实际 $($r0[0]),$($r0[1])  预期 $expL,$expT —— 放弃点击（避免坐标错位）" "WARN"
    Log "   (若你手动移动过自动化窗口，请重启脚本)" "WARN"
    exit 6
}
if ([math]::Abs($r0[2] - $vw2.width) -gt 12 -or [math]::Abs($r0[3] - $vw2.height) -gt 40) {
    Log "!! 窗口尺寸异常: 实际 $($r0[2])x$($r0[3])  预期 $($vw2.width)x$($vw2.height) —— 放弃点击" "WARN"
    exit 6
}
}

$bx = 0; $by = 0
$dw = $r0[2] - $vw2.width; $dh = $r0[3] - $vw2.height
if ($dw -gt 0 -and $dw -le 40) { $bx = [int][math]::Round($dw/2) }
if ($dh -gt 0 -and $dh -le 120) { if ($dh -le 12) { $by = [int]$dh } else { $by = [int][math]::Floor($dh/2) } }
$sx = $r0[0] + $bx + [int]$signPt.x
$sy = $r0[1] + $by + [int]$signPt.y
Log "步骤7: 点击签到 -> 屏幕($sx,$sy)  [窗口 $([DW]::RectStr($h)) 边框补偿 X=$bx Y=$by]"

# ---- 安全闸门 2: 定位必须通过 ----
# 页面显示「不在考勤范围」时，按钮位置/状态都不可信（且本来就不该签）。
$geoMustPass = $true
if ($cfg.'_定位注入' -and $cfg.'_定位注入'.PSObject.Properties.Name -contains "必须通过") {
    $geoMustPass = [bool]$cfg.'_定位注入'.必须通过
}
if ($geoMustPass -and $txt -match "不在考勤范围") {
    Log "!! 定位校验未通过（页面显示「不在考勤范围」）—— 拒绝点击" "WARN"
    Log "   若你本人确实在宿舍，请检查定位注入是否生效" "WARN"
    exit 7
}

# 等待按钮激活
$maxWait = 360
if ($cfg.'_重试' -and $cfg.'_重试'.最长等待秒) { $maxWait = [int]$cfg.'_重试'.最长等待秒 }
$nowHour = (Get-Date).Hour
if (-not ($nowHour -ge 21 -or $nowHour -lt 1)) {
    if ($cfg.'_白天测试' -and $cfg.'_白天测试'.按钮等待秒) {
        $maxWait = [int]$cfg.'_白天测试'.按钮等待秒
        Log "  当前不在考勤时段，按钮等待缩短为 ${maxWait}s"
    }
}

# ---- 安全闸门 3: 点击前逐项确认 ----
function Test-ClickSafe {
    param([string]$PageTxt, [string]$WinTitle)
    # 3.1 必须仍在学工系统页面
    if ($WinTitle -notmatch "xsfw\.gzist\.edu\.cn") {
        return "窗口标题不是学工系统: $WinTitle"
    }
    # 3.2 必须是查寝页面（含签到按钮）
    if ($PageTxt -notmatch "点击签到") {
        return "页面未见「点击签到」按钮"
    }
    # 3.3 不能是"不在考勤范围"状态
    if ($PageTxt -match "不在考勤范围") {
        return "页面显示「不在考勤范围」"
    }
    # 3.4 不能已签到
    foreach ($k in @("无需重复签到","您已签到成功")) {
        if ($PageTxt -match [regex]::Escape($k)) { return "页面显示已签到（$k）" }
    }
    # 3.5 必须是考勤时段内
    if ($PageTxt -match "非考勤时段") {
        return "页面显示「非考勤时段」"
    }
    return ""   # 空 = 安全
}

$sw5 = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw5.Elapsed.TotalSeconds -lt $maxWait) {
    Start-Sleep -Seconds 2   # 2026-09-26 晚: 5s -> 2s, 首轮即检查(21:05 时按钮早已激活)
    $t2 = Get-PageText
    if ($t2 -match $kwsRe) { Log ">>> 已签到"; break }
    # 页面已明说"非考勤时段" -> 继续等没有意义，立即退出（省去无谓等待）
    # 注意: 正式运行在 21:05，那时页面不会有这句；只有白天/过点才会走到。
    if ($t2 -match "非考勤时段") {
        Log "  页面显示「非考勤时段」—— 无需继续等待，退出" "WARN"
        break
    }
    # 页面显示"不在考勤范围" -> 定位有问题，也不必等
    if ($t2 -match "不在考勤范围") {
        Log "  页面显示「不在考勤范围」—— 无需继续等待，退出" "WARN"
        break
    }
    # 隐藏桌面模式下没有窗口句柄 -> 用 CDP 已知的业务页地址作为"仍在学工系统页面"的依据
    #   (那种模式下 CDP 目标就是唯一权威; 其余判据仍是页面文字)
    $t = if ($script:NoWindow) { [string]$cfg.url } else { [DW]::Title($h) }
    if ($t -notmatch "xsfw\.gzist\.edu\.cn") {
        # 标题不含预期关键字时，整轮按钮检查都会被跳过 —— 必须留痕，
        # 否则最后只会看到"等待超时"，无法定位原因。（2026-09-26 补）
        Log "  [本轮] 窗口标题异常，跳过按钮检查: $t" "WARN"
    }
    if ($t -match "xsfw\.gzist\.edu\.cn") {
        # 判断按钮是否激活 ——【隐藏模式以页面文字为准】(2026-09-27 探针实测后重写):
        #   探针证实: 签到按钮是 <a class="erweima-bksy">, 【不是】button 元素, 祖先链也没有 btn 类名,
        #   因此"必须命中按钮类元素"的守卫会误拒它, 把隐藏模式逼回 PrintWindow 像素法
        #   (屏幕外窗口的截图不可靠) -> 可能整晚判不出按钮状态而漏签。
        #   新判据: 页面自己会声明状态 —— 非考勤时段会显示「非考勤时段，请在21:00至23:40之间登记」;
        #   进入考勤则显示「你已进入考勤登记范围」且无前者。故:
        #     · 页面含「非考勤时段」      -> 未激活(不点击, 继续等)
        #     · 页面含「点击签到」且无前者 -> 视为已激活(是否真点仍由闸门3 逐项确认)
        #   样式颜色仅作辅助参考(该按钮背景可能透明/是图片, 不能作为唯一判据), 不依赖任何截图。
        $tot = 1; $ratio = 0.0
        if ($script:Hidden -and $null -ne $script:Cdp.Ws) {
            $t2now = if ($t2) { $t2 } else { Get-PageText }
            $hasSign = ($t2now -match "点击签到")
            $offHour = ($t2now -match "非考勤时段")
            if ($offHour -or -not $hasSign) {
                $ratio = 1.0    # 未激活
                Log "  [隐藏模式] 页面文字判定: $(if ($offHour) { '非考勤时段' } else { '未见「点击签到」' }) -> 未激活，继续等"
            } else {
                # 文字显示可签 -> 再尽力读一次样式颜色作为辅助(读不到不影响判定)
                $bs = Eval-Js "(function(){var e0=document.elementFromPoint($([int]$signPt.x),$([int]$signPt.y));var e=e0;var n=0;while(e&&n<6){var cs=getComputedStyle(e);var bg=cs.backgroundColor;if(bg&&bg!=='rgba(0, 0, 0, 0)'&&bg!=='transparent'){return {bg:bg,tag:(e.tagName||''),cls:((e.className||'')+'').substring(0,40)}}e=e.parentElement;n++}return {bg:'',tag:(e0?e0.tagName:'none'),cls:''}})()"
                if ($bs -and $bs.bg) { Log "  [隐藏模式] 页面文字判定已激活; 样式参考 $($bs.bg) <$($bs.tag)>" }
                else { Log "  [隐藏模式] 页面文字判定已激活(样式背景透明/取不到, 不影响判定)" }
                $ratio = 0.0
            }
        }
        if (-not $script:Hidden -and $null -eq $ratio) {
            $tmp = Join-Path $ShotDir "_btn.png"
            if ([DW]::PrintToFile($h, $tmp)) {
                try {
                    $bmp = New-Object System.Drawing.Bitmap($tmp)
                    # 【收紧】只采样按钮【圆形内部】的像素。
                    # 实测按钮边界 X 118~297, Y 384~563（181x181 圆）。
                    # 旧版用矩形 110~305 x 380~570，四角会采到周围页面元素 ——
                    # 若附近有彩色内容会把灰色占比拉低，误判"已激活"导致盲点。
                    # 2026-09-26 深夜: LockBits 一次拷贝替代 ~1000 次 GetPixel(提速 ~10x)
                    $bcx = 208; $bcy = 474; $br = 78   # 圆心/半径(略小于实际 90，确保在内部)
                    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
                    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    $stride = $data.Stride
                    $raw = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
                    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
                    [void]$bmp.UnlockBits($data)
                    $gray = 0; $other = 0
                    for ($yy = ($bcy - $br); $yy -le ($bcy + $br); $yy += 5) {
                        $rowBase = $yy * $stride
                        for ($xx = ($bcx - $br); $xx -le ($bcx + $br); $xx += 5) {
                            $dx = $xx - $bcx; $dy = $yy - $bcy
                            if (($dx*$dx + $dy*$dy) -gt ($br*$br)) { continue }   # 圆外跳过
                            $o = $rowBase + ($xx * 4)   # BGRA 小端: B,G,R,A
                            $pB = $raw[$o]; $pG = $raw[$o + 1]; $pR = $raw[$o + 2]
                            if ($pR -gt 235 -and $pG -gt 235 -and $pB -gt 235) { continue }
                            if ([math]::Abs($pR-178) -le 12 -and [math]::Abs($pG-181) -le 12 -and [math]::Abs($pB-182) -le 12) { $gray++ } else { $other++ }
                        }
                    }
                    $bmp.Dispose()
                    $tot = $gray + $other
                    $ratio = if ($tot -gt 0) { $gray / $tot } else { 1 }
                } catch { }
            }
        }
        # 两个来源都没拿到数据 -> 明确置为"无有效数据"(旧版此处 $ratio 为 $null, 比较时被当成 0 会误判已激活)
        if ($null -eq $ratio) { $tot = 0; $ratio = 1 }
                if ($tot -eq 0) {
                    Log "  按钮区域无有效像素（截图可能失败），本轮跳过"
                } elseif ($ratio -lt 0.25) {
                    # 【安全闸门3】点击前逐项确认，任一不符即不点击
                    $unsafe = Test-ClickSafe -PageTxt $t2 -WinTitle $t
                    if ($unsafe -ne "") {
                        Log "  !! 点击前检查未通过: $unsafe —— 本轮不点击" "WARN"
                        if ($unsafe -match "不在考勤范围|非考勤时段|已签到") {
                            Log "     这是明确的不可签状态，停止等待" "WARN"
                            break
                        }
                        continue
                    }
                    Log "  安全检查通过（页面/标题/定位/时段均正常）"
                    Log "  按钮已激活（灰色占比 $([math]::Round($ratio*100,1))%），开始点击..."
                    $clickedByCdp = $false
                    $verifyText = $null
                    if ($script:Hidden -and $null -ne $script:Cdp.Ws) {
                        # 隐藏模式: CDP 点击四级阶梯 —— 鼠标没生效就换触摸, 再不行用 JS click() 兜底。
                        # 【2026-09-27 加固】按钮定位改为 DOM 特征优先(探针实测: <a class="erweima-bksy">点击签到</a>),
                        #   仅在没有该元素时才退回固定坐标 elementFromPoint —— 因为隐藏桌面下窗口尺寸
                        #   可能与 430x900 不同, 固定页面坐标可能落空。
                        $br2 = Eval-Js "(function(){var e=document.querySelector('a.erweima-bksy,.erweima-bksy');var how='class';if(!e){var a=document.querySelectorAll('a,button,div,span');for(var i=0;i<a.length;i++){var t=(a[i].innerText||'').replace(/\s+/g,'');if(t==='点击签到'){e=a[i];how='text';break}}}if(!e){e=document.elementFromPoint($([int]$signPt.x),$([int]$signPt.y));how='point'}if(!e)return null;var r=e.getBoundingClientRect();if(!(r.width>0))return null;return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2),w:Math.round(r.width),h:Math.round(r.height),tag:(e.tagName||''),how:how}})()"
                        if ($br2) {
                            Log "  按钮定位: <$($br2.tag)> $($br2.w)x$($br2.h) 中心($($br2.x),$($br2.y))  定位方式=$($br2.how)"
                            # ① 鼠标点击(可信事件)
                            Log "  [隐藏模式·1/3] CDP 鼠标点击 ($($br2.x),$($br2.y))"
                            Invoke-CdpMouseAt $br2.x $br2.y
                            $verifyText = Get-SignSuccessText 10
                            # ② 触摸点击(可信事件; 浏览器会据此合成 click)
                            if (-not $verifyText) {
                                Log "  [隐藏模式·2/3] 鼠标未见效 -> CDP 触摸点击"
                                Invoke-CdpTouchAt $br2.x $br2.y
                                $verifyText = Get-SignSuccessText 10
                            }
                            # ③ JS click()(非可信, 但框架的 onClick 一定收得到) —— 同样优先按 DOM 特征定位
                            if (-not $verifyText) {
                                Log "  [隐藏模式·3/3] 触摸未见效 -> JS el.click() 兜底"
                                [void](Eval-Js "(function(){var e=document.querySelector('a.erweima-bksy,.erweima-bksy');if(!e){var a=document.querySelectorAll('a,button,div,span');for(var i=0;i<a.length;i++){var t=(a[i].innerText||'').replace(/\s+/g,'');if(t==='点击签到'){e=a[i];break}}}if(!e){e=document.elementFromPoint($($br2.x),$($br2.y))}if(!e)return 0;try{e.click()}catch(x){}var p=e.parentElement;if(p){try{p.click()}catch(x){}}return 1})()")
                                $verifyText = Get-SignSuccessText 10
                            }
                            $clickedByCdp = $true
                            if ($verifyText) { Log "  [隐藏模式] 点击已生效并检测到成功字样" }
                            else { Log "  [隐藏模式] 三种点击方式均未见成功字样" "WARN" }
                        } else {
                            Log "  [隐藏模式] CDP 取按钮坐标失败 -> 回退屏幕点击" "WARN"
                        }
                    }
                    if (-not $clickedByCdp -or (-not $verifyText -and -not $script:done)) {
                        # 最后兜底: 抢前台 + 屏幕鼠标点击(会短暂打断游戏, 但优先保证签到成功)
                        #   仅在 CDP 方式全部失败时使用, 属罕见路径。
                        $fgAllow = $true
                        if ($cfg.'_自动登录' -and ($cfg.'_自动登录'.PSObject.Properties.Name -contains "允许抢前台兜底")) {
                            $fgAllow = [bool]$cfg.'_自动登录'.允许抢前台兜底
                        }
                        if ($clickedByCdp -and -not $fgAllow) {
                            Log "  已用 CDP 点击但未确认 -> 按配置不抢前台, 交给后续轮询/人工确认" "WARN"
                        } else {
                            Log "  [兜底] 抢前台 + 屏幕鼠标点击（会短暂打断前台程序）" "WARN"
                            [DW]::ForceForeground($h) | Out-Null
                            Start-Sleep -Milliseconds 500
                            [DW]::Click($sx, $sy)
                        }
                    }
                    $script:clicked = $true
                    if ($verifyText) { $after = $verifyText } else { $after = "" }
                    # 点击后轮询等待结果（成功就立即结束，不再固定等 12 秒）
                    $sw6 = [System.Diagnostics.Stopwatch]::StartNew()
                    $signCapTries = 0
                    while ($sw6.Elapsed.TotalSeconds -lt 30) {
                        Start-Sleep -Milliseconds 500
                        $after = Get-PageText
                        $hit = $false
                        foreach ($k in $kws) { if ($after -match [regex]::Escape($k)) { $hit = $true; break } }
                        if ($hit) { break }
                        # v3: 弹窗验证码出现时自动识别（最佳努力; 失败仍走人工等待）
                        if ($after -match "验证码" -and $signCapTries -lt 3 -and (Get-Command Invoke-HandleSignCaptcha -ErrorAction SilentlyContinue)) {
                            $signCapTries++
                            Log "  检测到签到弹窗验证码 -> 尝试自动识别（第 $signCapTries 次）"
                            if (Invoke-HandleSignCaptcha) {
                                Log "  弹窗验证码已自动提交 ✓"
                            } else {
                                Log "  弹窗验证码自动处理未成功（如页面停留请人工输入）" "WARN"
                            }
                        }
                    }
                    Log "  点击后页面(等待 $([int]$sw6.Elapsed.TotalSeconds)s): $(if($after -and $after.Length -gt 200){$after.Substring(0,200)}else{$after})"
                    foreach ($k in $kws) {
                        if ($after -match [regex]::Escape($k)) { Log ">>> 签到成功！（出现「$k」）"; $script:done = $true; break }
                    }
                    break
                } else {
                    Log "  按钮仍为灰色（占比 $([math]::Round($ratio*100,1))%），未到考勤时段，继续等..."
                }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
if (-not $script:done) {
    if ($script:clicked) {
        Log "  已点击但未检测到成功字样 —— 请查看截图确认" "WARN"
    } elseif ($sw5.Elapsed.TotalSeconds -ge $maxWait) {
        Log "  等待 ${maxWait}s 后按钮仍未激活 —— 当前不在考勤时段，未点击" "WARN"
    }
}

# ---- 截图存证 ----
# 隐藏模式优先 CDP 截屏(被遮挡/后台也可靠); 回退 PrintWindow
try {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $finalShot = Join-Path $ShotDir "$stamp-final-窗口.png"
    $shotOk = $false
    if ($script:Hidden -and $null -ne $script:Cdp.Ws) {
        $shot = Send-Cdp "Page.captureScreenshot" @{ format = "png" }
        if ($shot -and $shot.result -and $shot.result.data) {
            [System.IO.File]::WriteAllBytes($finalShot, [Convert]::FromBase64String($shot.result.data))
            $shotOk = $true
        }
    }
    if (-not $shotOk) { $shotOk = [DW]::PrintToFile($h, $finalShot) }
    if ($shotOk) { Log "截图: $finalShot" }
    else { Log "截图失败（CDP 与 PrintWindow 均未成功）" "WARN" }
} catch { Log "截图异常: $($_.Exception.Message)" "WARN" }

# ---- 汇总 ----
Log "==================== 结束 ===================="
if ($script:done)        { Log "结果: 签到成功 ✓" }
elseif ($script:clicked) { Log "结果: 已点击但未确认成功（查看截图）" "WARN" }
else                     { Log "结果: 未点击（不在考勤时段或其他原因）" "WARN" }
# 签到成功 -> 清掉"需要人工登录"提醒文件
if ($script:done) {
    try {
        $mf = Join-Path $Root "需要人工登录.txt"
        if (Test-Path $mf) { Remove-Item $mf -Force -ErrorAction SilentlyContinue; Log "已清除提醒文件(本次签到成功)" }
    } catch { }
}
if ($null -ne $script:Cdp.Ws) { [void]$script:Cdp.Ws.Dispose() }
# 结束即清理: 关闭自动化浏览器, 不留后台开销(用户明确要求)
[void](Stop-AutoBrowser)
exit 0
