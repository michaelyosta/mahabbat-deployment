Option Explicit

Dim fso, shell, root, nodePath, appPath, configPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
nodePath = fso.BuildPath(root, "runtime\node.exe")
appPath = fso.BuildPath(root, "bridge-app.mjs")
configPath = fso.BuildPath(root, "config\bridge.env")

If Not fso.FileExists(nodePath) Then
  MsgBox "Не найден встроенный компонент запуска. Распакуйте архив полностью и повторите запуск.", 16, "Mahabbat Print Bridge"
  WScript.Quit 1
End If
If Not fso.FileExists(configPath) Then
  MsgBox "Не найден файл подключения. Используйте полный архив, подготовленный разработчиком.", 16, "Mahabbat Print Bridge"
  WScript.Quit 1
End If

shell.Run """" & nodePath & """ """ & appPath & """", 0, False
