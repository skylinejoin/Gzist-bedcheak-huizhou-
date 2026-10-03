' ============================================================
'  Silent hidden-mode test launcher  (no console window at all)
'  ------------------------------------------------------------
'  Double-click this file to test hidden mode WITHOUT any window
'  popping up:
'     - wscript.exe runs .vbs with no console  -> nothing appears
'     - it starts test-hidden.ps1 fully hidden (10s delay, then
'       the sign-in flow runs behind the scenes)
'  Wait ~1 minute, then open hidden-test-result.txt / signin.log
'  (or shots\) to see the outcome.
'
'  Note: .bat launchers ALWAYS show a console window - that is a
'  cmd limitation. For the nightly scheduled task the console is
'  hidden (-WindowStyle Hidden), so nothing pops up either.
' ============================================================
Option Explicit
Dim sh, fso, here, psExe, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\test-hidden.ps1"" -DelaySec 10"
' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
