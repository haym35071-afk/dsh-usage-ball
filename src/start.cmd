@echo off
rem 调试入口：会保留一个控制台窗口，出错时能直接看到
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Normal -File "%~dp0widget.ps1" -Collect
