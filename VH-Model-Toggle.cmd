@echo off
rem Double-click entry point for the NInfer chat engine (VH-Model.ps1 toggle).
rem Evicts the model if it is loaded, loads it if it is not. A cold load is ~70 s,
rem so this deliberately runs in a visible console: the progress dots and the
rem closing VRAM line are the whole point of the window.
rem
rem -ExecutionPolicy Bypass is scoped to this one process. Without it a default
rem Restricted/RemoteSigned machine refuses the .ps1 and the window closes with an
rem error nobody reads.
setlocal
title NInfer chat model -- toggle
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VH-Model.ps1" toggle
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo   Toggle exited with code %RC%.
echo   Press any key to close . . .
pause >nul
endlocal
