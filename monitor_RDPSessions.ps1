# Enable modern TLS support for HTTPS communications
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Configuration
$config = @{
    BetterStackHeartbeatURL = "https://uptime.betterstack.com/api/v1/heartbeat/UCqofmJcN6zCJ5Uty6TAn8Xz"
    BlackScreenThreshold = 0.10  # 10% of sessions showing black screen triggers alert
}

function Test-CriticalProcesses {
    param (
        [int]$SessionId,
        [string]$Username
    )
    
    $processStatus = @{
        DWM = $false
        TaskHost = $false
        CSRSS = $false
        Winlogon = $false
    }

    $criticalProcesses = Get-Process -ErrorAction SilentlyContinue | 
        Where-Object { $_.SessionId -eq $SessionId }

    $processStatus.DWM = ($criticalProcesses | Where-Object ProcessName -eq 'dwm') -ne $null
    $processStatus.TaskHost = ($criticalProcesses | Where-Object ProcessName -like 'taskhostw*') -ne $null
    $processStatus.CSRSS = ($criticalProcesses | Where-Object ProcessName -eq 'csrss') -ne $null
    $processStatus.Winlogon = ($criticalProcesses | Where-Object ProcessName -eq 'winlogon') -ne $null

    # Count missing critical processes
    $missingCount = ($processStatus.Values | Where-Object { $_ -eq $false }).Count
    
    # Generate detailed status message
    $statusDetails = "Session $SessionId ($Username) Process Status:`n"
    foreach ($process in $processStatus.Keys) {
        $status = if ($processStatus[$process]) { "Running" } else { "Missing" }
        $statusDetails += "- $process : $status`n"
    }

    return @{
        IsBlackScreen = ($missingCount -ge 2)  # Alert if 2 or more critical processes are missing
        Details = $processStatus
        StatusMessage = $statusDetails
        MissingCount = $missingCount
    }
}

function Test-RDPSessions {
    try {
        # Get all RDP sessions with more detail
        $rdpSessions = query session 2>&1
        Write-Host "`nDetailed Session Information:"
        Write-Host "-------------------------"
        $rdpSessions | ForEach-Object { Write-Host $_ }
        Write-Host "-------------------------`n"

        if ($rdpSessions -match "No User exists") {
            Write-Host "No active RDP sessions"
            return @{
                IsHealthy = $true
                BlackScreenCount = 0
                TotalSessions = 0
                Details = @()
            }
        }

        # Skip header row
        $sessions = $rdpSessions | Select-Object -Skip 1
        $sessionDetails = @()
        $blackScreenCount = 0
        $totalSessions = 0

        foreach ($session in $sessions) {
            try {
                # Parse session information more carefully
                $sessionInfo = $session.Trim() -split '\s+'
                $sessionName = $sessionInfo[0]
                $username = $sessionInfo[1]
                $sessionId = $sessionInfo[2]
                $state = $sessionInfo[3]

                # Only process Active RDP sessions
                if ($state -eq "Active" -and -not [string]::IsNullOrEmpty($username) -and $sessionName -like "rdp-tcp*") {
                    $totalSessions++
                    
                    # Check critical processes
                    $processStatus = Test-CriticalProcesses -SessionId $sessionId -Username $username
                    
                    if ($processStatus.IsBlackScreen) {
                        $blackScreenCount++
                    }

                    Write-Host $processStatus.StatusMessage

                    $sessionDetails += @{
                        Username = $username
                        SessionId = $sessionId
                        IsBlackScreen = $processStatus.IsBlackScreen
                        ProcessDetails = $processStatus.Details
                        MissingProcessCount = $processStatus.MissingCount
                    }
                }
            }
            catch {
                Write-Warning "Error processing session: $_"
                continue
            }
        }

        return @{
            IsHealthy = ($blackScreenCount / [math]::Max($totalSessions, 1)) -lt $config.BlackScreenThreshold
            BlackScreenCount = $blackScreenCount
            TotalSessions = $totalSessions
            Details = $sessionDetails
        }
    }
    catch {
        Write-Warning "Error checking RDP sessions: $_"
        return @{
            IsHealthy = $false
            BlackScreenCount = 0
            TotalSessions = 0
            Details = @()
            Error = $_.Exception.Message
        }
    }
}

function Send-BetterStackHeartbeat {
    param (
        [bool]$IsHealthy,
        [string]$Details,
        [string]$Status
    )
    
    try {
        $body = @{
            status = $Status
            message = $Details
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $config.BetterStackHeartbeatURL -Method Post -Body $body -ContentType "application/json"
        Write-Host "Heartbeat sent successfully"
    }
    catch {
        Write-Warning "Failed to send Better Stack heartbeat: $_"
    }
}

# Main execution (single run)
Write-Host "Starting RDP Monitor..."
$status = Test-RDPSessions
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$details = "Time: $timestamp`n"
$details += "Total Sessions: $($status.TotalSessions)`n"
$details += "Black Screens: $($status.BlackScreenCount)`n"

if ($status.Details.Count -gt 0) {
    $details += "`nAffected Sessions:`n"
    foreach ($session in $status.Details | Where-Object { $_.IsBlackScreen }) {
        $details += "- User: $($session.Username), Session: $($session.SessionId)`n"
        $details += "  Missing Processes: $($session.MissingProcessCount)`n"
        foreach ($process in $session.ProcessDetails.Keys) {
            if (-not $session.ProcessDetails[$process]) {
                $details += "    - $process`n"
            }
        }
    }
}

if (-not $status.IsHealthy) {
    Write-Warning $details
    # Check if we're above threshold for critical status
    if (($status.BlackScreenCount / [math]::Max($status.TotalSessions, 1)) -ge $config.BlackScreenThreshold) {
        Send-BetterStackHeartbeat -IsHealthy $false -Details $details -Status "error"
    } else {
        Send-BetterStackHeartbeat -IsHealthy $false -Details $details -Status "warning"
    }
}
else {
    Write-Host "[$timestamp] RDP sessions are healthy"
    Send-BetterStackHeartbeat -IsHealthy $true -Details "All sessions healthy" -Status "success"
}

# Log to Windows Event Log
if (-not [System.Diagnostics.EventLog]::SourceExists("RDPBlackScreenMonitor")) {
    New-EventLog -LogName Application -Source "RDPBlackScreenMonitor"
}

# Use different EventIds based on status
if (-not $status.IsHealthy) {
    # Check if we're above threshold for critical status
    if (($status.BlackScreenCount / [math]::Max($status.TotalSessions, 1)) -ge $config.BlackScreenThreshold) {
        Write-EventLog -LogName Application `
            -Source "RDPBlackScreenMonitor" `
            -EventId 1002 `
            -EntryType Error `
            -Message $details
    } else {
        Write-EventLog -LogName Application `
            -Source "RDPBlackScreenMonitor" `
            -EventId 1001 `
            -EntryType Warning `
            -Message $details
    }
} else {
    Write-EventLog -LogName Application `
        -Source "RDPBlackScreenMonitor" `
        -EventId 1000 `
        -EntryType Information `
        -Message $details
}
