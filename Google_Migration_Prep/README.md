# Creating a new folder in OneDrive for all users.

## Prereqs:
Azure Creds

Microsoft Online Services Sign-In Assistant for IT Professionals RTW - https://www.microsoft.com/en-us/download/details.aspx?id=41950

Powershell Module for SharePoint (command below) 
```
PS> Install-Module SharePointPnPPowerShellOnline
PS> Install-Module Microsoft.Online.SharePoint.PowerShell
PS> Install-Module AzureAD
PS> Install-Module MSOnline
```

Get user list and save as .csv (example output is provided in file "UsersToPreProv1.csv")
```
PS> Connect-MSOLService
PS> Get-MSOLUser | Where-Object { $_.isLicensed -eq "True"} | Select-Object DisplayName, UserPrincipalName, isLicensed | Export-Csv C:\temp\UsersToPreProv1.csv
```

## Run the script:
```
PS> .\Create_Migration_Folder.ps1
```


### Note on Site Collection Administrator:
When this script is ran it will remove the designated Site Administrator, if you use your own account then your account will be removed from your site. Either use a disposable Site Administrator account or remove your account from the script csv and just do your account manually.

Path to modify Site Administrator:
Sharepoint Admin --> More Features --> User Profiles --> Manage User Profiles --> Find Profile --> Click on Profile --> Manage Site Collection Owner.
