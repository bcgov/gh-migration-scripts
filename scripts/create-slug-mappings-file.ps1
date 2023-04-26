[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Org,
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if($_ -notmatch "(\.csv$)"){
            throw "The file specified in the OutputFile argument must have the extension 'csv'"
        }
        return $true 
    })]
    [System.IO.FileInfo]    
    $OutputFile,
    [Parameter(Mandatory = $false)]
    [string]
    $Token,
    [Parameter(Mandatory = $false)]
    [switch]
    $Confirm
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\common-teams.ps1

$token= GetToken -token $Token -envToken $env:GH_PAT

Write-Host "Fetching teams from organization '$Org'..." -ForegroundColor Blue
$teams = GetTeams -org $Org -token $token

if($teams.Length -eq 0){
    Write-Host "No teams found in organization '$Org'." -ForegroundColor Yellow
    exit 0
}

$slugMappings = @($teams | ForEach-Object {
    $team = $_

    Write-Host "Fetching members of team '$($team.name)'..." -ForegroundColor Blue
    $teamMembers = GetTeamMembers -org $Org -team $team.slug -token $token

    $teamMembers | ForEach-Object {
        $teamMember = $_

        return [ordered]@{
            slug_source_org = $teamMember.login
            slug_target_org = "<CHANGE TO EMU USER SLUG>"
        }
    }
} | Select-Object -Unique) | ForEach-Object {
    $teamMemberEmail = GetTeamMemberDetails -teamMember $_.slug_source_org -token $token

    if($teamMemberEmail.email -ne $null){
        $new_slug = "$($teamMemberEmail.Split("@")[0].Replace(".", "-"))_emu"

        $_.slug_target_org = $new_slug        
    }

    return $_
}



SaveTo-Csv -Data $slugMappings -OutputFile $OutputFile -Confirm $Confirm

Write-Host "Done." -ForegroundColor Green