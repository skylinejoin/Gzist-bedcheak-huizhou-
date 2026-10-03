' ============================================================
'  One-click self-check - ZERO WINDOW, no popup at all
'  ------------------------------------------------------------
'  Double-click to run the full acceptance self-check silently.
'  Nothing appears on screen; when it finishes, read the report file in the project folder:
'      (self-check report, .txt - Chinese name)
'
'  Checks: script syntax/BOM, config, scheduled task, real run
'  with a no-new-window assertion, run result, and leftovers.
'
'  ASCII-only on purpose (Windows Script Host reads .vbs as ANSI).
' ============================================================
Option Explicit
Dim sh, fso, here, psExe, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\verify-all.ps1"""
sh.Run cmd, 0, False
