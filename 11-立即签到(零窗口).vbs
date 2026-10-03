' ============================================================
'  Run sign-in once - ZERO WINDOW (no console, no browser window)
'  ------------------------------------------------------------
'  Double-click this file to run one full sign-in pass with NO
'  window created at all:
'     - wscript.exe runs .vbs without any console window
'     - it launches daily-signin2.ps1 in hidden mode
'     - the browser runs in headless mode (no window)
'  Safe to trigger while gaming / watching fullscreen video.
'
'  Note: this variant never opens a visible window. Results go to
'        signin.log (in the same folder as this file)
'        If you need to watch progress or handle a manual login,
'        use 2-...bat instead (that one shows a console).
'
'  ASCII-only on purpose: Windows Script Host reads .vbs as ANSI
'  by default, so non-ASCII text here would break parsing.
' ============================================================
Option Explicit
Dim sh, fso, here, psExe, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\daily-signin2.ps1"""
sh.Run cmd, 0, False
