# Specify the path to the CSV file
$csvFilePath = "accounts.csv"

# Specify the path for the config file
$configFilePath = "config"

# Read the CSV file
$csvData = Import-Csv $csvFilePath

# Initialize an empty string to store config content
$configContent = ""

# Loop through each row in the CSV data
foreach ($row in $csvData) {
    # Get the values for each field
    $awsName = $row.AWSName
    $awsId = $row.AWSId
    
    # Append the values to the config content
    $configContent += "[profile $awsName]`n"
    $configContent += "sso_session = test-sso`n"
    $configContent += "sso_account_id = $awsId`n"
    $configContent += "sso_role_name = AWSAdministratorAccess`n"
    $configContent += "region = us-west-2`n"
    $configContent += "output = json`n"
    $configContent += "`n"  # Add a blank line between each entry
}

# Write the config content to the config file
$configContent | Out-File -FilePath $configFilePath -Encoding utf8

Write-Host "Config file created successfully at: $configFilePath"
