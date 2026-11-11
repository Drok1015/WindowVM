@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UseHostProxy.ps1" -Restore
if errorlevel 1 pause
