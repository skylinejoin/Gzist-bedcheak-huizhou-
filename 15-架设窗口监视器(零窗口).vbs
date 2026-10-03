' ============================================================
'  Arm the window-detective monitor - ZERO WINDOW
'  ------------------------------------------------------------
'  Double-click this file before 21:00 to watch for any popup
'  during the 21:05 / 21:15 / 21:25 automatic runs.
'  wscript has no console; the monitor itself creates no window.
'  It stops by itself after 40 minutes and writes a report:
'      (monitor report .txt in the project folder)
'  ASCII-only on purpose (Windows Script Host reads .vbs as ANSI).
' ============================================================
Option Explicit
Dim sh, fso, here, psExe, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\window-monitor.ps1"" -Minutes 40"
sh.Run cmd, 0, False