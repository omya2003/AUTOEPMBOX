<#
.SYNOPSIS
    Iraje EPM box-making verification harness.

.DESCRIPTION
    Re-runnable verification for Install-IrajeEPM.ps1 results. Auto-detects
    whether the box is a configured NTP server, an EPM server, or both, then
    runs a battery of independent checks. Emits color-coded console output,
    a self-contained HTML report, and (optionally) JSON for tooling.

    Designed to be safe to run any time. Read-only - never modifies the
    server. Exits 0 if all checks pass, 1 if any check fails.

.PARAMETER Role
    NTPServer | EPMServer | Auto (default). Force a role to skip auto-detection.

.PARAMETER DomainName
    Expected AD domain name (e.g. Iepm.local). When supplied, the script
    asserts the actual domain matches.

.PARAMETER ServerIP
    Expected primary IPv4 of this server. Used to validate IIS bindings.

.PARAMETER NtpServerIP
    Expected NTP source for the EPM server's w32time client.

.PARAMETER MySqlRootPassword
    Required to verify the 'epm' database exists. If omitted, that check is
    skipped (still reports MySQL service status).

.PARAMETER OutputHtml
    Path for the HTML report. Default:
    C:\ProgramData\IrajeEPM\verify\report-<timestamp>.html

.PARAMETER OutputJson
    Optional path for raw results JSON.

.PARAMETER Quiet
    Print only the final summary line, not per-check output.

.PARAMETER FailFast
    Exit on first failure. Useful for CI gates.

.EXAMPLE
    .\Test-IrajeEPM.ps1

.EXAMPLE
    .\Test-IrajeEPM.ps1 -Role EPMServer -DomainName Iepm.local -ServerIP 192.168.1.50 -NtpServerIP 192.168.1.81

.EXAMPLE
    .\Test-IrajeEPM.ps1 -OutputHtml C:\reports\epm.html -Quiet
#>
[CmdletBinding()]
param(
    [ValidateSet('NTPServer','EPMServer','Auto')]
    [string]$Role = 'Auto',

    [string]$DomainName,
    [string]$ServerIP,
    [string]$NtpServerIP,
    [string]$MySqlRootPassword,

    [string]$OutputHtml,
    [string]$OutputJson,

    [switch]$Quiet,
    [switch]$FailFast
)

# ----------------------------------------------------------------------------
# Bootstrap
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$script:VerifyRoot = 'C:\ProgramData\IrajeEPM\verify'
$script:StartTime  = Get-Date
$script:Stamp      = $script:StartTime.ToString('yyyyMMdd-HHmmss')
if (-not (Test-Path -LiteralPath $script:VerifyRoot)) {
    New-Item -ItemType Directory -Path $script:VerifyRoot -Force | Out-Null
}
if (-not $OutputHtml) {
    $OutputHtml = Join-Path $script:VerifyRoot "report-$script:Stamp.html"
}

$script:Results       = New-Object System.Collections.Generic.List[object]
$script:CurrentPhase  = $null
$script:CurrentPhaseN = 0
$script:RoleDetected  = $null

# ----------------------------------------------------------------------------
# Check framework
# ----------------------------------------------------------------------------

function Set-Phase {
    param([string]$Name)
    $script:CurrentPhaseN++
    $script:CurrentPhase = $Name
    if (-not $Quiet) {
        Write-Host ''
        Write-Host ("Phase {0}: {1}" -f $script:CurrentPhaseN, $Name) -ForegroundColor White -BackgroundColor DarkBlue
    }
}

function Add-CheckResult {
    param(
        [string]$Name,
        [ValidateSet('Pass','Fail','Warn','Skip')] [string]$Status,
        [string]$Detail = '',
        [string]$Remedy = ''
    )
    $r = [pscustomobject]@{
        Phase    = $script:CurrentPhase
        PhaseN   = $script:CurrentPhaseN
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Remedy   = $Remedy
        At       = (Get-Date).ToString('o')
    }
    $script:Results.Add($r) | Out-Null
    Write-CheckLine $r
    if ($FailFast -and $Status -eq 'Fail') {
        Write-ConsoleSummary
        Write-HtmlReport
        exit 1
    }
}

function Write-CheckLine {
    param($Result)
    if ($Quiet) { return }
    $statusText = switch ($Result.Status) {
        'Pass' { '[PASS]' }
        'Fail' { '[FAIL]' }
        'Warn' { '[WARN]' }
        'Skip' { '[SKIP]' }
    }
    $color = switch ($Result.Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        'Skip' { 'DarkGray' }
    }
    $name = $Result.Name
    if ($name.Length -gt 56) { $name = $name.Substring(0,53) + '...' }
    $line = "  {0} {1,-56}" -f $statusText, $name
    Write-Host $line -ForegroundColor $color -NoNewline
    if ($Result.Detail) {
        Write-Host ("  {0}" -f $Result.Detail) -ForegroundColor DarkGray
    } else {
        Write-Host ''
    }
    if ($Result.Status -eq 'Fail' -and $Result.Remedy) {
        Write-Host ("         Fix: {0}" -f $Result.Remedy) -ForegroundColor DarkYellow
    }
}

function Invoke-Check {
    param(
        [string]$Name,
        [scriptblock]$Body,
        [string]$Remedy = ''
    )
    try {
        $r = & $Body
        if ($null -eq $r) {
            Add-CheckResult -Name $Name -Status Skip -Detail 'Skipped'
        } elseif ($r -is [hashtable] -or $r -is [pscustomobject]) {
            $s = if ($r.PSObject.Properties.Name -contains 'Status') { $r.Status } else { 'Pass' }
            $d = if ($r.PSObject.Properties.Name -contains 'Detail') { $r.Detail } else { '' }
            $rem = if ($r.PSObject.Properties.Name -contains 'Remedy') { $r.Remedy } else { $Remedy }
            Add-CheckResult -Name $Name -Status $s -Detail $d -Remedy $rem
        } elseif ($r -is [bool]) {
            if ($r) { Add-CheckResult -Name $Name -Status Pass -Detail 'OK' }
            else    { Add-CheckResult -Name $Name -Status Fail -Detail 'Returned false' -Remedy $Remedy }
        } else {
            Add-CheckResult -Name $Name -Status Pass -Detail "$r"
        }
    } catch {
        Add-CheckResult -Name $Name -Status Fail -Detail $_.Exception.Message -Remedy $Remedy
    }
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Get-OsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        Caption     = $os.Caption.Trim()
        Version     = [Version]$os.Version
        BuildNumber = $os.BuildNumber
        ProductType = [int]$os.ProductType
        IsServer    = ($os.ProductType -ne 1)
        IsDC        = ($os.ProductType -eq 2)
    }
}

function Test-ServiceRunning {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ Status='Fail'; Detail="Service '$Name' not installed" } }
    if ($svc.Status -ne 'Running') { return @{ Status='Fail'; Detail="Service '$Name' is $($svc.Status)" } }
    return @{ Status='Pass'; Detail="Running (StartType=$($svc.StartType))" }
}

function Test-FeatureInstalled {
    param([string]$FeatureName)
    $f = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    if (-not $f) { return @{ Status='Fail'; Detail="Feature '$FeatureName' not found (Get-WindowsFeature unavailable - need Server SKU)" } }
    if (-not $f.Installed) { return @{ Status='Fail'; Detail="Feature '$FeatureName' not installed" } }
    return @{ Status='Pass'; Detail='Installed' }
}

function Get-MySqlClientPath {
    $hit = Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue
    if ($hit) { return $hit[0].FullName }
    return $null
}

function Get-InstalledProducts {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName }
    }
}

function Test-InstalledProduct {
    param([string]$Pattern)
    $hit = Get-InstalledProducts | Where-Object { $_.DisplayName -match $Pattern } | Select-Object -First 1
    if ($hit) {
        $ver = if ($hit.PSObject.Properties.Name -contains 'DisplayVersion') { $hit.DisplayVersion } else { '' }
        return @{ Status='Pass'; Detail="$($hit.DisplayName) $ver".Trim() }
    }
    return @{ Status='Fail'; Detail="No product matching /$Pattern/ found" }
}

# ----------------------------------------------------------------------------
# Role detection
# ----------------------------------------------------------------------------

function Test-IsNtpServerRole {
    try {
        $a = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name AnnounceFlags -ErrorAction Stop
        $n = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer' -Name Enabled -ErrorAction Stop
        return ($a.AnnounceFlags -eq 5 -and $n.Enabled -eq 1)
    } catch { return $false }
}

function Test-IsEpmServerRole {
    $os = Get-OsInfo
    if (-not $os.IsDC) { return $false }
    $rds = Get-WindowsFeature -Name 'RDS-RD-Server' -ErrorAction SilentlyContinue
    return ($rds -and $rds.Installed)
}

function Resolve-Role {
    if ($Role -ne 'Auto') {
        return @($Role)
    }
    $detected = @()
    if (Test-IsNtpServerRole) { $detected += 'NTPServer' }
    if (Test-IsEpmServerRole) { $detected += 'EPMServer' }
    if ($detected.Count -eq 0) {
        Write-Host ''
        Write-Host 'Auto-detection found neither NTP-server nor EPM-server fingerprints on this box.' -ForegroundColor Yellow
        Write-Host 'Defaulting to EPMServer checks - many will fail. Pass -Role explicitly to override.' -ForegroundColor Yellow
        return @('EPMServer')
    }
    return $detected
}

# ============================================================================
# NTP SERVER CHECKS
# ============================================================================

function Invoke-NtpServerChecks {
    Set-Phase 'NTP Server Configuration'

    Invoke-Check -Name 'AnnounceFlags = 5 (reliable NTP source)' -Remedy "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name AnnounceFlags -Value 5" -Body {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name AnnounceFlags -ErrorAction Stop).AnnounceFlags
        if ($v -eq 5) { @{ Status='Pass'; Detail="AnnounceFlags = $v" } }
        else          { @{ Status='Fail'; Detail="Expected 5, got $v" } }
    }

    Invoke-Check -Name 'NtpServer provider Enabled = 1' -Remedy "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer' -Name Enabled -Value 1" -Body {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer' -Name Enabled -ErrorAction Stop).Enabled
        if ($v -eq 1) { @{ Status='Pass'; Detail="Enabled = $v" } }
        else          { @{ Status='Fail'; Detail="Expected 1, got $v" } }
    }

    Invoke-Check -Name 'Manual peer list contains public NTP pool' -Body {
        $cfg = & w32tm /query /configuration 2>&1 | Out-String
        $hasTimeWindows = $cfg -match 'time\.windows\.com'
        $hasPool        = $cfg -match 'pool\.ntp\.org'
        if ($hasTimeWindows -or $hasPool) {
            $sources = @()
            if ($hasTimeWindows) { $sources += 'time.windows.com' }
            if ($hasPool)        { $sources += 'pool.ntp.org' }
            @{ Status='Pass'; Detail="Configured sources: $($sources -join ', ')" }
        } else {
            @{ Status='Fail'; Detail='Neither time.windows.com nor pool.ntp.org configured';
               Remedy='w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update' }
        }
    }

    Invoke-Check -Name 'Windows Time service (w32time) is running' -Remedy 'Start-Service w32time' -Body {
        Test-ServiceRunning -Name 'w32time'
    }

    Invoke-Check -Name "Firewall rule 'NTP Server UDP 123' present and enabled" -Remedy 'New-NetFirewallRule -DisplayName "NTP Server UDP 123" -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow' -Body {
        $r = Get-NetFirewallRule -DisplayName 'NTP Server UDP 123' -ErrorAction SilentlyContinue
        if (-not $r) { return @{ Status='Fail'; Detail='Rule missing' } }
        if (-not $r.Enabled) { return @{ Status='Warn'; Detail='Rule present but disabled' } }
        @{ Status='Pass'; Detail="Enabled, Direction=$($r.Direction), Action=$($r.Action)" }
    }

    Invoke-Check -Name 'w32tm reports a healthy status' -Body {
        $out = & w32tm /query /status 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return @{ Status='Fail'; Detail="w32tm failed: $out" } }
        if ($out -notmatch 'Leap Indicator') { return @{ Status='Fail'; Detail='Status output missing Leap Indicator line' } }
        $leap = if ($out -match 'Leap Indicator:\s+(\S+.*)') { $Matches[1] } else { 'unknown' }
        $src  = if ($out -match 'Source:\s+(.+)')           { $Matches[1].Trim() } else { 'unknown' }
        @{ Status='Pass'; Detail="Leap=$leap; Source=$src" }
    }

    Invoke-Check -Name 'Listening on UDP port 123' -Body {
        $ep = Get-NetUDPEndpoint -LocalPort 123 -ErrorAction SilentlyContinue
        if ($ep) { @{ Status='Pass'; Detail="$(@($ep).Count) endpoint(s) listening" } }
        else     { @{ Status='Fail'; Detail='No process listening on UDP/123 (is w32time really running?)' } }
    }
}

# ============================================================================
# EPM SERVER CHECKS
# ============================================================================

function Invoke-EpmServerChecks {

    Set-Phase 'OS & Time'

    Invoke-Check -Name 'Windows Server 2012 R2 or newer' -Body {
        $os = Get-OsInfo
        if (-not $os.IsServer) { return @{ Status='Fail'; Detail="$($os.Caption) (not a server SKU)" } }
        if ($os.Version -lt [Version]'6.3') { return @{ Status='Fail'; Detail="Too old: $($os.Caption)" } }
        @{ Status='Pass'; Detail="$($os.Caption) (build $($os.BuildNumber))" }
    }

    Invoke-Check -Name 'Time zone is set' -Body {
        $tz = (Get-TimeZone).Id
        @{ Status='Pass'; Detail=$tz }
    }

    Invoke-Check -Name 'w32time service running' -Remedy 'Start-Service w32time' -Body {
        Test-ServiceRunning -Name 'w32time'
    }

    if ($NtpServerIP) {
        Invoke-Check -Name "NTP source matches -NtpServerIP ($NtpServerIP)" -Remedy "w32tm /config /manualpeerlist:`"$NtpServerIP,0x8`" /syncfromflags:manual /update; Restart-Service w32time" -Body {
            $src = (& w32tm /query /source 2>&1) -join "`n"
            if ($src -match [regex]::Escape($NtpServerIP)) { @{ Status='Pass'; Detail="Source contains $NtpServerIP" } }
            else { @{ Status='Fail'; Detail="Expected $NtpServerIP, got: $($src.Trim())" } }
        }
    }

    Invoke-Check -Name 'Last NTP sync time is recent (<24h)' -Body {
        $st = (& w32tm /query /status 2>&1) -join "`n"
        if ($st -match 'Last Successful Sync Time:\s+(.+)') {
            $when = $Matches[1].Trim()
            try {
                $dt = [DateTime]::Parse($when)
                $ageMin = [int]((Get-Date) - $dt).TotalMinutes
                if ($ageMin -lt 1440) { @{ Status='Pass'; Detail="$when (~${ageMin}min ago)" } }
                else { @{ Status='Warn'; Detail="Last sync $when (>24h ago)" } }
            } catch {
                @{ Status='Warn'; Detail="Cannot parse: $when" }
            }
        } else {
            @{ Status='Warn'; Detail='No Last Successful Sync Time in w32tm status' }
        }
    }

    Set-Phase 'Active Directory Forest'

    Invoke-Check -Name 'AD DS role installed' -Body { Test-FeatureInstalled -FeatureName 'AD-Domain-Services' }

    Invoke-Check -Name 'Server is a Domain Controller' -Body {
        $os = Get-OsInfo
        if ($os.IsDC) { @{ Status='Pass'; Detail='ProductType = 2 (DC)' } }
        else          { @{ Status='Fail'; Detail="ProductType = $($os.ProductType) (not a DC)" } }
    }

    Invoke-Check -Name 'ActiveDirectory module loads' -Remedy 'Install-WindowsFeature RSAT-AD-PowerShell' -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        @{ Status='Pass'; Detail='Module imported' }
    }

    Invoke-Check -Name 'Domain matches expected name' -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        $d = Get-ADDomain
        if ($DomainName) {
            if ($d.DNSRoot -ieq $DomainName) { @{ Status='Pass'; Detail="DNSRoot = $($d.DNSRoot)" } }
            else { @{ Status='Fail'; Detail="Expected $DomainName, got $($d.DNSRoot)" } }
        } else {
            @{ Status='Pass'; Detail="DNSRoot = $($d.DNSRoot)" }
        }
    }

    Invoke-Check -Name 'Forest functional level >= 2016' -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        $f = Get-ADForest
        if ($f.ForestMode -match 'Windows(2016|2019|2022|2025)' -or $f.ForestMode -eq 'WindowsThreshold') {
            @{ Status='Pass'; Detail="ForestMode = $($f.ForestMode)" }
        } else {
            @{ Status='Warn'; Detail="ForestMode = $($f.ForestMode) (doc target: Windows2016Forest)" }
        }
    }

    Invoke-Check -Name 'DNS resolves the forest name' -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = (Get-ADDomain).DNSRoot
        try {
            $r = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop
            $ips = ($r | Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress) -join ', '
            if ($ips) { @{ Status='Pass'; Detail="$domain -> $ips" } }
            else      { @{ Status='Warn'; Detail="Resolved but no A records: $domain" } }
        } catch {
            @{ Status='Fail'; Detail=$_.Exception.Message; Remedy="Set NIC DNS to point at this server's own IP" }
        }
    }

    Set-Phase 'AD Users & OUs'

    foreach ($ou in @('Iraje','Nologoff','Winupdate')) {
        $ouName = $ou
        Invoke-Check -Name "OU '$ouName' exists" -Remedy "New-ADOrganizationalUnit -Name $ouName -Path (Get-ADDomain).DistinguishedName" -Body {
            Import-Module ActiveDirectory -ErrorAction Stop
            $hit = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -ErrorAction SilentlyContinue
            if ($hit) { @{ Status='Pass'; Detail=$hit.DistinguishedName } }
            else      { @{ Status='Fail'; Detail='Missing' }   }
        }
    }

    $expectedUsers = @(
        @{ Name='iraje';     OU='Iraje';     DomainAdmin=$true  }
        @{ Name='irajedev';  OU='Iraje';     DomainAdmin=$true  }
        @{ Name='irajeacv';  OU='Iraje';     DomainAdmin=$true  }
        @{ Name='iEPM';      OU='Winupdate'; DomainAdmin=$true  }
        @{ Name='winupdate'; OU='Winupdate'; DomainAdmin=$false }
        @{ Name='irajejobs'; OU='Nologoff';  DomainAdmin=$false }
        @{ Name='irajesrv';  OU='Users';     DomainAdmin=$false }
        @{ Name='epmsusr';   OU='Users';     DomainAdmin=$false }
    )
    foreach ($u in $expectedUsers) {
        $uname = $u.Name; $uou = $u.OU; $isAdmin = $u.DomainAdmin
        Invoke-Check -Name "User '$uname' exists, enabled, password never expires" -Body {
            Import-Module ActiveDirectory -ErrorAction Stop
            $au = Get-ADUser -Filter "SamAccountName -eq '$uname'" -Properties PasswordNeverExpires, MemberOf -ErrorAction SilentlyContinue
            if (-not $au) { return @{ Status='Fail'; Detail='User not found' } }
            $issues = @()
            if (-not $au.Enabled)             { $issues += 'disabled' }
            if (-not $au.PasswordNeverExpires){ $issues += 'password expires (should be PasswordNeverExpires)' }
            if ($au.DistinguishedName -notmatch [regex]::Escape($uou)) {
                $issues += "in wrong OU ($($au.DistinguishedName))"
            }
            if ($issues.Count -gt 0) { return @{ Status='Warn'; Detail=($issues -join '; ') } }
            @{ Status='Pass'; Detail=$au.DistinguishedName }
        }
        if ($isAdmin) {
            Invoke-Check -Name "User '$uname' is a Domain Admin" -Remedy "Add-ADGroupMember -Identity 'Domain Admins' -Members $uname" -Body {
                Import-Module ActiveDirectory -ErrorAction Stop
                $au = Get-ADUser -Identity $uname -Properties MemberOf -ErrorAction SilentlyContinue
                if (-not $au) { return @{ Status='Fail'; Detail='User missing' } }
                $inGroup = $au.MemberOf -match 'CN=Domain Admins,'
                if ($inGroup) { @{ Status='Pass'; Detail='Member of Domain Admins' } }
                else          { @{ Status='Fail'; Detail='Not in Domain Admins' } }
            }
        }
    }

    Invoke-Check -Name "Built-in Administrator was renamed to 'irajeacv'" -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        $domSid = (Get-ADDomain).DomainSID.Value
        $admin = Get-ADUser -Filter * | Where-Object { $_.SID.Value -eq "$domSid-500" } | Select-Object -First 1
        if (-not $admin) { return @{ Status='Fail'; Detail='SID -500 account missing' } }
        if ($admin.SamAccountName -eq 'irajeacv') { @{ Status='Pass'; Detail='SID -500 SAM = irajeacv' } }
        else { @{ Status='Fail'; Detail="SID -500 SAM = $($admin.SamAccountName) (expected irajeacv)" } }
    }

    Invoke-Check -Name "'Remote Desktop Users' group grants Write Members to Everyone" -Body {
        Import-Module ActiveDirectory -ErrorAction Stop
        $g = Get-ADGroup -Identity 'Remote Desktop Users'
        $adsi = [ADSI]"LDAP://$($g.DistinguishedName)"
        $acl = $adsi.psbase.ObjectSecurity
        $rule = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq 'Everyone' -and $_.ActiveDirectoryRights -match 'WriteProperty'
        } | Select-Object -First 1
        if ($rule) { @{ Status='Pass'; Detail='Everyone has WriteProperty on group' } }
        else { @{ Status='Warn'; Detail='No Everyone WriteProperty ACE found (manual config may differ)' } }
    }

    Set-Phase 'Group Policy'

    foreach ($ou in @('Iraje','Nologoff','Winupdate')) {
        $ouName = $ou
        Invoke-Check -Name "Block inheritance enabled on OU '$ouName'" -Body {
            Import-Module GroupPolicy     -ErrorAction Stop
            Import-Module ActiveDirectory -ErrorAction Stop
            $domainDN = (Get-ADDomain).DistinguishedName
            $inh = Get-GPInheritance -Target "OU=$ouName,$domainDN" -ErrorAction Stop
            $blocked = $inh.GpoInheritanceBlocked
            if ("$blocked" -eq 'Yes' -or $blocked -eq $true) { @{ Status='Pass'; Detail='Blocked' } }
            else { @{ Status='Fail'; Detail='Not blocked' } }
        }
    }

    foreach ($pair in @(
        @{ Gpo='Iraje group policy';    OU='Iraje'    }
        @{ Gpo='Nologoff group policy'; OU='Nologoff' }
        @{ Gpo='winupdate group policy';OU='Winupdate'}
    )) {
        $gpoName = $pair.Gpo; $ouName = $pair.OU
        Invoke-Check -Name "GPO '$gpoName' exists and is linked to OU '$ouName'" -Body {
            Import-Module GroupPolicy     -ErrorAction Stop
            Import-Module ActiveDirectory -ErrorAction Stop
            $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
            if (-not $gpo) { return @{ Status='Warn'; Detail='GPO missing (may be optional)' } }
            $domainDN = (Get-ADDomain).DistinguishedName
            $links = (Get-GPInheritance -Target "OU=$ouName,$domainDN").GpoLinks
            $linked = $links | Where-Object { $_.DisplayName -eq $gpoName }
            if ($linked) { @{ Status='Pass'; Detail='Linked and enabled' } }
            else { @{ Status='Fail'; Detail="GPO exists but not linked to OU=$ouName" } }
        }
    }

    Invoke-Check -Name "irajesrv has 'Allow log on locally' on the DC" -Body {
        $tmp = Join-Path $env:TEMP "secaudit-$([Guid]::NewGuid()).inf"
        try {
            & secedit /export /cfg $tmp /quiet 2>&1 | Out-Null
            if (-not (Test-Path $tmp)) { return @{ Status='Warn'; Detail='secedit export failed' } }
            $rights = Get-Content $tmp -Raw -ErrorAction Stop
            $line = ($rights -split "`n") | Where-Object { $_ -match '^SeInteractiveLogonRight' } | Select-Object -First 1
            if (-not $line) { return @{ Status='Warn'; Detail='SeInteractiveLogonRight not in policy export' } }
            if ($line -match 'irajesrv') { @{ Status='Pass'; Detail=$line.Trim() } }
            else { @{ Status='Warn'; Detail="Right exists but irajesrv not obviously listed: $($line.Trim())" } }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    Set-Phase 'Remote Desktop Services'

    foreach ($f in @('RDS-RD-Server','RDS-Web-Access','RDS-Gateway','RDS-Licensing')) {
        $feat = $f
        Invoke-Check -Name "Feature '$feat' installed" -Remedy "Install-WindowsFeature -Name $feat -IncludeManagementTools" -Body {
            Test-FeatureInstalled -FeatureName $feat
        }
    }

    Invoke-Check -Name 'RDS deployment present (RDS-CONNECTION-BROKER)' -Body {
        Import-Module RemoteDesktop -ErrorAction Stop
        $cb = Get-RDServer -ErrorAction SilentlyContinue | Where-Object { $_.Roles -contains 'RDS-CONNECTION-BROKER' } | Select-Object -First 1
        if ($cb) { @{ Status='Pass'; Detail="Broker: $($cb.Server)" } }
        else     { @{ Status='Fail'; Detail='No Connection Broker found - deployment may be missing' } }
    }

    Invoke-Check -Name "Session collection 'EPM App' exists" -Body {
        Import-Module RemoteDesktop -ErrorAction Stop
        $c = Get-RDSessionCollection -CollectionName 'EPM App' -ErrorAction SilentlyContinue
        if ($c) { @{ Status='Pass'; Detail="Hosts: $($c.Size) session host(s)" } }
        else    { @{ Status='Fail'; Detail="Collection 'EPM App' missing" } }
    }

    Invoke-Check -Name "RemoteApp 'Shadow' published with CommandLineSetting=Allow" -Body {
        Import-Module RemoteDesktop -ErrorAction Stop
        $r = Get-RDRemoteApp -CollectionName 'EPM App' -ErrorAction SilentlyContinue | Where-Object { $_.Alias -eq 'Shadow' -or $_.DisplayName -eq 'Shadow' } | Select-Object -First 1
        if (-not $r) { return @{ Status='Fail'; Detail='Shadow RemoteApp not published' } }
        if ($r.CommandLineSetting -ne 'Allow') {
            @{ Status='Warn'; Detail="Published but CommandLineSetting=$($r.CommandLineSetting) (doc requires Allow)" }
        } else {
            @{ Status='Pass'; Detail="Path: $($r.FilePath)" }
        }
    }

    Invoke-Check -Name 'RD Licensing configured as Per-Device' -Body {
        Import-Module RemoteDesktop -ErrorAction Stop
        try {
            $cb = (Get-RDServer | Where-Object { $_.Roles -contains 'RDS-CONNECTION-BROKER' } | Select-Object -First 1).Server
            $lc = Get-RDLicenseConfiguration -ConnectionBroker $cb -ErrorAction Stop
            if ($lc.Mode -eq 'PerDevice') { @{ Status='Pass'; Detail='Mode = PerDevice' } }
            else                          { @{ Status='Warn'; Detail="Mode = $($lc.Mode) (doc target: PerDevice)" } }
        } catch {
            @{ Status='Warn'; Detail=$_.Exception.Message }
        }
    }

    Set-Phase 'IIS & Web Site'

    foreach ($f in @('Web-Server','Web-WebSockets','Web-AppInit','Web-WHC','Web-Mgmt-Compat')) {
        $feat = $f
        Invoke-Check -Name "Feature '$feat' installed" -Body { Test-FeatureInstalled -FeatureName $feat }
    }

    Invoke-Check -Name "Site 'EPMDashboard' exists and is Started" -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $s = Get-Website -Name 'EPMDashboard' -ErrorAction SilentlyContinue
        if (-not $s) { return @{ Status='Fail'; Detail='Site missing' } }
        if ($s.State -ne 'Started') { return @{ Status='Fail'; Detail="State = $($s.State)" } }
        @{ Status='Pass'; Detail="State=$($s.State); PhysicalPath=$($s.PhysicalPath)" }
    }

    Invoke-Check -Name "'EPMDashboard' has an HTTPS binding" -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $b = Get-WebBinding -Name 'EPMDashboard' -Protocol 'https' -ErrorAction SilentlyContinue
        if (-not $b) { return @{ Status='Fail'; Detail='No HTTPS binding' } }
        $info = ($b | ForEach-Object { $_.bindingInformation }) -join ', '
        if ($ServerIP -and ($info -notmatch [regex]::Escape($ServerIP))) {
            return @{ Status='Warn'; Detail="HTTPS binding present ($info) but expected IP $ServerIP not found" }
        }
        @{ Status='Pass'; Detail=$info }
    }

    Invoke-Check -Name 'SSL certificate bound to a port (IIS:\SslBindings)' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $sslEntry = @(Get-ChildItem 'IIS:\SslBindings\' -ErrorAction SilentlyContinue)
        if ($sslEntry.Count -gt 0) { @{ Status='Pass'; Detail="$($sslEntry.Count) SSL binding(s) registered" } }
        else { @{ Status='Warn'; Detail='No SSL binding rows in IIS:\SslBindings' } }
    }

    Invoke-Check -Name 'Default Web Site removed' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) {
            @{ Status='Warn'; Detail='Default Web Site still present (doc says delete)' }
        } else {
            @{ Status='Pass'; Detail='Removed' }
        }
    }

    Set-Phase 'App Pool & Worker Service'

    Invoke-Check -Name "App pool 'EPMDashboard' exists" -Body {
        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path 'IIS:\AppPools\EPMDashboard') { @{ Status='Pass'; Detail='Present' } }
        else { @{ Status='Fail'; Detail='Missing' } }
    }

    Invoke-Check -Name 'EPMDashboard Identity = LocalSystem' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'processModel.identityType').Value
        if ($v -eq 'LocalSystem') { @{ Status='Pass'; Detail=$v }   }
        else                       { @{ Status='Fail'; Detail="Got $v, expected LocalSystem" } }
    }

    Invoke-Check -Name 'EPMDashboard Enable32BitAppOnWin64 = True' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'enable32BitAppOnWin64').Value
        if ([bool]$v) { @{ Status='Pass'; Detail='True' } } else { @{ Status='Fail'; Detail='False' } }
    }

    Invoke-Check -Name 'EPMDashboard managedRuntimeVersion = No Managed Code' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'managedRuntimeVersion').Value
        if ([string]::IsNullOrEmpty($v)) { @{ Status='Pass'; Detail='No Managed Code' } }
        else { @{ Status='Fail'; Detail="Got '$v', expected '' (No Managed Code)" } }
    }

    Invoke-Check -Name 'EPMDashboard startMode = AlwaysRunning' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'startMode').Value
        if ($v -eq 'AlwaysRunning') { @{ Status='Pass'; Detail=$v } }
        else { @{ Status='Fail'; Detail="Got $v, expected AlwaysRunning" } }
    }

    Invoke-Check -Name 'EPMDashboard idleTimeout = 0 (warm-up)' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'processModel.idleTimeout').Value
        if ($v -eq [TimeSpan]::Zero) { @{ Status='Pass'; Detail='00:00:00' } }
        else { @{ Status='Fail'; Detail="Got $v, expected 00:00:00" } }
    }

    Invoke-Check -Name 'EPMDashboard periodic recycle = 0 (warm-up)' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\AppPools\EPMDashboard' -Name 'recycling.periodicRestart.time').Value
        if ($v -eq [TimeSpan]::Zero) { @{ Status='Pass'; Detail='00:00:00' } }
        else { @{ Status='Warn'; Detail="Got $v, expected 00:00:00" } }
    }

    Invoke-Check -Name 'EPMDashboard site preloadEnabled = True' -Body {
        Import-Module WebAdministration -ErrorAction Stop
        $v = (Get-ItemProperty 'IIS:\Sites\EPMDashboard' -Name 'applicationDefaults.preloadEnabled').Value
        if ([bool]$v) { @{ Status='Pass'; Detail='True' } } else { @{ Status='Fail'; Detail='False' } }
    }

    Invoke-Check -Name "Service 'iworker' is installed" -Remedy 'iworker is created by Install-IrajeEPM Phase 12' -Body {
        $svc = Get-Service -Name 'iworker' -ErrorAction SilentlyContinue
        if ($svc) { @{ Status='Pass'; Detail="StartType=$($svc.StartType)" } }
        else      { @{ Status='Fail'; Detail='iworker not installed' } }
    }

    Invoke-Check -Name "Service 'iworker' is running" -Remedy 'Start-Service iworker' -Body {
        Test-ServiceRunning -Name 'iworker'
    }

    Invoke-Check -Name "Service 'iworker' has recovery actions" -Body {
        $out = (& sc.exe qfailure iworker 2>&1) -join "`n"
        if ($out -match 'RESTART') { @{ Status='Pass'; Detail='Restart action configured' } }
        else { @{ Status='Warn'; Detail='No RESTART in recovery output' }   }
    }

    Set-Phase 'Firewall & Security'

    Invoke-Check -Name "Firewall rule 'Iraje' exists (TCP 445, 443, 3389)" -Body {
        $r = Get-NetFirewallRule -DisplayName 'Iraje' -ErrorAction SilentlyContinue
        if (-not $r) { return @{ Status='Fail'; Detail='Rule missing' } }
        $pf = $r | Get-NetFirewallPortFilter
        $portList = @($pf.LocalPort) | Sort-Object
        $ports = $portList -join ', '
        $required = @('443','445','3389')
        $missing = $required | Where-Object { $portList -notcontains $_ }
        if ($missing) { @{ Status='Warn'; Detail="Rule present (ports: $ports); missing: $($missing -join ',')" } }
        else { @{ Status='Pass'; Detail="Ports: $ports" } }
    }

    Invoke-Check -Name 'Windows Firewall enabled on all three profiles' -Body {
        $bad = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled })
        if ($bad.Count -gt 0) { @{ Status='Warn'; Detail="Disabled profile(s): $(($bad.Name) -join ', ')" } }
        else { @{ Status='Pass'; Detail='Domain, Private, Public all on' } }
    }

    Invoke-Check -Name 'NLA disabled on RDP-Tcp (UserAuthentication = 0)' -Body {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication).UserAuthentication
        if ($v -eq 0) { @{ Status='Pass'; Detail='Disabled' } }
        else { @{ Status='Warn'; Detail="UserAuthentication = $v (expected 0)" } }
    }

    Invoke-Check -Name 'UAC ConsentPromptBehaviorAdmin = 0 (Never notify)' -Body {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
        if ($v -eq 0) { @{ Status='Pass'; Detail='0 = Never notify' } }
        else { @{ Status='Warn'; Detail="Got $v, doc target 0" } }
    }

    Invoke-Check -Name 'PsExec EULA accepted (no first-run prompt)' -Body {
        $ok = $false
        foreach ($p in @('HKLM:\Software\Sysinternals\PsExec','HKCU:\Software\Sysinternals\PsExec')) {
            try {
                $v = (Get-ItemProperty -Path $p -Name EulaAccepted -ErrorAction Stop).EulaAccepted
                if ($v -eq 1) { $ok = $true; break }
            } catch {}
        }
        if ($ok) { @{ Status='Pass'; Detail='Set' } }
        else     { @{ Status='Warn'; Detail='Not set - first PsExec run will block on EULA' } }
    }

    Invoke-Check -Name 'GoogleUpdate disabled' -Body {
        $exe = "${env:ProgramFiles(x86)}\Google\Update\GoogleUpdate.exe"
        $task = Get-ScheduledTask | Where-Object { $_.TaskName -like 'GoogleUpdate*' } | Select-Object -First 1
        if (-not (Test-Path -LiteralPath $exe) -and -not $task) { @{ Status='Pass'; Detail='Renamed and task removed' } }
        elseif ($task) { @{ Status='Warn'; Detail="Task '$($task.TaskName)' still present" } }
        else { @{ Status='Warn'; Detail='GoogleUpdate.exe still present' } }
    }

    Set-Phase 'Database & Migrations'

    Invoke-Check -Name 'MySQL service installed and running' -Body {
        $svc = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $svc) { return @{ Status='Fail'; Detail='No MySQL service installed' } }
        if ($svc.Status -ne 'Running') { return @{ Status='Fail'; Detail="Service $($svc.Name) is $($svc.Status)" } }
        @{ Status='Pass'; Detail="$($svc.Name) running" }
    }

    Invoke-Check -Name "'epm' database exists" -Body {
        if (-not $MySqlRootPassword) { return @{ Status='Skip'; Detail='Pass -MySqlRootPassword to verify' } }
        $mysql = Get-MySqlClientPath
        if (-not $mysql) { return @{ Status='Fail'; Detail='mysql.exe not found' } }
        $out = & $mysql -u root "--password=$MySqlRootPassword" -e 'SHOW DATABASES;' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return @{ Status='Fail'; Detail=("MySQL login failed: " + $out.Trim()) } }
        if ($out -match '(?im)^\s*epm\s*$') { @{ Status='Pass'; Detail="'epm' DB present" } }
        else { @{ Status='Fail'; Detail="'epm' DB missing in output" } }
    }

    Invoke-Check -Name 'Flyway CLI installed at C:\flyway-11.20.2\flyway.cmd' -Body {
        if (Test-Path 'C:\flyway-11.20.2\flyway.cmd') { @{ Status='Pass'; Detail='Present' } }
        else { @{ Status='Fail'; Detail='Missing' } }
    }

    Invoke-Check -Name 'MySQL connector JAR present in Flyway drivers folder' -Body {
        $jar = Get-ChildItem 'C:\flyway-11.20.2\drivers\mysql-connector-*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($jar) { @{ Status='Pass'; Detail=$jar.Name } }
        else { @{ Status='Fail'; Detail='No mysql-connector JAR in drivers folder' } }
    }

    Invoke-Check -Name 'C:\flyway-11.20.2 on machine PATH' -Body {
        $p = [Environment]::GetEnvironmentVariable('Path','Machine')
        if ($p -match [regex]::Escape('C:\flyway-11.20.2')) { @{ Status='Pass'; Detail='Present' } }
        else { @{ Status='Warn'; Detail='Not in machine PATH' } }
    }

    Invoke-Check -Name 'FLYWAY_DB_USER + FLYWAY_DB_PASSWORD machine env vars set' -Body {
        $u = [Environment]::GetEnvironmentVariable('FLYWAY_DB_USER','Machine')
        $p = [Environment]::GetEnvironmentVariable('FLYWAY_DB_PASSWORD','Machine')
        if ($u -and $p) { @{ Status='Pass'; Detail="user=$u, password=(set)" } }
        else { @{ Status='Warn'; Detail="user=$u, password=$(if($p){'set'}else{'MISSING'})" } }
    }

    Invoke-Check -Name 'Flyway migrations applied (info reports Success)' -Body {
        $work = 'C:\Windows\Web\IrajeEPM\epmdms'
        if (-not (Test-Path $work)) { return @{ Status='Skip'; Detail='epmdms folder missing' } }
        $flyway = 'C:\flyway-11.20.2\flyway.cmd'
        if (-not (Test-Path $flyway)) { return @{ Status='Skip'; Detail='flyway.cmd missing' } }
        $prev = Get-Location
        try {
            Set-Location -LiteralPath $work
            $out = & $flyway info 2>&1 | Out-String
        } finally { Set-Location $prev }
        if ($out -match 'No migrations found') { return @{ Status='Warn'; Detail='No migrations - is epm-db populated?' } }
        if ($out -match 'Pending')             { return @{ Status='Warn'; Detail='Pending migrations exist' } }
        if ($out -match 'Failed')              { return @{ Status='Fail'; Detail='Failed migrations - check flyway info' } }
        if ($out -match 'Success')             { return @{ Status='Pass'; Detail='All Success' } }
        @{ Status='Warn'; Detail='Could not interpret flyway info output' }
    }

    Set-Phase 'Installed Software'

    foreach ($pat in @(
        @{ Name='Google Chrome';                            Pattern='^Google Chrome' }
        @{ Name='Microsoft .NET Hosting Bundle';            Pattern='Windows Server Hosting|\.NET .* Hosting' }
        @{ Name='Erlang/OTP';                               Pattern='^Erlang OTP' }
        @{ Name='RabbitMQ Server';                          Pattern='RabbitMQ Server' }
        @{ Name='Visual C++ 2015-2022 Redistributable x64'; Pattern='Visual C\+\+ 20\d\d.*x64' }
        @{ Name='MySQL Server';                             Pattern='^MySQL Server' }
        @{ Name='MySQL Workbench';                          Pattern='^MySQL Workbench' }
    )) {
        $pname = $pat.Name; $pat2 = $pat.Pattern
        Invoke-Check -Name "$pname installed" -Body { Test-InstalledProduct -Pattern $pat2 }
    }

    Invoke-Check -Name 'RabbitMQ service running' -Body { Test-ServiceRunning -Name 'RabbitMQ' }

    Invoke-Check -Name 'RabbitMQ management plugin enabled' -Body {
        $sbinDir = Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Directory -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
        if (-not $sbinDir) { return @{ Status='Skip'; Detail='RabbitMQ not installed' } }
        $sbin = Join-Path $sbinDir.FullName 'sbin'
        $plugins = Join-Path $sbin 'rabbitmq-plugins.bat'
        if (-not (Test-Path $plugins)) { return @{ Status='Skip'; Detail='rabbitmq-plugins.bat missing' } }
        $out = & $plugins list 2>&1 | Out-String
        if ($out -match '\[E.\]\s+rabbitmq_management') { @{ Status='Pass'; Detail='Enabled' } }
        else { @{ Status='Fail'; Detail='Not enabled - run "rabbitmq-plugins enable rabbitmq_management"' } }
    }

    foreach ($f in @('NET-Framework-Core','Simple-TCPIP','Telnet-Client')) {
        $feat = $f
        Invoke-Check -Name "Feature '$feat' installed" -Body { Test-FeatureInstalled -FeatureName $feat }
    }

    Set-Phase 'EPM Application Files'

    foreach ($p in @(
        'C:\Windows\Web\IrajeEPM\EPMDashboard',
        'C:\Windows\Web\IrajeEPM\IrajeWorker',
        'C:\Windows\Web\IrajeEPM\IrajeSecureAccess',
        'C:\Windows\Web\IrajeEPM\epmdms',
        'C:\Windows\Web\Logs',
        'C:\software'
    )) {
        $folder = $p
        Invoke-Check -Name "Folder exists: $folder" -Body {
            if (Test-Path -LiteralPath $folder) {
                $count = @(Get-ChildItem -LiteralPath $folder -ErrorAction SilentlyContinue).Count
                @{ Status='Pass'; Detail="$count item(s) inside" }
            } else {
                @{ Status='Fail'; Detail='Missing' }
            }
        }
    }

    Invoke-Check -Name 'EpmWorker.exe present in IrajeWorker folder' -Body {
        if (Test-Path 'C:\Windows\Web\IrajeEPM\IrajeWorker\EpmWorker.exe') { @{ Status='Pass'; Detail='Present' } }
        else { @{ Status='Fail'; Detail='EpmWorker.exe missing - iworker service will fail to start' } }
    }

    Invoke-Check -Name 'appsetting.json present and references an HTTP(S) endpoint' -Body {
        $f = 'C:\Windows\Web\IrajeEPM\IrajeWorker\appsetting.json'
        if (-not (Test-Path -LiteralPath $f)) { return @{ Status='Fail'; Detail='Missing' } }
        $txt = Get-Content -LiteralPath $f -Raw
        if ($txt -match 'https?://[^\s",]+') { @{ Status='Pass'; Detail="URL pattern found: $($Matches[0])" } }
        else { @{ Status='Warn'; Detail='No URL in appsetting.json' }   }
    }

    Invoke-Check -Name 'Shadow.exe present in C:\Windows\Web' -Body {
        if (Test-Path 'C:\Windows\Web\Shadow.exe') { @{ Status='Pass'; Detail='Present' } }
        else { @{ Status='Fail'; Detail='Missing - Phase 14 Shadow RemoteApp will fail' } }
    }

    Invoke-Check -Name "Self-signed certificate present for this server's FQDN" -Body {
        $cs = Get-CimInstance Win32_ComputerSystem
        $fqdn = "$env:COMPUTERNAME.$($cs.Domain)"
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match "CN=$fqdn" } | Select-Object -First 1
        if ($cert) { @{ Status='Pass'; Detail="Thumbprint $($cert.Thumbprint); NotAfter $($cert.NotAfter)" } }
        else { @{ Status='Warn'; Detail="No cert with CN=$fqdn in LocalMachine\My" } }
    }

    Set-Phase 'Miscellaneous Hardening'

    Invoke-Check -Name 'IIS_IUSRS and IUSR have access to EPMDashboard folder' -Body {
        $path = 'C:\Windows\Web\IrajeEPM\EPMDashboard'
        if (-not (Test-Path $path)) { return @{ Status='Skip'; Detail='Folder missing' } }
        $acl = Get-Acl -Path $path
        $iisAccess = $acl.Access | Where-Object { $_.IdentityReference -match 'IIS_IUSRS' }
        $iusrAccess = $acl.Access | Where-Object { $_.IdentityReference -match 'IUSR' }
        $missing = @()
        if (-not $iisAccess)  { $missing += 'IIS_IUSRS' }
        if (-not $iusrAccess) { $missing += 'IUSR' }
        if ($missing.Count -gt 0) { @{ Status='Warn'; Detail="Missing ACE for: $($missing -join ', ')" } }
        else { @{ Status='Pass'; Detail='Both present' } }
    }

    Invoke-Check -Name 'C:\Windows\Web owner = irajeacv (or domain admin equivalent)' -Body {
        $acl = Get-Acl -Path 'C:\Windows\Web'
        if ($acl.Owner -match 'irajeacv') { @{ Status='Pass'; Detail=$acl.Owner } }
        else { @{ Status='Warn'; Detail="Owner = $($acl.Owner)" } }
    }

    Invoke-Check -Name 'IIS Application Initialization feature installed' -Body {
        Test-FeatureInstalled -FeatureName 'Web-AppInit'
    }

    Invoke-Check -Name 'IrajeEPMResume scheduled task has been removed (install finished)' -Body {
        $t = Get-ScheduledTask -TaskName 'IrajeEPMResume' -ErrorAction SilentlyContinue
        if (-not $t) { @{ Status='Pass'; Detail='No resume task pending' } }
        else { @{ Status='Warn'; Detail="Resume task still registered (state=$($t.State)) - last install may not have completed" } }
    }

    Invoke-Check -Name 'Install state file shows all install steps Done' -Body {
        $sf = 'C:\ProgramData\IrajeEPM\state.json'
        if (-not (Test-Path $sf)) { return @{ Status='Skip'; Detail='No install state file (verify ran independently)' } }
        $state = Get-Content $sf -Raw | ConvertFrom-Json
        $stepProps = $state.Steps.PSObject.Properties
        $total = @($stepProps).Count
        $done = @($stepProps | Where-Object { $_.Value -eq 'Done' }).Count
        $outstanding = @($stepProps | Where-Object { $_.Value -in @('Failed','InProgress','Pending') } | ForEach-Object { $_.Name })
        if ($done -eq $total) { @{ Status='Pass'; Detail="$done/$total Done" } }
        else { @{ Status='Warn'; Detail="$done/$total Done; outstanding: $($outstanding -join ', ')" } }
    }
}

# ============================================================================
# Output rendering
# ============================================================================

function Write-ConsoleSummary {
    $total = $script:Results.Count
    $pass  = @($script:Results | Where-Object Status -eq 'Pass').Count
    $fail  = @($script:Results | Where-Object Status -eq 'Fail').Count
    $warn  = @($script:Results | Where-Object Status -eq 'Warn').Count
    $skip  = @($script:Results | Where-Object Status -eq 'Skip').Count

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor White
    Write-Host '                          VERIFICATION SUMMARY' -ForegroundColor White
    Write-Host ('=' * 78) -ForegroundColor White
    Write-Host ('Total checks:  {0}' -f $total)
    Write-Host ('  Passed:      {0}' -f $pass)  -ForegroundColor Green
    Write-Host ('  Warnings:    {0}' -f $warn) -ForegroundColor Yellow
    Write-Host ('  Failed:      {0}' -f $fail) -ForegroundColor Red
    if ($skip -gt 0) { Write-Host ('  Skipped:     {0}' -f $skip) -ForegroundColor DarkGray }
    Write-Host ''

    if ($fail -gt 0) {
        Write-Host 'FAILED CHECKS:' -ForegroundColor Red
        foreach ($r in @($script:Results | Where-Object Status -eq 'Fail')) {
            Write-Host ("  [{0}] {1}" -f $r.Phase, $r.Name) -ForegroundColor Red
            if ($r.Detail) { Write-Host ("       -> {0}" -f $r.Detail) -ForegroundColor DarkGray }
            if ($r.Remedy) { Write-Host ("       Fix: {0}" -f $r.Remedy) -ForegroundColor DarkYellow }
        }
        Write-Host ''
    }
    if ($warn -gt 0) {
        Write-Host 'WARNINGS:' -ForegroundColor Yellow
        foreach ($r in @($script:Results | Where-Object Status -eq 'Warn')) {
            Write-Host ("  [{0}] {1}" -f $r.Phase, $r.Name) -ForegroundColor Yellow
            if ($r.Detail) { Write-Host ("       -> {0}" -f $r.Detail) -ForegroundColor DarkGray }
        }
        Write-Host ''
    }

    $verdict = if ($fail -gt 0) { 'FAIL' } elseif ($warn -gt 0) { 'PASS (with warnings)' } else { 'PASS' }
    $color   = if ($fail -gt 0) { 'Red' }   elseif ($warn -gt 0) { 'Yellow' }              else { 'Green' }
    Write-Host ('Overall verdict: {0}' -f $verdict) -ForegroundColor $color
    Write-Host ('Report file:    {0}' -f $OutputHtml)
    if ($OutputJson) { Write-Host ('JSON file:      {0}' -f $OutputJson) }
    Write-Host ''
}

function ConvertTo-HtmlSafe {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function Write-HtmlReport {
    $total = $script:Results.Count
    $pass  = @($script:Results | Where-Object Status -eq 'Pass').Count
    $fail  = @($script:Results | Where-Object Status -eq 'Fail').Count
    $warn  = @($script:Results | Where-Object Status -eq 'Warn').Count
    $skip  = @($script:Results | Where-Object Status -eq 'Skip').Count

    $os = Get-OsInfo
    $hostname = $env:COMPUTERNAME
    try { $cs = Get-CimInstance Win32_ComputerSystem; if ($cs.Domain) { $hostname = "$env:COMPUTERNAME.$($cs.Domain)" } } catch {}

    $css = @'
<style>
body { font-family: 'Segoe UI', Arial, sans-serif; max-width: 1200px; margin: 24px auto; padding: 20px; background: #f4f6f8; color: #333; }
h1 { color: #1e2a38; border-bottom: 4px solid #2980b9; padding-bottom: 10px; margin-bottom: 6px; }
.meta { color: #7f8c8d; margin-bottom: 24px; font-size: 0.95em; }
.summary { display: flex; gap: 16px; margin: 20px 0 28px; }
.summary-card { padding: 18px 12px; border-radius: 8px; flex: 1; color: white; text-align: center; }
.summary-card .num { font-size: 2em; font-weight: 700; line-height: 1; }
.summary-card .lbl { margin-top: 6px; text-transform: uppercase; letter-spacing: 1px; font-size: 0.8em; }
.pass-bg { background: #27ae60; }
.fail-bg { background: #c0392b; }
.warn-bg { background: #e67e22; }
.skip-bg { background: #7f8c8d; }
.verdict { padding: 12px 20px; border-radius: 6px; font-weight: 700; font-size: 1.2em; display: inline-block; margin: 8px 0 24px; color: white; }
.phase { background: white; margin: 20px 0; padding: 18px 22px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.phase h2 { color: #2c3e50; margin-top: 0; border-bottom: 1px solid #ecf0f1; padding-bottom: 8px; font-size: 1.2em; }
.check { padding: 10px 14px; border-left: 5px solid; margin: 6px 0; background: #fafbfc; border-radius: 0 4px 4px 0; }
.check.pass { border-color: #27ae60; }
.check.fail { border-color: #c0392b; background: #fff5f5; }
.check.warn { border-color: #e67e22; background: #fff9e6; }
.check.skip { border-color: #95a5a6; background: #f8f9fa; opacity: 0.75; }
.tag { display: inline-block; padding: 2px 8px; border-radius: 12px; color: white; font-size: 0.8em; font-weight: 600; margin-right: 10px; min-width: 50px; text-align: center; }
.tag.pass { background: #27ae60; }
.tag.fail { background: #c0392b; }
.tag.warn { background: #e67e22; }
.tag.skip { background: #95a5a6; }
.check-name { font-weight: 600; color: #2c3e50; }
.check-detail { color: #7f8c8d; margin-top: 4px; font-size: 0.92em; }
.check-remedy { color: #c0392b; margin-top: 4px; font-size: 0.92em; font-family: Consolas, monospace; background: #fdf2f2; padding: 4px 8px; border-radius: 3px; display: inline-block; }
table.kv td { padding: 3px 14px 3px 0; }
table.kv td:first-child { color: #7f8c8d; font-weight: 600; }
</style>
'@

    $verdictText  = if ($fail -gt 0) { "FAIL  -  $fail check(s) need attention" } elseif ($warn -gt 0) { "PASS with $warn warning(s)" } else { 'PASS  -  All systems go' }
    $verdictClass = if ($fail -gt 0) { 'fail-bg' } elseif ($warn -gt 0) { 'warn-bg' } else { 'pass-bg' }
    $rolesDisplay = if ($script:RoleDetected) { $script:RoleDetected -join ' + ' } else { 'unknown' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8"/>')
    [void]$sb.AppendLine("<title>Iraje EPM Verification - $(ConvertTo-HtmlSafe $hostname)</title>")
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine('<h1>Iraje EPM Verification Report</h1>')
    [void]$sb.AppendLine("<div class=`"meta`">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') in $([int]((Get-Date) - $script:StartTime).TotalSeconds)s</div>")
    [void]$sb.AppendLine('<table class="kv">')
    [void]$sb.AppendLine("<tr><td>Server:</td><td>$(ConvertTo-HtmlSafe $hostname)</td></tr>")
    [void]$sb.AppendLine("<tr><td>OS:</td><td>$(ConvertTo-HtmlSafe $os.Caption) (build $($os.BuildNumber))</td></tr>")
    [void]$sb.AppendLine("<tr><td>Role checked:</td><td>$(ConvertTo-HtmlSafe $rolesDisplay)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Expected domain:</td><td>$(if($DomainName){ConvertTo-HtmlSafe $DomainName}else{'(not supplied)'})</td></tr>")
    [void]$sb.AppendLine("<tr><td>Expected server IP:</td><td>$(if($ServerIP){ConvertTo-HtmlSafe $ServerIP}else{'(not supplied)'})</td></tr>")
    [void]$sb.AppendLine("<tr><td>Expected NTP IP:</td><td>$(if($NtpServerIP){ConvertTo-HtmlSafe $NtpServerIP}else{'(not supplied)'})</td></tr>")
    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine("<div class=`"verdict $verdictClass`">$(ConvertTo-HtmlSafe $verdictText)</div>")
    [void]$sb.AppendLine('<div class="summary">')
    [void]$sb.AppendLine("  <div class=`"summary-card pass-bg`"><div class=`"num`">$pass</div><div class=`"lbl`">Passed</div></div>")
    [void]$sb.AppendLine("  <div class=`"summary-card warn-bg`"><div class=`"num`">$warn</div><div class=`"lbl`">Warnings</div></div>")
    [void]$sb.AppendLine("  <div class=`"summary-card fail-bg`"><div class=`"num`">$fail</div><div class=`"lbl`">Failed</div></div>")
    [void]$sb.AppendLine("  <div class=`"summary-card skip-bg`"><div class=`"num`">$skip</div><div class=`"lbl`">Skipped</div></div>")
    [void]$sb.AppendLine('</div>')

    $phases = $script:Results | Group-Object Phase
    $phases = $phases | Sort-Object { ($_.Group | Select-Object -First 1).PhaseN }
    foreach ($pg in $phases) {
        $first = $pg.Group | Select-Object -First 1
        [void]$sb.AppendLine("<div class=`"phase`"><h2>Phase $($first.PhaseN): $(ConvertTo-HtmlSafe $pg.Name)</h2>")
        foreach ($r in $pg.Group) {
            $cls = $r.Status.ToLower()
            $tagText = $r.Status.ToUpper()
            $nameHtml = ConvertTo-HtmlSafe $r.Name
            $detHtml = if ($r.Detail) { "<div class=`"check-detail`">$(ConvertTo-HtmlSafe $r.Detail)</div>" } else { '' }
            $remHtml = if ($r.Remedy -and $r.Status -ne 'Pass') { "<div class=`"check-remedy`">Fix: $(ConvertTo-HtmlSafe $r.Remedy)</div>" } else { '' }
            [void]$sb.AppendLine("<div class=`"check $cls`"><span class=`"tag $cls`">$tagText</span><span class=`"check-name`">$nameHtml</span>$detHtml$remHtml</div>")
        }
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</body></html>')

    Set-Content -LiteralPath $OutputHtml -Value $sb.ToString() -Encoding UTF8
}

function Write-JsonReport {
    if (-not $OutputJson) { return }
    $payload = [pscustomobject]@{
        Generated      = (Get-Date).ToString('o')
        Hostname       = $env:COMPUTERNAME
        RoleDetected   = $script:RoleDetected
        ExpectedDomain = $DomainName
        ExpectedIP     = $ServerIP
        ExpectedNtpIP  = $NtpServerIP
        Results        = $script:Results.ToArray()
        Summary        = @{
            Total = $script:Results.Count
            Pass  = @($script:Results | Where-Object Status -eq 'Pass').Count
            Fail  = @($script:Results | Where-Object Status -eq 'Fail').Count
            Warn  = @($script:Results | Where-Object Status -eq 'Warn').Count
            Skip  = @($script:Results | Where-Object Status -eq 'Skip').Count
        }
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor White -BackgroundColor DarkBlue
Write-Host '              Iraje EPM Box-Making Verification' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host ('=' * 78) -ForegroundColor White -BackgroundColor DarkBlue

$rolesToRun = Resolve-Role
$script:RoleDetected = $rolesToRun
Write-Host ("Roles to verify: {0}" -f ($rolesToRun -join ', ')) -ForegroundColor Cyan

foreach ($r in $rolesToRun) {
    switch ($r) {
        'NTPServer' { Invoke-NtpServerChecks }
        'EPMServer' { Invoke-EpmServerChecks }
    }
}

Write-ConsoleSummary
Write-HtmlReport
Write-JsonReport

$failCount = @($script:Results | Where-Object Status -eq 'Fail').Count
exit ($(if ($failCount -gt 0) { 1 } else { 0 }))
