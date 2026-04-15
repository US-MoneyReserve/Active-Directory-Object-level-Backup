# Security Audit — Backup-ADPreChange.ps1

**Audited:** 2026-04-15
**Scope:** Full code review of `Backup-ADPreChange.ps1` (170 lines) and `README.md`

---

## Verdict Summary

| Question | Answer |
|---|---|
| Does the script do what it claims? | **Yes** — all 5 advertised steps are implemented correctly |
| Does it do anything harmful or malicious? | **No** — strictly read-only against AD; writes only to local filesystem |
| Does it phone home or exfiltrate data? | **No** — zero network calls, no internet connectivity required |
| Are there security vulnerabilities? | **Yes** — see findings below (1 High, 1 Medium, 3 Low, 1 Informational) |

---

## 1. Validity — Does It Do What It Claims?

Every advertised feature is implemented and maps to legitimate Microsoft cmdlets/tools:

| Claimed Feature | Implementation | Lines | Verified |
|---|---|---|---|
| ntdsutil IFM backup (full ntds.dit + SYSVOL) | Pipes commands to `ntdsutil.exe`, validates ntds.dit exists | 135–158 | Yes |
| GPO backup via `Backup-Gpo -All` | Uses `Backup-Gpo -All -Path`, exports CSV index | 81–93 | Yes |
| Export all Users, Groups, Computers, OUs | Uses `Get-ADUser/Group/Computer/OrganizationalUnit -Filter * -Properties *` with `Export-Clixml` | 95–133 | Yes |
| FSMO role holder snapshot | Uses `netdom query fsmo` | 55–63 | Yes |
| AD Recycle Bin status check | Uses `Get-ADOptionalFeature` | 65–79 | Yes |

## 2. Harmful Behavior Check

**No harmful behavior found.** The script is strictly read-only with respect to Active Directory:

- Only **reads** AD objects (`Get-AD*` cmdlets) — never `Set-`, `New-`, `Remove-`, or `Move-`
- Only **writes to the local filesystem** (backup directory)
- Does **not** transmit data over the network — no `Invoke-WebRequest`, `Invoke-RestMethod`, `Send-MailMessage`, `Start-BitsTransfer`, or any outbound calls
- Does **not** download or execute anything from the internet
- Does **not** modify AD permissions, GPOs, DNS, group memberships, or schema
- Does **not** install software or modify the registry
- Does **not** use obfuscation, encoded commands, `Invoke-Expression`, or dynamic code generation
- `ntdsutil ifm create full` is a standard Microsoft-supported read-only snapshot operation

## 3. Security Findings

### FINDING-01: Sensitive Data Exposure in Backup Files (HIGH)

**Location:** Lines 101–103, 123–124

```powershell
Get-ADUser -Filter * -Properties * | Export-Clixml (Join-Path $objDir 'users.xml')
Get-ADComputer -Filter * -Properties * | Export-Clixml (Join-Path $objDir 'computers.xml')
```

`-Properties *` exports **every attribute** on every object, which may include:

- **LAPS passwords** (`ms-Mcs-AdmPwd`, `msLAPS-Password`)
- **gMSA credentials** (`msDS-ManagedPassword`) if the running account can read them
- **Confidential attributes** marked with `SEARCH_FLAG_CONFIDENTIAL`
- **Password metadata**, logon history, `UserAccountControl` flags

The backup files are written as **unencrypted plaintext CLIXML** on disk.

**Recommendation:** Replace `-Properties *` with an explicit property list that excludes secrets, or encrypt the output, or at minimum restrict the output directory ACLs (see FINDING-02).

---

### FINDING-02: No ACL Protection on Backup Directory (MEDIUM)

**Location:** Lines 38, 84, 98

```powershell
New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
```

The backup directories and files **inherit ACLs from the parent folder**. On a default `C:\` drive, `BUILTIN\Users` typically have read access. This means any authenticated user who can reach the backup path could read:

- `ntds.dit` — contains **all domain password hashes**
- CLIXML exports — full AD object data including sensitive attributes
- GPO backups — may contain embedded passwords (Group Policy Preferences)

**Recommendation:** Set explicit restrictive ACLs after directory creation:

```powershell
$acl = Get-Acl $backupDir
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl $backupDir $acl
```

---

### FINDING-03: Potential Command Injection via ntdsutil stdin (LOW)

**Location:** Line 148

```powershell
$ntdsCmd = "ac in ntds`nifm`ncreate full `"$ifmDir`"`nq`nq`n"
$ntdsCmd | ntdsutil.exe 2>&1
```

`$ifmDir` is interpolated into piped stdin for ntdsutil. A crafted `-BackupRoot` could inject additional ntdsutil commands. **Low risk** because running this script already requires Domain Admin and ntdsutil would likely error on malformed paths.

---

### FINDING-04: `Get-WmiObject` Deprecated (LOW)

**Location:** Line 139

```powershell
$isDC = (Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4
```

`Get-WmiObject` is deprecated in PowerShell 7+ and removed in some configurations.

**Recommendation:** Replace with `Get-CimInstance Win32_ComputerSystem`.

---

### FINDING-05: No Exit Code or Failure Summary (LOW)

**Location:** Lines 160–170

The script catches errors per step and logs warnings but never sets a non-zero exit code on partial failure. Automation wrappers cannot determine if the backup completed fully or partially. The final summary does not indicate which steps failed.

**Recommendation:** Track step pass/fail in a counter and exit with a non-zero code if any step failed.

---

### FINDING-06: `-DomainController` Parameter is Unused (INFORMATIONAL)

**Location:** Line 22

```powershell
[string]$DomainController = $env:COMPUTERNAME
```

This parameter is accepted but never passed to any cmdlet as `-Server $DomainController`. All AD queries hit the default DC. A user who specifies this parameter may believe they are targeting a specific DC when they are not.

**Recommendation:** Either pass `-Server $DomainController` to each `Get-AD*` and `Backup-Gpo` cmdlet, or remove the parameter to avoid confusion.

---

## 4. How to Verify It Works

### Option A: Lab Testing (Recommended)

Stand up a Windows Server DC in a VM, populate test objects, run the script, then verify:

```powershell
# After running the script, verify each artifact:
Test-Path "$backupDir\fsmo-roles.txt"
Test-Path "$backupDir\recyclebin-status.txt"
Test-Path "$backupDir\GPOs"
Test-Path "$backupDir\ADObjects\users.xml"
Test-Path "$backupDir\IFM\Active Directory\ntds.dit"

# Verify exports round-trip:
$backupUsers = (Import-Clixml "$backupDir\ADObjects\users.xml").Count
$liveUsers   = (Get-ADUser -Filter *).Count
if ($backupUsers -ne $liveUsers) { Write-Warning "User count mismatch!" }
```

### Option B: Code Audit (Completed)

Every step maps 1:1 to standard Microsoft cmdlets. There is no obfuscation, encoded commands, dynamic code generation, or external service calls.

### Option C: Post-Run Validation Script

Add a verification step that reads back each export and compares counts and checksums against live AD queries.

---

## Conclusion

**The script is legitimate, does exactly what it advertises, and contains no malicious behavior.** It is a well-structured, single-purpose AD backup tool using only standard Microsoft cmdlets and tools.

The primary security concerns are operational: the backup output contains highly sensitive data (password hashes in ntds.dit, potentially LAPS passwords in CLIXML exports) and the script does not restrict filesystem access to the output. These are the most important items to address before production use.
