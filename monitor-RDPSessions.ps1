# Enable modern TLS support for HTTPS communications
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Configuration
$config = @{
    BetterStackHeartbeatURL = "<BS heartbeat URL>"
    BlackScreenThreshold = 0.10  # 10% of sessions showing black screen triggers alert
    WarningBannerTimeout = 1  # Minutes to wait before considering user stuck at warning banner
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
                $sessionName = $sessionInfo[0].TrimStart('>')
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

function Test-WarningBannerHang {
    try {
        # Get RDP authentication events from the last 10 minutes
        $startTime = (Get-Date).AddMinutes(-10)
        $rdpLogons = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            ID = 4624
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Properties[8].Value -eq 3  # LogonType 3 = RDP
        }

        # Get Terminal Services session logon events for IP addresses
        $tsLogons = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
            ID = 21
            StartTime = $startTime
        } -ErrorAction SilentlyContinue

        $stuckUsers = @()
        
        foreach ($logon in $rdpLogons) {
            $username = $logon.Properties[5].Value
            $domain = $logon.Properties[6].Value
            $logonTime = $logon.TimeCreated
            $fullUsername = "$domain\$username"
            
            # Get IP address from Terminal Services log
            $sourceIP = "Unknown"
            $matchingTSLogon = $tsLogons | Where-Object {
                $_.TimeCreated -ge $logonTime.AddMinutes(-1) -and 
                $_.TimeCreated -le $logonTime.AddMinutes(1) -and
                $_.Message -match [regex]::Escape($username)
            } | Select-Object -First 1
            
            if ($matchingTSLogon) {
                # Extract IP from Terminal Services message
                if ($matchingTSLogon.Message -match 'Source Network Address: (\d+\.\d+\.\d+\.\d+)') {
                    $sourceIP = $matches[1]
                }
            }
            
            # Comprehensive filtering for system/process accounts
            $isSystemAccount = $false
            
            # Filter out computer accounts (ending with $)
            if ($username.EndsWith('$')) {
                $isSystemAccount = $true
            }
            
            # Filter out all uppercase usernames (system accounts)
            if ($username -match '^[A-Z_$]+$') {
                $isSystemAccount = $true
            }
            
            # Filter out specific system accounts
            if ($username -in @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON', 'IUSR', 'IWAM')) {
                $isSystemAccount = $true
            }
            
            # Filter out system domains
            if ($domain -in @('NT AUTHORITY', 'Window Manager', 'BUILTIN')) {
                $isSystemAccount = $true
            }
            
            # Filter out service account patterns (SVC_, SRV_, etc.)
            if ($username -match '^(SVC|SRV|SERVICE)_') {
                $isSystemAccount = $true
            }
            
            # Filter out accounts with only numbers and underscores
            if ($username -match '^[0-9_]+$') {
                $isSystemAccount = $true
            }
            
            # Skip system accounts
            if ($isSystemAccount) {
                continue
            }
            
            # Check if this user has an active desktop session
            $activeSession = query session 2>&1 | Select-Object -Skip 1 | Where-Object {
                $_ -match "Active" -and $_ -match [regex]::Escape($username)
            }
            
            # If no active session found and logon was more than 1 minute ago, check if user ever successfully logged in
            if (-not $activeSession -and $logonTime -lt (Get-Date).AddMinutes(-$config.WarningBannerTimeout)) {
                
                # Check if user ever successfully established a session (Terminal Services Event ID 21)
                $successfulSession = Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
                    ID = 21
                    StartTime = $logonTime
                } -ErrorAction SilentlyContinue | Where-Object {
                    $_.Message -match [regex]::Escape($username) -and
                    $_.TimeCreated -ge $logonTime
                } | Select-Object -First 1
                
                # Only flag as stuck if they never successfully established a session
                if (-not $successfulSession) {
                    $stuckUsers += @{
                        Username = $fullUsername
                        LogonTime = $logonTime
                        MinutesStuck = [math]::Round(((Get-Date) - $logonTime).TotalMinutes, 1)
                        SourceIP = $sourceIP
                    }
                }
            }
        }
        
        return @{
            HasWarningBannerHang = $stuckUsers.Count -gt 0
            StuckUsers = $stuckUsers
            TotalStuckUsers = $stuckUsers.Count
        }
    }
    catch {
        Write-Warning "Error checking warning banner hangs: $_"
        return @{
            HasWarningBannerHang = $false
            StuckUsers = @()
            TotalStuckUsers = 0
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
$warningBannerStatus = Test-WarningBannerHang
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$details = "Time: $timestamp`n"
$details += "Total Sessions: $($status.TotalSessions)`n"
$details += "Black Screens: $($status.BlackScreenCount)`n"
$details += "Warning Banner Hangs: $($warningBannerStatus.TotalStuckUsers)`n"

if ($warningBannerStatus.StuckUsers.Count -gt 0) {
    $details += "`nUsers Stuck at Warning Banner:`n"
    foreach ($user in $warningBannerStatus.StuckUsers) {
        $details += "- User: $($user.Username)`n"
        $details += "  Logon Time: $($user.LogonTime)`n"
        $details += "  Minutes Stuck: $($user.MinutesStuck)`n"
        $details += "  Source IP: $($user.SourceIP)`n"
    }
}

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
    $details += "`nHealthy Sessions:`n"
    foreach ($session in $status.Details | Where-Object { -not $_.IsBlackScreen }) {
        # Get IP address for this user - find the most recent event FOR THIS SPECIFIC USER
        $userIP = "Unknown"
        $matchingTSLogon = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
            ID = 21
            StartTime = (Get-Date).AddMinutes(-30)
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match [regex]::Escape($session.Username)
        } | Sort-Object TimeCreated -Descending | Select-Object -First 1

        if ($matchingTSLogon -and $matchingTSLogon.Message -match 'Source Network Address: (\d+\.\d+\.\d+\.\d+)') {
            $userIP = $matches[1]
        }
        
        $details += "- User: $($session.Username), Session: $($session.SessionId), IP: $userIP`n"
    }
}

# Check for warning banner hangs first (complete failure)
if ($warningBannerStatus.HasWarningBannerHang) {
    Write-Warning $details
    Send-BetterStackHeartbeat -IsHealthy $false -Details $details -Status "error"
}
# Then check for black screen conditions
elseif ($status.BlackScreenCount -eq 0) {
    Write-Host "[$timestamp] RDP sessions are healthy"
    Send-BetterStackHeartbeat -IsHealthy $true -Details "All sessions healthy" -Status "success"
}
elseif (($status.BlackScreenCount / [math]::Max($status.TotalSessions, 1)) -ge $config.BlackScreenThreshold) {
    Write-Warning $details
    Send-BetterStackHeartbeat -IsHealthy $false -Details $details -Status "error"
}
else {
    Write-Warning $details
    Send-BetterStackHeartbeat -IsHealthy $false -Details $details -Status "warning"
}

# Log to Windows Event Log
if (-not [System.Diagnostics.EventLog]::SourceExists("RDPBlackScreenMonitor")) {
    New-EventLog -LogName Application -Source "RDPBlackScreenMonitor"
}

# Use different EventIds based on status
if ($warningBannerStatus.HasWarningBannerHang) {
    # Warning banner hang = complete failure (Event ID 1003)
    Write-EventLog -LogName Application `
        -Source "RDPBlackScreenMonitor" `
        -EventId 1003 `
        -EntryType Error `
        -Message $details
}
elseif ($status.BlackScreenCount -eq 0) {
    Write-EventLog -LogName Application `
        -Source "RDPBlackScreenMonitor" `
        -EventId 1000 `
        -EntryType Information `
        -Message $details
}
elseif (($status.BlackScreenCount / [math]::Max($status.TotalSessions, 1)) -ge $config.BlackScreenThreshold) {
    Write-EventLog -LogName Application `
        -Source "RDPBlackScreenMonitor" `
        -EventId 1002 `
        -EntryType Error `
        -Message $details
}
else {
    Write-EventLog -LogName Application `
        -Source "RDPBlackScreenMonitor" `
        -EventId 1001 `
        -EntryType Warning `
        -Message $details
}
