<#
.SYNOPSIS
    Pre-change Active Directory safety backup.

.DESCRIPTION
    Belt-and-suspenders AD backup to run before a risky change.
    Independent of Veeam. Produces:
      1. ntdsutil IFM (full AD database + SYSVOL) - portable, restorable to a fresh DC
      2. All GPOs backed up via Backup-Gpo (restore with Restore-Gpo)
      3. Full export of all Users, Groups, Computers, OUs to CLIXML (for diffing/reference)
      4. FSMO role holder snapshot
      5. AD Recycle Bin status check (warns if disabled)

.NOTES
    Run as Domain Admin on a DC (or box with RSAT AD tools + GPMC).
    ntdsutil IFM step must run ON a DC.
#>

[CmdletBinding()]
param(
    [string]$BackupRoot = "C:\ADBackup",
    [string]$DomainController = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot $timestamp
$logFile   = Join-Path $backupDir 'backup.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (Test-Path $backupDir) { Add-Content -Path $logFile -Value $line }
}

# ---------- Setup ----------
New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
Write-Log "Backup root: $backupDir"
Write-Log "Running as: $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"

# ---------- Module check ----------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy     -ErrorAction Stop
    Write-Log "Modules loaded: ActiveDirectory, GroupPolicy"
} catch {
    Write-Log "Failed to load required modules. Install RSAT-AD-Tools + GPMC. $_" 'ERROR'
    throw
}

$domain = (Get-ADDomain).DNSRoot
Write-Log "Domain: $domain"

# ---------- 1. FSMO role snapshot ----------
Write-Log "Step 1/5: Capturing FSMO role holders"
try {
    $fsmo = netdom query fsmo 2>&1
    $fsmo | Out-File (Join-Path $backupDir 'fsmo-roles.txt')
    Write-Log "FSMO roles saved to fsmo-roles.txt"
} catch {
    Write-Log "FSMO query failed: $_" 'WARN'
}

# ---------- 2. AD Recycle Bin status ----------
Write-Log "Step 2/5: Checking AD Recycle Bin status"
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
} catch {
    Write-Log "Recycle Bin check failed: $_" 'WARN'
}

# ---------- 3. GPO backup ----------
Write-Log "Step 3/5: Backing up all GPOs"
$gpoDir = Join-Path $backupDir 'GPOs'
New-Item -Path $gpoDir -ItemType Directory -Force | Out-Null
try {
    $gpoResult = Backup-Gpo -All -Path $gpoDir -Comment "Pre-change backup $timestamp"
    Write-Log "Backed up $($gpoResult.Count) GPOs to $gpoDir"
    # Dump a human-readable index
    $gpoResult | Select-Object DisplayName, Id, BackupDirectory |
        Export-Csv (Join-Path $backupDir 'gpo-index.csv') -NoTypeInformation
} catch {
    Write-Log "GPO backup failed: $_" 'ERROR'
}

# ---------- 4. AD object export ----------
Write-Log "Step 4/5: Exporting AD objects (Users, Groups, Computers, OUs)"
$objDir = Join-Path $backupDir 'ADObjects'
New-Item -Path $objDir -ItemType Directory -Force | Out-Null

try {
    Write-Log "  Exporting users..."
    Get-ADUser -Filter * -Properties * |
        Export-Clixml (Join-Path $objDir 'users.xml')

    Write-Log "  Exporting groups (with members)..."
    $groups = Get-ADGroup -Filter * -Properties *
    $groups | Export-Clixml (Join-Path $objDir 'groups.xml')

    # Separate membership dump so restoring group memberships is trivial
    $membership = foreach ($g in $groups) {
        try {
            $members = Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction Stop |
                       Select-Object -ExpandProperty DistinguishedName
        } catch { $members = @() }
        [pscustomobject]@{
            Group   = $g.DistinguishedName
            Members = $members
        }
    }
    $membership | Export-Clixml (Join-Path $objDir 'group-membership.xml')

    Write-Log "  Exporting computers..."
    Get-ADComputer -Filter * -Properties * |
        Export-Clixml (Join-Path $objDir 'computers.xml')

    Write-Log "  Exporting OUs..."
    Get-ADOrganizationalUnit -Filter * -Properties * |
        Export-Clixml (Join-Path $objDir 'ous.xml')

    Write-Log "AD object export complete"
} catch {
    Write-Log "AD object export partial failure: $_" 'WARN'
}

# ---------- 5. ntdsutil IFM (full AD database snapshot) ----------
Write-Log "Step 5/5: Running ntdsutil IFM (full NTDS.dit + SYSVOL snapshot)"

# Must run ON a DC
$isDC = (Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4
if (-not $isDC) {
    Write-Log "This host is NOT a domain controller. Skipping ntdsutil IFM." 'WARN'
    Write-Log "  Run this script on a DC, or run ntdsutil manually on a DC:" 'WARN'
    Write-Log "    ntdsutil `"ac in ntds`" `"ifm`" `"create full $backupDir\IFM`" q q" 'WARN'
} else {
    $ifmDir = Join-Path $backupDir 'IFM'
    try {
        # ntdsutil requires the target dir to NOT pre-exist
        $ntdsCmd = "ac in ntds`nifm`ncreate full `"$ifmDir`"`nq`nq`n"
        $ntdsCmd | ntdsutil.exe 2>&1 | Tee-Object -FilePath (Join-Path $backupDir 'ntdsutil.log')
        if (Test-Path (Join-Path $ifmDir 'Active Directory\ntds.dit')) {
            Write-Log "IFM created successfully at $ifmDir"
        } else {
            Write-Log "IFM directory created but ntds.dit not found - check ntdsutil.log" 'ERROR'
        }
    } catch {
        Write-Log "ntdsutil IFM failed: $_" 'ERROR'
    }
}

# ---------- Summary ----------
Write-Log "============================================================"
Write-Log "Backup complete: $backupDir"
Write-Log "Contents:"
Get-ChildItem $backupDir -Recurse -Depth 1 | ForEach-Object {
    Write-Log "  $($_.FullName.Replace($backupDir, '.'))"
}
Write-Log "============================================================"
Write-Log "RECOMMENDED: copy $backupDir off this DC to a separate host/share"
Write-Log "  e.g. Copy-Item '$backupDir' '\\fileserver\backups\AD' -Recurse"
