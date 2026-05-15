<# 
    Setup-DevMachine.ps1
    Extended dev workstation installer

    Run as Administrator, with:
    Set-ExecutionPolicy Bypass -Scope Process -Force
#>

$LogFile = "$PSScriptRoot\install.log"
Start-Transcript -Path $LogFile -Append
$ErrorActionPreference = "Stop"

function Log {
    param([string]$Message)
    Write-Host $Message
    Add-Content -Path $LogFile -Value "$(Get-Date) :: $Message"
}

function Download {
    param(
        [string]$Url,
        [string]$OutFile
    )
    if (!(Test-Path $OutFile)) {
        Log "Downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $OutFile
    } else {
        Log "Already downloaded: $OutFile"
    }
}

$DownloadDir = "$PSScriptRoot\downloads"
if (!(Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir | Out-Null }

# ---------------------------------------------------------
# Core app installs (same as before)
# ---------------------------------------------------------

# LibreOffice
Download "https://download.documentfoundation.org/libreoffice/stable/24.2.0/win/x86_64/LibreOffice_24.2.0_Win_x86-64.msi" "$DownloadDir\LibreOffice.msi"
Start-Process msiexec.exe -ArgumentList "/i `"$DownloadDir\LibreOffice.msi`" /quiet /norestart" -Wait

# Paint.NET
Download "https://www.dotpdn.com/files/paint.net.5.0.13.install.anycpu.web.exe" "$DownloadDir\paintdotnet.exe"
Start-Process "$DownloadDir\paintdotnet.exe" -ArgumentList "/auto" -Wait

# Apache
Download "https://www.apachehaus.com/downloads/httpd-2.4.58-o111s-x64-vc17.zip" "$DownloadDir\apache.zip"
if (!(Test-Path "C:\Apache24")) { Expand-Archive "$DownloadDir\apache.zip" -DestinationPath "C:\Apache24" -Force }

# PHP
Download "https://windows.php.net/downloads/releases/php-8.3.3-Win32-vs17-x64.zip" "$DownloadDir\php.zip"
if (!(Test-Path "C:\PHP")) { Expand-Archive "$DownloadDir\php.zip" -DestinationPath "C:\PHP" -Force }

# MySQL Installer
Download "https://dev.mysql.com/get/Downloads/MySQLInstaller/mysql-installer-community-8.0.36.0.msi" "$DownloadDir\mysql-installer.msi"
Start-Process msiexec.exe -ArgumentList "/i `"$DownloadDir\mysql-installer.msi`" /passive" -Wait

# VS Code
Download "https://update.code.visualstudio.com/latest/win32-x64-user/stable" "$DownloadDir\vscode.exe"
Start-Process "$DownloadDir\vscode.exe" -ArgumentList "/VERYSILENT /NORESTART" -Wait

# Visual Studio Community
Download "https://aka.ms/vs/17/release/vs_community.exe" "$DownloadDir\vs_community.exe"
Start-Process "$DownloadDir\vs_community.exe" -ArgumentList "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NetWeb" -Wait

# Sysinternals
Download "https://download.sysinternals.com/files/SysinternalsSuite.zip" "$DownloadDir\SysinternalsSuite.zip"
if (!(Test-Path "C:\Sysinternals")) { Expand-Archive "$DownloadDir\SysinternalsSuite.zip" -DestinationPath "C:\Sysinternals" -Force }

# ---------------------------------------------------------
# Chocolatey + Dev tools (Docker, Python, Java, Go, Terraform, k8s tools)
# ---------------------------------------------------------

if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "Installing Chocolatey"
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
} else {
    Log "Chocolatey already installed"
}

choco feature enable -n allowGlobalConfirmation | Out-Null

Log "Installing dev tools via Chocolatey"
choco install docker-desktop
choco install python
choco install openjdk
choco install golang
choco install terraform
choco install kubernetes-cli
choco install kind
choco install kubernetes-helm
choco install git -y

# Rust via rustup
if (!(Test-Path "$env:USERPROFILE\.cargo\bin\rustc.exe")) {
    Log "Installing Rust via rustup"
    Download "https://win.rustup.rs/x86_64" "$DownloadDir\rustup-init.exe"
    Start-Process "$DownloadDir\rustup-init.exe" -ArgumentList "-y" -Wait
}

# ---------------------------------------------------------
# WSL2 enablement
# ---------------------------------------------------------

Log "Enabling WSL and VirtualMachinePlatform"
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null

# ---------------------------------------------------------
# Configure Apache + PHP
# ---------------------------------------------------------

Log "Configuring Apache with PHP"

if (!(Test-Path "C:\PHP\php.ini")) {
    Copy-Item "C:\PHP\php.ini-production" "C:\PHP\php.ini" -Force
}

$ApacheConf = "C:\Apache24\conf\httpd.conf"
$phpConfigBlock = @"
LoadModule php_module "C:/PHP/php8apache2_4.dll"
AddHandler application/x-httpd-php .php
PHPIniDir "C:/PHP"
DirectoryIndex index.php index.html
"@

if (-not (Select-String -Path $ApacheConf -Pattern "php8apache2_4.dll" -Quiet)) {
    Add-Content $ApacheConf $phpConfigBlock
    Log "Added PHP module configuration to httpd.conf"
}

# Install Apache as a service (idempotent-ish)
Start-Process "C:\Apache24\bin\httpd.exe" -ArgumentList "-k install -n Apache24" -Wait

# ---------------------------------------------------------
# MySQL root password + database creation
# ---------------------------------------------------------

$MySQLBin = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
$MySQLRootPassword = "RootPassword123!"
$MySQLDbName = "devdb"
$MySQLUser = "devuser"
$MySQLUserPassword = "DevUserPass123!"

Log "Configuring MySQL root password (if not already set)"

try {
    & "$MySQLBin\mysqladmin.exe" -u root password $MySQLRootPassword
} catch {
    Log "mysqladmin root password may already be set, continuing..."
}

Log "Creating MySQL database and user"
& "$MySQLBin\mysql.exe" -u root -p$MySQLRootPassword -e "CREATE DATABASE IF NOT EXISTS $MySQLDbName;"
& "$MySQLBin\mysql.exe" -u root -p$MySQLRootPassword -e "CREATE USER IF NOT EXISTS '$MySQLUser'@'localhost' IDENTIFIED BY '$MySQLUserPassword';"
& "$MySQLBin\mysql.exe" -u root -p$MySQLRootPassword -e "GRANT ALL PRIVILEGES ON $MySQLDbName.* TO '$MySQLUser'@'localhost'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------
# PHP + Apache validation
# ---------------------------------------------------------

$Htdocs = "C:\Apache24\htdocs"
if (!(Test-Path $Htdocs)) { New-Item -ItemType Directory -Path $Htdocs | Out-Null }

$PhpInfoFile = Join-Path $Htdocs "info.php"
"<?php phpinfo(); ?>" | Out-File -FilePath $PhpInfoFile -Encoding ASCII -Force

Log "Starting Apache service"
Start-Service -Name "Apache24" -ErrorAction SilentlyContinue

Start-Sleep -Seconds 10

Log "Validating Apache + PHP via HTTP request"
try {
    $response = Invoke-WebRequest -Uri "http://localhost/info.php" -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -eq 200 -and $response.Content -like "*phpinfo()*") {
        Log "Apache + PHP validation successful"
    } else {
        Log "Apache + PHP validation returned unexpected content"
    }
} catch {
    Log "Apache + PHP validation failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------
# Add PHP to PATH
# ---------------------------------------------------------

$envPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($envPath -notlike "*C:\PHP*") {
    [Environment]::SetEnvironmentVariable("Path", "$envPath;C:\PHP", "Machine")
    Log "Added PHP to PATH"
}

# ---------------------------------------------------------
# Simple Windows services monitoring script
# ---------------------------------------------------------

$MonitorScript = "C:\Tools"
if (!(Test-Path $MonitorScript)) { New-Item -ItemType Directory -Path $MonitorScript | Out-Null }

$ServiceMonitorFile = Join-Path $MonitorScript "Monitor-Services.ps1"
@'
param(
    [string[]]$Services = @("Apache24","MySQL80","docker","w32time")
)

foreach ($svc in $Services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($null -eq $s) {
        Write-Host "Service $svc not found"
        continue
    }
    if ($s.Status -ne "Running") {
        Write-Host "Service $svc is $($s.Status). Attempting to start..."
        try {
            Start-Service $svc
            Write-Host "Service $svc started."
        } catch {
            Write-Host "Failed to start $svc: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Service $svc is running."
    }
}
'@ | Out-File -FilePath $ServiceMonitorFile -Encoding UTF8 -Force

Log "Created service monitoring script at $ServiceMonitorFile"

# ---------------------------------------------------------
# Desktop shortcuts
# ---------------------------------------------------------

function New-Shortcut {
    param(
        [string]$TargetPath,
        [string]$ShortcutPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = ""
    )
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $TargetPath
    if ($Arguments) { $Shortcut.Arguments = $Arguments }
    if ($WorkingDirectory) { $Shortcut.WorkingDirectory = $WorkingDirectory }
    $Shortcut.Save()
}

$Desktop = [Environment]::GetFolderPath("Desktop")

New-Shortcut -TargetPath "C:\Program Files\Microsoft VS Code\Code.exe" -ShortcutPath (Join-Path $Desktop "VS Code.lnk")
New-Shortcut -TargetPath "C:\Program Files\Git\bin\git-bash.exe" -ShortcutPath (Join-Path $Desktop "Git Bash.lnk")
New-Shortcut -TargetPath "C:\Apache24\bin\httpd.exe" -ShortcutPath (Join-Path $Desktop "Apache HTTPD.lnk")
New-Shortcut -TargetPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -ShortcutPath (Join-Path $Desktop "Service Monitor.lnk") -Arguments "-ExecutionPolicy Bypass -File `"$ServiceMonitorFile`""

Log "Desktop shortcuts created"

Log "Setup complete!"
Stop-Transcript
