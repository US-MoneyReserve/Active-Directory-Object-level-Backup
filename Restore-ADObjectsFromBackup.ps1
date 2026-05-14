<#
.SYNOPSIS
    Restores selected AD object attributes and group membership from ADObjects CLIXML exports.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath,
    [switch]$RestoreUsers,
    [switch]$RestoreGroups,
    [switch]$RestoreComputers,
    [switch]$RestoreOUs,
    [switch]$RestoreGroupMembership,
    [string[]]$UserAttributeAllowList = @('DisplayName','GivenName','Surname','EmailAddress','Enabled','UserPrincipalName'),
    [string[]]$GroupAttributeAllowList = @('Description','ManagedBy'),
    [string[]]$ComputerAttributeAllowList = @('Description','DNSHostName','Enabled'),
    [string[]]$OUAttributeAllowList = @('Description','ManagedBy','ProtectedFromAccidentalDeletion')
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

function Test-BackupFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Required backup file not found: $Path"
    }
}

function Set-AllowedAttributes {
    param(
        [string]$Identity,
        [object]$Source,
        [string[]]$AllowList,
        [scriptblock]$Setter,
        [string]$ObjectType
    )

    $replace = @{}
    foreach ($attr in $AllowList) {
        if ($null -ne $Source.$attr) {
            $replace[$attr] = $Source.$attr
        }
    }

    if ($replace.Count -eq 0) {
        Write-Verbose "No allowed attributes found for $ObjectType '$Identity'"
        return
    }

    if ($PSCmdlet.ShouldProcess("$ObjectType:$Identity", "Set attributes: $($replace.Keys -join ', ')")) {
        & $Setter -Identity $Identity -Replace $replace
    }
}

if (-not ($RestoreUsers -or $RestoreGroups -or $RestoreComputers -or $RestoreOUs -or $RestoreGroupMembership)) {
    throw 'Specify at least one restore switch (e.g. -RestoreUsers).'
}

$objRoot = Join-Path $BackupPath 'ADObjects'
Test-BackupFile -Path $objRoot

if ($RestoreUsers) {
    $usersPath = Join-Path $objRoot 'users.xml'
    Test-BackupFile -Path $usersPath
    $users = Import-Clixml $usersPath
    foreach ($user in $users) {
        if (Get-ADUser -Identity $user.DistinguishedName -ErrorAction SilentlyContinue) {
            Set-AllowedAttributes -Identity $user.DistinguishedName -Source $user -AllowList $UserAttributeAllowList -Setter { param($Identity,$Replace) Set-ADUser -Identity $Identity -Replace $Replace } -ObjectType 'User'
        } else {
            Write-Warning "User missing in current AD (not recreated automatically): $($user.DistinguishedName)"
        }
    }
}

if ($RestoreGroups) {
    $groupsPath = Join-Path $objRoot 'groups.xml'
    Test-BackupFile -Path $groupsPath
    $groups = Import-Clixml $groupsPath
    foreach ($group in $groups) {
        if (Get-ADGroup -Identity $group.DistinguishedName -ErrorAction SilentlyContinue) {
            Set-AllowedAttributes -Identity $group.DistinguishedName -Source $group -AllowList $GroupAttributeAllowList -Setter { param($Identity,$Replace) Set-ADGroup -Identity $Identity -Replace $Replace } -ObjectType 'Group'
        } else {
            Write-Warning "Group missing in current AD (not recreated automatically): $($group.DistinguishedName)"
        }
    }
}

if ($RestoreComputers) {
    $computersPath = Join-Path $objRoot 'computers.xml'
    Test-BackupFile -Path $computersPath
    $computers = Import-Clixml $computersPath
    foreach ($computer in $computers) {
        if (Get-ADComputer -Identity $computer.DistinguishedName -ErrorAction SilentlyContinue) {
            Set-AllowedAttributes -Identity $computer.DistinguishedName -Source $computer -AllowList $ComputerAttributeAllowList -Setter { param($Identity,$Replace) Set-ADComputer -Identity $Identity -Replace $Replace } -ObjectType 'Computer'
        } else {
            Write-Warning "Computer missing in current AD (not recreated automatically): $($computer.DistinguishedName)"
        }
    }
}

if ($RestoreOUs) {
    $ousPath = Join-Path $objRoot 'ous.xml'
    Test-BackupFile -Path $ousPath
    $ous = Import-Clixml $ousPath
    foreach ($ou in $ous) {
        if (Get-ADOrganizationalUnit -Identity $ou.DistinguishedName -ErrorAction SilentlyContinue) {
            Set-AllowedAttributes -Identity $ou.DistinguishedName -Source $ou -AllowList $OUAttributeAllowList -Setter { param($Identity,$Replace) Set-ADOrganizationalUnit -Identity $Identity -Replace $Replace } -ObjectType 'OU'
        } else {
            Write-Warning "OU missing in current AD (not recreated automatically): $($ou.DistinguishedName)"
        }
    }
}

if ($RestoreGroupMembership) {
    $membershipPath = Join-Path $objRoot 'group-membership.xml'
    Test-BackupFile -Path $membershipPath
    $membershipRecords = Import-Clixml $membershipPath

    foreach ($record in $membershipRecords) {
        $groupDn = $record.Group
        if (-not (Get-ADGroup -Identity $groupDn -ErrorAction SilentlyContinue)) {
            Write-Warning "Cannot restore membership; group missing: $groupDn"
            continue
        }

        $targetMembers = @($record.Members)
        $currentMembers = @(Get-ADGroupMember -Identity $groupDn -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DistinguishedName)

        $toAdd = $targetMembers | Where-Object { $_ -and ($_ -notin $currentMembers) }
        foreach ($member in $toAdd) {
            if ($PSCmdlet.ShouldProcess("Group:$groupDn", "Add member $member")) {
                try {
                    Add-ADGroupMember -Identity $groupDn -Members $member -ErrorAction Stop
                } catch {
                    Write-Warning "Failed to add $member to $groupDn : $($_.Exception.Message)"
                }
            }
        }
    }
}
