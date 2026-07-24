@echo off
chcp 65001 >nul
title Jason Chat
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
if errorlevel 1 (
    echo.
    echo 客户端启动失败，请查看上方错误信息。
    pause
)
