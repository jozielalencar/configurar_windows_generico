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

:: Usa o PowerShell nativo: em Windows 64-bit chamado por processo 32-bit, Sysnative aponta para o 64-bit
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

:: Executa o script PowerShell
"%PS_EXE%" -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

pause