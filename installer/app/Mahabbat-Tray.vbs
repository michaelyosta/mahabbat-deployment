Option Explicit
' Mahabbat tray launcher: starts the NotifyIcon host without a terminal window.
Dim fso, shell, appDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & fso.BuildPath(appDir, "tray-host.ps1") & """", 0, False
