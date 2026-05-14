<#
.SYNOPSIS
    Pre-change Active Directory safety backup.

.DESCRIPTION
    Belt-and-suspenders AD backup to run before a risky change.
    Independent of Veeam. Produces:
      1. ntdsutil IFM (full AD database + SYSVOL) - portable, restorable to a fresh DC
      2. All GPOs backed up via Backup-Gpo (restore with Restore-Gpo)
      3. Full or scoped export of Users, Groups, Computers, OUs to CLIXML (for diffing/reference)
      4. FSMO role holder snapshot
      5. AD Recycle Bin status check (warns if disabled)
      6. Integrity manifest (SHA-256) over exported artifacts
#>

[CmdletBinding()]
param(
    [string]$BackupRoot = "C:\ADBackup",
    [switch]$FailOnCriticalStep,
    [switch]$SkipIFM,
    [ValidateSet('Full','Scoped')]
    [string]$ExportMode = 'Full',
    [string[]]$SearchBase,
    [string[]]$UserProperties = @('SamAccountName','Enabled','GivenName','Surname','DisplayName','Mail','UserPrincipalName','DistinguishedName','MemberOf','WhenChanged','WhenCreated'),
    [string[]]$GroupProperties = @('SamAccountName','GroupScope','GroupCategory','Description','DistinguishedName','ManagedBy','WhenChanged','WhenCreated'),
    [string[]]$ComputerProperties = @('SamAccountName','DNSHostName','Enabled','OperatingSystem','OperatingSystemVersion','DistinguishedName','WhenChanged','WhenCreated'),
    [string[]]$OUProperties = @('Name','DistinguishedName','LinkedGroupPolicyObjects','ProtectedFromAccidentalDeletion','WhenChanged','WhenCreated')
)

$ErrorActionPreference = 'Stop'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot $timestamp
$logFile   = Join-Path $backupDir 'backup.log'
$runState = [ordered]@{
    Fsmo          = $false
    RecycleBin    = $false
    GpoBackup     = $false
    ObjectExport  = $false
    IfmBackup     = $false
    Manifest      = $false
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (Test-Path $backupDir) { Add-Content -Path $logFile -Value $line }
}

function Invoke-Critical {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        $runState[$Name] = $true
    } catch {
        Write-Log "Critical step '$Name' failed: $($_.Exception.Message)" 'ERROR'
        $runState[$Name] = $false
        if ($FailOnCriticalStep) {
            throw
        }
    }
}

function Get-DirectoryItems {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @()
    }
    return Get-ChildItem -Path $Path -Force
}

# ---------- Setup ----------
New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
Write-Log "Backup root: $backupDir"
Write-Log "Running as: $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
Write-Log "Export mode: $ExportMode"
if ($ExportMode -eq 'Scoped') {
    if (-not $SearchBase -or $SearchBase.Count -eq 0) {
        throw "ExportMode 'Scoped' requires at least one -SearchBase DN."
    }
    Write-Log "Scoped SearchBase values: $($SearchBase -join '; ')"
}

# ---------- Module check ----------
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop
Write-Log "Modules loaded: ActiveDirectory, GroupPolicy"

$domain = (Get-ADDomain).DNSRoot
Write-Log "Domain: $domain"

# ---------- 1. FSMO role snapshot ----------
Write-Log "Step 1/6: Capturing FSMO role holders"
try {
    $fsmo = netdom query fsmo 2>&1
    $fsmo | Out-File (Join-Path $backupDir 'fsmo-roles.txt')
    Write-Log "FSMO roles saved to fsmo-roles.txt"
    $runState['Fsmo'] = $true
} catch {
    Write-Log "FSMO query failed: $_" 'WARN'
}

# ---------- 2. AD Recycle Bin status ----------
Write-Log "Step 2/6: Checking AD Recycle Bin status"
try {
    $rb = Get-ADOptionalFeature -Filter 'name -like "Recycle Bin Feature"'
    if ($rb.EnabledScopes.Count -gt 0) {
        Write-Log "AD Recycle Bin is ENABLED (scopes: $($rb.EnabledScopes -join ', '))"
        "ENABLED" | Out-File (Join-Path $backupDir 'recyclebin-status.txt')
    } else {
        Write-Log "AD Recycle Bin is DISABLED. Consider enabling BEFORE your change window." 'WARN'
        Write-Log "  Enable with: Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target '$((Get-ADForest).RootDomain)'" 'WARN'
        "DISABLED" | Out-File (Join-Path $backupDir 'recyclebin-status.txt')
    }
    $runState['RecycleBin'] = $true
} catch {
    Write-Log "Recycle Bin check failed: $_" 'WARN'
}

# ---------- 3. GPO backup ----------
Write-Log "Step 3/6: Backing up all GPOs"
$gpoDir = Join-Path $backupDir 'GPOs'
New-Item -Path $gpoDir -ItemType Directory -Force | Out-Null
Invoke-Critical -Name 'GpoBackup' -Action {
    $gpoResult = Backup-Gpo -All -Path $gpoDir -Comment "Pre-change backup $timestamp"
    if (-not $gpoResult -or (Get-DirectoryItems -Path $gpoDir).Count -eq 0) {
        throw "No GPO artifacts were created in $gpoDir"
    }
    Write-Log "Backed up $($gpoResult.Count) GPOs to $gpoDir"
    $gpoResult | Select-Object DisplayName, Id, BackupDirectory |
        Export-Csv (Join-Path $backupDir 'gpo-index.csv') -NoTypeInformation
}

# ---------- 4. AD object export ----------
Write-Log "Step 4/6: Exporting AD objects (Users, Groups, Computers, OUs)"
$objDir = Join-Path $backupDir 'ADObjects'
New-Item -Path $objDir -ItemType Directory -Force | Out-Null

Invoke-Critical -Name 'ObjectExport' -Action {
    if ($ExportMode -eq 'Full') {
        Write-Log "  Exporting users (full directory scope)..."
        Get-ADUser -Filter * -Properties $UserProperties |
            Export-Clixml (Join-Path $objDir 'users.xml')

        Write-Log "  Exporting groups (full directory scope)..."
        $groups = Get-ADGroup -Filter * -Properties $GroupProperties
    } else {
        Write-Log "  Exporting users (scoped)..."
        $allUsers = foreach ($base in $SearchBase) {
            Get-ADUser -SearchBase $base -SearchScope Subtree -Filter * -Properties $UserProperties
        }
        $allUsers | Sort-Object DistinguishedName -Unique |
            Export-Clixml (Join-Path $objDir 'users.xml')

        Write-Log "  Exporting groups (scoped)..."
        $groups = foreach ($base in $SearchBase) {
            Get-ADGroup -SearchBase $base -SearchScope Subtree -Filter * -Properties $GroupProperties
        }
        $groups = $groups | Sort-Object DistinguishedName -Unique
    }

    $groups | Export-Clixml (Join-Path $objDir 'groups.xml')

    $membership = foreach ($g in $groups) {
        try {
            $members = Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction Stop |
                Select-Object -ExpandProperty DistinguishedName
        } catch {
            $members = @()
        }
        [pscustomobject]@{
            Group   = $g.DistinguishedName
            Members = $members
        }
    }
    $membership | Export-Clixml (Join-Path $objDir 'group-membership.xml')

    if ($ExportMode -eq 'Full') {
        Write-Log "  Exporting computers (full directory scope)..."
        Get-ADComputer -Filter * -Properties $ComputerProperties |
            Export-Clixml (Join-Path $objDir 'computers.xml')

        Write-Log "  Exporting OUs (full directory scope)..."
        Get-ADOrganizationalUnit -Filter * -Properties $OUProperties |
            Export-Clixml (Join-Path $objDir 'ous.xml')
    } else {
        Write-Log "  Exporting computers (scoped)..."
        $allComputers = foreach ($base in $SearchBase) {
            Get-ADComputer -SearchBase $base -SearchScope Subtree -Filter * -Properties $ComputerProperties
        }
        $allComputers | Sort-Object DistinguishedName -Unique |
            Export-Clixml (Join-Path $objDir 'computers.xml')

        Write-Log "  Exporting OUs (scoped)..."
        $allOus = foreach ($base in $SearchBase) {
            Get-ADOrganizationalUnit -SearchBase $base -SearchScope Subtree -Filter * -Properties $OUProperties
        }
        $allOus | Sort-Object DistinguishedName -Unique |
            Export-Clixml (Join-Path $objDir 'ous.xml')
    }

    $requiredFiles = @('users.xml','groups.xml','group-membership.xml','computers.xml','ous.xml')
    foreach ($required in $requiredFiles) {
        $target = Join-Path $objDir $required
        if (-not (Test-Path $target)) {
            throw "Expected export file missing: $required"
        }
    }
    Write-Log "AD object export complete"
}

# ---------- 5. ntdsutil IFM (full AD database snapshot) ----------
Write-Log "Step 5/6: Running ntdsutil IFM (full NTDS.dit + SYSVOL snapshot)"
if ($SkipIFM) {
    Write-Log "SkipIFM specified. Skipping IFM creation by operator request." 'WARN'
} else {
    $isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
    if (-not $isDC) {
        Write-Log "This host is NOT a domain controller. Skipping ntdsutil IFM." 'WARN'
        Write-Log "  Run this script on a DC, or run ntdsutil manually on a DC:" 'WARN'
        Write-Log "    ntdsutil `"ac in ntds`" `"ifm`" `"create full $backupDir\IFM`" q q" 'WARN'
    } else {
        $ifmDir = Join-Path $backupDir 'IFM'
        Invoke-Critical -Name 'IfmBackup' -Action {
            $ntdsCmd = "ac in ntds`nifm`ncreate full `"$ifmDir`"`nq`nq`n"
            $ntdsCmd | ntdsutil.exe 2>&1 | Tee-Object -FilePath (Join-Path $backupDir 'ntdsutil.log')
            if (-not (Test-Path (Join-Path $ifmDir 'Active Directory\ntds.dit'))) {
                throw "IFM directory created but ntds.dit not found - check ntdsutil.log"
            }
            Write-Log "IFM created successfully at $ifmDir"
        }
    }
}

# ---------- 6. Integrity manifest ----------
Write-Log "Step 6/6: Building SHA-256 manifest"
Invoke-Critical -Name 'Manifest' -Action {
    $manifestPath = Join-Path $backupDir 'manifest-sha256.txt'
    $allFiles = Get-ChildItem -Path $backupDir -Recurse -File | Where-Object { $_.Name -ne 'manifest-sha256.txt' }
    if (-not $allFiles) {
        throw "No files found to hash."
    }

    $hashOutput = foreach ($file in $allFiles) {
        $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256
        "{0}  .\{1}" -f $hash.Hash, $file.FullName.Substring($backupDir.Length + 1)
    }

    $hashOutput | Out-File -FilePath $manifestPath -Encoding ascii
    Write-Log "Manifest written: $manifestPath"
}

# ---------- Summary ----------
Write-Log "============================================================"
Write-Log "Backup complete: $backupDir"
Write-Log "Step status:"
$runState.GetEnumerator() | ForEach-Object {
    $stateText = if ($_.Value) { 'SUCCESS' } else { 'NOT-COMPLETED/FAILED' }
    Write-Log "  $($_.Key): $stateText"
}

if ($FailOnCriticalStep) {
    $criticalSteps = @('GpoBackup','ObjectExport','Manifest')
    if (-not $SkipIFM) {
        $criticalSteps += 'IfmBackup'
    }

    $failedCritical = $criticalSteps | Where-Object { -not $runState[$_] }
    if ($failedCritical.Count -gt 0) {
        Write-Log "Critical failure(s): $($failedCritical -join ', ')" 'ERROR'
        throw "Backup run failed due to critical step failures."
    }
}

Write-Log "Contents:"
Get-ChildItem $backupDir -Recurse -Depth 1 | ForEach-Object {
    Write-Log "  $($_.FullName.Replace($backupDir, '.'))"
}
Write-Log "============================================================"
Write-Log "RECOMMENDED: copy $backupDir off this DC to a separate host/share"
Write-Log "  e.g. Copy-Item '$backupDir' '\\fileserver\backups\AD' -Recurse"
Write-Log "RECOMMENDED: place backup in encrypted storage with strict ACLs and audit logging"
