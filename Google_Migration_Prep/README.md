# Creating a new folder in OneDrive for all users.

## Prereqs:
Azure Creds

Microsoft Online Services Sign-In Assistant for IT Professionals RTW - https://www.microsoft.com/en-us/download/details.aspx?id=41950

Powershell Module for SharePoint (command below) 
```
PS> Install-Module SharePointPnPPowerShellOnline
```

Get user list and save as .csv (example output is provided in file "UsersToPreProv1.csv")
```
PS> Connect-MSOLService
PS> Get-MSOLUser | Where-Object { $_.isLicensed -eq "True"} | Select-Object DisplayName, UserPrincipalName, isLicensed | Export-Csv C:\temp\Users.csv
```

## Run the script:
```
PS> .\Create_Migration_Folder.ps1
```
