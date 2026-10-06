Option Explicit
' Mahabbat-Setup launcher: starts the localhost setup API + opens the wizard.
Dim fso, shell, appDir, nodePath, apiPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
nodePath = fso.BuildPath(appDir, "installer\app\runtime\node.exe")
apiPath = fso.BuildPath(appDir, "installer\app\setup-api.mjs")

If Not fso.FileExists(nodePath) Then
  MsgBox "Не найден встроенный компонент запуска. Переустановите Mahabbat.", 16, "Mahabbat"
  WScript.Quit 1
End If

shell.Run """" & nodePath & """ """ & apiPath & """ --port 3119 --root """ & appDir & """", 0, False
WScript.Sleep 1500
shell.Run "http://127.0.0.1:3119/", 1, False
