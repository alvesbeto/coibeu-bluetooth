@echo off
rem Install the Coibeu WKDY-81X over Bluetooth. The PowerShell script elevates itself.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar-impressora-coibeu.ps1" %*
