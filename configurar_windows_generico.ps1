#Requires -Version 5.1

param(
    [switch]$SkipWinget,

    # All: fase de máquina (admin) + fase de usuário. Machine/User: apenas a fase indicada.
    [ValidateSet('All', 'Machine', 'User')]
    [string]$Phase = 'All',

    # Usado pela fase de usuário quando executada em outra conta via tarefa agendada
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Em Windows 64-bit, um PowerShell 32-bit (iniciado por um processo 32-bit) tem HKLM\SOFTWARE
# redirecionado para WOW6432Node e System32 para SysWOW64. Relança no PowerShell nativo 64-bit.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -Path $nativePowerShell) {
        Write-Host "PowerShell 32-bit detectado em Windows 64-bit. Relançando em 64-bit..." -ForegroundColor Yellow
        $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($key in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$key]
            if ($value -is [switch]) {
                if ($value.IsPresent) { $relaunchArgs += "-$key" }
            }
            else {
                $relaunchArgs += "-$key", "$value"
            }
        }
        & $nativePowerShell @relaunchArgs
        exit $LASTEXITCODE
    }
}

# Contadores do resumo final
$script:StepResults = [ordered]@{ OK = 0; Falhas = 0 }
$script:FailedSteps = New-Object System.Collections.Generic.List[string]
$script:ExplorerRestartRequested = $false

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

function Invoke-Safely {
    param(
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        # Por padrão uma falha é registrada e o script continua. -Critical interrompe a execução.
        [switch]$Critical
    )

    Write-Log $StepName 'INFO'

    try {
        & $ScriptBlock
        $script:StepResults.OK++
        Write-Log "$StepName concluído." 'OK'
    }
    catch {
        $script:StepResults.Falhas++
        $script:FailedSteps.Add($StepName)
        Write-Log "$StepName falhou: $($_.Exception.Message)" 'ERROR'
        if ($Critical) {
            throw
        }
    }
}

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-StepSummary {
    param([Parameter(Mandatory = $true)][string]$Title)

    $level = if ($script:StepResults.Falhas -gt 0) { 'WARN' } else { 'OK' }
    Write-Log "$Title - etapas OK: $($script:StepResults.OK); falhas: $($script:StepResults.Falhas)" $level
    foreach ($step in $script:FailedSteps) {
        Write-Log "  Falhou: $step" 'WARN'
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

function Import-NativeMethods {
    if ('WinAPI.NativeMethods' -as [type]) {
        return
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinAPI
{
    public static class NativeMethods
    {
        [DllImport("shell32.dll", CharSet=CharSet.Auto)]
        public static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
    }
}
'@
    }
    catch {
        Write-Log "Falha ao registrar métodos nativos: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Invoke-ExplorerRefresh {
    Import-NativeMethods

    [UIntPtr]$result = [UIntPtr]::Zero
    [WinAPI.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    # Envia WM_SETTINGCHANGE para o broadcast handle; passa lParam como IntPtr::Zero
    [void][WinAPI.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$result)
}

function Set-ExplorerStartFolder {
    Invoke-Safely "Definindo pasta de abertura do Explorer para Downloads" {
        Set-ItemProperty `
            -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
            -Name "LaunchTo" `
            -Type DWord `
            -Value 3
    }
}

function Disable-WindowsSpotlight {
    Invoke-Safely "Desativando Windows Spotlight/Destaques" {
        $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

        $pairs = @{
            'RotatingLockScreenEnabled' = 0
            'RotatingLockScreenOverlayEnabled' = 0
            'SystemPaneSuggestionsEnabled' = 0
            'SubscribedContent-338389Enabled' = 0
            'SubscribedContent-338388Enabled' = 0
            'SubscribedContent-310093Enabled' = 0
        }

        foreach ($name in $pairs.Keys) {
            Set-RegistryValueIfNeeded -Path $cdm -Name $name -Value ([int]$pairs[$name]) -Type ([Microsoft.Win32.RegistryValueKind]::DWord)
        }

        Write-Log "Windows Spotlight/Destaques ajustado (ContentDeliveryManager)." 'INFO'
    }
}

function Disable-WindowsSpotlightCompletely {
    Invoke-Safely "Desativando Spotlight (limpeza completa)" {
        # Repete e amplia as chaves do ContentDeliveryManager
        $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $keys = @(
            'RotatingLockScreenEnabled',
            'RotatingLockScreenOverlayEnabled',
            'SystemPaneSuggestionsEnabled',
            'SubscribedContent-338389Enabled',
            'SubscribedContent-338388Enabled',
            'SubscribedContent-310093Enabled',
            'SubscribedContent-353971Enabled',
            'SubscribedContent-338090Enabled'
        )

        foreach ($k in $keys) {
            Set-RegistryValueIfNeeded -Path $cdm -Name $k -Value 0 -Type ([Microsoft.Win32.RegistryValueKind]::DWord)
        }

        # Remove assets em cache para evitar reaparecimento
        $assetsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets'
        if (Test-Path -Path $assetsPath) {
            try {
                Get-ChildItem -Path $assetsPath -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Log "Arquivos de assets do Spotlight removidos: $assetsPath" 'INFO'
            }
            catch {
                Write-Log "Falha ao remover assets: $($_.Exception.Message)" 'WARN'
            }
        }

        # Força reinício do host de experiência do Shell para aplicar alterações
        try {
            Get-CurrentSessionProcess -Name ShellExperienceHost | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-Log "Não foi possível reiniciar ShellExperienceHost: $($_.Exception.Message)" 'WARN'
        }

        Request-ExplorerRestart
        Write-Log "Tentativa completa para desativar Spotlight executada." 'INFO'
    }
}

function Hide-SpotlightImageIcon {
    Invoke-Safely "Ocultando ícone 'Saiba mais sobre essa imagem' do Spotlight" {
        # Remove o ícone "Saiba mais sobre essa imagem" do Windows Spotlight no Windows 10

        $guid = "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}"

        $hidePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        $nameSpacePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$guid"

        # Cria a chave de ocultação, se necessário
        if (-not (Test-Path $hidePath)) {
            New-Item -Path $hidePath -Force | Out-Null
        }

        # Manda o Windows ocultar o ícone
        New-ItemProperty `
            -Path $hidePath `
            -Name $guid `
            -PropertyType DWord `
            -Value 1 `
            -Force | Out-Null

        # Remove a entrada do ícone do NameSpace
        if (Test-Path $nameSpacePath) {
            Remove-Item -Path $nameSpacePath -Recurse -Force
        }

        Request-ExplorerRestart
    }
}

function Set-DesktopIcons {
    Invoke-Safely "Ajustando ícones da área de trabalho (apenas Lixeira visível)" {
        $hidePaths = @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu'
        )

        $iconsToHide = @{
            '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' = 1 # This PC
            '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' = 1 # User Files
            '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' = 1 # Control Panel
            '{208D2C60-3AEA-1069-A2D7-08002B30309D}' = 1 # Network
        }

        foreach ($path in $hidePaths) {
            if (-not (Test-Path -Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }

            foreach ($guid in $iconsToHide.Keys) {
                Set-RegistryValueIfNeeded -Path $path -Name $guid -Value ([int]$iconsToHide[$guid]) -Type ([Microsoft.Win32.RegistryValueKind]::DWord)
            }

            # Garantir que a Lixeira esteja visível
            $recycleGuid = '{645FF040-5081-101B-9F08-00AA002F954E}'
            Set-RegistryValueIfNeeded -Path $path -Name $recycleGuid -Value 0 -Type ([Microsoft.Win32.RegistryValueKind]::DWord)
        }

        # Reinício do Explorer é feito uma única vez ao final da fase de usuário
        Request-ExplorerRestart
    }
}

function Set-StartMenuPersonalization {
    Invoke-Safely "Ajustando personalização do Menu Iniciar" {
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        # Múltiplos nomes possíveis para a opção "aplicativos adicionados recentemente" em diferentes builds/localizações
        $pairs = @{
            'Start_ShowMoreTiles' = 0
            'Start_NotifyNewApps' = 0
            'Start_NotifyNewAppsEnabled' = 0
            'Start_ShowRecentlyAddedApps' = 0
            'Start_ShowMostUsedApps' = 0
            'Start_ShowSuggestions' = 0
            'Start_ShowFullScreen' = 0
            'Start_TrackDocs' = 0
            'Start_ShowAccountNotifications' = 0
        }

        foreach ($name in $pairs.Keys) {
            try {
                $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
            }
            catch {
                $current = $null
            }

            if ($current -ne $pairs[$name]) {
                Set-RegistryValueIfNeeded -Path $path -Name $name -Value ([int]$pairs[$name]) -Type ([Microsoft.Win32.RegistryValueKind]::DWord)
                Write-Log "Start menu: definido $name = $($pairs[$name])" 'INFO'
            }
            else {
                Write-Log "Start menu: $name já igual a $current" 'INFO'
            }
        }

        # Reinício do Explorer é feito uma única vez ao final da fase de usuário
        Request-ExplorerRestart
    }
}

function New-SystemRestorePoint {
    param(
        [string]$Description = 'Antes de configurar_windows_generico'
    )

    Invoke-Safely "Criando ponto de restauração do sistema" {
        $systemDrive = "$env:SystemDrive\"

        # Serviços necessários para a criação do ponto (VSS e Shadow Copy Provider)
        foreach ($svcName in @('VSS', 'swprv')) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.StartType -eq 'Disabled') {
                Set-Service -Name $svcName -StartupType Manual
                Write-Log "Serviço $svcName estava desativado; alterado para Manual." 'WARN'
            }
        }

        # Habilita a Proteção do Sistema na unidade do Windows (desativada por padrão em muitas instalações)
        Enable-ComputerRestore -Drive $systemDrive
        Write-Log "Proteção do Sistema habilitada em $systemDrive" 'INFO'

        # Garante espaço para as cópias de sombra (sem espaço o ponto não é criado)
        try {
            $vssOut = & vssadmin.exe Resize ShadowStorage "/For=$env:SystemDrive" "/On=$env:SystemDrive" '/MaxSize=5%' 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "vssadmin não ajustou o armazenamento de sombra (código $LASTEXITCODE): $($vssOut -join ' ')" 'WARN'
            }
        }
        catch {
            Write-Log "Falha ao ajustar armazenamento de sombra: $($_.Exception.Message)" 'WARN'
        }

        # O Windows bloqueia a criação de mais de um ponto a cada 24h (apenas emite um aviso, sem erro).
        # Zera temporariamente a frequência mínima para permitir a criação.
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $freqName = 'SystemRestorePointCreationFrequency'
        $previousFreq = $null
        try { $previousFreq = (Get-ItemProperty -Path $srKey -Name $freqName -ErrorAction Stop).$freqName } catch { }

        $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_ }).Count

        try {
            New-ItemProperty -Path $srKey -Name $freqName -Value 0 -PropertyType DWord -Force | Out-Null
            Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -WarningAction SilentlyContinue -WarningVariable cpWarn
        }
        finally {
            if ($null -eq $previousFreq) {
                Remove-ItemProperty -Path $srKey -Name $freqName -ErrorAction SilentlyContinue
            }
            else {
                New-ItemProperty -Path $srKey -Name $freqName -Value $previousFreq -PropertyType DWord -Force | Out-Null
            }
        }

        # Checkpoint-Computer não lança erro quando o ponto é ignorado; confirma pela contagem
        $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_ }).Count
        if ($after -le $before) {
            $detail = if ($cpWarn) { ($cpWarn | ForEach-Object { $_.Message }) -join ' ' } else { 'nenhum ponto novo encontrado.' }
            throw "O ponto de restauração não foi criado: $detail"
        }

        Write-Log "Ponto de restauração '$Description' criado." 'OK'
    }
}

function Disable-SetupSuggestions {
    Invoke-Safely "Desativando 'Sugerir maneiras de terminar a configuração do computador'" {
        $dword = [Microsoft.Win32.RegistryValueKind]::DWord

        Set-RegistryValueIfNeeded -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
            -Name 'ScoobeSystemSettingEnabled' -Value 0 -Type $dword

        Set-RegistryValueIfNeeded -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Name 'SubscribedContent-310093Enabled' -Value 0 -Type $dword
    }
}

function Set-WallpaperToImage {
    Invoke-Safely "Verificando e ajustando fundo de tela para modo imagem" {
        $wallpaperPath = "HKCU:\Control Panel\Desktop"
        $wallpaperValue = $null
        
        try {
            $wallpaperValue = (Get-ItemProperty -Path $wallpaperPath -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper
        }
        catch {
            $wallpaperValue = $null
        }

            # Garante que os métodos nativos estejam registrados antes de usá-los
            Import-NativeMethods

        # Seleciona uma imagem padrão do Windows para o papel de parede
        $defaultWallpapers = @(
            "C:\Windows\Web\Wallpaper\Windows\img0.jpg",
            "C:\Windows\Web\Wallpaper\Windows\img1.jpg",
            "C:\Windows\Web\Wallpaper\Windows\Windows.bmp"
        )

        $selectedWallpaper = $null
        foreach ($wallpaper in $defaultWallpapers) {
            if (Test-Path -Path $wallpaper) {
                $selectedWallpaper = $wallpaper
                break
            }
        }

        if (-not $selectedWallpaper) {
            Write-Log "Nenhuma imagem padrão do Windows foi encontrada." 'WARN'
            return
        }

        if ($wallpaperValue -and (Test-Path -Path $wallpaperValue)) {
            if ($wallpaperValue -eq $selectedWallpaper) {
                Write-Log "O papel de parede já está definido como: $selectedWallpaper" 'INFO'
            }
            else {
                Write-Log "O papel de parede atual é válido, mas diferente do desejado: $wallpaperValue" 'INFO'
            }
        }
        else {
            Write-Log "Papel de parede atual não é válido ou não existe. Aplicando um novo." 'INFO'
        }

        Set-ItemProperty -Path $wallpaperPath -Name "Wallpaper" -Value $selectedWallpaper -Type String -Force
        Set-ItemProperty -Path $wallpaperPath -Name "WallpaperStyle" -Value "10" -Type String -Force
        Set-ItemProperty -Path $wallpaperPath -Name "TileWallpaper" -Value "0" -Type String -Force

        # Atualiza a tela de fundo usando SystemParametersInfo para Windows 10
        [WinAPI.NativeMethods]::SystemParametersInfo(0x0014, 0, $selectedWallpaper, 0x0001 -bor 0x0002) | Out-Null

        # Aplica tema de desktop para forçar o ajuste automático do papel de parede
        Set-WindowsThemeForWallpaper -WallpaperPath $selectedWallpaper

        Write-Log "Fundo de tela alterado para: $selectedWallpaper" 'INFO'
        Invoke-ExplorerRefresh
    }
}

function Set-WindowsThemeForWallpaper {
    param(
        [Parameter(Mandatory = $true)][string]$WallpaperPath
    )

    Invoke-Safely "Aplicando tema de desktop com o wallpaper" {
        # No Windows 10 (build < 22000) abrir o .theme gerado exibe "Este tema não pode ser aplicado
        # à área de trabalho", embora o papel de parede seja aplicado pelas APIs abaixo. Lá, usa só as APIs.
        $isWindows10 = [Environment]::OSVersion.Version.Build -lt 22000

        if ($isWindows10) {
            Write-Log "Windows 10 detectado: aplicando papel de parede sem abrir arquivo de tema." 'INFO'
        }
        else {
            $themeDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Themes"
            if (-not (Test-Path -Path $themeDir)) {
                New-Item -ItemType Directory -Path $themeDir -Force | Out-Null
            }

            $themeFile = Join-Path $themeDir "WallpaperTheme.theme"
            $themeContent = @"
[Theme]
DisplayName=Wallpaper Theme
; Gerado pelo script
[Control Panel\Desktop]
Wallpaper=$WallpaperPath
TileWallpaper=0
WallpaperStyle=10
Pattern=

[VisualStyles]
Path=%SystemRoot%\Resources\Themes\aero\aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
ColorizationColor=0
ColorizationAfterglow=0

[Boot]
Wallpaper=

[Sounds]
; Use the default Windows sound scheme
[SoundRules]
"@

            Set-Content -Path $themeFile -Value $themeContent -Encoding Unicode

            $themeRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
            Set-ItemProperty -Path $themeRegistryPath -Name 'CurrentTheme' -Value $themeFile -Type String -Force
            Set-ItemProperty -Path $themeRegistryPath -Name 'LastLoadedTheme' -Value $themeFile -Type String -Force

            try {
                Start-Process -FilePath $themeFile | Out-Null
            }
            catch {
                Write-Log "Falha ao aplicar o tema via Start-Process: $($_.Exception.Message)" 'WARN'
            }

            Start-Sleep -Seconds 2
        }

        Import-NativeMethods
        try {
            [WinAPI.NativeMethods]::SystemParametersInfo(0x0014, 0, $WallpaperPath, 0x0001 -bor 0x0002) | Out-Null
        }
        catch {
            Write-Log "SystemParametersInfo falhou: $($_.Exception.Message)" 'WARN'
        }

        try {
            Set-WallpaperViaDesktopWallpaperApi -WallpaperPath $WallpaperPath
        }
        catch {
            Write-Log "DesktopWallpaper COM não pôde ser usado: $($_.Exception.Message)" 'WARN'
            Write-Log "Tentando fallback via rundll32 e refresh de sistema." 'INFO'
            try {
                Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -NoNewWindow -Wait -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Falha ao executar rundll32: $($_.Exception.Message)" 'WARN'
            }
        }

        Invoke-ExplorerRefresh
    }
}

function Set-WallpaperViaDesktopWallpaperApi {
    param(
        [Parameter(Mandatory = $true)][string]$WallpaperPath
    )

    Invoke-Safely "Definindo papel de parede via DesktopWallpaper API" {
        # IDesktopWallpaper não tem ProgID nem IDispatch ("Shell.DesktopWallpaper" não existe),
        # então New-Object -ComObject falha com REGDB_E_CLASSNOTREG. Usa interop tipado via CLSID.
        if (-not ('WinAPI.DesktopWallpaperHelper' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinAPI
{
    [StructLayout(LayoutKind.Sequential)]
    public struct WallpaperRect { public int Left, Top, Right, Bottom; }

    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDesktopWallpaper
    {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
        uint GetMonitorDevicePathCount();
        WallpaperRect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(int position);
        int GetPosition();
        void SetSlideshow(IntPtr items);
        IntPtr GetSlideshow();
        void SetSlideshowOptions(int options, uint slideshowTick);
        void GetSlideshowOptions(out int options, out uint slideshowTick);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
        int GetStatus();
        void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    public static class DesktopWallpaperHelper
    {
        private static readonly Guid ClsidDesktopWallpaper = new Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD");

        // position: 0=Center, 1=Tile, 2=Stretch, 3=Fit, 4=Fill, 5=Span
        public static void Apply(string path, int position)
        {
            Type t = Type.GetTypeFromCLSID(ClsidDesktopWallpaper, true);
            IDesktopWallpaper dw = (IDesktopWallpaper)Activator.CreateInstance(t);
            try
            {
                dw.Enable(true);
                uint count = dw.GetMonitorDevicePathCount();
                if (count == 0)
                {
                    dw.SetWallpaper(null, path);
                }
                for (uint i = 0; i < count; i++)
                {
                    dw.SetWallpaper(dw.GetMonitorDevicePathAt(i), path);
                }
                dw.SetPosition(position);
            }
            finally
            {
                Marshal.ReleaseComObject(dw);
            }
        }
    }
}
'@
        }

        # 4 = Fill, equivalente a WallpaperStyle=10 no registro
        [WinAPI.DesktopWallpaperHelper]::Apply($WallpaperPath, 4)
    }
}

function Get-CurrentSessionProcess {
    param([Parameter(Mandatory = $true)][string]$Name)

    # Como administrador, Get-Process lista processos de TODAS as sessões (outros usuários logados).
    # Filtra pela sessão atual para não afetar a área de trabalho de outras pessoas.
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }
}

function Request-ExplorerRestart {
    # As etapas apenas sinalizam; o reinício acontece uma única vez ao final da fase de usuário.
    $script:ExplorerRestartRequested = $true
}

function Restart-Explorer {
    Invoke-Safely "Reiniciando o Explorer para aplicar alterações" {
        Get-CurrentSessionProcess -Name explorer | Stop-Process -Force -ErrorAction SilentlyContinue

        # O Windows (Winlogon, AutoRestartShell=1) relança o shell sozinho, como o usuário e sem elevação.
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Seconds 1
            $running = @(Get-CurrentSessionProcess -Name explorer).Count -gt 0
        } while (-not $running -and (Get-Date) -lt $deadline)

        if (-not $running) {
            if (Test-IsAdministrator) {
                # Start-Process a partir de um processo elevado criaria um shell elevado.
                # runas /trustlevel:0x20000 inicia com token de usuário comum.
                Write-Log "Explorer não voltou sozinho. Iniciando sem elevação." 'WARN'
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\runas.exe') -ArgumentList '/trustlevel:0x20000', (Join-Path $env:WINDIR 'explorer.exe') -WindowStyle Hidden
            }
            else {
                Write-Log "Explorer não voltou sozinho. Iniciando manualmente." 'WARN'
                Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe')
            }
            Start-Sleep -Seconds 3
        }

        Invoke-ExplorerRefresh
        $script:ExplorerRestartRequested = $false
    }
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

function Get-WingetExecutable {
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
    }
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
        }
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
    }
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
        }
    }
}

function Add-RunToTaskbarPin {
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
            "Fixar na Barra de Tarefas",
            "Pin to taskbar",
            "Pin to Taskbar",
            "Pin na barra de tarefas",
            "Pin to Tas&kbar"
        )

        $verb = $item.Verbs() | ForEach-Object {
            $name = $_.Name -as [string]
            if (-not $name) {
                return
            }

            $cleanName = $name.Replace("&", "").Trim()
            [PSCustomObject]@{
                Verb      = $_
                CleanName = $cleanName
            }
        } | Where-Object {
            $pinVerbs -contains $_.CleanName -or
            $_.CleanName -match '(?i)\b(pin|fixar)\b.*\b(taskbar|barra)\b' -or
            $_.CleanName -match '(?i)\b(taskbar|barra)\b.*\b(pin|fixar)\b'
        } | Select-Object -First 1

        if (-not $verb) {
            $availableVerbNames = $item.Verbs() | ForEach-Object {
                $name = $_.Name -as [string]
                if ($name) { $name.Replace("&", "").Trim() }
            } | Where-Object { $_ }

            Write-Log "Verbos disponíveis: $($availableVerbNames -join '; ')" 'INFO'
        }

        if ($verb) {
            $verb.Verb.DoIt()
            Start-Sleep -Milliseconds 800

            if (Test-Path (Join-Path $taskbarPins $shortcutName)) {
                Write-Log "'Executar' fixado na barra de tarefas com sucesso." 'OK'
            } else {
                Write-Log "Comando de fixação executado, mas não foi possível confirmar se foi fixado." 'WARN'
            }
        }
        else {
            Write-Log "Não encontrei a opção 'Fixar na barra de tarefas'. Tentando fallback direto via pasta de itens fixados." 'WARN'

            $taskbarShortcutPath = Join-Path $taskbarPins $shortcutName
            
            Write-Log "Caminho do taskbar pins: $taskbarPins" 'INFO'
            Write-Log "Caminho do atalho original: $shortcutPath" 'INFO'
            Write-Log "Caminho de destino: $taskbarShortcutPath" 'INFO'
            
            if (-not (Test-Path -Path $taskbarPins)) {
                Write-Log "Pasta de pins não existe. Tentando criar: $taskbarPins" 'WARN'
                try {
                    New-Item -Path $taskbarPins -ItemType Directory -Force | Out-Null
                    Write-Log "Pasta criada com sucesso." 'INFO'
                }
                catch {
                    Write-Log "Erro ao criar pasta de pins: $($_.Exception.Message)" 'ERROR'
                    $taskbarPins = $null
                }
            }
            else {
                Write-Log "Pasta de pins existe." 'INFO'
            }

            if ($taskbarPins) {
                try {
                    if (Test-Path $shortcutPath) {
                        Write-Log "Atalho original existe. Copiando..." 'INFO'
                        Copy-Item -Path $shortcutPath -Destination $taskbarShortcutPath -Force -ErrorAction Stop
                        Write-Log "Atalho copiado com sucesso." 'INFO'
                        
                        Start-Sleep -Milliseconds 500
                        Invoke-ExplorerRefresh

                        if (Test-Path $taskbarShortcutPath) {
                            Write-Log "'Executar' fixado na barra de tarefas via fallback (cópia direta)." 'OK'
                        }
                        else {
                            Write-Log "Cópia foi feita mas o arquivo não está acessível imediatamente. Aguardando..." 'WARN'
                            Start-Sleep -Milliseconds 1000
                            if (Test-Path $taskbarShortcutPath) {
                                Write-Log "'Executar' confirmado após espera." 'OK'
                            }
                            else {
                                Write-Log "Atalho criado em: $shortcutPath (não confirmado no taskbar)" 'INFO'
                            }
                        }
                    }
                    else {
                        Write-Log "Atalho original não existe em: $shortcutPath" 'ERROR'
                    }
                }
                catch {
                    Write-Log "Fallback direto falhou: $($_.Exception.Message)" 'ERROR'
                    Write-Log "Atalho foi criado em: $shortcutPath (pode ser fixado manualmente)" 'INFO'
                }
            }
        }
    }
}

function Import-ConfigFromJson {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Arquivo de configuração não encontrado: $ConfigPath"
    }

    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        Write-Log "Configuração carregada de: $ConfigPath" 'OK'
        return $config
    }
    catch {
        throw "Erro ao carregar configuração JSON: $($_.Exception.Message)"
    }
}

function Test-InternetConnection {
    try {
        Resolve-DnsName -Name 'www.msftconnecttest.com' -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        try {
            Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }
}

function Invoke-MachinePhase {
    # Fase de máquina: exige administrador e altera o sistema como um todo (HKLM, Appx de todos os usuários, winget).
    Write-Log "=== Fase de máquina ===" 'INFO'

    # Define o caminho do arquivo de configuração
    $scriptDir = Split-Path -Parent $PSCommandPath
    $configPath = Join-Path $scriptDir "config.json"

    # Configuração é pré-requisito: sem ela a fase de máquina não continua
    $config = Import-ConfigFromJson -ConfigPath $configPath
    $appxApps = $config.remove
    $packagesToInstall = $config.install

    # Cria ponto de restauração antes de qualquer alteração no sistema
    New-SystemRestorePoint

    Remove-AppxPackagesSafe -PackageNames $appxApps

    if ($SkipWinget) {
        Write-Log "Opção SkipWinget ativada. Pulando instalação de pacotes via Winget." 'WARN'
    }
    elseif (-not (Test-InternetConnection)) {
        Write-Log "Sem conexão com a internet. Pulando instalação de pacotes." 'WARN'
    }
    else {
        $script:WingetReady = $false
        Invoke-Safely "Localizando Winget" {
            Get-WingetExecutable
            $script:WingetReady = $true
        }

        if ($script:WingetReady) {
            Update-AllPackagesWithWinget
            Install-WingetPackagesIfMissing -PackageIds $packagesToInstall
        }
    }
}

function Invoke-UserPhase {
    # Fase de usuário: tudo que grava em HKCU/perfil. Deve rodar na conta de quem usa a área de trabalho.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Log "=== Fase de usuário ($identity) ===" 'INFO'

    Set-MouseSettings
    Set-ExplorerStartFolder
    Disable-WindowsSpotlightCompletely
    # Oculta o ícone 'Saiba mais sobre essa imagem' (solução testada pelo usuário)
    Hide-SpotlightImageIcon
    # Ajusta personalização do Menu Iniciar
    Set-StartMenuPersonalization
    # Desativa "Sugerir maneiras de terminar a configuração do computador"
    Disable-SetupSuggestions
    # Ajusta ícones da área de trabalho (apenas Lixeira visível)
    Set-DesktopIcons
    Set-WallpaperToImage
    Add-RunToTaskbarPin

    # Reinício único do Explorer, apenas se alguma etapa pediu
    if ($script:ExplorerRestartRequested) {
        Restart-Explorer
    }
}

function Get-InteractiveUser {
    # Descobre o dono da área de trabalho (explorer.exe) da sessão atual. Quando o script roda como
    # SYSTEM (sessão 0), usa o usuário conectado ao console.
    $sessionId = (Get-Process -Id $PID).SessionId
    $explorer = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sessionId" -ErrorAction SilentlyContinue) |
        Select-Object -First 1

    if (-not $explorer) {
        $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if (-not $consoleUser) {
            return $null
        }

        foreach ($candidate in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
            $candidateOwner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwner
            if ($candidateOwner.ReturnValue -eq 0 -and "$($candidateOwner.Domain)\$($candidateOwner.User)" -ieq $consoleUser) {
                $explorer = $candidate
                break
            }
        }

        if (-not $explorer) {
            return $null
        }
    }

    $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
    $ownerSid = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or $ownerSid.ReturnValue -ne 0) {
        return $null
    }

    return [PSCustomObject]@{
        Name = "$($owner.Domain)\$($owner.User)"
        Sid  = $ownerSid.Sid
    }
}

function Invoke-UserPhaseAsUser {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$UserSid
    )

    # Copia o script para um local que o usuário consegue ler e onde pode gravar o log
    $stageDir = Join-Path $env:ProgramData 'configurar_windows_generico'
    if (-not (Test-Path -Path $stageDir)) {
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    }

    $acl = Get-Acl -Path $stageDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($UserSid)), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $stageDir -AclObject $acl

    $stageScript = Join-Path $stageDir 'configurar_windows_generico.ps1'
    Copy-Item -Path $PSCommandPath -Destination $stageScript -Force
    $logFile = Join-Path $stageDir ("fase_usuario_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $taskName = 'configurar_windows_generico_fase_usuario'
    $powerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stageScript`" -Phase User -LogPath `"$logFile`""

    $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
    # Interactive + Limited: roda na sessão já aberta do usuário, sem pedir senha e sem elevação
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Log "Fase de usuário iniciada na conta $UserName. Aguardando conclusão..." 'INFO'

        $deadline = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $taskName).State
        } while ($state -in @('Running', 'Queued') -and (Get-Date) -lt $deadline)

        $taskResult = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult

        if (Test-Path -Path $logFile) {
            Write-Host ''
            Write-Host "----- Log da fase de usuário ($UserName) -----" -ForegroundColor Gray
            Get-Content -Path $logFile | ForEach-Object { Write-Host $_ }
            Write-Host "----- Fim do log ($logFile) -----" -ForegroundColor Gray
            Write-Host ''
        }
        else {
            Write-Log "Log da fase de usuário não foi gerado: $logFile" 'WARN'
        }

        if ($state -in @('Running', 'Queued')) {
            throw "A fase de usuário não terminou em 15 minutos."
        }
        if ($taskResult -ne 0) {
            throw "A fase de usuário terminou com código $taskResult (veja o log acima)."
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $stageScript -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UserPhaseForInteractiveUser {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $interactive = Get-InteractiveUser

    if (-not $interactive) {
        Write-Log "Nenhum usuário com área de trabalho ativa foi encontrado. Fase de usuário ignorada; execute com -Phase User na conta desejada." 'WARN'
        return
    }

    if ($interactive.Sid -eq $current.User.Value) {
        Invoke-UserPhase
        return
    }

    # Ex.: usuário padrão executou o .bat e um técnico digitou a senha de administrador no UAC.
    # O HKCU deste processo é o do administrador, então a fase de usuário roda na conta da sessão.
    Write-Log "Script elevado como '$($current.Name)', mas a área de trabalho é de '$($interactive.Name)'. Aplicando as configurações de usuário na conta '$($interactive.Name)'." 'WARN'
    Invoke-Safely "Executando fase de usuário como $($interactive.Name)" {
        Invoke-UserPhaseAsUser -UserName $interactive.Name -UserSid $interactive.Sid
    }
}

$exitCode = 0
$transcriptStarted = $false

try {
    if ($LogPath) {
        Start-Transcript -Path $LogPath -Force | Out-Null
        $transcriptStarted = $true
    }

    $osVersion = [Environment]::OSVersion.Version
    Write-Log ("Iniciando script (fase: {0}; Windows build {1}; SO 64-bit: {2}; processo 64-bit: {3})" -f $Phase, $osVersion.Build, [Environment]::Is64BitOperatingSystem, [Environment]::Is64BitProcess) 'INFO'

    if ($Phase -in @('All', 'Machine')) {
        if (-not (Test-IsAdministrator)) {
            throw "A fase de máquina exige execução como administrador. Use o run.bat ou execute com -Phase User para aplicar apenas as configurações de usuário."
        }
        Invoke-MachinePhase
    }

    if ($Phase -eq 'User') {
        Invoke-UserPhase
    }
    elseif ($Phase -eq 'All') {
        Invoke-UserPhaseForInteractiveUser
    }

    Write-StepSummary -Title "Resumo da execução (fase $Phase)"
    if ($script:StepResults.Falhas -gt 0) {
        $exitCode = 2
        Write-Log "Script concluído com falhas em algumas etapas." 'WARN'
    }
    else {
        Write-Log "Script concluído com sucesso." 'OK'
    }
}
catch {
    Write-Log "Erro fatal: $($_.Exception.Message)" 'ERROR'
    $exitCode = 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

exit $exitCode
