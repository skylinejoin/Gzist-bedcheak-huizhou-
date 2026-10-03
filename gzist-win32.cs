using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DW {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;

  public static string Title(IntPtr h) { var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
  public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static List<IntPtr> WindowsOfPid(uint pid) {
    var l = new List<IntPtr>();
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp == pid && IsWindowVisible(h) && GetWindowTextLength(h) > 0) l.Add(h);
      return true;
    }, IntPtr.Zero);
    return l;
  }
  public static List<IntPtr> AllVisibleTitled() {
    var l = new List<IntPtr>();
    EnumWindows((h, p) => { if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h,out r);
    return new int[]{ r.Left, r.Top, r.Right-r.Left, r.Bottom-r.Top }; }
  public static void Click(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(150);
    mouse_event(LEFTDOWN,0,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(70);
    mouse_event(LEFTUP,0,0,0,IntPtr.Zero);
  }
  public static bool ForceForeground(IntPtr h) {
    uint d;
    uint fg  = GetWindowThreadProcessId(GetForegroundWindow(), out d);
    uint cur = GetCurrentThreadId();
    uint tgt = GetWindowThreadProcessId(h, out d);
    AttachThreadInput(cur, fg, true); AttachThreadInput(cur, tgt, true);
    ShowWindow(h, 9); BringWindowToTop(h);
    bool ok = SetForegroundWindow(h);
    AttachThreadInput(cur, fg, false); AttachThreadInput(cur, tgt, false);
    return ok;
  }
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public static bool ShowNoActivateAt(IntPtr h, int x, int y, int w, int ht) {
    // SWP_NOZORDER(0x4) | SWP_NOACTIVATE(0x10) | SWP_SHOWWINDOW(0x40)
    // 把(可能被最小化创建的)窗口摆到指定位置并显示, 但【绝不激活】—— 不抢前台, 全屏游戏不受影响
    return SetWindowPos(h, IntPtr.Zero, x, y, w, ht, 0x0004 | 0x0010 | 0x0040);
  }
  public static void ShowNoActivateOnly(IntPtr h) { ShowWindow(h, 4); }   // SW_SHOWNOACTIVATE: 还原显示但不激活
  public static bool ShowNoActivateAtBottom(IntPtr h, int x, int y, int w, int ht) {
    // HWND_BOTTOM(1) | SWP_NOACTIVATE(0x10) | SWP_SHOWWINDOW(0x40)
    // 摆到指定位置 + 显示 + 【压到 Z 序最底层】且不激活:
    //   屏内 -> Chromium 不会当它"被遮挡/屏幕外"而节流渲染(实测屏幕外 15s, 屏内 1s);
    //   最底层且未激活 -> 全屏游戏/视频仍盖在它上面, 既不抢焦点也不挡画面。
    //   (2026-09-27 实测: 屏幕外方案会被 Chromium 钳制位置/触发升格, 反而弹窗并拖慢渲染)
    return SetWindowPos(h, (IntPtr)1, x, y, w, ht, 0x0010 | 0x0040);
  }
  public static bool IsMinimized(IntPtr h) { return IsIconic(h); }
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);

  // ================= 隐藏桌面启动(2026-09-27) =================
  // 目的: 让 Edge 的窗口【完全不出现在用户桌面上】。
  //   实测教训: 对独占全屏游戏, 桌面上出现任何窗口(哪怕最小化创建、哪怕压到 Z 序最底层)
  //   都可能触发显示模式切换, 把游戏踢出全屏。唯一彻底的办法是把窗口建在别的桌面上。
  //   自动化全程走 CDP(桌面无关, localhost), 所以窗口在哪个桌面完全不影响功能。
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct STARTUPINFO {
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateDesktop(string lpszDesktop, IntPtr lpszDevice, IntPtr pDevmode, int dwFlags, uint dwDesiredAccess, IntPtr lpsa);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool CloseDesktop(IntPtr hDesktop);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CreateProcess(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr hObject);
  [DllImport("kernel32.dll")]
  public static extern uint GetLastError();
  public static int LaunchOnHiddenDesktop(string exe, string args, string desktopName) {
    const uint DESKTOP_ALL_ACCESS = 0x000F01FF;
    IntPtr hDesk = CreateDesktop(desktopName, IntPtr.Zero, IntPtr.Zero, 0, DESKTOP_ALL_ACCESS, IntPtr.Zero);
    if (hDesk == IntPtr.Zero) return -1;
    try {
      STARTUPINFO si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      si.lpDesktop = desktopName;      // 子进程及其后代都跑在这个桌面上
      si.dwFlags = 1;                  // STARTF_USESHOWWINDOW
      si.wShowWindow = 0;              // SW_HIDE
      PROCESS_INFORMATION pi;
      string cmd = "\"" + exe + "\" " + args;
      bool ok = CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi);
      if (!ok) return -1;
      CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
      return pi.dwProcessId;
    } finally { CloseDesktop(hDesk); }
  }
  public static string RectStr(IntPtr h) { RECT r; if(!GetWindowRect(h,out r)) return "n/a";
    return r.Left+","+r.Top+" "+(r.Right-r.Left)+"x"+(r.Bottom-r.Top); }
  public static bool PrintToFile(IntPtr h, string path) {
    RECT r; if(!GetWindowRect(h,out r)) return false;
    int w=r.Right-r.Left, ht=r.Bottom-r.Top;
    if (w<=0||ht<=0) return false;
    using (var bmp = new System.Drawing.Bitmap(w,ht))
    using (var g = System.Drawing.Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      bool ok = PrintWindow(h, hdc, 2);
      g.ReleaseHdc(hdc);
      if (!ok) return false;
      bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
      return true;
    }
  }
}