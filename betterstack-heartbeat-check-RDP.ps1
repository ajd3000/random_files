# Better Stack API configuration
# This file will be stored on the server that needs to be monitored
# after the script is put on the server, create a scheduled task.
# credentials are stored in the Windows Credential Manager. See store-creds.ps1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$betterStackApiKey = "<API-TOKEN>" # Create this token is in Settings
$monitorId = "<Monitor-ID>" # This is the ID thats found at the end of the heartbeat when created
$betterStackUrl = "https://uptime.betterstack.com/api/v1/heartbeat"

# RDP Test configuration
$computerName = "computername.domain.local" # make sure this line gets update

function Test-RDPAndReport {
    try {
        # Get credentials from Windows Credential Manager
        $credential = Get-StoredCredential
        Write-Output "Retrieved stored credentials for user: $($credential.Username)"

        # Test RDP connection
        $tcpTest = Test-NetConnection -ComputerName $computerName -Port 3389
        if (-not $tcpTest.TcpTestSucceeded) {
            throw "RDP port 3389 is not accessible"
        }

        # Test authentication using stored credentials
        $session = New-PSSession -ComputerName $computerName -Credential $credential -ErrorAction Stop
        
        if ($session) {
            Remove-PSSession $session
            $status = "up"
            $message = "RDP is functioning correctly"
        }
    }
    catch {
        $status = "down"
        $message = "RDP check failed: $_"
    }

    # Report to Better Stack
    $body = @{
        status = $status
        message = $message
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri "$betterStackUrl/$monitorId" -Method Post -Headers @{
            "Authorization" = "Bearer $betterStackApiKey"
            "Content-Type" = "application/json"
        } -Body $body
    }
    catch {
        Write-Error "Failed to report to Better Stack: $_"
    }
}

# Run the test
Test-RDPAndReport
