# Backup-ADPreChange

A belt-and-suspenders **Active Directory safety backup** script designed to run immediately before a risky change (schema update, bulk object edit, GPO overhaul, DC promotion/demotion, etc.). It is independent of your primary backup product (Veeam, Commvault, etc.) and produces portable, standalone artifacts you can restore from without any third-party tooling.

## Why

Hypervisor snapshots and even application-aware VM backups can fail silently, get blocked by EDR (looking at you, SentinelOne boot protection), or simply not be granular enough when all you need to do is roll back one OU or one GPO. This script gives you a self-contained directory of everything you'd want to diff against or restore from after a bad change, in formats every AD admin already knows how to use.

## What it produces

Under `<BackupRoot>\<timestamp>\`:

| Artifact | Description | Restore tool |
|---|---|---|
| `IFM\` | Full `ntds.dit` + SYSVOL via `ntdsutil ifm create full` | Promote a fresh DC from media, or mount offline with `dsamain` |
| `GPOs\` | Every GPO backed up via `Backup-Gpo -All` | `Restore-Gpo` |
| `ADObjects\users.xml` | All users with all properties | `Import-Clixml` + `Set-ADUser` |
| `ADObjects\groups.xml` | All groups with all properties | `Import-Clixml` + `Set-ADGroup` |
| `ADObjects\group-membership.xml` | Flat group→members map for every group | `Add-ADGroupMember` in a loop |
| `ADObjects\computers.xml` | All computer objects | `Import-Clixml` |
| `ADObjects\ous.xml` | All OUs with all properties | `Import-Clixml` |
| `fsmo-roles.txt` | Output of `netdom query fsmo` | Reference |
| `recyclebin-status.txt` | `ENABLED` or `DISABLED` | Reference |
| `backup.log` | Timestamped run log | Reference |
| `ntdsutil.log` | Raw ntdsutil output | Reference |

## Requirements

- **Domain-joined Windows host** with:
  - PowerShell 5.1+ (or PowerShell 7)
  - `ActiveDirectory` module (RSAT-AD-Tools)
  - `GroupPolicy` module (GPMC)
- **Domain Admin** (or equivalent) credentials
- The **IFM step must run on an actual domain controller** — `ntdsutil ifm` only works on a DC. If you run the script from a management box, every other step works but IFM is skipped with a warning.
- Enough free disk at `-BackupRoot` for a full copy of `ntds.dit` + SYSVOL (plan for the size of your NTDS volume on any DC).

## Usage

Clone or copy the script to the target DC:

```powershell
# Default - writes to C:\ADBackup\<timestamp>\
.\Backup-ADPreChange.ps1

# Custom location (file share, another drive, etc.)
.\Backup-ADPreChange.ps1 -BackupRoot "D:\ADBackup"
.\Backup-ADPreChange.ps1 -BackupRoot "Z:\USMR\IT\ADBackup"
```

Run as **Administrator** in a PowerShell session opened by a Domain Admin account.

### Where to run it

Best practice: run on the **PDC Emulator**. Find it with:

```powershell
(Get-ADDomain).PDCEmulator
```

### Notes on `-BackupRoot`

- `ntdsutil ifm` may refuse to write directly to certain mapped drives or UNC paths depending on session context. If the IFM step fails on a network path but everything else succeeds, re-run with a local path (`C:\ADBackup`) and copy the output folder to your final destination afterward:

  ```powershell
  Copy-Item C:\ADBackup\20260414-* \\fileserver\backups\AD\ -Recurse
  ```

## After it finishes

**Copy the backup folder off the DC.** A backup sitting on the C: drive of the machine it's backing up is not a backup.

```powershell
Copy-Item 'C:\ADBackup\20260414-160530' '\\fileserver\backups\AD\' -Recurse
```

## Restore one-liners

Keep these handy in your change runbook.

### Restore a single GPO

```powershell
Restore-Gpo -Name "Some Policy" -Path "Z:\USMR\IT\ADBackup\<timestamp>\GPOs"
```

### Restore all GPOs

```powershell
Restore-Gpo -All -Path "Z:\USMR\IT\ADBackup\<timestamp>\GPOs"
```

### Diff users before vs after the change

```powershell
$before = Import-Clixml "Z:\USMR\IT\ADBackup\<ts>\ADObjects\users.xml"
$after  = Get-ADUser -Filter * -Properties *
Compare-Object $before $after -Property SamAccountName, Enabled, MemberOf
```

### Recover a deleted object (AD Recycle Bin required)

```powershell
Get-ADObject -Filter 'IsDeleted -eq $true -and Name -like "*username*"' -IncludeDeletedObjects |
    Restore-ADObject
```

### Nuclear option — rebuild a DC from IFM

On a freshly installed Windows Server that will become the recovery DC:

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController `
    -DomainName "usmoneyreserve.local" `
    -InstallDns `
    -InstallationMediaPath "C:\IFM" `
    -Credential (Get-Credential)
```

Copy the contents of the `IFM\` folder from the backup to `C:\IFM` on the new server first.

## What this script does NOT do

- It does not replace your enterprise backup product. Run it **in addition to** Veeam/Commvault/etc., not instead of.
- It does not back up certificate services, DHCP, DNS zones stored outside AD, or any non-AD server role. Those need their own backup procedures.
- It does not back up AD-integrated DNS records separately — they live in `ntds.dit` and come along with the IFM. If you need granular DNS record restore, export zones separately with `Export-DnsServerZone`.
- It does not enable AD Recycle Bin. It checks and warns. Enable it manually (one-way operation) **before** your change:

  ```powershell
  Enable-ADOptionalFeature 'Recycle Bin Feature' `
      -Scope ForestOrConfigurationSet `
      -Target (Get-ADForest).RootDomain
  ```

## Recommended workflow for a risky change

1. Verify AD Recycle Bin is enabled.
2. Run this script; confirm all five steps succeed.
3. Copy the output folder off the DC to a separate host.
4. Take your normal Veeam (or equivalent) backup with app-aware processing.
5. Document current FSMO role holders and any objects you plan to modify.
6. Perform the change.
7. Diff against `users.xml` / `groups.xml` / `ous.xml` to confirm only intended objects changed.
8. Keep the backup for at least one tombstone lifetime (default 180 days) before deleting.

## License

MIT. Use at your own risk. Test in a lab first. The author is not responsible for domains that get bricked by untested changes, including ones this script was supposed to help roll back from.
