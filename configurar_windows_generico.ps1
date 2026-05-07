Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'INFO'  { $color = 'Cyan' }
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'OK'    { $color = 'Green' }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
    if (Test-IsAdministrator) {
        return
    }

    Write-Log "Script não está em modo administrador. Solicitando elevação..." 'WARN'

    if (-not $PSCommandPath) {
        throw "Não foi possível elevar automaticamente porque o script não está sendo executado a partir de um arquivo."
    }

    $quotedPath = '"' + $PSCommandPath + '"'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedPath"

    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Normal
    exit
}

function Invoke-Safely {
    param(
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [switch]$ContinueOnError
    )

    Write-Log $StepName 'INFO'

    try {
        & $ScriptBlock
        Write-Log "$StepName concluído." 'OK'
    }
    catch {
        Write-Log "$StepName falhou: $($_.Exception.Message)" 'ERROR'
        if (-not $ContinueOnError) {
            throw
        }
    }
}

function Set-RegistryValueIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Type
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $exists = $true
    $current = $null

    try {
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        $exists = $false
    }

    $needsUpdate = $true

    if ($exists) {
        if ($Type -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
            if ($current -is [byte[]] -and $Value -is [byte[]] -and $current.Length -eq $Value.Length) {
                $needsUpdate = -not ([System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$Value))
            }
        }
        else {
            $needsUpdate = ($current -ne $Value)
        }
    }

    if ($needsUpdate) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log "Registro atualizado: $Path -> $Name" 'INFO'
    }
    else {
        Write-Log "Registro já estava conforme: $Path -> $Name" 'INFO'
    }
}

function Ensure-NativeMethodsLoaded {
    if ('WinAPI.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WinAPI
{
    public static class NativeMethods
    {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
"@
}

function Invoke-ExplorerRefresh {
    Ensure-NativeMethodsLoaded

    [UIntPtr]$result = [UIntPtr]::Zero
    [WinAPI.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    [void][WinAPI.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
}

function Restart-Explorer {
    Invoke-Safely "Reiniciando o Explorer para aplicar alterações" {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process explorer.exe
        Start-Sleep -Seconds 3
        Invoke-ExplorerRefresh
    } -ContinueOnError
}

function Set-MouseSpeed {
    Invoke-Safely "Configurando velocidade do cursor para o máximo" {
        Set-RegistryValueIfNeeded -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSensitivity' -Value '20' -Type ([Microsoft.Win32.RegistryValueKind]::String)

        $mouseSensitivity = (Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSensitivity' -ErrorAction Stop).MouseSensitivity
        if ($mouseSensitivity -ne '20') {
            throw "A velocidade do cursor não ficou em 20."
        }

        Write-Log "Velocidade do cursor confirmada em 20." 'OK'
    }
}

function Set-MouseScrollLines {
    Invoke-Safely "Configurando rolagem do mouse para 6 linhas" {
        Set-RegistryValueIfNeeded -Path 'HKCU:\Control Panel\Desktop' -Name 'WheelScrollLines' -Value '6' -Type ([Microsoft.Win32.RegistryValueKind]::String)

        $wheelLines = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WheelScrollLines' -ErrorAction Stop).WheelScrollLines
        if ($wheelLines -ne '6') {
            throw "A rolagem de linhas não ficou em 6."
        }

        Write-Log "Rolagem do mouse confirmada em 6 linhas." 'OK'
    }
}

function Set-MouseSettings {
    Set-MouseSpeed
    Set-MouseScrollLines
}

function Open-FileExplorerOptions {
    Invoke-Safely "Abrindo Opções do Explorador de Arquivos" {
        Start-Process "control.exe" -ArgumentList "folders"
    }
}

function Get-WingetPathFromAppInstaller {
    $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $package) {
        return $null
    }

    $candidate = Join-Path $package.InstallLocation 'winget.exe'
    if (Test-Path -Path $candidate) {
        return $candidate
    }

    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -Path $windowsApps) {
        $found = Get-ChildItem -Path $windowsApps -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

function Ensure-Winget {
    $script:WingetExe = $null

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:WingetExe = $cmd.Source
        Write-Log "Winget já está disponível em: $script:WingetExe" 'INFO'
        return
    }

    $existingPath = Get-WingetPathFromAppInstaller
    if ($existingPath) {
        $script:WingetExe = $existingPath
        Write-Log "Winget encontrado via App Installer em: $script:WingetExe" 'INFO'
        return
    }

    throw "Winget não encontrado. Instale o App Installer da Microsoft Store e execute novamente."
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$IgnoreNonZeroExitCode
    )

    $output = & $script:WingetExe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)

    if (-not $IgnoreNonZeroExitCode -and $exitCode -ne 0) {
        $message = $text.Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "Winget retornou código de saída $exitCode."
        }
        throw $message
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
        Text     = $text
    }
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $result = Invoke-Winget -Arguments @(
        'list'
        '--id', $PackageId
        '--exact'
        '--accept-source-agreements'
        '--disable-interactivity'
    ) -IgnoreNonZeroExitCode

    return ($result.ExitCode -eq 0 -and $result.Text -match [regex]::Escape($PackageId))
}

function Install-JapaneseLanguagePackFallback {
    Invoke-Safely "Instalando pacote de idioma japonês via recurso nativo do Windows" {
        $languageCmd = Get-Command -Name Install-Language -ErrorAction SilentlyContinue
        if (-not $languageCmd) {
            throw "O cmdlet Install-Language não está disponível neste sistema."
        }

        $alreadyInstalled = $false
        try {
            $installedLanguages = Get-InstalledLanguage -ErrorAction Stop
            if ($installedLanguages.LanguageId -contains 'ja-JP') {
                $alreadyInstalled = $true
            }
        }
        catch {
            Write-Log "Não foi possível validar idiomas instalados previamente. Tentando instalação mesmo assim." 'WARN'
        }

        if ($alreadyInstalled) {
            Write-Log "Idioma ja-JP já está instalado. Nenhuma ação necessária." 'INFO'
            return
        }

        Install-Language -Language 'ja-JP' -ErrorAction Stop | Out-Null
    } -ContinueOnError
}

function Install-WingetPackagesIfMissing {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageIds
    )

    $nonFatalExitCodes = @(
        -2147012889
        -2147012867
        -2147012839
        -1978335212
    )

    foreach ($packageId in $PackageIds) {
        Invoke-Safely "Validando instalação do pacote $packageId" {
            if ($packageId -eq 'Microsoft.LanguageExperiencePack.ja-jp' -and (Get-Command -Name Get-InstalledLanguage -ErrorAction SilentlyContinue)) {
                try {
                    $installedLanguages = Get-InstalledLanguage -ErrorAction Stop
                    if ($installedLanguages.LanguageId -contains 'ja-JP') {
                        Write-Log "Idioma ja-JP já está instalado. Nenhuma ação necessária." 'INFO'
                        return
                    }
                }
                catch {
                    Write-Log "Não foi possível validar o idioma antes da instalação. Prosseguindo." 'WARN'
                }
            }

            if (Test-WingetPackageInstalled -PackageId $packageId) {
                Write-Log "Pacote $packageId já instalado. Nenhuma ação necessária." 'INFO'
                return
            }

            Write-Log "Pacote $packageId não encontrado. Instalando..." 'INFO'

            $result = Invoke-Winget -Arguments @(
                'install'
                '--id', $packageId
                '--exact'
                '--silent'
                '--accept-package-agreements'
                '--accept-source-agreements'
                '--disable-interactivity'
            ) -IgnoreNonZeroExitCode

            if ($result.ExitCode -eq 0) {
                return
            }

            if ($packageId -eq 'Microsoft.LanguageExperiencePack.ja-jp') {
                Write-Log "Instalação via winget do pacote $packageId falhou. Tentando fallback nativo do Windows." 'WARN'
                Install-JapaneseLanguagePackFallback
                return
            }

            if ($result.ExitCode -in $nonFatalExitCodes) {
                Write-Log "Winget retornou código $($result.ExitCode) para $packageId. Validando se o pacote ficou instalado." 'WARN'
                Start-Sleep -Seconds 3

                if (Test-WingetPackageInstalled -PackageId $packageId) {
                    Write-Log "Pacote $packageId detectado após tentativa do winget." 'INFO'
                    return
                }

                Write-Log "Pacote $packageId não foi confirmado após a tentativa. Continuando sem interromper o script." 'WARN'
                return
            }

            throw "Falha ao instalar $packageId. Código de saída: $($result.ExitCode)"
        } -ContinueOnError
    }
}

function Update-AllPackagesWithWinget {
    Invoke-Safely "Atualizando todos os pacotes via Winget" {
        $result = Invoke-Winget -Arguments @(
            'upgrade'
            '--all'
            '--silent'
            '--accept-package-agreements'
            '--accept-source-agreements'
            '--disable-interactivity'
        ) -IgnoreNonZeroExitCode

        if ($result.ExitCode -notin @(0, 1)) {
            throw "Winget retornou código de saída $($result.ExitCode)."
        }

        if ($result.Text -match 'No available upgrade found' -or
            $result.Text -match 'Nenhuma atualização disponível' -or
            $result.Text -match 'No installed package found matching input criteria') {
            Write-Log "Nenhuma atualização pendente encontrada." 'INFO'
        }
    } -ContinueOnError
}

function Remove-AppxPackagesSafe {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageNames
    )

    foreach ($app in $PackageNames) {
        Invoke-Safely "Removendo AppxPackage: $app" {
            $packages = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
            if (-not $packages) {
                Write-Log "Pacote $app não encontrado. Nada a remover." 'INFO'
                return
            }

            foreach ($pkg in $packages) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Log "Pacote removido: $($pkg.PackageFullName)" 'INFO'
                }
                catch {
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                        Write-Log "Pacote removido para o usuário atual: $($pkg.PackageFullName)" 'INFO'
                    }
                    catch {
                        Write-Log "Não foi possível remover $($pkg.PackageFullName): $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        } -ContinueOnError
    }
}

function Pin-RunToTaskbar {
    Invoke-Safely "Fixando 'Executar' na barra de tarefas" {

        $shortcutName = "Executar.lnk"
        $shortcutDir  = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
        $shortcutPath = Join-Path $shortcutDir $shortcutName

        $taskbarPins = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"

        # Verifica se já está fixado
        if (Test-Path (Join-Path $taskbarPins $shortcutName)) {
            Write-Log "'Executar' já está fixado na barra de tarefas." 'OK'
            return
        }

        # Cria atalho persistente
        $WScriptShell = New-Object -ComObject WScript.Shell
        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "$env:WINDIR\System32\rundll32.exe"
        $shortcut.Arguments = "shell32.dll,#61"
        $shortcut.WorkingDirectory = "$env:WINDIR\System32"
        $shortcut.IconLocation = "$env:WINDIR\System32\shell32.dll,25"
        $shortcut.Description = "Abrir caixa Executar"
        $shortcut.Save()

        # Tenta fixar usando verbos do Explorer
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace($shortcutDir)
        $item = $folder.ParseName($shortcutName)

        if (-not $item) {
            throw "Não foi possível localizar o atalho criado: $shortcutPath"
        }

        $pinVerbs = @(
            "Fixar na barra de tarefas",
            "Pin to taskbar",
            "Pin to Taskbar"
        )

        $verb = $item.Verbs() | Where-Object {
            $cleanName = $_.Name.Replace("&", "").Trim()
            $pinVerbs -contains $cleanName
        } | Select-Object -First 1

        if ($verb) {
            $verb.DoIt()
            Start-Sleep -Milliseconds 800

            if (Test-Path (Join-Path $taskbarPins $shortcutName)) {
                Write-Log "'Executar' fixado na barra de tarefas com sucesso." 'OK'
            } else {
                Write-Log "Comando de fixação executado, mas não foi possível confirmar se foi fixado." 'WARN'
            }
        }
        else {
            Write-Log "Não encontrei a opção 'Fixar na barra de tarefas'. Talvez o Windows tenha bloqueado esse método." 'WARN'
            Write-Log "Atalho criado em: $shortcutPath" 'INFO'
        }
    }
}

try {
    Ensure-Elevated

    Write-Log "Iniciando script..." 'INFO'

    $appxApps = @(
        "Microsoft.Edge"
        "Microsoft.XboxApp"
        "Microsoft.XboxGamingOverlay"
        "Microsoft.MicrosoftSolitaireCollection"
        "Microsoft.Office.OneNote"
        "Microsoft.MSPaint"
        "Microsoft.SkypeApp"
        "Microsoft.549981C3F5F10"
        "Microsoft.BingWeather"
        "Microsoft.BingNews"
        "Microsoft.MixedReality.Portal"
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.MicrosoftTeams"
        "Microsoft.Microsoft3DViewer"
        "Microsoft.Office.Project"
        "Microsoft.Office.Publisher"
        "Microsoft.365Copilot"
        "Microsoft.OneDrive"
        "Microsoft.LinkedIn"
        "Microsoft.Clipchamp"
        "Microsoft.Todos"
        "Microsoft.GamingApp"
        "Microsoft.Bing"
        "Microsoft.WindowsPay"
        "Microsoft.XboxSpeechToTextOverlay"
        "Microsoft.XboxIdentityProvider"
        "Microsoft.XboxLive"
    )

    $packagesToInstall = @(
        "Google.Chrome"
        "Mozilla.Firefox"
        "SumatraPDF.SumatraPDF"
        "RevoUninstaller.RevoUninstaller"
        "Microsoft.LanguageExperiencePack.ja-jp"
        "RARLab.WinRAR"
        "AnyDesk.AnyDesk"
        "winaero.tweaker"
    )

    Remove-AppxPackagesSafe -PackageNames $appxApps

    if (-not (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet)) {
        Write-Log "Sem conexão com a internet. Pulando instalação de pacotes." 'WARN'
    }
    else {
        Ensure-Winget
        Update-AllPackagesWithWinget
        Install-WingetPackagesIfMissing -PackageIds $packagesToInstall
    }

    Set-MouseSettings
    Pin-RunToTaskbar
    Restart-Explorer
    Open-FileExplorerOptions

    Write-Log "Script concluído com sucesso." 'OK'
}
catch {
    Write-Log "Erro fatal: $($_.Exception.Message)" 'ERROR'
    exit 1
}
