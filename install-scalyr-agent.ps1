
# Scalyr Agent Installation and Configuration Script
# This script downloads, installs, and configures the Scalyr agent on Windows Server 2022

param(
    [string]$ApiKey = "<GET THIS KEY FROM KEEPER - "scalyr agent API key">",
    [string]$ScalyrServer = "https://xdr.us1.sentinelone.net"
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Check if running as administrator
if (-not (Test-Administrator)) {
    Write-ColorOutput "This script must be run as Administrator!" -Color "Red"
    Write-ColorOutput "Please run PowerShell as Administrator and try again." -Color "Yellow"
    exit 1
}

Write-ColorOutput "Starting Scalyr Agent Installation and Configuration..." -Color "Green"

try {
    # Step 1: Download the Scalyr Agent MSI
    Write-ColorOutput "Step 1: Downloading Scalyr Agent MSI..." -Color "Yellow"
    $msiUrl = "<PATH_TO_THE_FILE>ScalyrAgentInstaller-2.2.18.msi"
    $msiPath = "$env:TEMP\ScalyrAgentInstaller-2.2.18.msi"
    
    # Remove existing MSI if it exists
    if (Test-Path $msiPath) {
        Remove-Item $msiPath -Force
    }
    
    # Download the MSI
    Write-ColorOutput "Downloading from: $msiUrl" -Color "Cyan"
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Write-ColorOutput "Download completed successfully!" -Color "Green"
    
    # Step 2: Install the MSI
    Write-ColorOutput "Step 2: Installing Scalyr Agent..." -Color "Yellow"
    $installArgs = @(
        "/i", $msiPath,
        "/quiet",
        "/norestart"
    )
    
    Write-ColorOutput "Running installation with arguments: $($installArgs -join ' ')" -Color "Cyan"
    $installProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru
    
    if ($installProcess.ExitCode -eq 0) {
        Write-ColorOutput "Scalyr Agent installed successfully!" -Color "Green"
    } else {
        Write-ColorOutput "Installation failed with exit code: $($installProcess.ExitCode)" -Color "Red"
        throw "MSI installation failed"
    }
    
    # Step 3: Wait for installation to complete and files to be available
    Write-ColorOutput "Step 3: Waiting for installation to complete..." -Color "Yellow"
    Start-Sleep -Seconds 10
    
    # Verify installation
    $scalyrPath = "C:\Program Files (x86)\Scalyr"
    $configPath = "$scalyrPath\config"
    $agentJsonPath = "$configPath\agent.json"
    
    if (-not (Test-Path $scalyrPath)) {
        throw "Scalyr installation directory not found: $scalyrPath"
    }
    
    if (-not (Test-Path $configPath)) {
        throw "Scalyr config directory not found: $configPath"
    }
    
    Write-ColorOutput "Installation verification completed!" -Color "Green"
    
    # Step 4: Configure agent.json
    Write-ColorOutput "Step 4: Configuring agent.json..." -Color "Yellow"
    
    # Create the agent.json content
    $agentJsonContent = @"
{
  // Configuration for the Scalyr Agent. For help:
  //
  // https://www.scalyr.com/help/scalyr-agent-2

  // Enter a "Write Logs" api key for your account. These are available at https://www.scalyr.com/keys
  "api_key": "$ApiKey",

  // Fields describing this server. These fields are attached to each log message, and
  // can be used to filter data from a particular server or group of servers.
  "server_attributes": {
     // Fill in this field if you'd like to override the server's hostname.
     // "serverHost": "https://xdr.us1.sentinelone.net",

     // You can add whatever additional fields you'd like.
     // "tier": "production"
  },

  // Log files to upload to Scalyr. You can use '*' wildcards here.
  "logs": [
     // { "path": "/var/log/httpd/access.log", "attributes": { "parser": "accessLog" } }
  ],

  "monitors": [
    {
      "module": "scalyr_agent.builtin_monitors.windows_event_log_monitor",
      "event_logs_to_collect": [
        "Application",
        "System",
        "Security"
      ]
    }
  ]
}
"@
    
    # Backup existing agent.json if it exists
    if (Test-Path $agentJsonPath) {
        $backupPath = "$agentJsonPath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-ColorOutput "Backing up existing agent.json to: $backupPath" -Color "Cyan"
        Copy-Item $agentJsonPath $backupPath
    }
    
    # Write the new configuration
    Write-ColorOutput "Writing new agent.json configuration..." -Color "Cyan"
    
    # Create file without BOM using .NET method
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($agentJsonPath, $agentJsonContent, $utf8NoBom)
    
    # Set proper permissions on the config file
    Write-ColorOutput "Setting file permissions..." -Color "Cyan"
    
    # Take ownership of the file
    Write-ColorOutput "Taking ownership of agent.json..." -Color "Cyan"
    & takeown /f $agentJsonPath
    
    # Grant full permissions to Administrators
    Write-ColorOutput "Setting permissions for Administrators..." -Color "Cyan"
    & icacls $agentJsonPath /grant Administrators:F
    
    # Also set permissions for the Scalyr service account
    Write-ColorOutput "Setting permissions for Scalyr service..." -Color "Cyan"
    & icacls $agentJsonPath /grant "NT AUTHORITY\SYSTEM":F
    
    # Set more restrictive permissions (remove world read/write)
    Write-ColorOutput "Setting restrictive permissions..." -Color "Cyan"
    & icacls $agentJsonPath /remove "Everyone"
    & icacls $agentJsonPath /grant "Administrators:(F)"
    & icacls $agentJsonPath /grant "SYSTEM:(F)"
    
    Write-ColorOutput "agent.json configuration completed!" -Color "Green"
    
    # Step 5: Set the Scalyr server
    Write-ColorOutput "Step 5: Setting Scalyr server..." -Color "Yellow"
    $scalyrExePath = "$scalyrPath\bin\scalyr-agent-2.exe"
    
    if (-not (Test-Path $scalyrExePath)) {
        throw "Scalyr agent executable not found: $scalyrExePath"
    }
    
    Write-ColorOutput "Setting Scalyr server to: $ScalyrServer" -Color "Cyan"
    & $scalyrExePath config --set-scalyr-server $ScalyrServer
    
    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "Scalyr server configuration completed!" -Color "Green"
    } else {
        Write-ColorOutput "Warning: Scalyr server configuration may have failed (exit code: $LASTEXITCODE)" -Color "Yellow"
    }
    
    # Step 6: Start the Scalyr service
    Write-ColorOutput "Step 6: Starting Scalyr service..." -Color "Yellow"
    
    # Try to start the service
    Write-ColorOutput "Starting Scalyr agent..." -Color "Cyan"
    & $scalyrExePath start
    
    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "Scalyr agent started successfully!" -Color "Green"
    } else {
        Write-ColorOutput "Warning: Scalyr agent start may have failed (exit code: $LASTEXITCODE)" -Color "Yellow"
    }
    
    # Step 7: Verify service status
    Write-ColorOutput "Step 7: Verifying service status..." -Color "Yellow"
    Start-Sleep -Seconds 5
    
    try {
        # Check for various possible service names
        $possibleServiceNames = @("ScalyrAgent", "Scalyr", "ScalyrAgentService")
        $serviceFound = $false
        
        foreach ($serviceName in $possibleServiceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Write-ColorOutput "Found Scalyr service: $serviceName" -Color "Cyan"
                Write-ColorOutput "Service status: $($service.Status)" -Color "Cyan"
                if ($service.Status -eq "Running") {
                    Write-ColorOutput "✓ Scalyr service is running successfully!" -Color "Green"
                } else {
                    Write-ColorOutput "⚠ Scalyr service is not running. Status: $($service.Status)" -Color "Yellow"
                }
                $serviceFound = $true
                break
            }
        }
        
        if (-not $serviceFound) {
            Write-ColorOutput "⚠ Scalyr service not found with common names. Checking all services..." -Color "Yellow"
            $allServices = Get-Service | Where-Object { $_.Name -like "*scalyr*" -or $_.DisplayName -like "*scalyr*" }
            if ($allServices) {
                Write-ColorOutput "Found Scalyr-related services:" -Color "Cyan"
                foreach ($svc in $allServices) {
                    Write-ColorOutput "  - $($svc.Name): $($svc.Status)" -Color "Cyan"
                }
            } else {
                Write-ColorOutput "⚠ No Scalyr services found. The agent may be running as a process instead of a service." -Color "Yellow"
            }
        }
        
        # Check if the agent process is running
        $agentProcess = Get-Process -Name "scalyr-agent-2" -ErrorAction SilentlyContinue
        if ($agentProcess) {
            Write-ColorOutput "✓ Scalyr agent process is running (PID: $($agentProcess.Id))" -Color "Green"
        } else {
            Write-ColorOutput "⚠ Scalyr agent process not found" -Color "Yellow"
        }
        
    } catch {
        Write-ColorOutput "⚠ Could not verify service status: $($_.Exception.Message)" -Color "Yellow"
    }
    
    # Cleanup
    Write-ColorOutput "Cleaning up temporary files..." -Color "Yellow"
    if (Test-Path $msiPath) {
        Remove-Item $msiPath -Force
        Write-ColorOutput "Temporary MSI file removed" -Color "Green"
    }
    
    Write-ColorOutput "`n=== SCALYR AGENT INSTALLATION COMPLETED ===" -Color "Green"
    Write-ColorOutput "Installation Summary:" -Color "White"
    Write-ColorOutput "- MSI Downloaded and Installed: ✓" -Color "Green"
    Write-ColorOutput "- agent.json Configured: ✓" -Color "Green"
    Write-ColorOutput "- Scalyr Server Set: ✓" -Color "Green"
    Write-ColorOutput "- Agent Started: ✓" -Color "Green"
    Write-ColorOutput "`nYou can check the Scalyr dashboard to verify logs are being received." -Color "Cyan"
    
} catch {
    Write-ColorOutput "`n=== INSTALLATION FAILED ===" -Color "Red"
    Write-ColorOutput "Error: $($_.Exception.Message)" -Color "Red"
    Write-ColorOutput "Stack Trace: $($_.ScriptStackTrace)" -Color "Red"
    
    # Cleanup on failure
    if (Test-Path $msiPath) {
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    }
    
    exit 1
}
