@echo off
:: Verifica se já está como admin
net session >nul 2>&1
if %errorLevel% neq 0 (
echo Solicitando permissao de administrador...
powershell -Command "Start-Process cmd -ArgumentList '/c "%~s0"' -Verb RunAs"
exit
)

:: Caminho do script PS1 na mesma pasta do BAT
set "PS_SCRIPT=%~dp0configurar_windows_generico.ps1"

:: Executa o script PowerShell
powershell -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

pause