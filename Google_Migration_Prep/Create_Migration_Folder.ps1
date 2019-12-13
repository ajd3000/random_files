#Connect to SPO
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Connect-PnPOnline -Url https://axialhealthcare-admin.sharepoint.com -SPOManagementShell

#Import users
$myUsers = Import-Csv -Path "C:\users\$env:USERNAME\scripts\UsersToPreProv1.csv"
#Retrieve the URLs + export them
$ODFBurls = @()
foreach ($user in $myUsers) {
    $ODFBurls += Get-PnPUserProfileProperty -Account $user.UserPrincipalName
}
$ODFBurls | Select-Object PersonalUrl | Export-Csv -Path "C:\users\$env:USERNAME\scripts\URLs.csv" -NoTypeInformation

#Connect to SharePoint Admin Center using the SPO module
Connect-SPOService -Url https://axialhealthcare-admin.sharepoint.com
#Import users
$userURLs = Import-Csv -Path "C:\users\$env:USERNAME\scripts\URLs.csv"
#Store 2nd Admin account into a variable
$adminAcctToAdd = "adickinson@axialhealthcare.com"
#Add 2nd Site Collection admin
foreach ($url in $userURLS) {
    Write-Host "Connecting to: $($url.PersonalUrl) and adding user $($adminAcctToAdd)" -ForegroundColor Green
    Set-SPOUser -Site $url.PersonalUrl -LoginName $adminAcctToAdd -IsSiteCollectionAdmin $true
}

#Import URLs
$userURLs = Import-Csv -Path "C:\users\$env:USERNAME\scripts\URLs.csv"
#Add a folder in each ODFB
foreach ($url in $userURLs) {
    Connect-PnPOnline -Url $url.PersonalUrl -SPOManagementShell
    Add-PnPFolder -Name "GoogleITMigratedData" -Folder "Documents"
}

#Import users
$userURLs = Import-Csv -Path "C:\users\$env:USERNAME\scripts\URLs.csv"
#Store 2nd Admin account into a variable
$adminAcctToRemove = "adickinson@axialhealthcare.com"
#Remove 2nd Site Collection admin
foreach ($url in $userURLs) {
    Write-Host "Connecting to: $($url.PersonalUrl) and Removing user $($adminAcctToRemove)" -ForegroundColor Green
    Set-SPOUser -Site $url.PersonalUrl -LoginName $adminAcctToRemove -IsSiteCollectionAdmin $false
}