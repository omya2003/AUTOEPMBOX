<#
.SYNOPSIS
    One-click hardening + Iraje EPM installation for Windows Server.

.DESCRIPTION
    Automates every step of the "EPM Phase 1 box making" runbook (NTP role + EPM
    server role). Idempotent, reboot-resumable via a SYSTEM-context scheduled task.
    Minimum supported OS: Windows Server 2012 R2.

.PARAMETER Role
    NTPServer   - run only the dedicated-NTP-server configuration (Phase 1).
    EPMServer   - run the full EPM server setup (Phases 2..17).

.PARAMETER DomainName
    Active Directory forest / domain name to create. Required for -Role EPMServer.
    Doc convention: end in .local  (e.g. 'Iepm.local').

.PARAMETER ServerIP
    Primary IPv4 of the EPM server (used to bind the HTTPS site). Required for EPMServer.

.PARAMETER NtpServerIP
    IP of the dedicated NTP server. Required for EPMServer; ignored for NTPServer role.

.PARAMETER ArchivePassword
    Password for the EPM_Tools_Setup.7z archive. Required for EPMServer.

.PARAMETER DsrmPassword
    Directory Services Restore Mode password set during DC promotion.
    Default: doc value '@@Re$tore@!2323@@'.

.PARAMETER iEpmPassword
    Password for the iEPM admin AD user. Default: doc value 'Enc$rypt@012026'.

.PARAMETER DefaultUserPassword
    Password applied to every other AD service/admin user the script creates
    (irajesrv, epmsusr, irajejobs, iraje, irajedev, winupdate). REQUIRED.

.PARAMETER AdministratorPassword
    Password set on the renamed built-in Administrator account (irajeacv).
    Defaults to -DefaultUserPassword.

.PARAMETER MySqlRootPassword
    MySQL root password. Default: doc value '@@Fzcv##2026@@'.

.PARAMETER CustomRdpPort
    Optional additional TCP port to allow inbound for RDP.

.PARAMETER HttpsPort
    HTTPS port for the EPMDashboard IIS site. Default 443.

.PARAMETER AssetsRoot
    Path to the prerequisites folder (default: .\assets next to this script).

.PARAMETER DontEnableFirewall
    Skip turning Windows Firewall on at the end of the firewall step.

.PARAMETER Resume
    Internal: passed automatically by the post-reboot scheduled task. Continues
    execution from the saved state file.

.EXAMPLE
    # NTP server box
    .\Install-IrajeEPM.ps1 -Role NTPServer

.EXAMPLE
    # EPM server box (one-click)
    .\Install-IrajeEPM.ps1 `
        -Role EPMServer `
        -DomainName       Iepm.local `
        -ServerIP         192.168.1.50 `
        -NtpServerIP      192.168.1.81 `
        -ArchivePassword  'tools-zip-pwd' `
        -DefaultUserPassword 'Default$User2026!'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('NTPServer','EPMServer')]
    [string]$Role,

    # EPMServer required:
    [string]$DomainName,
    [string]$ServerIP,
    [string]$NtpServerIP,
    [string]$ArchivePassword,
    [string]$DefaultUserPassword,

    # EPMServer optional (sensible defaults):
    [string]$DsrmPassword           = '@@Re$tore@!2323@@',
    [string]$iEpmPassword           = 'Enc$rypt@012026',
    [string]$AdministratorPassword,
    [string]$MySqlRootPassword      = '@@Fzcv##2026@@',
    [int]   $CustomRdpPort,
    [int]   $HttpsPort              = 443,
    [string]$AssetsRoot,
    [switch]$DontEnableFirewall,

    # Internal:
    [switch]$Resume
)

# ----------------------------------------------------------------------------
# Bootstrap
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir  = Split-Path -Parent $scriptPath

# Auto-detect the project root so the script works whether it lives at the
# project root (flat layout) or inside a Scripts\ subfolder. Modules and the
# default assets folder are expected to be siblings of the project root.
$projectRoot = $scriptDir
$coreProbe   = 'modules\IrajeEPM.Core.psm1'
if (-not (Test-Path -LiteralPath (Join-Path $scriptDir $coreProbe))) {
    $parent = Split-Path -Parent $scriptDir
    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent $coreProbe))) {
        $projectRoot = $parent
    }
}

# Resolve assets root (default: 'assets' folder at the project root).
# Avoid the null-coalescing operator (??) - Server 2012R2/2016 ship with PowerShell 5.1.
if (-not $AssetsRoot) { $AssetsRoot = Join-Path $projectRoot 'assets' }
$resolved = Resolve-Path -LiteralPath $AssetsRoot -ErrorAction SilentlyContinue
if ($resolved) { $AssetsRoot = $resolved.ProviderPath }

# Import modules from the resolved project root.
Import-Module (Join-Path $projectRoot 'modules\IrajeEPM.Core.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'modules\IrajeEPM.NTP.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'modules\IrajeEPM.EPMServer.psm1')  -Force -DisableNameChecking

Initialize-IrajeLog
Write-IrajeLog -Level OK -Message ('=' * 78)
Write-IrajeLog -Level OK -Message "Iraje EPM box-making script - role: $Role, resume: $Resume"
Write-IrajeLog -Level OK -Message ('=' * 78)

try {
    Assert-IsAdmin
    $osInfo = Assert-SupportedOS

    # ----------------------------------------------------------------------------
    # NTPServer role
    # ----------------------------------------------------------------------------
    if ($Role -eq 'NTPServer') {
        $state = Get-IrajeState
        if (-not $state -or $state.Role -ne 'NTPServer') {
            $params = @{ Role = 'NTPServer' }
            $state = New-IrajeState -Role 'NTPServer' -Params $params -StepNames (Get-NtpStepNames)
            Save-IrajeState -State $state
        }
        Invoke-IrajeNtpServerSetup -State $state
        Unregister-IrajeResumeTask
        Write-IrajeLog -Level OK -Message ('=' * 78)
        Write-IrajeLog -Level OK -Message 'NTP server setup finished.'
        Write-IrajeLog -Level OK -Message ('=' * 78)
        Stop-IrajeLog
        return
    }

    # ----------------------------------------------------------------------------
    # EPMServer role - param normalisation
    # ----------------------------------------------------------------------------

    # If a state file from a prior run exists for the same role, always continue from
    # it - the resume scheduled task will re-launch us with the same params, and we
    # must not overwrite progress. To start over, delete C:\ProgramData\IrajeEPM\state.json.
    $existing = Get-IrajeState
    if ($existing -and $existing.Role -eq 'EPMServer') {
        Write-IrajeLog -Level INFO -Message 'Continuing EPMServer run from saved state.'
        $state = $existing
        $P = ConvertTo-Hashtable $state.Params
    } else {
        foreach ($name in @('DomainName','ServerIP','NtpServerIP','ArchivePassword','DefaultUserPassword')) {
            if (-not (Get-Variable -Name $name -Scope 0).Value) {
                throw "Missing required parameter: -$name (for -Role EPMServer)."
            }
        }
        if (-not $AdministratorPassword) { $AdministratorPassword = $DefaultUserPassword }

        # Validate assets layout up front
        foreach ($p in @(
            (Join-Path $AssetsRoot 'EPM_Setup_files_V1'),
            (Join-Path $AssetsRoot 'EPM_Setup_files_V1\EPM_App_Setup_Configuration')
        )) {
            if (-not (Test-Path -LiteralPath $p)) {
                throw "Missing required assets path: $p"
            }
        }
        $toolsArchive = Join-Path $AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup.7z'
        $toolsFolder  = Join-Path $AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
        if (-not (Test-Path -LiteralPath $toolsArchive) -and -not (Test-Path -LiteralPath $toolsFolder)) {
            throw "Neither EPM_Tools_Setup.7z nor extracted EPM_Tools_Setup folder found under $AssetsRoot\EPM_Setup_files_V1\"
        }

        $P = @{
            Role                  = 'EPMServer'
            DomainName            = $DomainName
            ServerIP              = $ServerIP
            NtpServerIP           = $NtpServerIP
            ArchivePassword       = $ArchivePassword
            DsrmPassword          = $DsrmPassword
            iEpmPassword          = $iEpmPassword
            DefaultUserPassword   = $DefaultUserPassword
            AdministratorPassword = $AdministratorPassword
            MySqlRootPassword     = $MySqlRootPassword
            CustomRdpPort         = $CustomRdpPort
            HttpsPort             = $HttpsPort
            AssetsRoot            = $AssetsRoot
            DontEnableFirewall    = [bool]$DontEnableFirewall
        }
        $state = New-IrajeState -Role 'EPMServer' -Params $P -StepNames (Get-EpmServerStepNames)
        Save-IrajeState -State $state
    }

    # Run the orchestrator
    Invoke-IrajeEpmServerSetup -State $state -ScriptPath $scriptPath

    # All done - clean up resume task
    Unregister-IrajeResumeTask

    Write-IrajeLog -Level OK -Message ('=' * 78)
    Write-IrajeLog -Level OK -Message 'EPM server box-making finished successfully.'
    Write-IrajeLog -Level OK -Message ("Domain:        {0}" -f $state.Params.DomainName)
    Write-IrajeLog -Level OK -Message ("Server IP:     {0}" -f $state.Params.ServerIP)
    Write-IrajeLog -Level OK -Message ("HTTPS endpoint: https://{0}:{1}/" -f $state.Params.ServerIP, $state.Params.HttpsPort)
    Write-IrajeLog -Level OK -Message ('=' * 78)
}
catch {
    Write-IrajeLog -Level ERROR -Message "Run failed: $($_.Exception.Message)"
    Write-IrajeLog -Level ERROR -Message ($_.ScriptStackTrace)
    Stop-IrajeLog
    exit 1
}
finally {
    Stop-IrajeLog
}
