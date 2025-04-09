# First time setup - run this once to store the credential
# When the script is executed you will be prompted for the password
$credentialParams = @{
    Target = "RDPMonitor"  # Unique identifier for this credential
    UserName = "domain\username" # Update this line
    Password = (Read-Host -AsSecureString "Enter Password")
}
cmdkey /add:$credentialParams.Target /user:$credentialParams.UserName /pass:$credentialParams.Password

# In your monitoring script - retrieve the stored credential
function Get-StoredCredential {
    $cred = cmdkey /list | Where-Object { $_ -like "*Target=RDPMonitor*" }
    if ($cred) {
        $username = $cred -replace ".*User=([^\s]+).*", '$1'
        $password = $cred -replace ".*Password=([^\s]+).*", '$1'
        return New-Object System.Management.Automation.PSCredential($username, $password)
    }
    throw "Stored credential not found"
}
