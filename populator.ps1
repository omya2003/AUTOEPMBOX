<#
.SYNOPSIS
    Automatic asset populator for the Iraje EPM box-making project.

.DESCRIPTION
    Discovers EPM patch contents in PutPatch\ and Windows ISO contents in ISO\,
    moves the right pieces into the right places under assets\, auto-edits
    db_setup.ps1 to use environment variables, and validates the result.

    Idempotent: re-running fills only the still-missing pieces. Existing
    assets\ content is preserved unless -Force is passed.

    Recognition is by FOLDER NAME and FILE CONTENTS, not by parent path.
    So a payload nested any number of levels deep is still detected.

    Five phases:
      1. Discover  - walk PutPatch\, expand .zip/.7z to temp, index ISO\
      2. Match     - find a best candidate for each required slot
      3. Place     - move (cut) from PutPatch to assets\, copy from ISO
      4. Patch     - auto-edit db_setup.ps1 to use env vars
      5. Validate  - confirm every required slot is populated; report missing

.PARAMETER ArchivePassword
    Password for any password-protected .7z file in PutPatch\. Requires
    7-Zip to be installed at "C:\Program Files\7-Zip\7z.exe".

.PARAMETER Force
    Overwrite items already present in assets\. By default, populated slots
    are skipped.

.PARAMETER WhatIf
    Show what the script would do without making changes.

.EXAMPLE
    .\populator.ps1

.EXAMPLE
    .\populator.ps1 -ArchivePassword 'my-7z-password'

.EXAMPLE
    .\populator.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ArchivePassword,
    [switch]$Force
)

# ----------------------------------------------------------------------------
# Bootstrap
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = $PSScriptRoot
if (-not $projectRoot) {
    $projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$putPatchDir = Join-Path $projectRoot 'PutPatch'
$isoDir      = Join-Path $projectRoot 'ISO'
$assetsDir   = Join-Path $projectRoot 'assets'
$epmRoot     = Join-Path $assetsDir 'EPM_Setup_files_V1'
$appCfgDir   = Join-Path $epmRoot 'EPM_App_Setup_Configuration'
$gpoDir      = Join-Path $epmRoot 'GPO'
$sxsDir      = Join-Path $assetsDir 'sxs'
$tempExtract = Join-Path $env:TEMP "populator-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Only pre-create the outer-most folders.
# Do NOT pre-create $epmRoot, $appCfgDir, $gpoDir: if the destination exists
# as an empty folder, Move-Item nests the source UNDER it instead of REPLACING
# it. Phase 3's Move-IntoSlot creates parent folders on demand as needed.
foreach ($p in @($putPatchDir, $isoDir, $assetsDir, $sxsDir)) {
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [ValidateSet('PHASE','INFO','OK','WARN','MISSING','ERROR')] [string]$Level,
        [Parameter(Mandatory)] [string]$Message
    )
    $color = switch ($Level) {
        'PHASE'   { 'Cyan' }
        'INFO'    { 'White' }
        'OK'      { 'Green' }
        'WARN'    { 'Yellow' }
        'MISSING' { 'Red' }
        'ERROR'   { 'Red' }
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ("[{0}][{1,-7}] {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

function Get-7ZipPath {
    foreach ($c in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-FolderFileCount {
    param([string]$Path)
    try { @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue).Count }
    catch { 0 }
}

# ----------------------------------------------------------------------------
# Phase 1 - Discovery
# ----------------------------------------------------------------------------
function Build-Inventory {
    Write-Log PHASE 'Phase 1: Discovery'

    # Step 1a: extract .zip files in PutPatch (recursive look)
    $zips = Get-ChildItem -Path $putPatchDir -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue
    foreach ($z in $zips) {
        $dst = Join-Path $tempExtract $z.BaseName
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        try {
            Expand-Archive -LiteralPath $z.FullName -DestinationPath $dst -Force -ErrorAction Stop
            Write-Log OK ("Extracted zip: {0}" -f $z.Name)
        } catch {
            Write-Log WARN ("Failed to extract {0}: {1}" -f $z.Name, $_.Exception.Message)
        }
    }

    # Step 1b: extract .7z files (requires 7-Zip)
    $sevens = Get-ChildItem -Path $putPatchDir -Recurse -File -Filter '*.7z' -ErrorAction SilentlyContinue
    if ($sevens) {
        $7z = Get-7ZipPath
        if (-not $7z) {
            Write-Log WARN '7-Zip not installed - .7z files in PutPatch will be skipped. Install 7-Zip from https://www.7-zip.org/ or extract manually first.'
        } else {
            foreach ($s in $sevens) {
                $dst = Join-Path $tempExtract $s.BaseName
                if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
                $args = @('x', "-o$dst", '-y', $s.FullName)
                if ($ArchivePassword) { $args = @('x', "-o$dst", "-p$ArchivePassword", '-y', $s.FullName) }
                $output = & $7z @args 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log OK ("Extracted 7z: {0}" -f $s.Name)
                } elseif ($output -join "`n" -match 'Wrong password') {
                    Write-Log ERROR ("Wrong -ArchivePassword for {0}" -f $s.Name)
                } else {
                    Write-Log WARN ("7-Zip exit {0} for {1}" -f $LASTEXITCODE, $s.Name)
                }
            }
        }
    }

    # Step 1c: walk PutPatch + tempExtract
    $roots = @($putPatchDir)
    if (Test-Path $tempExtract) { $roots += $tempExtract }

    $folders = New-Object System.Collections.Generic.List[object]
    $files   = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) { [void]$folders.Add($_) }
            else                  { [void]$files.Add($_)   }
        }
    }
    Write-Log OK ("Discovered {0} folders, {1} files in PutPatch + temp" -f $folders.Count, $files.Count)

    # Step 1d: find ISO
    $isoCandidates = @(Get-ChildItem -Path $isoDir -File -Filter '*.iso' -ErrorAction SilentlyContinue)
    $iso = $null
    if ($isoCandidates.Count -eq 0) {
        Write-Log WARN 'No .iso file in ISO\ - the sxs slot will be marked missing.'
    } elseif ($isoCandidates.Count -gt 1) {
        Write-Log WARN ("Multiple ISO files found; using {0}" -f $isoCandidates[0].Name)
        $iso = $isoCandidates[0]
    } else {
        Write-Log OK ("Found ISO: {0}" -f $isoCandidates[0].Name)
        $iso = $isoCandidates[0]
    }

    [pscustomobject]@{ Folders = $folders; Files = $files; Iso = $iso }
}

# ----------------------------------------------------------------------------
# Phase 2 - Match each slot
# ----------------------------------------------------------------------------
function Find-Folder {
    param([object]$Inventory, [string]$Name, [scriptblock]$Filter)
    $cands = $Inventory.Folders | Where-Object { $_.Name -ieq $Name }
    if ($Filter) { $cands = $cands | Where-Object $Filter }
    if (-not $cands) { return $null }
    # Best = most files inside, tie-break by shortest path
    $cands | Sort-Object `
        @{ Expression = { Get-FolderFileCount $_.FullName }; Descending = $true },
        @{ Expression = { $_.FullName.Length };               Descending = $false } |
        Select-Object -First 1
}

function Find-File {
    param([object]$Inventory, [string]$Pattern)
    $cands = $Inventory.Files | Where-Object { $_.Name -imatch $Pattern }
    if (-not $cands) { return $null }
    $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Find-GpoBackup {
    param([object]$Inventory, [string]$NameRegex)
    $cands = $Inventory.Folders | Where-Object {
        $_.Name -imatch $NameRegex -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.xml'))
    }
    if (-not $cands) { return $null }
    $cands | Sort-Object @{ Expression = { $_.FullName.Length }; Descending = $false } | Select-Object -First 1
}

function Get-SlotMatches {
    param([object]$Inventory)
    Write-Log PHASE 'Phase 2: Matching slots'

    $r = [ordered]@{
        # Parent-level chunks (preferred - move whole subtree)
        ToolsSetup        = Find-Folder $Inventory -Name 'EPM_Tools_Setup'
        AppCfg            = Find-Folder $Inventory -Name 'EPM_App_Setup_Configuration'
        GpoRoot           = Find-Folder $Inventory -Name 'GPO'
        EpmGpoRoot        = Find-Folder $Inventory -Name 'EPM_GPO'

        # Atomic fallbacks for EPM_App_Setup_Configuration\
        EPMDashboard      = Find-Folder $Inventory -Name 'EPMDashboard'
        EPMMessageService = Find-Folder $Inventory -Name 'EPMMessageService'
        IrajeSecureAccess = Find-Folder $Inventory -Name 'IrajeSecureAccess'
        Software          = Find-Folder $Inventory -Name 'software'
        Web               = Find-Folder $Inventory -Name 'web' -Filter { Test-Path -LiteralPath (Join-Path $_.FullName 'Shadow.exe') }
        EpmDb             = Find-Folder $Inventory -Name 'epm-db'
        FlywayZip         = Find-File   $Inventory -Pattern '^flyway-commandline-.*\.zip$'
        MysqlConnector    = Find-File   $Inventory -Pattern '^mysql-connector.*\.jar$'
        DbSetupPs1        = Find-File   $Inventory -Pattern '^db_setup\.ps1$'

        # GPO subfolder atomic fallbacks
        GpoDdp            = Find-GpoBackup $Inventory -NameRegex 'DDP'
        GpoNologoff       = Find-GpoBackup $Inventory -NameRegex 'nologoff'
        GpoWinupdate      = Find-GpoBackup $Inventory -NameRegex 'winupdate'
        GpoIraje          = Find-GpoBackup $Inventory -NameRegex '^EPM_Iraje|Iraje_v'
    }

    foreach ($key in $r.Keys) {
        if ($r[$key]) {
            Write-Log OK ("Matched {0,-22} -> {1}" -f $key, $r[$key].FullName)
        }
    }
    return $r
}

# ----------------------------------------------------------------------------
# Phase 3 - Place
# ----------------------------------------------------------------------------
function Move-IntoSlot {
    <#
        Moves $Source to $Destination. Returns $true if moved, $false if skipped.
        Honors -Force from the outer scope and ShouldProcess from the cmdlet binding.
    #>
    param(
        [Parameter(Mandatory)] [System.IO.FileSystemInfo]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    # If a parent move already swept this source up, skip silently.
    # (Common case: GpoRoot was discovered inside EPM_Tools_Setup; after
    # EPM_Tools_Setup is moved, the GPO source path no longer exists in PutPatch.)
    if (-not (Test-Path -LiteralPath $Source.FullName)) {
        Write-Log INFO ("Skip {0}: source already moved by a parent" -f $Destination)
        return $false
    }
    if (Test-Path -LiteralPath $Destination) {
        $existing  = Get-Item -LiteralPath $Destination
        $isFolder  = $existing.PSIsContainer
        $isNonEmpty = if ($isFolder) {
            @(Get-ChildItem -LiteralPath $Destination -ErrorAction SilentlyContinue).Count -gt 0
        } else { $true }
        if ($isNonEmpty -and -not $Force) {
            Write-Log INFO ("Skip {0} (populated; use -Force to overwrite)" -f $Destination)
            return $false
        }
        # ALWAYS remove the existing destination (whether empty folder or -Force).
        # Move-Item nests the source UNDER an existing folder rather than replacing,
        # so we must clear the destination first.
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if ($PSCmdlet.ShouldProcess($Destination, "Move from $($Source.FullName)")) {
        try {
            Move-Item -LiteralPath $Source.FullName -Destination $Destination -Force -ErrorAction Stop
            Write-Log OK ("Moved -> {0}" -f $Destination)
            return $true
        } catch {
            Write-Log ERROR ("Move failed: {0}" -f $_.Exception.Message)
            return $false
        }
    }
    return $false
}

function Place-Items {
    param([object]$Inventory, [hashtable]$M)
    Write-Log PHASE 'Phase 3: Placing items into assets\'

    # --- 3a: EPM_Tools_Setup (parent) ---
    if ($M.ToolsSetup) {
        Move-IntoSlot -Source $M.ToolsSetup -Destination (Join-Path $epmRoot 'EPM_Tools_Setup') | Out-Null
    }

    # --- 3b: EPM_App_Setup_Configuration (parent) ---
    if ($M.AppCfg) {
        Move-IntoSlot -Source $M.AppCfg -Destination $appCfgDir | Out-Null
    } else {
        # Atomic fallback - find each subfolder/file individually
        if ($M.EPMDashboard)      { Move-IntoSlot -Source $M.EPMDashboard      -Destination (Join-Path $appCfgDir 'EPMDashboard')      | Out-Null }
        if ($M.EPMMessageService) { Move-IntoSlot -Source $M.EPMMessageService -Destination (Join-Path $appCfgDir 'EPMMessageService') | Out-Null }
        if ($M.IrajeSecureAccess) { Move-IntoSlot -Source $M.IrajeSecureAccess -Destination (Join-Path $appCfgDir 'IrajeSecureAccess') | Out-Null }
        if ($M.Software)          { Move-IntoSlot -Source $M.Software          -Destination (Join-Path $appCfgDir 'software')          | Out-Null }
        if ($M.Web)               { Move-IntoSlot -Source $M.Web               -Destination (Join-Path $appCfgDir 'web')               | Out-Null }
        if ($M.EpmDb)             { Move-IntoSlot -Source $M.EpmDb             -Destination (Join-Path $appCfgDir 'epm-db')            | Out-Null }
        if ($M.FlywayZip)         { Move-IntoSlot -Source $M.FlywayZip         -Destination (Join-Path $appCfgDir $M.FlywayZip.Name)   | Out-Null }
        if ($M.MysqlConnector)    { Move-IntoSlot -Source $M.MysqlConnector    -Destination (Join-Path $appCfgDir $M.MysqlConnector.Name) | Out-Null }
        if ($M.DbSetupPs1)        { Move-IntoSlot -Source $M.DbSetupPs1        -Destination (Join-Path $appCfgDir 'db_setup.ps1')      | Out-Null }
    }

    # --- 3c: GPO root ---
    $gpoSrc = if ($M.GpoRoot) { $M.GpoRoot } elseif ($M.EpmGpoRoot) { $M.EpmGpoRoot } else { $null }
    if ($gpoSrc) {
        Move-IntoSlot -Source $gpoSrc -Destination $gpoDir | Out-Null
    } else {
        # Atomic GPO fallback
        $gpoMap = @(
            @{ Match = $M.GpoDdp;       NewName = 'EPM_DDP_v1.0' }
            @{ Match = $M.GpoNologoff;  NewName = 'EPM_nologoff_v1.0' }
            @{ Match = $M.GpoWinupdate; NewName = 'EPM_winupdate_v1.0' }
            @{ Match = $M.GpoIraje;     NewName = 'EPM_Iraje_v1.0' }
        )
        foreach ($g in $gpoMap) {
            if ($g.Match) {
                Move-IntoSlot -Source $g.Match -Destination (Join-Path $gpoDir $g.NewName) | Out-Null
            }
        }
    }

    # --- 3d: Normalization shuffle ---
    # Iraje sometimes ships the GPO folder INSIDE EPM_Tools_Setup. If we find
    # an EPM_GPO at any depth under EPM_Tools_Setup, promote it to the canonical
    # location at assets\EPM_Setup_files_V1\GPO\.
    $toolsRoot = Join-Path $epmRoot 'EPM_Tools_Setup'
    if (Test-Path -LiteralPath $toolsRoot) {
        $strayGpo = Get-ChildItem -LiteralPath $toolsRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq 'EPM_GPO' -or $_.Name -ieq 'GPO' } |
                    Select-Object -First 1
        if ($strayGpo) {
            $haveGpo = (Test-Path -LiteralPath $gpoDir) -and (@(Get-ChildItem -LiteralPath $gpoDir -ErrorAction SilentlyContinue).Count -gt 0)
            if (-not $haveGpo -or $Force) {
                if ($haveGpo -and $Force) { Remove-Item -LiteralPath $gpoDir -Recurse -Force }
                # Make sure $gpoDir's parent exists
                $gpoParent = Split-Path -Parent $gpoDir
                if (-not (Test-Path $gpoParent)) { New-Item -ItemType Directory -Path $gpoParent -Force | Out-Null }
                Move-Item -LiteralPath $strayGpo.FullName -Destination $gpoDir -Force
                Write-Log OK ("Promoted GPO out of EPM_Tools_Setup -> {0}" -f $gpoDir)
            }
        }
    }

    # Normalize GPO subfolder names (DDP / nologoff / winupdate / Iraje) to canonical
    if (Test-Path -LiteralPath $gpoDir) {
        $renameMap = @{
            'DDP'       = 'EPM_DDP_v1.0'
            'nologoff'  = 'EPM_nologoff_v1.0'
            'winupdate' = 'EPM_winupdate_v1.0'
            'Iraje'     = 'EPM_Iraje_v1.0'
        }
        Get-ChildItem -LiteralPath $gpoDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($key in $renameMap.Keys) {
                $canonical = $renameMap[$key]
                if ($_.Name -imatch $key -and $_.Name -ne $canonical) {
                    $target = Join-Path $gpoDir $canonical
                    if (-not (Test-Path -LiteralPath $target)) {
                        try {
                            Rename-Item -LiteralPath $_.FullName -NewName $canonical
                            Write-Log OK ("Renamed GPO subfolder {0} -> {1}" -f $_.Name, $canonical)
                        } catch {
                            Write-Log WARN ("Could not rename {0}: {1}" -f $_.Name, $_.Exception.Message)
                        }
                        break
                    }
                }
            }
        }
    }

    # --- 3e: ISO -> sxs ---
    if ($Inventory.Iso) {
        $hasSxs = @(Get-ChildItem -LiteralPath $sxsDir -Filter '*.cab' -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasSxs -and -not $Force) {
            Write-Log INFO 'Skip sxs\ (populated; use -Force to overwrite)'
        } else {
            Write-Log PHASE 'Phase 3b: Mounting ISO + copying sxs'
            $isoPath = $Inventory.Iso.FullName
            $mount = $null
            try {
                $mount = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
                Start-Sleep -Seconds 2
                $vol = $mount | Get-Volume
                $drive = $vol.DriveLetter
                if (-not $drive) { throw 'Could not determine drive letter for mounted ISO' }
                $sxsSrc = "${drive}:\sources\sxs"
                if (-not (Test-Path -LiteralPath $sxsSrc)) {
                    Write-Log WARN ("ISO has no \sources\sxs\ folder - not a Windows install ISO? Path tested: $sxsSrc")
                } else {
                    if ($hasSxs -and $Force) {
                        Get-ChildItem -LiteralPath $sxsDir -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
                    }
                    Copy-Item -Path (Join-Path $sxsSrc '*') -Destination $sxsDir -Recurse -Force
                    $copied = @(Get-ChildItem -LiteralPath $sxsDir -File -ErrorAction SilentlyContinue).Count
                    Write-Log OK ("Copied {0} files from ISO sxs" -f $copied)
                }
            } catch {
                Write-Log ERROR ("ISO operation failed: {0}" -f $_.Exception.Message)
            } finally {
                if ($mount) {
                    try { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null } catch {}
                    Write-Log OK 'Dismounted ISO'
                }
            }
        }
    }

    # --- 3f: Move PutPatch leftovers to PutPatch\_unmapped\ ---
    $unmapped = Join-Path $putPatchDir '_unmapped'
    $leftovers = Get-ChildItem -LiteralPath $putPatchDir -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne '_unmapped' -and $_.Name -ne 'README.txt' }
    if ($leftovers) {
        if (-not (Test-Path -LiteralPath $unmapped)) { New-Item -ItemType Directory -Path $unmapped -Force | Out-Null }
        foreach ($item in $leftovers) {
            $target = Join-Path $unmapped $item.Name
            if (Test-Path -LiteralPath $target) {
                $target = Join-Path $unmapped ("{0}__{1}" -f $item.Name, (Get-Date -Format 'yyyyMMddHHmmss'))
            }
            try {
                Move-Item -LiteralPath $item.FullName -Destination $target -Force
            } catch {
                Write-Log WARN ("Could not move leftover {0} to _unmapped: {1}" -f $item.Name, $_.Exception.Message)
            }
        }
        Write-Log INFO ("Moved {0} leftover item(s) to PutPatch\_unmapped\" -f @($leftovers).Count)
    }

    # Cleanup temp extract dir
    if (Test-Path -LiteralPath $tempExtract) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------
# Phase 4 - Auto-edit db_setup.ps1
# ----------------------------------------------------------------------------
function Patch-DbSetupScript {
    Write-Log PHASE 'Phase 4: Patching db_setup.ps1'
    $f = Join-Path $appCfgDir 'db_setup.ps1'
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Log WARN 'db_setup.ps1 not present yet; skipping patch'
        return
    }
    $content  = Get-Content -LiteralPath $f -Raw
    $original = $content
    # Replace hard-coded $appPoolName / $dbPassword string literals with env-var references
    $content = $content -replace '(\$appPoolName\s*=\s*)("[^"]*"|''[^'']*'')', '$1$env:IRAJE_APPPOOL'
    $content = $content -replace '(\$dbPassword\s*=\s*)("[^"]*"|''[^'']*'')',   '$1$env:IRAJE_DBPASSWORD'
    if ($content -ne $original) {
        Set-Content -LiteralPath $f -Value $content -Encoding UTF8
        Write-Log OK 'Patched db_setup.ps1 to read $env:IRAJE_APPPOOL and $env:IRAJE_DBPASSWORD'
    } else {
        Write-Log INFO 'db_setup.ps1 already uses env vars (or pattern not found)'
    }
}

# ----------------------------------------------------------------------------
# Phase 5 - Validation
# ----------------------------------------------------------------------------
function Test-Slot {
    param([string]$Kind, [string]$Path)
    switch ($Kind) {
        'FolderExists'   { return (Test-Path -LiteralPath $Path -PathType Container) }
        'FolderNonEmpty' {
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
            return (@(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
        }
        'FileExists'     { return (Test-Path -LiteralPath $Path -PathType Leaf) }
        'FilePattern'    { return (@(Get-ChildItem -Path $Path -ErrorAction SilentlyContinue).Count -gt 0) }
    }
    return $false
}

function Run-Validation {
    Write-Log PHASE 'Phase 5: Validation'
    $required = @(
        @{ Name='assets\EPM_Setup_files_V1\EPM_Tools_Setup\';                            Kind='FolderNonEmpty'; Path=(Join-Path $epmRoot 'EPM_Tools_Setup'); Hint='Iraje payload missing EPM_Tools_Setup folder' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\EPMDashboard\';                  Kind='FolderNonEmpty'; Path=(Join-Path $appCfgDir 'EPMDashboard'); Hint='EPMDashboard folder not found in patch' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\EPMMessageService\';             Kind='FolderNonEmpty'; Path=(Join-Path $appCfgDir 'EPMMessageService'); Hint='EPMMessageService folder not found in patch' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\IrajeSecureAccess\';             Kind='FolderNonEmpty'; Path=(Join-Path $appCfgDir 'IrajeSecureAccess'); Hint='IrajeSecureAccess folder not found in patch' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\software\';                      Kind='FolderExists';   Path=(Join-Path $appCfgDir 'software'); Hint='software folder not found in patch' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\web\Shadow.exe';                 Kind='FileExists';     Path=(Join-Path $appCfgDir 'web\Shadow.exe'); Hint='web\ folder with Shadow.exe not found' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\epm-db\';                        Kind='FolderNonEmpty'; Path=(Join-Path $appCfgDir 'epm-db'); Hint='epm-db migration folder not found' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\flyway-commandline-*.zip';       Kind='FilePattern';    Path=(Join-Path $appCfgDir 'flyway-commandline-*.zip'); Hint='Flyway CLI zip not found' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\mysql-connector*.jar';           Kind='FilePattern';    Path=(Join-Path $appCfgDir 'mysql-connector*.jar'); Hint='MySQL connector JAR not found' }
        @{ Name='assets\...\EPM_App_Setup_Configuration\db_setup.ps1';                   Kind='FileExists';     Path=(Join-Path $appCfgDir 'db_setup.ps1'); Hint='db_setup.ps1 not found' }
        @{ Name='assets\...\GPO\EPM_DDP_v1.0\manifest.xml';                              Kind='FileExists';     Path=(Join-Path $gpoDir 'EPM_DDP_v1.0\manifest.xml'); Hint='Default Domain Policy GPO backup missing' }
        @{ Name='assets\...\GPO\EPM_nologoff_v1.0\manifest.xml';                         Kind='FileExists';     Path=(Join-Path $gpoDir 'EPM_nologoff_v1.0\manifest.xml'); Hint='Nologoff OU GPO backup missing' }
        @{ Name='assets\...\GPO\EPM_winupdate_v1.0\manifest.xml';                        Kind='FileExists';     Path=(Join-Path $gpoDir 'EPM_winupdate_v1.0\manifest.xml'); Hint='Winupdate OU GPO backup missing' }
        @{ Name='assets\sxs\*NetFx3*.cab';                                               Kind='FilePattern';    Path=(Join-Path $sxsDir '*NetFx3*.cab'); Hint='Provide the Windows Server installation ISO in ISO\\ - the script copies \\sources\\sxs\\ from it' }
    )
    $optional = @(
        @{ Name='assets\...\GPO\EPM_Iraje_v1.0\manifest.xml (optional)';                 Kind='FileExists';     Path=(Join-Path $gpoDir 'EPM_Iraje_v1.0\manifest.xml'); Hint='Iraje OU GPO backup (optional)' }
    )

    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($r in $required) {
        if (Test-Slot -Kind $r.Kind -Path $r.Path) {
            Write-Log OK ("present  {0}" -f $r.Name)
        } else {
            Write-Log MISSING ("MISSING  {0}" -f $r.Name)
            [void]$missing.Add($r)
        }
    }
    foreach ($o in $optional) {
        if (Test-Slot -Kind $o.Kind -Path $o.Path) {
            Write-Log OK ("present  {0}" -f $o.Name)
        } else {
            Write-Log WARN ("absent   {0}" -f $o.Name)
        }
    }
    return $missing
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
try {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host '              Iraje EPM Asset Populator' -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ('=' * 78) -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ''

    if ($Force)         { Write-Log WARN '-Force is set; existing assets\ slots will be overwritten' }
    if ($WhatIfPreference){ Write-Log WARN '-WhatIf is set; no changes will be made' }

    $inv      = Build-Inventory
    $matches  = Get-SlotMatches -Inventory $inv
    Place-Items -Inventory $inv -M $matches
    Patch-DbSetupScript
    # Force array context so $missing.Count is the item count, not the
    # key count of a single-hashtable auto-unroll.
    $missing  = @(Run-Validation)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor White
    if ($missing.Count -eq 0) {
        Write-Host '          PATCH POPULATED SUCCESSFULLY' -ForegroundColor Green
        Write-Host '          All required pieces are in place.' -ForegroundColor Green
        Write-Host '          You may now run: cd Scripts; .\Install-IrajeEPM.ps1 ...' -ForegroundColor Green
    } else {
        Write-Host ("          INCOMPLETE  -  {0} required piece(s) missing" -f $missing.Count) -ForegroundColor Red
        Write-Host ''
        foreach ($m in $missing) {
            Write-Host ("            [MISSING] {0}" -f $m.Name) -ForegroundColor Red
            if ($m.Hint) {
                Write-Host ("                      Hint: {0}" -f $m.Hint) -ForegroundColor DarkYellow
            }
        }
        Write-Host ''
        Write-Host '          What to do next:' -ForegroundColor Yellow
        Write-Host '          1. Find a more complete patch (or your Windows ISO).' -ForegroundColor Yellow
        Write-Host '          2. Drop it into PutPatch\ (or ISO\).' -ForegroundColor Yellow
        Write-Host '          3. Re-run .\populator.ps1' -ForegroundColor Yellow
        Write-Host '          Already-populated pieces in assets\ are preserved.' -ForegroundColor Yellow
    }
    Write-Host ('=' * 78) -ForegroundColor White
    Write-Host ''

    exit ($(if ($missing.Count -gt 0) { 1 } else { 0 }))
}
catch {
    Write-Log ERROR ("Populator failed: {0}" -f $_.Exception.Message)
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 2
}
