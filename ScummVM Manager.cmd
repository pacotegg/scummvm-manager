@echo off
REM Lanza la interfaz grafica (WPF) de ScummVM Collection Manager, oculta.
REM -WindowStyle Hidden oculta la consola; el GUI ademas oculta su propia
REM ventana al arrancar. Para arranque 100%% sin parpadeo usa el .vbs.
start "" /B powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ScummVM-Manager-GUI.ps1"
