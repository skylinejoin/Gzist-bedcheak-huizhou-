' ============================================================
'  Task runner for the scheduled sign-in job - NO WINDOW AT ALL
'  ------------------------------------------------------------
'  wscript.exe itself has no console window, and it starts
'  PowerShell with window style 0 (hidden). Using wscript as the
'  Task Scheduler action is therefore the reliable way to avoid
'  any console window flash from the scheduled run.
'
'  ASCII-only on purpose (Windows Script Host reads .vbs as ANSI).
' ============================================================
Option Explicit
Dim sh, fso, here, psExe, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\daily-signin2.ps1"""
sh.Run cmd, 0, False