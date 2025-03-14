[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    $SourceOrg,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    $TargetOrg,
    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (-Not ($_ | Test-Path) ) {
                throw "File or folder does not exist"
            }

            if (-Not ($_ | Test-Path -PathType Leaf) ) {
                throw "The ReposFile argument must be a file. Folder paths are not allowed."
            }

            if ($_ -notmatch "(\.csv$)") {
                throw "The file specified in the ReposFile argument must be of type csv"
            }

            return $true 
        })]
    [System.IO.FileInfo]
    $ReposFile,
    [Parameter(Mandatory = $false)]
    [System.IO.FileInfo]
    $SlugMappingFile,
    [Parameter(Mandatory = $false)]
    [string]
    $SourceToken,
    [Parameter(Mandatory = $false)]
    [string]
    $TargetToken,
    [Parameter(Mandatory = $false)]
    [switch]
    $SkipEmptySlugMappings,
    [Parameter(Mandatory = $false)]
    [switch]
    $AddTeamMembers
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\common-repos.ps1
. $PSScriptRoot\common-teams.ps1

function GetSlugMappings ($path) {
    if ($null -eq $path) {
        return @()
    }
    
    if (-Not ($path | Test-Path) ) {
        throw "File or folder does not exist"
    }

    if (-Not ($path | Test-Path -PathType Leaf) ) {
        throw "The SlugMappingFile argument must be a file. Folder paths are not allowed."
    }

    if ($path -notmatch "(\.csv$)") {
        throw "The file specified in the SlugMappingFile argument must be of type csv"
    }

    return @(Import-Csv -Path $path)
}

function FindRootTeams($teams) {
    $rootTeams = @()

    $teams | ForEach-Object {
        $team = $_

        if ($null -eq $team.parent) {
            $rootTeams += $team
        }
        else {
            do {
                $parent = $teams | Where-Object -Property slug -EQ -Value $team.parent.slug
                $team = $parent
            } while (
                $null -ne $team.parent
            )

            $rootTeams += $team
        }
    }

    return $rootTeams | Select-Object -Unique
}

$sourcePat = GetToken -token $SourceToken -envToken $env:GH_SOURCE_PAT
$targetPat = GetToken -token $TargetToken -envToken $env:GH_PAT

$slugMappings = GetSlugMappings -path $SlugMappingFile

Write-Host "Fetching teams from organization '$SourceOrg'..." -ForegroundColor Blue
$sourceTeams = GetTeams -org $SourceOrg -token $sourcePat

if ($sourceTeams.Length -eq 0) {
    Write-Host "No teams found in organization '$SourceOrg'." -ForegroundColor Yellow
    exit 0
}

Write-Host "Creating teams in the organization '$TargetOrg'..." -ForegroundColor Blue

$newTeams = @()

$sourceTeams | ForEach-Object {
    $sourceTeam = $_

    $targetTeam = $sourceTeam | Select-Object -Property @{name = "name"; expr = { $_.slug } }, description, privacy, permission

    $newTeam = CreateOrFetchTeam -org $TargetOrg -team $targetTeam -token $targetPat | Select-Object -Property id, name, slug

    $newTeams += $newTeam
}

Write-Host "Creating teams hierarchy in the organization '$TargetOrg'..." -ForegroundColor Blue

$sourceTeams | ForEach-Object {
    $sourceTeam = $_    

    if (-Not ($sourceTeam.parent -eq $null)) {
        $targetTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceTeam.slug
        $targetParentTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceTeam.parent.slug

        AddTeamToParent -org $TargetOrg -team $targetTeam.slug -parent $targetParentTeam.id -token $targetPat
    }
}

$sourceRepos = Import-Csv -Path $ReposFile

$defaultPermissions = @("pull", "triage", "push", "maintain", "admin")

$sourceRepos | ForEach-Object {
    $sourceRepo = $_
    $sourceRepoTeams = GetRepoTeams -org $SourceOrg -repo $sourceRepo.name -token $sourcePat

    Write-Host "Adding teams to repo '$($sourceRepo.name)' in the organization '$TargetOrg'..." -ForegroundColor Blue

    if (ExistsRepo -org $TargetOrg -repo $sourceRepo.name -token $targetPat) {
        $sourceRepoTeams | ForEach-Object {
            $sourceRepoTeam = $_
    
            $targetRepoTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceRepoTeam.slug
    
            if ($null -ne $targetRepoTeam) {
                $permissions = $defaultPermissions | ForEach-Object { if ($sourceRepoTeam.permissions.$_) { return $_ } }
                $permissions | ForEach-Object { UpdateTeamRepoPermission -org $TargetOrg -team $targetRepoTeam.slug -repo "$TargetOrg/$($sourceRepo.name)" -permission $_ -token $targetPat }            
            }
            else {
                Write-Host "The team '$($sourceRepoTeam.slug)' cannot be added to repo '$($sourceRepo.name)' in org '$TargetOrg'. This team does not exist." -ForegroundColor Yellow
            }
        }  
    }
    else {
        Write-Host "Teams cannot be added to repo '$($sourceRepo.name)' in org '$TargetOrg'. This repo does not exist." -ForegroundColor Yellow
    }
}

if ($AddTeamMembers) {
    $allSourceRepoTeams = @()

    $sourceRepos | ForEach-Object {
        $sourceRepo = $_
        $sourceRepoTeams = GetRepoTeams -org $SourceOrg -repo $sourceRepo.name -token $sourcePat

        $allSourceRepoTeams += $sourceRepoTeams | Select-Object -Property slug, name      
    }

    $allSourceRepoTeams = $allSourceRepoTeams | Select-Object -Property slug, name -Unique 

    $allSourceRepoTeams | ForEach-Object {
        $sourceRepoTeam = $_
        # $sourceRepoTeamGroups = GetTeamGroups -org $SourceOrg -team $sourceTeam.slug -token $sourcePat
        $sourceRepoTeamMembers = GetTeamMembers -org $SourceOrg -team $sourceRepoTeam.slug -token $sourcePat

        $targetTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceRepoTeam.slug

        # if ($sourceRepoTeamGroups.Length -gt 0) {
        #     $targetTeamGroups = UpdateTeamGroups -org $TargetOrg -team $targetTeam.slug -groups $sourceRepoTeamGroups -token $targetPat
    
        #     if ($targetTeamGroups.Length -eq 0) {
        #         Write-Host "The groups cannot be added to team $($targetTeam.slug) in org '$TargetOrg'. This team is not externally managed." -ForegroundColor Yellow
        #     }
        # }

        $sourceRepoTeamMembers | ForEach-Object {
            $sourceTeamMember = $_
            $sourceTeamMemberRole = GetTeamMemberRole -org $SourceOrg -team $sourceRepoTeam.slug -teamMember $sourceTeamMember.login -token $sourcePat
        
            $targetTeamMemberSlug = $slugMappings | Where-Object -Property slug_source_org -EQ -Value $sourceTeamMember.login | Select-Object -First 1 -ExpandProperty slug_target_org

            if (-Not($SkipEmptySlugMappings) -or -Not([string]::IsNullOrWhiteSpace($targetTeamMemberSlug))) {

                if ([string]::IsNullOrWhiteSpace($targetTeamMemberSlug)) {
                    $targetTeamMemberSlug = $sourceTeamMember.login
                }

                UpdateTeamMemberRole -org $TargetOrg -team $targetTeam.slug -teamMember $targetTeamMemberSlug -role $sourceTeamMemberRole -token $targetPat
            }
            else {
                Write-Host "The team member '$($sourceTeamMember.login)' cannot be added to team '$($targetTeam.name)' in org '$TargetOrg'. The slug mapping is empty." -ForegroundColor Yellow
            }
        }
    }
}

# Write-Host "Adding team repositories in the organization '$TargetOrg'..." -ForegroundColor Blue

# $defaultPermissions = @("pull", "triage", "push", "maintain", "admin")

# $sourceTeams | ForEach-Object {
#     $sourceTeam = $_    
#     $sourceTeamRepos = GetTeamRepos -org $SourceOrg -team $sourceTeam.slug -token $sourcePat

#     $targetTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceTeam.slug

#     $sourceTeamRepos | ForEach-Object {
#         $sourceTeamRepo = $_
        
#         if (ExistsRepo -org $TargetOrg -repo $sourceTeamRepo.name -token $targetPat) {
#             $permissions = $defaultPermissions | ForEach-Object { if ($sourceTeamRepo.permissions.$_) { return $_ } }
#             $permissions | ForEach-Object { UpdateTeamRepoPermission -org $TargetOrg -team $targetTeam.slug -repo "$TargetOrg/$($sourceTeamRepo.name)" -permission $_ -token $targetPat }
#         }
#         else {
#             Write-Host "The team '$($targetTeam.name)' cannot be added to repo '$($sourceTeamRepo.name)' in org '$TargetOrg'. This repo does not exist." -ForegroundColor Yellow
#         }
#     }
# }

# if ($AddTeamMembers) {
#     Write-Host "Adding team members in the organization '$TargetOrg'..." -ForegroundColor Blue

#     $sourceTeams | ForEach-Object {
#         $sourceTeam = $_    
#         $sourceTeamMembers = GetTeamMembers -org $SourceOrg -team $sourceTeam.slug -token $sourcePat

#         $targetTeam = $newTeams | Where-Object -Property slug -EQ -Value $sourceTeam.slug

#         $sourceTeamMembers | ForEach-Object {
#             $sourceTeamMember = $_
#             $sourceTeamMemberRole = GetTeamMemberRole -org $SourceOrg -team $sourceTeam.slug -teamMember $sourceTeamMember.login -token $sourcePat
        
#             $targetTeamMemberSlug = $slugMappings | Where-Object -Property slug_source_org -EQ -Value $sourceTeamMember.login | Select-Object -First 1 -ExpandProperty slug_target_org

#             if (-Not($SkipEmptySlugMappings) -or -Not([string]::IsNullOrWhiteSpace($targetTeamMemberSlug))) {

#                 if ([string]::IsNullOrWhiteSpace($targetTeamMemberSlug)) {
#                     $targetTeamMemberSlug = $sourceTeamMember.login
#                 }

#                 UpdateTeamMemberRole -org $TargetOrg -team $targetTeam.slug -teamMember $targetTeamMemberSlug -role $sourceTeamMemberRole -token $targetPat
#             }
#             else {
#                 Write-Host "The team member '$($sourceTeamMember.login)' cannot be added to team '$($targetTeam.name)' in org '$TargetOrg'. The slug mapping is empty." -ForegroundColor Yellow
#             }
#         }
#     }
# }

Write-Host "Done." -ForegroundColor Green