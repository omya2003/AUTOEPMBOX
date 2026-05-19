#requires -Version 4.0
<#
    IrajeEPM.NTP.psm1
    Phase 1 - dedicated NTP server configuration.

    Steps (idempotent):
        ConfigureNtpManualPeerList     w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update
        SetAnnounceFlags               HKLM\...\W32Time\Config\AnnounceFlags = 5
        EnableNtpServerProvider        HKLM\...\W32Time\TimeProviders\NtpServer\Enabled = 1
        OpenNtpFirewall                Inbound UDP/123 allow rule "NTP Server UDP 123"
        RestartW32time                 net stop/start w32time
        VerifyNtpServer                w32tm /query /status + /configuration sanity check
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Re-import core if not already loaded. PowerShell handles double-import gracefully.
Import-Module (Join-Path $PSScriptRoot 'IrajeEPM.Core.psm1') -Force -DisableNameChecking

$script:NtpStepNames = @(
    'ConfigureNtpManualPeerList'
    'SetAnnounceFlags'
    'EnableNtpServerProvider'
    'OpenNtpFirewall'
    'RestartW32time'
    'VerifyNtpServer'
)

function Get-NtpStepNames { return $script:NtpStepNames }

function Invoke-NtpManualPeerList {
    Write-IrajeLog -Level STEP -Message 'Configuring NTP manual peer list (time.windows.com, pool.ntp.org)'
    Invoke-Native -File 'w32tm.exe' -Arguments @(
        '/config',
        '/manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8"',
        '/syncfromflags:manual',
        '/reliable:yes',
        '/update'
    ) | Out-Null
}

function Set-NtpAnnounceFlags {
    Write-IrajeLog -Level STEP -Message 'Setting AnnounceFlags = 5 (reliable NTP source)'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
    Set-ItemProperty -Path $path -Name 'AnnounceFlags' -Value 5 -Type DWord
}

function Enable-NtpServerProvider {
    Write-IrajeLog -Level STEP -Message 'Enabling NtpServer time provider'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer'
    Set-ItemProperty -Path $path -Name 'Enabled' -Value 1 -Type DWord
}

function Open-NtpFirewallRule {
    $name = 'NTP Server UDP 123'
    Write-IrajeLog -Level STEP -Message "Ensuring firewall rule '$name' for UDP/123 inbound"
    $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-IrajeLog -Level OK -Message "Firewall rule '$name' already present."
        return
    }
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow | Out-Null
    Write-IrajeLog -Level OK -Message "Created firewall rule '$name'."
}

function Restart-W32Time {
    Write-IrajeLog -Level STEP -Message 'Restarting Windows Time service (w32time)'
    # Use Restart-Service so it handles already-stopped / already-running cases idempotently
    try { Stop-Service  -Name 'w32time' -Force -ErrorAction Stop } catch { Write-IrajeLog -Level WARN -Message "Stop w32time: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
    Start-Service -Name 'w32time' -ErrorAction Stop
    # Give the service a moment to start receiving
    Start-Sleep -Seconds 3
}

function Test-NtpServerConfigured {
    Write-IrajeLog -Level STEP -Message 'Verifying NTP server configuration'
    $statusRes = Invoke-Native -File 'w32tm.exe' -Arguments @('/query','/status')        -AllowFail
    $cfgRes    = Invoke-Native -File 'w32tm.exe' -Arguments @('/query','/configuration') -AllowFail

    $statusOk = $statusRes.ExitCode -eq 0 -and ($statusRes.StdOut -match 'Leap Indicator')
    $cfgText  = $cfgRes.StdOut
    $hasNtpServerEnabled = ($cfgText -match '(?ms)\[NtpServer\][^\[]*Enabled:\s*1')
    $hasFlags5           = ($cfgText -match '(?m)AnnounceFlags:\s*5')

    Write-IrajeLog -Level INFO -Message "w32tm status reachable: $statusOk; NtpServer Enabled: $hasNtpServerEnabled; AnnounceFlags=5: $hasFlags5"
    if (-not ($statusOk -and $hasNtpServerEnabled -and $hasFlags5)) {
        throw "NTP server verification failed. status=$statusOk enabled=$hasNtpServerEnabled flags5=$hasFlags5"
    }
    Write-IrajeLog -Level OK -Message 'NTP server reports a healthy configuration.'
}

function Invoke-IrajeNtpServerSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $State)

    Invoke-IrajeStep -State $State -Name 'ConfigureNtpManualPeerList' -Body { Invoke-NtpManualPeerList }
    Invoke-IrajeStep -State $State -Name 'SetAnnounceFlags'           -Body { Set-NtpAnnounceFlags }
    Invoke-IrajeStep -State $State -Name 'EnableNtpServerProvider'    -Body { Enable-NtpServerProvider }
    Invoke-IrajeStep -State $State -Name 'OpenNtpFirewall'            -Body { Open-NtpFirewallRule }
    Invoke-IrajeStep -State $State -Name 'RestartW32time'             -Body { Restart-W32Time }
    Invoke-IrajeStep -State $State -Name 'VerifyNtpServer'            -Body { Test-NtpServerConfigured }

    Write-IrajeLog -Level OK -Message 'NTP server role: all steps complete.'
}

Export-ModuleMember -Function Get-NtpStepNames, Invoke-IrajeNtpServerSetup
