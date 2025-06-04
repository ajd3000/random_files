# Get all local users and their group memberships
$users = Get-LocalUser | Where-Object { $_.Enabled -eq $true }

$results = @()

foreach ($user in $users) {
    # Get all local groups
    $allGroups = Get-LocalGroup
    
    # Initialize array to store groups the user belongs to
    $userGroups = @()
    
    # Check each group for user membership
    foreach ($group in $allGroups) {
        $members = Get-LocalGroupMember -Group $group.Name
        if ($members.Name -like "*$($user.Name)*") {
            $userGroups += $group.Name
        }
    }
    
    # Join groups with semicolon
    $groupString = $userGroups -join ";"
    
    # Check if password is expired
    $passwordStatus = if ($user.PasswordExpires -eq $null) { "Never Expires" }
                     elseif ($user.PasswordExpires -lt (Get-Date)) { "Expired" }
                     else { "Not Expired" }
    
    # Create object with user information
    $userInfo = [PSCustomObject]@{
        Username = $user.Name
        Groups = $groupString
        PasswordStatus = $passwordStatus
    }
    
    $results += $userInfo
}

# Export to CSV
$results | Export-Csv -Path "user_groups_report.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Report has been generated as 'user_groups_report.csv'"
