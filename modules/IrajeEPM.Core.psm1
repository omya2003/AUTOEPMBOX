#requires -Version 4.0
<#
    IrajeEPM.Core.psm1
    Shared primitives: logging, state, OS detection, elevation, reboot/resume.
    Loaded by Install-IrajeEPM.ps1 on every invocation (including post-reboot resumes).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StateRoot   = 'C:\ProgramData\IrajeEPM'
$script:StateFile   = Join-Path $StateRoot 'state.json'
$script:LogDir      = Join-Path $StateRoot 'logs'
$script:TaskName    = 'IrajeEPMResume'
$script:CurrentLog  = $null

# ---------- logging ----------

function Initialize-IrajeLog {
    [CmdletBinding()]
    param()
    foreach ($d in @($script:StateRoot, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:CurrentLog = Join-Path $script:LogDir "install-$stamp.log"
    # Start a transcript so installer stdout/stderr is captured too
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
    Start-Transcript -Path $script:CurrentLog -Append | Out-Null
    Write-IrajeLog -Level INFO -Message "Logging to $script:CurrentLog"
}

function Write-IrajeLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)] [string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Stop-IrajeLog {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
}

# ---------- state ----------
# State shape:
#   {
#     "Role": "EPMServer",
#     "Params": { "DomainName": "...", "ServerIP": "...", ... },
#     "Steps": { "PreflightChecks": "Done", "DisableNla": "Done", ... },
#     "StartedAt": "...", "UpdatedAt": "..."
#   }

function Get-IrajeState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        return Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
    } catch {
        Write-IrajeLog -Level WARN -Message "State file corrupt: $($_.Exception.Message). Starting fresh."
        return $null
    }
}

function Save-IrajeState {
    param([Parameter(Mandatory)] $State)
    $State.UpdatedAt = (Get-Date).ToString('o')
    if (-not (Test-Path -LiteralPath $script:StateRoot)) {
        New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function New-IrajeState {
    param(
        [Parameter(Mandatory)] [string]$Role,
        [Parameter(Mandatory)] [hashtable]$Params,
        [Parameter(Mandatory)] [string[]]$StepNames
    )
    $steps = [ordered]@{}
    foreach ($s in $StepNames) { $steps[$s] = 'Pending' }
    [pscustomobject]@{
        Role      = $Role
        Params    = $Params
        Steps     = [pscustomobject]$steps
        StartedAt = (Get-Date).ToString('o')
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function Set-IrajeStepStatus {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string]$StepName,
        [Parameter(Mandatory)] [ValidateSet('Pending','InProgress','Done','Failed','Skipped')] [string]$Status,
        [string]$Detail
    )
    if (-not ($State.Steps.PSObject.Properties.Name -contains $StepName)) {
        $State.Steps | Add-Member -NotePropertyName $StepName -NotePropertyValue $Status -Force
    } else {
        $State.Steps.$StepName = $Status
    }
    Save-IrajeState -State $State
    $msg = "Step '$StepName' -> $Status"
    if ($Detail) { $msg += " ($Detail)" }
    Write-IrajeLog -Level STEP -Message $msg
}

function Get-IrajeStepStatus {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] [string]$StepName)
    if ($State.Steps.PSObject.Properties.Name -contains $StepName) {
        return $State.Steps.$StepName
    }
    return 'Pending'
}

# ---------- environment / OS ----------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-IsAdmin {
    if (-not (Test-IsAdmin)) {
        throw "This script must run elevated (Administrator). Right-click PowerShell and 'Run as administrator'."
    }
}

function Get-WindowsServerInfo {
    # Use Win32_OperatingSystem rather than [System.Environment]::OSVersion (deprecated reporting)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $ver = [Version]$os.Version
    [pscustomobject]@{
        Caption    = $os.Caption.Trim()
        Version    = $ver
        BuildNumber= $os.BuildNumber
        IsServer   = ($os.ProductType -ne 1)  # 1 = workstation, 2 = DC, 3 = server
        IsDC       = ($os.ProductType -eq 2)
    }
}

function Assert-SupportedOS {
    $info = Get-WindowsServerInfo
    if (-not $info.IsServer) {
        throw "This script is for Windows Server only. Detected: $($info.Caption)"
    }
    # Server 2012 R2 == 6.3.9600
    $min = [Version]'6.3'
    if ($info.Version -lt $min) {
        throw "Minimum supported OS is Windows Server 2012 R2 (6.3). Detected: $($info.Caption) ($($info.Version))"
    }
    Write-IrajeLog -Level OK -Message "OS check passed: $($info.Caption) (build $($info.BuildNumber))"
    return $info
}

function Test-IsDomainController {
    return (Get-WindowsServerInfo).IsDC
}

function Test-IsDomainJoined {
    return (Get-CimInstance Win32_ComputerSystem).PartOfDomain
}

# ---------- reboot / resume ----------

function Register-IrajeResumeTask {
    <#
        Registers a SYSTEM-context scheduled task that runs once at next boot, re-launching
        the script with the same parameters. We pass the entry-point script path and a
        rebuilt param string. Existing task with the same name is replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [hashtable]$Params
    )

    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',("`"$ScriptPath`""))
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($null -eq $v -or $v -eq '') { continue }
        if ($v -is [switch] -or $v -is [bool]) {
            if ([bool]$v) { $argList += "-$k" }
        } else {
            $argList += "-$k"
            # Wrap in single quotes so passwords with $ # @ ! survive the cmdline
            $sv = "$v".Replace("'","''")
            $argList += "'$sv'"
        }
    }
    $argument = ($argList -join ' ')

    $action    = New-ScheduledTaskAction  -Execute 'powershell.exe' -Argument $argument
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -Priority 4

    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $script:TaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Iraje EPM box-making auto-resume after reboot' | Out-Null
    Write-IrajeLog -Level OK -Message "Registered scheduled task '$script:TaskName' for post-reboot resume."
}

function Unregister-IrajeResumeTask {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-IrajeLog -Level OK -Message "Removed scheduled task '$script:TaskName'."
    }
}

function Request-IrajeReboot {
    <#
        Calls Register-IrajeResumeTask, flushes state, then restarts the computer.
        Caller must have already saved any state it wants to persist.
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [hashtable]$Params,
        [int]$DelaySeconds = 10,
        [string]$Reason = 'Iraje EPM setup requires reboot'
    )
    Register-IrajeResumeTask -ScriptPath $ScriptPath -Params $Params
    Write-IrajeLog -Level WARN -Message "Rebooting in $DelaySeconds seconds - $Reason. Script will auto-resume."
    Stop-IrajeLog
    Start-Sleep -Seconds $DelaySeconds
    Restart-Computer -Force
    # Restart-Computer doesn't always return immediately; exit just in case
    exit 0
}

# ---------- step runner ----------

function Invoke-IrajeStep {
    <#
        Wraps a step function: checks state, marks InProgress, runs the scriptblock,
        marks Done on success or Failed on exception. Idempotent - Done steps are skipped.
    #>
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Body,
        [switch]$ContinueOnError
    )
    $status = Get-IrajeStepStatus -State $State -StepName $Name
    if ($status -eq 'Done') {
        Write-IrajeLog -Level OK -Message "Skip '$Name' (already Done)."
        return
    }
    if ($status -eq 'Skipped') {
        Write-IrajeLog -Level INFO -Message "Skip '$Name' (marked Skipped)."
        return
    }
    Set-IrajeStepStatus -State $State -StepName $Name -Status InProgress
    try {
        & $Body
        Set-IrajeStepStatus -State $State -StepName $Name -Status Done
    } catch {
        $msg = $_.Exception.Message
        Set-IrajeStepStatus -State $State -StepName $Name -Status Failed -Detail $msg
        Write-IrajeLog -Level ERROR -Message "Step '$Name' failed: $msg"
        if (-not $ContinueOnError) { throw }
    }
}

# ---------- small helpers used across modules ----------

function Test-AssetPath {
    param([Parameter(Mandatory)] [string]$Path, [switch]$AllowMissing)
    $exists = Test-Path -LiteralPath $Path
    if (-not $exists -and -not $AllowMissing) {
        throw "Required asset not found: $Path"
    }
    return $exists
}

function Invoke-Native {
    <#
        Runs a native command, captures stdout/stderr, throws on non-zero exit code unless -AllowFail.
        Use this instead of bare invocation so we get logging and non-zero detection.
    #>
    param(
        [Parameter(Mandatory)] [string]$File,
        [string[]]$Arguments = @(),
        [switch]$AllowFail,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($stdout) { Write-IrajeLog -Level INFO -Message ("[$File stdout] " + ($stdout.Trim())) }
    if ($stderr) { Write-IrajeLog -Level INFO -Message ("[$File stderr] " + ($stderr.Trim())) }
    if ($p.ExitCode -ne 0 -and -not $AllowFail) {
        throw "Native call failed ($File exit $($p.ExitCode)): $stderr"
    }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function ConvertTo-Hashtable {
    # Convert a PSCustomObject back to a hashtable (state.Params after JSON round-trip)
    param([Parameter(Mandatory)] $InputObject)
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

Export-ModuleMember -Function `
    Initialize-IrajeLog, Write-IrajeLog, Stop-IrajeLog, `
    Get-IrajeState, Save-IrajeState, New-IrajeState, `
    Set-IrajeStepStatus, Get-IrajeStepStatus, `
    Test-IsAdmin, Assert-IsAdmin, `
    Get-WindowsServerInfo, Assert-SupportedOS, Test-IsDomainController, Test-IsDomainJoined, `
    Register-IrajeResumeTask, Unregister-IrajeResumeTask, Request-IrajeReboot, `
    Invoke-IrajeStep, Test-AssetPath, Invoke-Native, ConvertTo-Hashtable
