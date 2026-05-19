#requires -Version 4.0
<#
    IrajeEPM.EPMServer.psm1
    Phases 2..17 of the box-making runbook - preflight through IIS warm-up.

    All step functions are idempotent. The orchestrator (Invoke-IrajeEpmServerSetup)
    calls Invoke-IrajeStep on each one in order; reboot-causing steps register the
    resume scheduled task before triggering the reboot, then the script resumes from
    the same state file after the box comes back.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'IrajeEPM.Core.psm1') -Force -DisableNameChecking

# ---------- step list (also the execution order) ----------

$script:EpmServerStepNames = @(
    # Phase 2 - preflight & basic OS prep
    'PreflightChecks'
    'DisableNla'
    'SyncTimeWithNtpServer'

    # Phase 3 - AD DS install + DC promotion (REBOOT after PromoteToDc)
    'InstallAdDsRoles'
    'PromoteToDc'

    # Phase 4 - RDS + IIS roles (REBOOT after InstallRdsAndIisRoles)
    'InstallRdsAndIisRoles'

    # Phase 5 - additional features
    'InstallAdditionalFeatures'

    # Phase 6 - RDS deployment / Gateway / Licensing / Collection
    'InstallRdsSessionDeployment'
    'ConfigureRdGateway'
    'ConfigureRdLicensing'
    'CreateEpmAppCollection'
    'DisableNlaOnCollection'

    # Phase 7 - AD objects (OUs, users, groups, delegation)
    'CreateAdOrganizationalUnits'
    'CreateAdUsers'
    'RenameAdministratorToIrajeacv'
    'ConfigureRemoteDesktopUsersGroup'
    'DelegateControlOnDomain'

    # Phase 8 - firewall
    'ConfigureFirewallRules'

    # Phase 9 - EPM Tools extraction + dependency installers
    'ExtractEpmToolsArchive'
    'InstallChromeAndDisableUpdate'
    'InstallDotNetHosting'
    'InstallOtpWin64'
    'InstallRabbitMq'
    'InstallVcRedist'
    'InstallMySqlServer'
    'InstallMySqlWorkbench'

    # Phase 10 - GPO import + UAC
    'ConfigureGroupPolicies'
    'AddIrajesrvAllowLogonLocally'
    'DisableUserAccountControl'

    # Phase 11 - DB & Flyway
    'CreateEpmFolderStructure'
    'CreateEpmDatabase'
    'InstallFlyway'
    'RunFlywayMigrate'
    'PatchMySqlDomainSettings'

    # Phase 12 - IIS site, app-pool, worker service
    'InstallWebSocketProtocol'
    'CreateSelfSignedCertAndSite'
    'ConfigureEpmDashboardAppPool'
    'GrantIisPermissions'
    'CreateIworkerService'
    'PatchAppSettingsJson'
    'RunDbSetupScript'

    # Phase 13 - Myrtille / IrajeSecureAccess
    'InstallIrajeSecureAccess'

    # Phase 14 - Web folder, Shadow.exe RemoteApp, IIS warm-up
    'DeployWebFolderAndShadow'
    'ConfigureIisWarmup'
)

function Get-EpmServerStepNames { return $script:EpmServerStepNames }

# ============================================================================
# Phase 2 - Preflight & basic OS prep
# ============================================================================

function Test-EpmPreflight {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Running preflight checks'

    if ((Test-IsDomainJoined) -and -not (Test-IsDomainController)) {
        throw 'Server is already domain-joined (but not a DC). Doc requires this box to start in a workgroup.'
    }

    if (-not [System.Net.IPAddress]::TryParse($P.ServerIP, [ref]$null)) {
        throw "ServerIP '$($P.ServerIP)' is not a valid IPv4 address."
    }

    if ($P.DomainName -notmatch '\.local$') {
        Write-IrajeLog -Level WARN -Message "DomainName '$($P.DomainName)' does not end in .local - doc recommends .local TLD."
    }

    # Activation status (best-effort, just a warning)
    try {
        $lic = & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /dli 2>&1
        $licStr = $lic -join "`n"
        if ($licStr -match 'License Status:\s+(.+)') {
            $status = $Matches[1].Trim()
            if ($status -notmatch 'Licensed') {
                Write-IrajeLog -Level WARN -Message "Windows activation status: $status - activate before going to production."
            } else {
                Write-IrajeLog -Level OK -Message "Windows activation status: $status"
            }
        }
    } catch {
        Write-IrajeLog -Level WARN -Message "Could not read activation status: $($_.Exception.Message)"
    }

    Write-IrajeLog -Level OK -Message ("Preflight OK. Hostname={0}; TimeZone={1}; LocalTime={2}" -f $env:COMPUTERNAME, (Get-TimeZone).Id, (Get-Date))
}

function Disable-Nla {
    Write-IrajeLog -Level STEP -Message 'Disabling Network Level Authentication on RDP'
    # Direct registry edit - same effect as gpedit path + gpupdate.
    $rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    if (-not (Test-Path -LiteralPath $rdp)) {
        throw "RDP registry key not found: $rdp"
    }
    Set-ItemProperty -Path $rdp -Name 'UserAuthentication' -Value 0 -Type DWord
    Set-ItemProperty -Path $rdp -Name 'SecurityLayer'     -Value 1 -Type DWord
    # Also clear the WMI version so RDP MMC reflects it
    try {
        $wmi = Get-CimInstance -Namespace 'root\CIMV2\TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop
        if ($wmi.UserAuthenticationRequired -ne 0) {
            $wmi | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = [uint32]0 } | Out-Null
        }
    } catch {
        Write-IrajeLog -Level WARN -Message "WMI NLA toggle failed (registry already set): $($_.Exception.Message)"
    }
    Write-IrajeLog -Level OK -Message 'NLA disabled on RDP-Tcp.'
}

function Sync-TimeWithNtpServer {
    param([Parameter(Mandatory)] [hashtable]$P)
    if (-not $P.NtpServerIP) {
        Write-IrajeLog -Level INFO -Message 'No NtpServerIP provided - skipping NTP-client sync configuration.'
        return
    }
    Write-IrajeLog -Level STEP -Message "Pointing w32time at NTP server $($P.NtpServerIP)"
    Invoke-Native -File 'w32tm.exe' -Arguments @(
        '/config', "/manualpeerlist:`"$($P.NtpServerIP),0x8`"", '/syncfromflags:manual', '/update'
    ) | Out-Null
    try { Stop-Service w32time -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    Start-Service w32time
    Start-Sleep -Seconds 3
    Invoke-Native -File 'w32tm.exe' -Arguments @('/resync','/rediscover') -AllowFail | Out-Null
    Invoke-Native -File 'w32tm.exe' -Arguments @('/query','/source')      -AllowFail | Out-Null
    Write-IrajeLog -Level OK -Message 'NTP client configured.'
}

# ============================================================================
# Phase 3 - AD DS install + DC promotion (REBOOT)
# ============================================================================

function Install-AdDsRoles {
    Write-IrajeLog -Level STEP -Message 'Installing AD DS + IIS hostable web core + IIS 6 mgmt compat + WinRM IIS ext'
    # Doc maps:
    #   "Active Directory Domain Services"        -> AD-Domain-Services
    #   "IIS Hostable Web Core"                   -> Web-WHC
    #   "WinRM IIS Extension"                     -> WinRM-IIS-Ext
    #   "IIS 6 Management Compatibility" (parent) -> Web-Mgmt-Compat
    #     "IIS 6 Metabase Compatibility"          -> Web-Metabase
    #     "IIS 6 Management Console"              -> Web-Lgcy-Mgmt-Console
    #     "IIS 6 Scripting Tools"                 -> Web-Lgcy-Scripting
    #     "IIS 6 WMI Compatibility"               -> Web-WMI
    #   "IIS Management Scripts and Tools"        -> Web-Scripting-Tools
    $features = @(
        'AD-Domain-Services'
        'Web-WHC'
        'WinRM-IIS-Ext'
        'Web-Mgmt-Compat'
        'Web-Metabase'
        'Web-Lgcy-Mgmt-Console'
        'Web-Lgcy-Scripting'
        'Web-WMI'
        'Web-Scripting-Tools'
    )
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    Write-IrajeLog -Level OK -Message "AD DS + IIS feature install result: $($result.Success). RestartNeeded=$($result.RestartNeeded)"
    if ($result.RestartNeeded -eq 'Yes') {
        Write-IrajeLog -Level WARN -Message 'AD DS install requested a reboot; DC promotion will reboot anyway.'
    }
}

function Promote-ToDc {
    param(
        [Parameter(Mandatory)] [hashtable]$P,
        [Parameter(Mandatory)] [string]$ScriptPath
    )
    if (Test-IsDomainController) {
        Write-IrajeLog -Level OK -Message "Already a Domain Controller for '$((Get-CimInstance Win32_ComputerSystem).Domain)'."
        return
    }
    Write-IrajeLog -Level STEP -Message "Promoting to Domain Controller for forest '$($P.DomainName)'"

    Import-Module ADDSDeployment -ErrorAction Stop

    $netbios = ($P.DomainName -split '\.')[0].ToUpper()
    if ($netbios.Length -gt 15) { $netbios = $netbios.Substring(0,15) }
    $dsrm = ConvertTo-SecureString $P.DsrmPassword -AsPlainText -Force

    # Register the resume task BEFORE the cmdlet reboots.
    Register-IrajeResumeTask -ScriptPath $ScriptPath -Params $P

    Write-IrajeLog -Level WARN -Message 'Calling Install-ADDSForest - this reboots the server. Script will auto-resume.'
    Install-ADDSForest `
        -DomainName            $P.DomainName `
        -DomainNetbiosName     $netbios `
        -SafeModeAdministratorPassword $dsrm `
        -ForestMode            'WinThreshold' `
        -DomainMode            'WinThreshold' `
        -InstallDns            $true `
        -CreateDnsDelegation:$false `
        -NoRebootOnCompletion:$false `
        -Force:$true | Out-Null

    # Cmdlet reboots; we should never reach this line.
    throw 'Install-ADDSForest returned without rebooting - manual intervention needed.'
}

# ============================================================================
# Phase 4 - RDS + IIS roles (REBOOT)
# ============================================================================

function Install-RdsAndIisRoles {
    param(
        [Parameter(Mandatory)] [hashtable]$P,
        [Parameter(Mandatory)] [string]$ScriptPath
    )
    Write-IrajeLog -Level STEP -Message 'Installing RDS Web Access + Session Host + Web-Server'
    $features = @(
        'Web-Server'
        'RDS-RD-Server'
        'RDS-Web-Access'
    )
    $allInstalled = $true
    foreach ($f in $features) {
        $fs = Get-WindowsFeature -Name $f
        if (-not $fs.Installed) { $allInstalled = $false; break }
    }
    if ($allInstalled) {
        Write-IrajeLog -Level OK -Message 'RDS + IIS roles already installed.'
        return
    }
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    Write-IrajeLog -Level OK -Message "RDS/IIS install RestartNeeded=$($result.RestartNeeded)"
    if ($result.RestartNeeded -eq 'Yes') {
        Request-IrajeReboot -ScriptPath $ScriptPath -Params $P -Reason 'RDS role install requires reboot'
    }
}

# ============================================================================
# Phase 5 - additional features
# ============================================================================

function Install-AdditionalFeatures {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing .NET 3.5, Simple TCP/IP Services, Telnet Client'
    $features = @('NET-Framework-Core','Simple-TCPIP','Telnet-Client')

    $sxs = Join-Path $P.AssetsRoot 'sxs'
    $sourceArg = @{}
    if (Test-Path -LiteralPath $sxs) {
        $sourceArg.Source = $sxs
        Write-IrajeLog -Level INFO -Message "Using .NET 3.5 SxS source: $sxs"
    } else {
        Write-IrajeLog -Level WARN -Message "No SxS folder at $sxs - .NET 3.5 install may fail if WSUS is restricted."
    }
    $result = Install-WindowsFeature -Name $features @sourceArg
    Write-IrajeLog -Level OK -Message "Additional features install Success=$($result.Success)"
    if ($result.RestartNeeded -eq 'Yes') {
        Write-IrajeLog -Level WARN -Message 'Additional features want a reboot; rolling it into the next mandatory reboot.'
    }
}

# ============================================================================
# Phase 6 - RDS deployment / Gateway / Licensing / Collection
# ============================================================================

function Install-RdsSessionDeployment {
    Write-IrajeLog -Level STEP -Message 'Creating Session-based RDS deployment (Quick Start equivalent)'
    Import-Module RemoteDesktop -ErrorAction Stop

    $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"

    # Idempotent: skip if deployment exists
    $existing = Get-RDServer -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Roles -contains 'RDS-CONNECTION-BROKER')) {
        Write-IrajeLog -Level OK -Message 'RDS deployment already present.'
        return
    }

    New-RDSessionDeployment `
        -ConnectionBroker $fqdn `
        -WebAccessServer  $fqdn `
        -SessionHost      $fqdn -ErrorAction Stop | Out-Null

    Write-IrajeLog -Level OK -Message 'RDS session-based deployment created.'
}

function Add-RdGatewayRole {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Adding RD Gateway server'
    Import-Module RemoteDesktop -ErrorAction Stop

    $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"
    $existing = Get-RDServer -Role RDS-GATEWAY -ErrorAction SilentlyContinue
    if ($existing) {
        Write-IrajeLog -Level OK -Message 'RD Gateway already configured.'
        return
    }

    # Install the underlying role first if missing
    if (-not (Get-WindowsFeature 'RDS-Gateway').Installed) {
        Install-WindowsFeature -Name 'RDS-Gateway' -IncludeManagementTools | Out-Null
    }

    Add-RDServer -Server $fqdn -Role RDS-GATEWAY -ConnectionBroker $fqdn -GatewayExternalFqdn $fqdn -ErrorAction Stop
    Write-IrajeLog -Level OK -Message "RD Gateway added with external FQDN $fqdn."
}

function Add-RdLicensingRole {
    Write-IrajeLog -Level STEP -Message 'Adding RD Licensing (per-device)'
    Import-Module RemoteDesktop -ErrorAction Stop
    $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"

    if (-not (Get-WindowsFeature 'RDS-Licensing').Installed) {
        Install-WindowsFeature -Name 'RDS-Licensing' -IncludeManagementTools | Out-Null
    }
    if (-not (Get-RDServer -Role RDS-LICENSING -ErrorAction SilentlyContinue)) {
        Add-RDServer -Server $fqdn -Role RDS-LICENSING -ConnectionBroker $fqdn -ErrorAction Stop
    }
    Set-RDLicenseConfiguration -ConnectionBroker $fqdn -LicenseServer $fqdn -Mode PerDevice -Force -ErrorAction Stop
    Write-IrajeLog -Level OK -Message 'RD Licensing configured (per-device).'
}

function New-EpmAppCollection {
    Write-IrajeLog -Level STEP -Message 'Creating EPM App session collection'
    Import-Module RemoteDesktop -ErrorAction Stop
    $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"

    # Remove default collections (best-effort) before creating EPM App
    Get-RDSessionCollection -ErrorAction SilentlyContinue | Where-Object { $_.CollectionName -ne 'EPM App' } | ForEach-Object {
        try { Remove-RDSessionCollection -CollectionName $_.CollectionName -Force -ErrorAction Stop }
        catch { Write-IrajeLog -Level WARN -Message "Could not remove collection $($_.CollectionName): $($_.Exception.Message)" }
    }

    if (Get-RDSessionCollection -CollectionName 'EPM App' -ErrorAction SilentlyContinue) {
        Write-IrajeLog -Level OK -Message "Collection 'EPM App' already exists."
    } else {
        New-RDSessionCollection -CollectionName 'EPM App' -SessionHost $fqdn -ConnectionBroker $fqdn -ErrorAction Stop | Out-Null
        Write-IrajeLog -Level OK -Message "Collection 'EPM App' created."
    }

    # Disable user profile disks
    Set-RDSessionCollectionConfiguration -CollectionName 'EPM App' -DisableUserProfileDisk -ConnectionBroker $fqdn -ErrorAction SilentlyContinue
}

function Disable-NlaOnCollection {
    Write-IrajeLog -Level STEP -Message 'Disabling NLA on EPM App collection security'
    Import-Module RemoteDesktop -ErrorAction Stop
    try {
        Set-RDSessionCollectionConfiguration -CollectionName 'EPM App' `
            -SecurityLayer RDP -EncryptionLevel ClientCompatible -AuthenticateUsingNLA $false -ErrorAction Stop
        Write-IrajeLog -Level OK -Message 'Collection NLA disabled.'
    } catch {
        Write-IrajeLog -Level WARN -Message "Set-RDSessionCollectionConfiguration NLA toggle: $($_.Exception.Message)"
    }
}

# ============================================================================
# Phase 7 - AD objects (OUs, users, group, delegation)
# ============================================================================

function Get-DomainDN { (Get-ADDomain).DistinguishedName }

function New-EpmOu {
    param([Parameter(Mandatory)] [string]$Name)
    $domainDN = Get-DomainDN
    $ouDN = "OU=$Name,$domainDN"
    if (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-IrajeLog -Level OK -Message "OU '$Name' already exists."
        return
    }
    New-ADOrganizationalUnit -Name $Name -Path $domainDN -ProtectedFromAccidentalDeletion $true | Out-Null
    Write-IrajeLog -Level OK -Message "Created OU $ouDN"
}

function New-EpmAdOrganizationalUnits {
    Write-IrajeLog -Level STEP -Message 'Creating OUs: Iraje, Nologoff, Winupdate'
    Import-Module ActiveDirectory -ErrorAction Stop
    New-EpmOu -Name 'Iraje'
    New-EpmOu -Name 'Nologoff'
    New-EpmOu -Name 'Winupdate'
}

function New-EpmAdUser {
    param(
        [Parameter(Mandatory)] [string]$SamAccountName,
        [Parameter(Mandatory)] [string]$OuName,         # OU short name OR 'Users' (for built-in container)
        [Parameter(Mandatory)] [securestring]$Password,
        [switch]$DomainAdmin
    )
    $domainDN = Get-DomainDN
    if ($OuName -eq 'Users') {
        $path = "CN=Users,$domainDN"
    } else {
        $path = "OU=$OuName,$domainDN"
    }
    if (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue) {
        Write-IrajeLog -Level OK -Message "User '$SamAccountName' already exists."
    } else {
        New-ADUser `
            -Name                  $SamAccountName `
            -SamAccountName        $SamAccountName `
            -UserPrincipalName     "$SamAccountName@$((Get-ADDomain).DNSRoot)" `
            -DisplayName           $SamAccountName `
            -GivenName             $SamAccountName `
            -AccountPassword       $Password `
            -PasswordNeverExpires  $true `
            -ChangePasswordAtLogon $false `
            -Enabled               $true `
            -Path                  $path | Out-Null
        Write-IrajeLog -Level OK -Message "Created user $SamAccountName in $path"
    }
    if ($DomainAdmin) {
        try {
            Add-ADGroupMember -Identity 'Domain Admins' -Members $SamAccountName -ErrorAction Stop
        } catch {
            if ($_.Exception.Message -notmatch 'already a member') {
                Write-IrajeLog -Level WARN -Message "Could not add $SamAccountName to Domain Admins: $($_.Exception.Message)"
            }
        }
    }
}

function New-EpmAdUsers {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Creating EPM service / admin accounts'
    Import-Module ActiveDirectory -ErrorAction Stop

    $defaultPwd = ConvertTo-SecureString $P.DefaultUserPassword -AsPlainText -Force
    $iEpmPwd    = ConvertTo-SecureString $P.iEpmPassword        -AsPlainText -Force

    # Winupdate OU
    New-EpmAdUser -SamAccountName 'winupdate' -OuName 'Winupdate' -Password $defaultPwd
    New-EpmAdUser -SamAccountName 'iEPM'      -OuName 'Winupdate' -Password $iEpmPwd -DomainAdmin

    # Nologoff OU
    New-EpmAdUser -SamAccountName 'irajejobs' -OuName 'Nologoff' -Password $defaultPwd

    # Users container
    New-EpmAdUser -SamAccountName 'irajesrv' -OuName 'Users' -Password $defaultPwd
    New-EpmAdUser -SamAccountName 'epmsusr'  -OuName 'Users' -Password $defaultPwd

    # Iraje OU
    New-EpmAdUser -SamAccountName 'iraje'    -OuName 'Iraje' -Password $defaultPwd -DomainAdmin
    New-EpmAdUser -SamAccountName 'irajedev' -OuName 'Iraje' -Password $defaultPwd -DomainAdmin
}

function Rename-AdministratorToIrajeacv {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message "Renaming built-in Administrator to 'irajeacv' and moving to Iraje OU"
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainDN = Get-DomainDN

    # Existing irajeacv-
    $renamed = Get-ADUser -Filter "SamAccountName -eq 'irajeacv'" -ErrorAction SilentlyContinue
    if ($renamed) {
        Write-IrajeLog -Level OK -Message "User 'irajeacv' already exists (rename previously done)."
    } else {
        # Find the built-in Administrator by SID suffix -500
        $domainSid = (Get-ADDomain).DomainSID.Value
        $adminSid  = "$domainSid-500"
        $admin = Get-ADUser -Filter * | Where-Object { $_.SID.Value -eq $adminSid }
        if (-not $admin) { throw "Could not locate built-in Administrator account (SID $adminSid)." }

        # Rename SAM + UPN
        $newUpn = "irajeacv@$((Get-ADDomain).DNSRoot)"
        Rename-ADObject -Identity $admin.DistinguishedName -NewName 'irajeacv'
        # After Rename-ADObject the DN changes; re-fetch
        $admin = Get-ADUser -Filter "SID -eq '$adminSid'"
        Set-ADUser -Identity $admin -SamAccountName 'irajeacv' -UserPrincipalName $newUpn -DisplayName 'irajeacv'
        Write-IrajeLog -Level OK -Message 'Built-in Administrator renamed to irajeacv.'
    }

    # Move to Iraje OU (if not already there)
    $u = Get-ADUser -Filter "SamAccountName -eq 'irajeacv'" -Properties DistinguishedName
    $irajeOu = "OU=Iraje,$domainDN"
    if ($u.DistinguishedName -notmatch [regex]::Escape($irajeOu)) {
        Move-ADObject -Identity $u.DistinguishedName -TargetPath $irajeOu
        Write-IrajeLog -Level OK -Message "Moved irajeacv to $irajeOu."
    }

    # Reset password
    $pwd = ConvertTo-SecureString $P.AdministratorPassword -AsPlainText -Force
    Set-ADAccountPassword -Identity 'irajeacv' -NewPassword $pwd -Reset
    Set-ADUser -Identity 'irajeacv' -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Write-IrajeLog -Level OK -Message 'Administrator (irajeacv) password reset.'
}

function Set-RemoteDesktopUsersManagedBy {
    Write-IrajeLog -Level STEP -Message "Setting Built-in 'Remote Desktop Users' Managed By = Everyone, allow membership update"
    Import-Module ActiveDirectory -ErrorAction Stop

    $rduGroup = Get-ADGroup -Identity 'Remote Desktop Users' -Properties managedBy, ManagedBy
    $everyoneSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'

    # The AD attribute "managedBy" must be a DN - we cannot point it at SID-only Everyone.
    # Real-world equivalent: leave managedBy empty, but grant Everyone Write Members on the group.
    Write-IrajeLog -Level INFO -Message "Cannot set 'Managed By' to Everyone directly (managedBy needs a DN). Granting Everyone Write-Members ACL instead."

    $groupAdsi = [ADSI]"LDAP://$($rduGroup.DistinguishedName)"
    $acl = $groupAdsi.psbase.ObjectSecurity
    $memberAttrGuid = [Guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'  # schema GUID for 'member'
    $ace = New-Object DirectoryServices.ActiveDirectoryAccessRule(
        $everyoneSid,
        [DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [Security.AccessControl.AccessControlType]::Allow,
        $memberAttrGuid
    )
    $acl.AddAccessRule($ace)
    $groupAdsi.psbase.ObjectSecurity = $acl
    $groupAdsi.psbase.CommitChanges()
    Write-IrajeLog -Level OK -Message 'Everyone granted Write-Members on Remote Desktop Users.'
}

function Invoke-DelegateControlOnDomain {
    Write-IrajeLog -Level STEP -Message 'Delegating control on domain to Administrators / Domain Users / Everyone / IIS / RDU'
    # The doc's "Delegate Control wizard" with 'Select all options' grants effectively-full control.
    # We use dsacls to add common task delegations to a curated principal list.
    $domainDN = Get-DomainDN
    $principals = @(
        'Administrators'
        'Domain Users'
        'Everyone'
        'IIS_IUSRS'
        'Remote Desktop Users'
    )
    foreach ($p in $principals) {
        try {
            $r = Invoke-Native -File 'dsacls.exe' -Arguments @("`"$domainDN`"",'/G',"`"$p`":GA") -AllowFail
            if ($r.ExitCode -ne 0) {
                Write-IrajeLog -Level WARN -Message "dsacls grant for $p exit $($r.ExitCode) - non-fatal"
            }
        } catch {
            Write-IrajeLog -Level WARN -Message "dsacls failed for $p`: $($_.Exception.Message)"
        }
    }
    Write-IrajeLog -Level OK -Message 'Delegation complete (best-effort).'
}

# ============================================================================
# Phase 8 - Firewall
# ============================================================================

function Set-EpmFirewall {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Configuring inbound firewall rules (445, 443, 3389 +optional custom RDP)'
    $ports = @(445,443,3389)
    if ($P.CustomRdpPort) { $ports += [int]$P.CustomRdpPort }

    $name = 'Iraje'
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $ports -Action Allow `
            -Profile Domain,Private,Public | Out-Null
        Write-IrajeLog -Level OK -Message "Created firewall rule '$name' for TCP $($ports -join ',')."
    } else {
        Set-NetFirewallRule -DisplayName $name -LocalPort $ports -ErrorAction SilentlyContinue
        Write-IrajeLog -Level OK -Message "Firewall rule '$name' already present; updated ports."
    }

    if (-not $P.DontEnableFirewall) {
        Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
        Write-IrajeLog -Level OK -Message 'Firewall enabled on Domain/Private/Public profiles.'
    } else {
        Write-IrajeLog -Level WARN -Message '-DontEnableFirewall set - leaving profiles in current state.'
    }
}

# ============================================================================
# Phase 9 - EPM Tools extraction + installers
# ============================================================================

function Get-SevenZipPath {
    # Prefer bundled / installed 7-Zip; fall back to assets-bundled exe if present.
    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Expand-EpmToolsArchive {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Extracting EPM_Tools_Setup archive'
    $sevenZip = Get-SevenZipPath
    if (-not $sevenZip) {
        throw '7-Zip not found. Install 7-Zip (from EPM_Tools_Setup) or bundle 7z.exe under assets\ before running.'
    }
    $archive = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup.7z'
    Test-AssetPath -Path $archive | Out-Null

    $dest = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -ErrorAction SilentlyContinue)) {
        Write-IrajeLog -Level OK -Message "EPM_Tools_Setup already extracted at $dest."
        return
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $pwd = $P.ArchivePassword
    Invoke-Native -File $sevenZip -Arguments @('x',"`"$archive`"","-o`"$dest`"","-p$pwd",'-y') | Out-Null
    Write-IrajeLog -Level OK -Message "Extracted EPM_Tools_Setup to $dest"
}

function Find-FirstFile {
    param([Parameter(Mandatory)] [string]$Root, [Parameter(Mandatory)] [string]$Pattern)
    $hit = Get-ChildItem -Path $Root -Recurse -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) { throw "Required installer '$Pattern' not found under $Root" }
    return $hit.FullName
}

function Install-ChromeAndDisableUpdate {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing Chrome and disabling Google Update'
    if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Google Chrome' }) {
        Write-IrajeLog -Level OK -Message 'Chrome already installed.'
    } else {
        $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
        $chrome = Find-FirstFile -Root $toolsRoot -Pattern 'ChromeStandaloneSetup*.exe'
        # Standalone Chrome setup supports /silent /install
        Invoke-Native -File $chrome -Arguments @('/silent','/install') -AllowFail | Out-Null
    }
    # Delete the GoogleUpdate scheduled task(s)
    Get-ScheduledTask | Where-Object { $_.TaskName -like 'GoogleUpdate*' } | ForEach-Object {
        try { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false }
        catch { Write-IrajeLog -Level WARN -Message "Failed to remove task $($_.TaskName): $($_.Exception.Message)" }
    }
    # Rename GoogleUpdate.exe so it cannot run again
    $gu = "${env:ProgramFiles(x86)}\Google\Update\GoogleUpdate.exe"
    if (Test-Path -LiteralPath $gu) {
        $bak = "$gu.disabled"
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
        Rename-Item -LiteralPath $gu -NewName 'GoogleUpdate.exe.disabled' -Force
        Write-IrajeLog -Level OK -Message "Disabled GoogleUpdate.exe (renamed to .disabled)."
    }
}

function Install-DotNetHosting {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing .NET Hosting Bundle'
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    $exe = Find-FirstFile -Root $toolsRoot -Pattern 'dotnet-hosting-*.exe'
    Invoke-Native -File $exe -Arguments @('/install','/quiet','/norestart') -AllowFail | Out-Null
}

function Install-OtpWin64 {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing OTPwin64 (Erlang runtime)'
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    $exe = Find-FirstFile -Root $toolsRoot -Pattern 'otp_win64*.exe'
    # NSIS installer - /S = silent
    Invoke-Native -File $exe -Arguments @('/S') -AllowFail | Out-Null
}

function Install-RabbitMq {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing RabbitMQ and enabling management plugin'
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    $exe = Find-FirstFile -Root $toolsRoot -Pattern 'rabbitmq-server-*.exe'
    Invoke-Native -File $exe -Arguments @('/S') -AllowFail | Out-Null

    # Find sbin dir under "C:\Program Files\RabbitMQ Server\rabbitmq_server-*"
    $sbin = Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName 'sbin' }
    if ($sbin -and (Test-Path -LiteralPath $sbin)) {
        $plugins = Join-Path $sbin 'rabbitmq-plugins.bat'
        Invoke-Native -File $plugins -Arguments @('enable','rabbitmq_management') -AllowFail -WorkingDirectory $sbin | Out-Null
        Write-IrajeLog -Level OK -Message 'RabbitMQ management plugin enabled.'
    } else {
        Write-IrajeLog -Level WARN -Message 'RabbitMQ sbin folder not found - enable management plugin manually.'
    }
}

function Install-VcRedist {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing Visual C++ Redistributable'
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    $exe = Find-FirstFile -Root $toolsRoot -Pattern 'vc_redist.x64*.exe'
    Invoke-Native -File $exe -Arguments @('/install','/quiet','/norestart') -AllowFail | Out-Null
}

function Install-MySqlServer {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing MySQL Server 9.5'
    # Real-world MySQL install is multi-step; use MySQLInstallerConsole if available,
    # otherwise the MSI with config-defaults. Customer can ship either flavour.
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'

    if (Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue) {
        Write-IrajeLog -Level OK -Message 'A MySQL service is already present - skipping installer.'
        return
    }

    $installerConsole = Find-FirstFile -Root $toolsRoot -Pattern 'MySQLInstallerConsole.exe' -ErrorAction SilentlyContinue
    if ($installerConsole) {
        # Community install via console
        $args = @(
            'community','install',
            "server;9.5.0;x64:*:port=3306;openfirewall=true;rootpasswd=$($P.MySqlRootPassword);servicename=MySQL95",
            '-silent'
        )
        Invoke-Native -File $installerConsole -Arguments $args -AllowFail | Out-Null
    } else {
        $msi = Find-FirstFile -Root $toolsRoot -Pattern 'mysql-installer-*.msi'
        Invoke-Native -File 'msiexec.exe' -Arguments @('/i',"`"$msi`"",'/qn','/norestart') -AllowFail | Out-Null
        Write-IrajeLog -Level WARN -Message 'MySQL MSI installed; you may need to run the MySQL Installer GUI once to fully configure the 9.5 server. Verify port 3306 + root password match the runbook before proceeding.'
    }
}

function Install-MySqlWorkbench {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing MySQL Workbench'
    $toolsRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\EPM_Tools_Setup'
    $msi = Find-FirstFile -Root $toolsRoot -Pattern 'mysql-workbench-*.msi'
    Invoke-Native -File 'msiexec.exe' -Arguments @('/i',"`"$msi`"",'/qn','/norestart') -AllowFail | Out-Null
}

# ============================================================================
# Phase 10 - GPO import + UAC
# ============================================================================

function Import-EpmGpoBackup {
    param(
        [Parameter(Mandatory)] [string]$BackupRoot,    # e.g. assets\...\GPO\EPM_DDP_v1.0
        [Parameter(Mandatory)] [string]$TargetName,    # e.g. 'Default Domain Policy' or new GPO name
        [switch]$CreateIfNeeded
    )
    Test-AssetPath -Path $BackupRoot | Out-Null
    # Find the BackupId (manifest.xml) - Import-GPO can also auto-detect via -BackupGpoName.
    Import-Module GroupPolicy -ErrorAction Stop

    # Detect a single GPO backup folder
    $manifest = Join-Path $BackupRoot 'manifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "GPO backup manifest.xml not found in $BackupRoot"
    }
    [xml]$m = Get-Content -LiteralPath $manifest
    $first = $m.Backups.BackupInst | Select-Object -First 1
    $backupId = $first.ID.'#cdata-section'
    if (-not $backupId) { $backupId = $first.ID }

    $tgt = Get-GPO -Name $TargetName -ErrorAction SilentlyContinue
    if (-not $tgt -and $CreateIfNeeded) {
        $tgt = New-GPO -Name $TargetName
        Write-IrajeLog -Level OK -Message "Created GPO '$TargetName'."
    }
    if (-not $tgt) { throw "Target GPO '$TargetName' not found and -CreateIfNeeded not set." }

    Import-GPO -BackupId $backupId.Trim('{','}') -TargetGuid $tgt.Id -Path $BackupRoot -ErrorAction Stop | Out-Null
    Write-IrajeLog -Level OK -Message "Imported GPO backup $BackupRoot -> '$TargetName'."
}

function Set-EpmGroupPolicies {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Configuring Group Policies (block inheritance + import 3 GPOs)'
    Import-Module GroupPolicy     -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainDN = Get-DomainDN
    foreach ($ou in @('Iraje','Nologoff','Winupdate')) {
        $ouDN = "OU=$ou,$domainDN"
        try {
            Set-GPInheritance -Target $ouDN -IsBlocked Yes -ErrorAction Stop | Out-Null
            Write-IrajeLog -Level OK -Message "Block inheritance on $ouDN."
        } catch {
            Write-IrajeLog -Level WARN -Message "Set-GPInheritance for $ouDN`: $($_.Exception.Message)"
        }
    }

    $gpoRoot = Join-Path $P.AssetsRoot 'EPM_Setup_files_V1\GPO'

    # Default Domain Policy: import EPM_DDP_v1.0 into the existing built-in GPO
    Import-EpmGpoBackup -BackupRoot (Join-Path $gpoRoot 'EPM_DDP_v1.0')     -TargetName 'Default Domain Policy'

    # Create + link 'Nologoff group policy' / 'winupdate group policy' / 'Iraje group policy'
    $linkPlan = @(
        @{ Name='Iraje group policy';    Backup='EPM_Iraje_v1.0';    LinkOU="OU=Iraje,$domainDN" }
        @{ Name='Nologoff group policy'; Backup='EPM_nologoff_v1.0'; LinkOU="OU=Nologoff,$domainDN" }
        @{ Name='winupdate group policy';Backup='EPM_winupdate_v1.0';LinkOU="OU=Winupdate,$domainDN" }
    )
    foreach ($plan in $linkPlan) {
        $backupDir = Join-Path $gpoRoot $plan.Backup
        if (-not (Test-Path -LiteralPath $backupDir)) {
            Write-IrajeLog -Level WARN -Message "GPO backup '$($plan.Backup)' not present at $backupDir - skipping '$($plan.Name)'."
            continue
        }
        Import-EpmGpoBackup -BackupRoot $backupDir -TargetName $plan.Name -CreateIfNeeded
        try {
            New-GPLink -Name $plan.Name -Target $plan.LinkOU -LinkEnabled Yes -ErrorAction Stop | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch 'already linked') {
                Write-IrajeLog -Level WARN -Message "New-GPLink failed for $($plan.Name): $($_.Exception.Message)"
            }
        }
    }

    Invoke-Native -File 'gpupdate.exe' -Arguments @('/force') -AllowFail | Out-Null
}

function Add-IrajesrvAllowLogonLocally {
    Write-IrajeLog -Level STEP -Message 'Adding irajesrv to Default Domain Controllers Policy -> Allow log on locally'
    Import-Module GroupPolicy     -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop

    # Use secedit on the DC for predictability
    $dom = (Get-ADDomain).DNSRoot
    $template = Join-Path $env:TEMP 'iraje-secpol.inf'
    @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeInteractiveLogonRight = $($dom -replace '\..*$','')\irajesrv,*S-1-5-32-544
"@ | Set-Content -LiteralPath $template -Encoding Unicode

    Invoke-Native -File 'secedit.exe' -Arguments @(
        '/configure','/db',"`"$env:TEMP\iraje-secpol.sdb`"",
        '/cfg',"`"$template`"",'/areas','USER_RIGHTS','/quiet'
    ) -AllowFail | Out-Null

    Invoke-Native -File 'gpupdate.exe' -Arguments @('/force') -AllowFail | Out-Null
    Write-IrajeLog -Level OK -Message 'Allow-log-on-locally updated for irajesrv.'
}

function Disable-UserAccountControl {
    Write-IrajeLog -Level STEP -Message 'Disabling UAC prompts (Never Notify)'
    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty -Path $sys -Name 'ConsentPromptBehaviorAdmin' -Value 0 -Type DWord
    Set-ItemProperty -Path $sys -Name 'PromptOnSecureDesktop'      -Value 0 -Type DWord
    Set-ItemProperty -Path $sys -Name 'EnableLUA'                  -Value 1 -Type DWord
    Write-IrajeLog -Level OK -Message 'UAC slider set to Never Notify (no reboot needed for ConsentPromptBehavior=0).'
}

# ============================================================================
# Phase 11 - DB & Flyway
# ============================================================================

function New-EpmFolderStructure {
    Write-IrajeLog -Level STEP -Message 'Creating C:\Windows\Web\IrajeEPM folder layout + C:\software + C:\Windows\Web\Logs'
    $folders = @(
        'C:\Windows\Web\IrajeEPM\EPMDashboard'
        'C:\Windows\Web\IrajeEPM\IrajeWorker'
        'C:\Windows\Web\IrajeEPM\IrajeSecureAccess'
        'C:\Windows\Web\IrajeEPM\epmdms'
        'C:\Windows\Web\Logs'
        'C:\software'
    )
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f)) {
            New-Item -ItemType Directory -Path $f -Force | Out-Null
        }
    }
    Write-IrajeLog -Level OK -Message 'EPM folder structure ready.'

    # Copy EPMDashboard + IrajeWorker (EPMMessageService) + IrajeSecureAccess + software + epm-db
    $appSrc = (Get-IrajeAppSetupRoot)
    if (Test-Path -LiteralPath (Join-Path $appSrc 'EPMDashboard')) {
        Copy-Item (Join-Path $appSrc 'EPMDashboard\*') 'C:\Windows\Web\IrajeEPM\EPMDashboard\' -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $appSrc 'EPMMessageService')) {
        Copy-Item (Join-Path $appSrc 'EPMMessageService\*') 'C:\Windows\Web\IrajeEPM\IrajeWorker\' -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $appSrc 'IrajeSecureAccess')) {
        Copy-Item (Join-Path $appSrc 'IrajeSecureAccess\*') 'C:\Windows\Web\IrajeEPM\IrajeSecureAccess\' -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $appSrc 'software')) {
        Copy-Item (Join-Path $appSrc 'software\*') 'C:\software\' -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $appSrc 'epm-db')) {
        Copy-Item (Join-Path $appSrc 'epm-db\*') 'C:\Windows\Web\IrajeEPM\epmdms\' -Recurse -Force
    }
    Write-IrajeLog -Level OK -Message 'EPM application bits copied into final locations.'
}

function Get-IrajeAppSetupRoot {
    # The doc lists EPM_Setup_files_V1\EPM_App_Setup_Configuration as the source of app bits.
    $state = Get-IrajeState
    if ($null -eq $state) { throw 'No state found.' }
    $assets = $state.Params.AssetsRoot
    if (-not $assets) { throw 'AssetsRoot not in state.' }
    return Join-Path $assets 'EPM_Setup_files_V1\EPM_App_Setup_Configuration'
}

function Get-MySqlClientPath {
    $candidates = Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue
    if ($candidates) { return $candidates[0].FullName }
    throw 'mysql.exe not found under "C:\Program Files\MySQL\MySQL Server *\bin\". Is MySQL Server installed?'
}

function New-EpmDatabase {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message "Creating 'epm' database in MySQL"
    $mysql = Get-MySqlClientPath
    $args = @('-u','root',"--password=$($P.MySqlRootPassword)",'-e','CREATE DATABASE IF NOT EXISTS epm;')
    Invoke-Native -File $mysql -Arguments $args | Out-Null
    Write-IrajeLog -Level OK -Message "Database 'epm' present."
}

function Install-Flyway {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Installing Flyway CLI + MySQL connector JAR + PATH + env vars'
    $appSrc = Get-IrajeAppSetupRoot

    if (-not (Test-Path 'C:\flyway-11.20.2')) {
        # Find the flyway zip
        $zip = Get-ChildItem -Path $appSrc -Recurse -Filter 'flyway-commandline-11.*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $zip) { throw 'flyway-commandline-11.*.zip not found in EPM_App_Setup_Configuration' }
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath 'C:\' -Force
        $extracted = Get-ChildItem 'C:\flyway-11.*' -Directory | Select-Object -First 1
        if ($extracted.Name -ne 'flyway-11.20.2') {
            Rename-Item -LiteralPath $extracted.FullName -NewName 'flyway-11.20.2'
        }
    }

    # Connector JAR - drop into drivers/
    $driverDir = 'C:\flyway-11.20.2\drivers'
    if (-not (Test-Path -LiteralPath $driverDir)) { New-Item -ItemType Directory -Path $driverDir | Out-Null }
    $connector = Get-ChildItem -Path $appSrc -Recurse -Filter 'mysql-connector-*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connector) {
        # Maybe inside a connector folder/zip - try to find/extract
        $connectorZip = Get-ChildItem -Path $appSrc -Recurse -Filter 'mysql-connector*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($connectorZip) {
            $tmp = Join-Path $env:TEMP 'mysql-connector-extract'
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive -LiteralPath $connectorZip.FullName -DestinationPath $tmp -Force
            $connector = Get-ChildItem -Path $tmp -Recurse -Filter 'mysql-connector-*.jar' | Select-Object -First 1
        }
    }
    if (-not $connector) { throw 'mysql-connector jar not found.' }
    Copy-Item $connector.FullName $driverDir -Force

    # PATH (machine scope) - only append if missing
    $path = [Environment]::GetEnvironmentVariable('Path','Machine')
    if ($path -notmatch [regex]::Escape('C:\flyway-11.20.2')) {
        [Environment]::SetEnvironmentVariable('Path', ($path.TrimEnd(';') + ';C:\flyway-11.20.2'), 'Machine')
        $env:Path = $env:Path + ';C:\flyway-11.20.2'
    }

    # Persistent env vars
    [Environment]::SetEnvironmentVariable('FLYWAY_DB_USER',     'root',                  'Machine')
    [Environment]::SetEnvironmentVariable('FLYWAY_DB_PASSWORD', $P.MySqlRootPassword,    'Machine')
    $env:FLYWAY_DB_USER     = 'root'
    $env:FLYWAY_DB_PASSWORD = $P.MySqlRootPassword

    Write-IrajeLog -Level OK -Message 'Flyway installed and PATH/env configured.'
}

function Invoke-FlywayMigrate {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Running flyway migrate'
    $workDir = 'C:\Windows\Web\IrajeEPM\epmdms'
    if (-not (Test-Path -LiteralPath $workDir)) { throw "epmdms folder missing: $workDir" }

    $flyway = 'C:\flyway-11.20.2\flyway.cmd'
    if (-not (Test-Path -LiteralPath $flyway)) { throw "Flyway CLI not found at $flyway" }

    Invoke-Native -File $flyway -Arguments @('migrate') -WorkingDirectory $workDir | Out-Null
    Invoke-Native -File $flyway -Arguments @('info')    -WorkingDirectory $workDir | Out-Null
    Write-IrajeLog -Level OK -Message 'Flyway migration complete.'
}

function Set-EpmMySqlDomainSettings {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message "Patching epm.domainsettings + epm.remoteaccesssettings rows with domain '$($P.DomainName)'"
    $mysql = Get-MySqlClientPath
    $sql = @"
USE epm;
INSERT IGNORE INTO domainsettings (domain) VALUES ('$($P.DomainName)');
UPDATE domainsettings SET domain='$($P.DomainName)' WHERE domain IS NULL OR domain='';
INSERT IGNORE INTO remoteaccesssettings (domain) VALUES ('$($P.DomainName)');
UPDATE remoteaccesssettings SET domain='$($P.DomainName)' WHERE domain IS NULL OR domain='';
"@
    $sqlFile = Join-Path $env:TEMP 'epm-domain-patch.sql'
    $sql | Set-Content -LiteralPath $sqlFile -Encoding UTF8
    Invoke-Native -File $mysql -Arguments @('-u','root',"--password=$($P.MySqlRootPassword)",'-e',"source $sqlFile") -AllowFail | Out-Null
    Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
    Write-IrajeLog -Level OK -Message 'Domain setting rows patched (best-effort - table schema may differ).'
}

# ============================================================================
# Phase 12 - IIS WebSocket + Site + AppPool + Worker service
# ============================================================================

function Install-WebSocketProtocol {
    Write-IrajeLog -Level STEP -Message 'Installing IIS WebSocket Protocol'
    if (-not (Get-WindowsFeature 'Web-WebSockets').Installed) {
        Install-WindowsFeature -Name Web-WebSockets | Out-Null
    }
    Write-IrajeLog -Level OK -Message 'WebSocket Protocol installed.'
}

function New-EpmSelfSignedCertAndSite {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Creating self-signed cert + EPMDashboard HTTPS site'
    Import-Module WebAdministration -ErrorAction Stop

    $fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "CN=$fqdn" } | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -DnsName $fqdn -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddYears(5)
        Write-IrajeLog -Level OK -Message "Self-signed cert created for $fqdn (thumbprint $($cert.Thumbprint))"
    } else {
        Write-IrajeLog -Level OK -Message "Re-using existing self-signed cert for $fqdn."
    }

    # Site
    if (-not (Get-Website -Name 'EPMDashboard' -ErrorAction SilentlyContinue)) {
        $port = if ($P.HttpsPort) { [int]$P.HttpsPort } else { 443 }
        New-Website -Name 'EPMDashboard' `
            -PhysicalPath 'C:\Windows\Web\IrajeEPM\EPMDashboard' `
            -IPAddress $P.ServerIP -Port $port -Ssl | Out-Null
        Write-IrajeLog -Level OK -Message "Created site EPMDashboard on $($P.ServerIP):$port (HTTPS)."
    }

    # Bind cert
    $binding = Get-WebBinding -Name 'EPMDashboard' -Protocol 'https' -ErrorAction SilentlyContinue
    if ($binding) {
        try {
            $binding.AddSslCertificate($cert.Thumbprint, 'my')
        } catch {
            Write-IrajeLog -Level WARN -Message "AddSslCertificate failed (may already be bound): $($_.Exception.Message)"
        }
    }

    # Delete Default Web Site
    if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) {
        Remove-Website -Name 'Default Web Site'
        Write-IrajeLog -Level OK -Message 'Default Web Site removed.'
    }
}

function Set-EpmDashboardAppPool {
    Write-IrajeLog -Level STEP -Message 'Configuring EPMDashboard app pool'
    Import-Module WebAdministration -ErrorAction Stop

    if (-not (Test-Path 'IIS:\AppPools\EPMDashboard')) {
        New-WebAppPool -Name 'EPMDashboard' | Out-Null
    }
    # Wire the site to the pool
    if (Get-Website -Name 'EPMDashboard' -ErrorAction SilentlyContinue) {
        Set-ItemProperty 'IIS:\Sites\EPMDashboard' -Name 'applicationPool' -Value 'EPMDashboard'
    }

    # Identity = LocalSystem, 32-bit on, No Managed Code
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'processModel.identityType' -Value 'LocalSystem'
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'enable32BitAppOnWin64'     -Value $true
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'managedRuntimeVersion'     -Value ''
    # Warm-up settings
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'startMode'                 -Value 'AlwaysRunning'
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'processModel.idleTimeout'  -Value ([TimeSpan]::Zero)
    Set-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'recycling.periodicRestart.time' -Value ([TimeSpan]::Zero)
    # Preload on site
    if (Get-Website -Name 'EPMDashboard' -ErrorAction SilentlyContinue) {
        Set-ItemProperty 'IIS:\Sites\EPMDashboard' -Name 'applicationDefaults.preloadEnabled' -Value $true
    }
    Restart-WebAppPool -Name 'EPMDashboard' -ErrorAction SilentlyContinue
    Write-IrajeLog -Level OK -Message 'EPMDashboard app pool fully tuned (LocalSystem, 32-bit, NoManagedCode, AlwaysRunning, NoIdleTimeout, NoRecycle, Preload).'
}

function Grant-EpmIisPermissions {
    Write-IrajeLog -Level STEP -Message 'Granting Full Control to IIS_IUSRS + IUSR on EPMDashboard folder'
    $path = 'C:\Windows\Web\IrajeEPM\EPMDashboard'
    foreach ($id in @('IIS_IUSRS','IUSR')) {
        Invoke-Native -File 'icacls.exe' -Arguments @("`"$path`"",'/grant',"${id}:(OI)(CI)F",'/T','/C') -AllowFail | Out-Null
    }
    Write-IrajeLog -Level OK -Message 'IIS_IUSRS + IUSR permissions granted on EPMDashboard.'
}

function New-IworkerService {
    Write-IrajeLog -Level STEP -Message 'Creating iworker Windows service'
    $exe = 'C:\Windows\Web\IrajeEPM\IrajeWorker\EpmWorker.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-IrajeLog -Level WARN -Message "EpmWorker.exe not found at $exe - service will be created but may not start until binaries are present."
    }
    if (-not (Get-Service -Name 'iworker' -ErrorAction SilentlyContinue)) {
        Invoke-Native -File 'sc.exe' -Arguments @('create','iworker',"binPath= `"$exe`"",'start= auto','obj= LocalSystem') | Out-Null
    }
    # Recovery - restart after 60s on each of the first 3 failures
    Invoke-Native -File 'sc.exe' -Arguments @('failure','iworker','reset= 86400','actions= restart/60000/restart/60000/restart/60000') | Out-Null

    try { Start-Service -Name 'iworker' -ErrorAction Stop } catch {
        Write-IrajeLog -Level WARN -Message "Start iworker: $($_.Exception.Message) - verify EpmWorker.exe is in place."
    }
    Write-IrajeLog -Level OK -Message 'iworker service registered with recovery actions.'
}

function Set-EpmAppSettingsJson {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Patching IrajeWorker\appsetting.json server IP:port'
    $file = 'C:\Windows\Web\IrajeEPM\IrajeWorker\appsetting.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Write-IrajeLog -Level WARN -Message "appsetting.json missing at $file - skipping patch."
        return
    }
    $port = if ($P.HttpsPort) { $P.HttpsPort } else { 443 }
    $content = Get-Content -LiteralPath $file -Raw
    # The doc says "replace ip as epm server ip:port number". Real key name unknown - best-effort regex.
    $patched = [Regex]::Replace($content, '(?<key>"(?:ServerUrl|ApiUrl|BaseUrl|EndPoint|EndpointUrl)"\s*:\s*")[^"]*(")', "`${key}https://$($P.ServerIP):$port`$2")
    if ($patched -eq $content) {
        Write-IrajeLog -Level WARN -Message 'No recognised URL key in appsetting.json - patch left untouched. Open file manually and replace IP:port.'
    } else {
        Set-Content -LiteralPath $file -Value $patched -Encoding UTF8
        Write-IrajeLog -Level OK -Message 'appsetting.json patched.'
    }
}

function Invoke-DbSetupScript {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Running db_setup.ps1 with EPMDashboard pool + DB password'
    $appSrc = Get-IrajeAppSetupRoot
    $script = Get-ChildItem -Path $appSrc -Recurse -Filter 'db_setup.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $script) {
        Write-IrajeLog -Level WARN -Message 'db_setup.ps1 not found - skipping. (Often shipped with EPM_setup_files.)'
        return
    }
    Unblock-File -LiteralPath $script.FullName -ErrorAction SilentlyContinue

    # Doc says: edit the file to set $appPoolName="EPMDashboard" and $dbPassword="...". We supply
    # them as env vars to avoid mutating the vendor script. db_setup.ps1 must be authored to read
    # these env vars (which is the contract going forward).
    $env:IRAJE_APPPOOL    = 'EPMDashboard'
    $env:IRAJE_DBPASSWORD = $P.MySqlRootPassword
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script.FullName
    } finally {
        Remove-Item Env:\IRAJE_APPPOOL -ErrorAction SilentlyContinue
        Remove-Item Env:\IRAJE_DBPASSWORD -ErrorAction SilentlyContinue
    }
    Write-IrajeLog -Level OK -Message 'db_setup.ps1 executed.'
}

# ============================================================================
# Phase 13 - Myrtille / IrajeSecureAccess
# ============================================================================

function Invoke-IrajeSecureAccessInstaller {
    param([Parameter(Mandatory)] [string]$Script, [Parameter(Mandatory)] [string]$Input)
    if (-not (Test-Path -LiteralPath $Script)) {
        Write-IrajeLog -Level WARN -Message "Myrtille installer not found: $Script - skipping."
        return
    }
    Unblock-File -LiteralPath $Script -ErrorAction SilentlyContinue
    Write-IrajeLog -Level INFO -Message "Running Myrtille installer: $Script (input='$Input')"
    # Pipe the input answer (path) into the script's first Read-Host.
    $Input | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script
}

function Install-IrajeSecureAccess {
    Write-IrajeLog -Level STEP -Message 'Installing IrajeSecureAccess (Myrtille) - 3 installers'
    $root = 'C:\Windows\Web\IrajeEPM\IrajeSecureAccess'
    if (-not (Test-Path -LiteralPath $root)) {
        throw "IrajeSecureAccess folder missing: $root. Make sure it was copied in Phase 11."
    }

    # 1) Myrtille.web.install - install path
    $webInst = Join-Path $root 'Myrtille.Web.Install.ps1'
    if (-not (Test-Path -LiteralPath $webInst)) {
        $webInst = Get-ChildItem $root -Recurse -Filter 'Myrtille.Web.Install*' | Select-Object -First 1 -ExpandProperty FullName
    }
    Invoke-IrajeSecureAccessInstaller -Script $webInst -Input 'C:\Windows\Web\IrajeEPM\IrajeSecureAccess'

    # 2) Myrtille.Admin.Services.install - binary path
    $adminInst = Get-ChildItem (Join-Path $root 'bin') -Recurse -Filter 'Myrtille.Admin.Services.Install*' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    Invoke-IrajeSecureAccessInstaller -Script $adminInst -Input 'C:\Windows\Web\IrajeEPM\IrajeSecureAccess\bin\Myrtille.Admin.Services.exe'

    # 3) Myrtille.Services.install - binary path
    $svcInst = Get-ChildItem (Join-Path $root 'bin') -Recurse -Filter 'Myrtille.Services.Install*' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    Invoke-IrajeSecureAccessInstaller -Script $svcInst -Input 'C:\Windows\Web\IrajeEPM\IrajeSecureAccess\bin\Myrtille.Services.exe'

    Write-IrajeLog -Level OK -Message 'IrajeSecureAccess installers invoked (verify services started).'
}

# ============================================================================
# Phase 14 - Web folder + Shadow.exe RemoteApp + IIS warm-up
# ============================================================================

function Deploy-WebFolderAndShadow {
    param([Parameter(Mandatory)] [hashtable]$P)
    Write-IrajeLog -Level STEP -Message 'Deploying web folder + Shadow.exe RemoteApp'
    $appSrc = Get-IrajeAppSetupRoot
    $webSrc = Join-Path $appSrc 'web'
    if (-not (Test-Path -LiteralPath $webSrc)) {
        Write-IrajeLog -Level WARN -Message "Web folder source not found: $webSrc - skipping."
        return
    }
    if (-not (Test-Path 'C:\Windows\Web')) {
        New-Item -ItemType Directory -Path 'C:\Windows\Web' -Force | Out-Null
    }
    Copy-Item (Join-Path $webSrc '*') 'C:\Windows\Web\' -Recurse -Force

    $dom = ($P.DomainName -split '\.')[0]
    $acvAccount = "$dom\irajeacv"

    Invoke-Native -File 'icacls.exe' -Arguments @('C:\Windows\Web','/setowner',$acvAccount,'/T','/C') -AllowFail | Out-Null
    Invoke-Native -File 'icacls.exe' -Arguments @('C:\Windows\Web','/grant',"${dom}\Domain Users:(OI)(CI)RX",'/T','/C') -AllowFail | Out-Null
    Invoke-Native -File 'icacls.exe' -Arguments @('C:\Windows\Web\Logs','/grant',"${dom}\Domain Users:(OI)(CI)F",'/T','/C') -AllowFail | Out-Null
    Write-IrajeLog -Level OK -Message 'Permissions set on C:\Windows\Web and Logs folder.'

    # PsExec EULA pre-accept (both HKLM and HKCU for SYSTEM context)
    foreach ($hive in @('HKLM\Software\Sysinternals\PsExec','HKCU\Software\Sysinternals\PsExec')) {
        Invoke-Native -File 'reg.exe' -Arguments @('add',$hive,'/v','EulaAccepted','/t','REG_DWORD','/d','1','/f') -AllowFail | Out-Null
    }

    # Publish Shadow.exe as RemoteApp on the EPM App collection
    Import-Module RemoteDesktop -ErrorAction Stop
    $existing = Get-RDRemoteApp -CollectionName 'EPM App' -ErrorAction SilentlyContinue | Where-Object { $_.Alias -eq 'Shadow' -or $_.DisplayName -eq 'Shadow' }
    if (-not $existing) {
        try {
            New-RDRemoteApp -CollectionName 'EPM App' `
                -DisplayName 'Shadow' `
                -FilePath 'C:\Windows\Web\Shadow.exe' `
                -CommandLineSetting 'Allow' -ErrorAction Stop | Out-Null
            Write-IrajeLog -Level OK -Message "Shadow.exe published as RemoteApp on 'EPM App' collection."
        } catch {
            Write-IrajeLog -Level WARN -Message "New-RDRemoteApp failed: $($_.Exception.Message)"
        }
    } else {
        # Ensure CommandLineSetting=Allow
        try {
            Set-RDRemoteApp -CollectionName 'EPM App' -Alias $existing.Alias -CommandLineSetting Allow -ErrorAction Stop
        } catch {
            Write-IrajeLog -Level WARN -Message "Set-RDRemoteApp: $($_.Exception.Message)"
        }
    }
}

function Set-IisWarmup {
    Write-IrajeLog -Level STEP -Message 'Ensuring Application Initialization role + recycle'
    if (-not (Get-WindowsFeature 'Web-AppInit').Installed) {
        Install-WindowsFeature -Name 'Web-AppInit' | Out-Null
    }
    Import-Module WebAdministration -ErrorAction Stop
    Restart-WebAppPool -Name 'EPMDashboard' -ErrorAction SilentlyContinue
    Write-IrajeLog -Level OK -Message 'Application Initialization installed; app pool recycled. Warm-up is complete.'
}

# ============================================================================
# Orchestrator
# ============================================================================

function Invoke-IrajeEpmServerSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string]$ScriptPath
    )
    $P = ConvertTo-Hashtable $State.Params

    Invoke-IrajeStep -State $State -Name 'PreflightChecks'         -Body { Test-EpmPreflight -P $P }
    Invoke-IrajeStep -State $State -Name 'DisableNla'              -Body { Disable-Nla }
    Invoke-IrajeStep -State $State -Name 'SyncTimeWithNtpServer'   -Body { Sync-TimeWithNtpServer -P $P }

    Invoke-IrajeStep -State $State -Name 'InstallAdDsRoles'        -Body { Install-AdDsRoles }
    Invoke-IrajeStep -State $State -Name 'PromoteToDc'             -Body { Promote-ToDc -P $P -ScriptPath $ScriptPath }

    Invoke-IrajeStep -State $State -Name 'InstallRdsAndIisRoles'   -Body { Install-RdsAndIisRoles -P $P -ScriptPath $ScriptPath }
    Invoke-IrajeStep -State $State -Name 'InstallAdditionalFeatures' -Body { Install-AdditionalFeatures -P $P }

    Invoke-IrajeStep -State $State -Name 'InstallRdsSessionDeployment' -Body { Install-RdsSessionDeployment }
    Invoke-IrajeStep -State $State -Name 'ConfigureRdGateway'      -Body { Add-RdGatewayRole -P $P }
    Invoke-IrajeStep -State $State -Name 'ConfigureRdLicensing'    -Body { Add-RdLicensingRole }
    Invoke-IrajeStep -State $State -Name 'CreateEpmAppCollection'  -Body { New-EpmAppCollection }
    Invoke-IrajeStep -State $State -Name 'DisableNlaOnCollection'  -Body { Disable-NlaOnCollection } -ContinueOnError

    Invoke-IrajeStep -State $State -Name 'CreateAdOrganizationalUnits' -Body { New-EpmAdOrganizationalUnits }
    Invoke-IrajeStep -State $State -Name 'CreateAdUsers'           -Body { New-EpmAdUsers -P $P }
    Invoke-IrajeStep -State $State -Name 'RenameAdministratorToIrajeacv' -Body { Rename-AdministratorToIrajeacv -P $P }
    Invoke-IrajeStep -State $State -Name 'ConfigureRemoteDesktopUsersGroup' -Body { Set-RemoteDesktopUsersManagedBy } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'DelegateControlOnDomain' -Body { Invoke-DelegateControlOnDomain } -ContinueOnError

    Invoke-IrajeStep -State $State -Name 'ConfigureFirewallRules'  -Body { Set-EpmFirewall -P $P }

    Invoke-IrajeStep -State $State -Name 'ExtractEpmToolsArchive'  -Body { Expand-EpmToolsArchive -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallChromeAndDisableUpdate' -Body { Install-ChromeAndDisableUpdate -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallDotNetHosting'    -Body { Install-DotNetHosting -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallOtpWin64'         -Body { Install-OtpWin64 -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallRabbitMq'         -Body { Install-RabbitMq -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallVcRedist'         -Body { Install-VcRedist -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallMySqlServer'      -Body { Install-MySqlServer -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallMySqlWorkbench'   -Body { Install-MySqlWorkbench -P $P }

    Invoke-IrajeStep -State $State -Name 'ConfigureGroupPolicies'  -Body { Set-EpmGroupPolicies -P $P } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'AddIrajesrvAllowLogonLocally' -Body { Add-IrajesrvAllowLogonLocally } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'DisableUserAccountControl' -Body { Disable-UserAccountControl }

    Invoke-IrajeStep -State $State -Name 'CreateEpmFolderStructure' -Body { New-EpmFolderStructure }
    Invoke-IrajeStep -State $State -Name 'CreateEpmDatabase'       -Body { New-EpmDatabase -P $P }
    Invoke-IrajeStep -State $State -Name 'InstallFlyway'           -Body { Install-Flyway -P $P }
    Invoke-IrajeStep -State $State -Name 'RunFlywayMigrate'        -Body { Invoke-FlywayMigrate -P $P }
    Invoke-IrajeStep -State $State -Name 'PatchMySqlDomainSettings' -Body { Set-EpmMySqlDomainSettings -P $P } -ContinueOnError

    Invoke-IrajeStep -State $State -Name 'InstallWebSocketProtocol' -Body { Install-WebSocketProtocol }
    Invoke-IrajeStep -State $State -Name 'CreateSelfSignedCertAndSite' -Body { New-EpmSelfSignedCertAndSite -P $P }
    Invoke-IrajeStep -State $State -Name 'ConfigureEpmDashboardAppPool' -Body { Set-EpmDashboardAppPool }
    Invoke-IrajeStep -State $State -Name 'GrantIisPermissions'     -Body { Grant-EpmIisPermissions }
    Invoke-IrajeStep -State $State -Name 'CreateIworkerService'    -Body { New-IworkerService } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'PatchAppSettingsJson'    -Body { Set-EpmAppSettingsJson -P $P } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'RunDbSetupScript'        -Body { Invoke-DbSetupScript -P $P } -ContinueOnError

    Invoke-IrajeStep -State $State -Name 'InstallIrajeSecureAccess' -Body { Install-IrajeSecureAccess } -ContinueOnError

    Invoke-IrajeStep -State $State -Name 'DeployWebFolderAndShadow' -Body { Deploy-WebFolderAndShadow -P $P } -ContinueOnError
    Invoke-IrajeStep -State $State -Name 'ConfigureIisWarmup'      -Body { Set-IisWarmup }

    Write-IrajeLog -Level OK -Message 'EPM Server role: all steps complete.'
}

Export-ModuleMember -Function Get-EpmServerStepNames, Invoke-IrajeEpmServerSetup
