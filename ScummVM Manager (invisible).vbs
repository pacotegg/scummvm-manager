' Lanzador 100% invisible (sin ninguna ventana negra) de ScummVM Collection Manager.
' Ejecuta el GUI WPF con PowerShell en modo oculto (WindowStyle 0).
Dim fso, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\ScummVM-Manager-GUI.ps1"""
CreateObject("WScript.Shell").Run cmd, 0, False
