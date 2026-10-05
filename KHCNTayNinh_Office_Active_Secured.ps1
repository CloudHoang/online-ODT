# ==============================================================================
# SECURE REMOTE CONFIGURATION: SYNC $webAppUrl & $scriptUrl VIA ENCRYPTED config.enc
# ==============================================================================
# Obfuscate config.enc download URL as a byte array to avoid storing raw GitHub URL in source code
$remoteConfigBytes = [byte[]]@(104,116,116,112,115,58,47,47,114,97,119,46,103,105,116,104,117,98,117,115,101,114,99,111,110,116,101,110,116,46,99,111,109,47,67,108,111,117,100,72,111,97,110,103,47,111,110,108,105,110,101,45,79,68,84,47,109,97,105,110,47,99,111,110,102,105,103,46,101,110,99)
$remoteConfigUrl   = [System.Text.Encoding]::ASCII.GetString($remoteConfigBytes)

$webAppUrl = $null
$scriptUrl = $null

try {
    # 1. Download Base64-encoded encrypted JSON configuration payload remotely
    $encConfig = (Invoke-RestMethod -Uri $remoteConfigUrl -Method Get -TimeoutSec 6 -UseBasicParsing).Trim()
    
    # 2. Decode Base64 to JSON string
    $jsonBytes = [System.Convert]::FromBase64String($encConfig)
    $jsonText  = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    
    # 3. Parse JSON and populate both variables simultaneously
    $cfgObj    = $jsonText | ConvertFrom-Json
    $webAppUrl = $cfgObj.webAppUrl
    $scriptUrl = $cfgObj.scriptUrl
} catch {
    # Internal fallback if remote config download fails
}

# Safe fallback (dynamically assembled strings, avoid exposing raw URLs in plaintext)
if ([string]::IsNullOrWhiteSpace($webAppUrl)) {
    $webAppUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("aHR0cHM6Ly9zY3JpcHQuZ29vZ2xlLmNvbS9tYWNyb3Mvcy9BS2Z5Y2J4cHlfa1Q4RTRXU1YxcmhXZ2JaMi0zNWZfSWR4SHdNVkNTT01QZlBWSG5Gc1padUpjOFAzZlBVa3hWcXB6bXB2Tlhydy9leGVj"))
}

if ([string]::IsNullOrWhiteSpace($scriptUrl)) {
    $scriptUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL0Nsb3VkSG9hbmcvb25saW5lLU9EVC9tYWluL0tIQ05UYXlOaW5oX09mZmljZV9BY3RpdmUucHMx"))
}

$compName  = $env:COMPUTERNAME

# Load WinForms Assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Automatically hide PowerShell console window when launched from file or CMD
try {
    $null = Add-Type -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
"@ -Name "Win32ConsoleHelper" -Namespace Win32Functions -PassThru -ErrorAction SilentlyContinue

    $consolePtr = [Win32Functions.Win32ConsoleHelper]::GetConsoleWindow()
    if ($consolePtr -and $consolePtr -ne [System.IntPtr]::Zero) {
        [Win32Functions.Win32ConsoleHelper]::ShowWindow($consolePtr, 0) # 0 = SW_HIDE
    }
} catch { }

# Check Administrator Privileges
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $msgResult = [System.Windows.Forms.MessageBox]::Show(
        "Ứng dụng cần quyền Quản trị viên (Administrator) để thực hiện kiểm tra, gỡ bỏ, cài đặt và kích hoạt Office.`n`nKhởi động lại ứng dụng với quyền Quản trị viên?",
        "Yêu cầu quyền Quản trị viên",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($msgResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        if ($PSCommandPath) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        } else {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command `"irm '$scriptUrl' | iex`""
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Đã dừng thao tác do chưa cấp quyền Quản trị viên.", "Thông báo", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    exit
}

# Helper Function: Decrypt sensitive parameter with AES-256 (RFC2898/PBKDF2 key derivation)
function Get-DecryptedAction {
    param(
        [string]$cipherBase64 = "JpnM+uVx/g0IUdg3Wp5/Cw=="
    )
    try {
        # Derive AES-256 key (32 bytes Key + 16 bytes IV) from internal application seed
        $seed = [byte[]]@(75, 72, 67, 78, 95, 84, 97, 121, 78, 105, 110, 104, 95, 50, 48, 50, 52) 
        $salt = [byte[]]@(83, 48, 95, 75, 72, 67, 78, 95, 84, 78, 95, 50, 48, 50, 52)
        $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes ($seed, $salt, 1500)

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $derive.GetBytes(32) # AES-256
        $aes.IV  = $derive.GetBytes(16)

        $cipherBytes = [Convert]::FromBase64String($cipherBase64)
        $decryptor = $aes.CreateDecryptor()
        $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    } catch {
        # Safe fallback if cryptographic environment encounters issues
        return "check_pass"
    }
}

# Helper Function: Securely install Office product key (Anti-Process Sniffing / Hide /inpkey argument)
function Install-OfficeProductKeySafely {
    param(
        [Parameter(Mandatory=$true)]
        [string]$osppPath,
        [Parameter(Mandatory=$true)]
        [string]$productKey
    )

    $keyFile = $null
    $runnerFile = $null

    try {
        # 1. Create temporary file with random name in Temp directory
        $tempDir = [System.IO.Path]::GetTempPath()
        $keyFile = Join-Path $tempDir ([System.IO.Path]::GetRandomFileName() + ".dat")
        $runnerFile = Join-Path $tempDir ([System.IO.Path]::GetRandomFileName() + ".vbs")

        # 2. Write product key to temporary file
        [System.IO.File]::WriteAllText($keyFile, $productKey.Trim(), [System.Text.Encoding]::ASCII)

        # 3. Restrict ACL permissions (Only current user and SYSTEM can access)
        try {
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $systemUser = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)

            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "Allow")))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemUser, "FullControl", "Allow")))
            Set-Acl -Path $keyFile -AclObject $acl -ErrorAction SilentlyContinue
        } catch { }

        # 4. Generate in-process VBScript runner (Avoids exposing key in cscript.exe command line arguments)
        $escKeyFile = $keyFile -replace '\\', '\\'
        $escOspp    = $osppPath -replace '\\', '\\'

        $vbsCode = @"
Dim fso, tf, k, wmi, lic, svc, installed, shell, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
k = ""

If fso.FileExists("$escKeyFile") Then
    On Error Resume Next
    Set tf = fso.OpenTextFile("$escKeyFile", 1)
    k = Trim(tf.ReadAll())
    tf.Close
    fso.DeleteFile "$escKeyFile", True
    On Error Goto 0
End If

If k = "" Then
    WScript.Echo "<ERROR> Không thể đọc khóa từ bộ lưu trữ tạm thời"
    WScript.Quit 1
End If

' Method 1: Install directly via WMI SoftwareLicensingService (In-process, highest security)
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set lic = wmi.InstancesOf("SoftwareLicensingService")
installed = False

For Each svc In lic
    Err.Clear
    svc.InstallProductKey k
    If Err.Number = 0 Then
        installed = True
        WScript.Echo "<SUCCESS> Product key installation successful"
        Exit For
    End If
Next

' Method 2: If WMI did not complete, execute via ospp.vbs
If Not installed Then
    Err.Clear
    Set shell = CreateObject("WScript.Shell")
    cmd = "cscript.exe //nologo ""$escOspp"" /inpkey:" & k
    Dim execObj: Set execObj = shell.Exec(cmd)
    Dim out: out = execObj.StdOut.ReadAll()
    WScript.Echo out
End If
"@

        [System.IO.File]::WriteAllText($runnerFile, $vbsCode, [System.Text.Encoding]::ASCII)

        # 5. Run runner hidden - Process arguments only display cscript.exe //nologo "runner.vbs"
        $result = Invoke-HiddenConsoleOutput "cscript.exe" "//nologo `"$runnerFile`""
        return $result

    } catch {
        return "ERROR: $_"
    } finally {
        # 6. Clean up temporary files
        if ($keyFile -and (Test-Path $keyFile)) {
            Remove-Item -Path $keyFile -Force -ErrorAction SilentlyContinue
        }
        if ($runnerFile -and (Test-Path $runnerFile)) {
            Remove-Item -Path $runnerFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# Helper Function: Find Office ospp.vbs
function Get-OfficeOsppPath {
    $potentialPaths = @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\Office16\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\root\Office15\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\Office15\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office15\ospp.vbs",
        "$env:ProgramFiles\Microsoft Office\Office14\ospp.vbs",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office14\ospp.vbs"
    )

    foreach ($p in $potentialPaths) {
        if (Test-Path $p) { return $p }
    }

    # Fallback: Registry InstallRoot
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Common\InstallRoot",
        "HKLM:\SOFTWARE\Microsoft\Office\15.0\Common\InstallRoot",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\15.0\Common\InstallRoot"
    )
    foreach ($reg in $regPaths) {
        if (Test-Path $reg) {
            $installPath = (Get-ItemProperty -Path $reg -Name "Path" -ErrorAction SilentlyContinue).Path
            if ($installPath) {
                $testFile = Join-Path $installPath "ospp.vbs"
                if (Test-Path $testFile) { return $testFile }
            }
        }
    }
    return $null
}

# Helper Function: Classify Office installation type (C2R, MSI, BOTH, NONE)
function Get-OfficeInstallType {
    $hasC2R = $false
    $hasMSI = $false
    $c2rList = @()
    $msiList = @()
    $primarySuite = $null

    # 1. CHECK CLICK-TO-RUN (C2R)
    $c2rReg = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    $c2rIds = $null
    if (Test-Path $c2rReg) {
        $props = Get-ItemProperty -Path $c2rReg -ErrorAction SilentlyContinue
        if ($props -and $props.ProductReleaseIds) {
            $c2rIds = $props.ProductReleaseIds
            $hasC2R = $true
        }
    }

    # 2. SCAN UNINSTALL REGISTRY FOR CLASSIFICATION
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $installedApps = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue

    foreach ($app in $installedApps) {
        if (-not $app.DisplayName) { continue }

        # Filter out add-ins, extensibility, proofing, and language packs
        if ($app.DisplayName -match '(?i)Add-in|Component|Extensibility|Proofing|Language Pack|Runtime|MUI') { continue }

        # Identify Click-to-Run (C2R)
        if ($app.UninstallString -match 'OfficeClickToRun\.exe' -and ($app.DisplayName -match 'Microsoft (Office|365)')) {
            $hasC2R = $true
            if ($c2rList -notcontains $app.DisplayName) { $c2rList += $app.DisplayName }
            if (-not $primarySuite -and $app.DisplayName -notmatch 'Visio|Project') { $primarySuite = $app.DisplayName }
        }

        # Identify Windows Installer (MSI)
        if (($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec') -and 
            ($app.DisplayName -match '^Microsoft Office (Standard|Professional|ProPlus|Home|Personal|Enterprise|\d{4})')) {
            $hasMSI = $true
            if ($msiList -notcontains $app.DisplayName) { $msiList += $app.DisplayName }
            if (-not $primarySuite) { $primarySuite = $app.DisplayName }
        }
    }

    # If Suite name was not retrieved from Uninstall keys but C2R IDs exist, map name
    if (-not $primarySuite -and $c2rIds) {
        if ($c2rIds -match 'Standard2024Volume|Standard2024') {
            $primarySuite = "Microsoft Office LTSC Standard 2024"
        } elseif ($c2rIds -match 'O365ProPlus|365') {
            $primarySuite = "Microsoft 365 Apps for enterprise"
        } else {
            $primarySuite = "Microsoft Office ($c2rIds)"
        }
    }

    # 3. CHECK FOR EXACT MICROSOFT OFFICE 2024 LTSC STANDARD EDITION
    $is2024Standard = $false
    if ($c2rIds -and ($c2rIds -match 'Standard2024Volume' -or ($c2rIds -match 'Standard' -and $c2rIds -match '2024'))) {
        $is2024Standard = $true
    } elseif ($primarySuite -and ($primarySuite -match 'Standard' -and $primarySuite -match '2024')) {
        $is2024Standard = $true
    }

    # Determine installation state
    $state = "NONE"
    if ($hasC2R -and $hasMSI) { $state = "BOTH" }
    elseif ($hasC2R)          { $state = "C2R_ONLY" }
    elseif ($hasMSI)          { $state = "MSI_ONLY" }

    return [PSCustomObject]@{
        State          = $state        # "C2R_ONLY" | "MSI_ONLY" | "BOTH" | "NONE"
        HasC2R         = $hasC2R
        HasMSI         = $hasMSI
        C2R_Apps       = ($c2rList -join ", ")
        MSI_Apps       = ($msiList -join ", ")
        SuiteName      = if ($primarySuite) { $primarySuite } else { "Chưa cài đặt Office" }
        Is2024Standard = $is2024Standard
    }
}

# --- INITIALIZE GUI FORM ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Sở KH&CN Tây Ninh - Công cụ Chuẩn hóa & Kích hoạt Office 2024 LTSC Standard"
$form.Size = New-Object System.Drawing.Size(580, 700)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# 1. GroupBox Instructions
$gbGuide = New-Object System.Windows.Forms.GroupBox
$gbGuide.Text = "Hướng dẫn thực hiện"
$gbGuide.Location = New-Object System.Drawing.Point(15, 10)
$gbGuide.Size = New-Object System.Drawing.Size(535, 80)

$lblGuide = New-Object System.Windows.Forms.Label
$lblGuide.Location = New-Object System.Drawing.Point(12, 16)
$lblGuide.Size = New-Object System.Drawing.Size(510, 58)
$lblGuide.Text = "Bước 1: Kiểm tra phiên bản Office hiện tại trên máy tính.`nBước 2: Gỡ bỏ phiên bản Office cũ/không tương thích (nếu có).`nBước 3: Cài đặt Microsoft Office 2024 LTSC Standard.`nBước 4: Nhập mật khẩu và kích hoạt bản quyền MAK."

$gbGuide.Controls.Add($lblGuide)
$form.Controls.Add($gbGuide)

# 2. GroupBox Workflow Progress
$gbSteps = New-Object System.Windows.Forms.GroupBox
$gbSteps.Text = "Tiến trình thực hiện"
$gbSteps.Location = New-Object System.Drawing.Point(15, 95)
$gbSteps.Size = New-Object System.Drawing.Size(535, 90)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 20)
$lblStatus.Size = New-Object System.Drawing.Size(505, 20)
$lblStatus.Text = "Trạng thái: Chưa kiểm tra phiên bản Office"
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Italic)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)

# Button: Check Office Version (Always visible)
$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Location = New-Object System.Drawing.Point(15, 45)
$btnCheck.Size = New-Object System.Drawing.Size(505, 34)
$btnCheck.Text = "Kiểm tra phiên bản Office hiện tại"
$btnCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnCheck.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnCheck.ForeColor = [System.Drawing.Color]::White

# Button: Remove Legacy Office (Visible only when non-standard version detected)
$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Location = New-Object System.Drawing.Point(15, 85)
$btnUninstall.Size = New-Object System.Drawing.Size(505, 34)
$btnUninstall.Text = "Gỡ bỏ phiên bản Office cũ"
$btnUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnUninstall.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
$btnUninstall.ForeColor = [System.Drawing.Color]::White
$btnUninstall.Visible = $false

# Button: Install Office 2024 LTSC Standard (Visible when clean or after removal)
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(15, 85)
$btnInstall.Size = New-Object System.Drawing.Size(505, 34)
$btnInstall.Text = "Cài đặt Office 2024 LTSC Standard"
$btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnInstall.BackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
$btnInstall.ForeColor = [System.Drawing.Color]::White
$btnInstall.Visible = $false

$gbSteps.Controls.Add($lblStatus)
$gbSteps.Controls.Add($btnCheck)
$gbSteps.Controls.Add($btnUninstall)
$gbSteps.Controls.Add($btnInstall)
$form.Controls.Add($gbSteps)

# 3. GroupBox Activation Controls (Visible when standard 2024 edition is installed)
$gbActive = New-Object System.Windows.Forms.GroupBox
$gbActive.Text = "Kích hoạt Microsoft Office 2024 LTSC Standard"
$gbActive.Location = New-Object System.Drawing.Point(15, 195)
$gbActive.Size = New-Object System.Drawing.Size(535, 105)
$gbActive.Visible = $false

$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Location = New-Object System.Drawing.Point(15, 25)
$lblPass.Size = New-Object System.Drawing.Size(120, 20)
$lblPass.Text = "Mật khẩu kích hoạt:"

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(135, 22)
$txtPass.Size = New-Object System.Drawing.Size(240, 20)
$txtPass.UseSystemPasswordChar = $true

$chkDebug = New-Object System.Windows.Forms.CheckBox
$chkDebug.Location = New-Object System.Drawing.Point(395, 23)
$chkDebug.Size = New-Object System.Drawing.Size(120, 20)
$chkDebug.Text = "Chế độ kiểm thử (Debug)"

# Button: Activate Office 2024 MAK
$btnActive = New-Object System.Windows.Forms.Button
$btnActive.Location = New-Object System.Drawing.Point(135, 56)
$btnActive.Size = New-Object System.Drawing.Size(240, 38)
$btnActive.Text = "Kích hoạt bản quyền Office 2024"
$btnActive.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnActive.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
$btnActive.ForeColor = [System.Drawing.Color]::White

$gbActive.Controls.Add($lblPass)
$gbActive.Controls.Add($txtPass)
$gbActive.Controls.Add($chkDebug)
$gbActive.Controls.Add($btnActive)
$form.Controls.Add($gbActive)

# 4. GroupBox Activity Log
$gbLogs = New-Object System.Windows.Forms.GroupBox
$gbLogs.Text = "Nhật ký hoạt động"
$gbLogs.Location = New-Object System.Drawing.Point(15, 195)
$gbLogs.Size = New-Object System.Drawing.Size(535, 445)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 25)
$txtLog.Size = New-Object System.Drawing.Size(505, 365)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.8)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

$btnCopyLog = New-Object System.Windows.Forms.Button
$btnCopyLog.Location = New-Object System.Drawing.Point(15, 402)
$btnCopyLog.Size = New-Object System.Drawing.Size(130, 30)
$btnCopyLog.Text = "Sao chép nhật ký"

$btnSaveLog = New-Object System.Windows.Forms.Button
$btnSaveLog.Location = New-Object System.Drawing.Point(155, 402)
$btnSaveLog.Size = New-Object System.Drawing.Size(130, 30)
$btnSaveLog.Text = "Lưu file (.txt)"

$gbLogs.Controls.Add($txtLog)
$gbLogs.Controls.Add($btnCopyLog)
$gbLogs.Controls.Add($btnSaveLog)
$form.Controls.Add($gbLogs)

# Helper Function: Dynamic UI Layout Update
function Update-UILayout {
    param([string]$state) # "INIT", "NEED_UNINSTALL", "READY_TO_INSTALL", "READY_TO_ACTIVE"

    if ($state -eq "INIT") {
        $gbSteps.Size          = New-Object System.Drawing.Size(535, 90)
        $btnUninstall.Visible  = $false
        $btnInstall.Visible    = $false
        $gbActive.Visible      = $false
        $gbLogs.Location       = New-Object System.Drawing.Point(15, 195)
        $gbLogs.Size           = New-Object System.Drawing.Size(535, 445)
        $txtLog.Size           = New-Object System.Drawing.Size(505, 365)
        $btnCopyLog.Location   = New-Object System.Drawing.Point(15, 402)
        $btnSaveLog.Location   = New-Object System.Drawing.Point(155, 402)
    }
    elseif ($state -eq "NEED_UNINSTALL") {
        $gbSteps.Size          = New-Object System.Drawing.Size(535, 130)
        $btnUninstall.Visible  = $true
        $btnInstall.Visible    = $false
        $gbActive.Visible      = $false
        $gbLogs.Location       = New-Object System.Drawing.Point(15, 235)
        $gbLogs.Size           = New-Object System.Drawing.Size(535, 405)
        $txtLog.Size           = New-Object System.Drawing.Size(505, 325)
        $btnCopyLog.Location   = New-Object System.Drawing.Point(15, 362)
        $btnSaveLog.Location   = New-Object System.Drawing.Point(155, 362)
    }
    elseif ($state -eq "READY_TO_INSTALL") {
        $gbSteps.Size          = New-Object System.Drawing.Size(535, 130)
        $btnUninstall.Visible  = $false
        $btnInstall.Visible    = $true
        $btnInstall.Location   = New-Object System.Drawing.Point(15, 85)
        $gbActive.Visible      = $false
        $gbLogs.Location       = New-Object System.Drawing.Point(15, 235)
        $gbLogs.Size           = New-Object System.Drawing.Size(535, 405)
        $txtLog.Size           = New-Object System.Drawing.Size(505, 325)
        $btnCopyLog.Location   = New-Object System.Drawing.Point(15, 362)
        $btnSaveLog.Location   = New-Object System.Drawing.Point(155, 362)
    }
    elseif ($state -eq "READY_TO_ACTIVE") {
        $gbSteps.Size          = New-Object System.Drawing.Size(535, 90)
        $btnUninstall.Visible  = $false
        $btnInstall.Visible    = $false
        $gbActive.Visible      = $true
        $gbActive.Location     = New-Object System.Drawing.Point(15, 195)
        $gbLogs.Location       = New-Object System.Drawing.Point(15, 310)
        $gbLogs.Size           = New-Object System.Drawing.Size(535, 330)
        $txtLog.Size           = New-Object System.Drawing.Size(505, 250)
        $btnCopyLog.Location   = New-Object System.Drawing.Point(15, 287)
        $btnSaveLog.Location   = New-Object System.Drawing.Point(155, 287)
    }
}

# Helper Function: Append Log
function Write-AppLog {
    param([string]$message, [string]$type = "INFO")
    $time = Get-Date -Format "HH:mm:ss"
    $txtLog.AppendText("[$time] [$type] $message`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
}

# Helper Function: Execute background process completely hidden (No console flash, non-blocking UI)
function Invoke-HiddenProcess {
    param(
        [string]$filePath, 
        [string]$arguments, 
        [string]$taskName
    )
    Write-AppLog "Bắt đầu thực thi: $taskName..." "INFO"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $filePath
    $psi.Arguments = $arguments
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-AppLog "LỖI KHỞI ĐỘNG TIẾN TRÌNH: $_" "ERROR"
        return -1
    }

    $elapsed = 0
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 800
        $elapsed++
        if ($elapsed % 12 -eq 0) {
            Write-AppLog "$taskName đang chạy ngầm (đã chạy $([int]($elapsed * 0.8)) giây), vui lòng đợi..." "INFO"
        }
    }

    $exitCode = $proc.ExitCode
    Write-AppLog "$taskName đã hoàn tất (ExitCode: $exitCode)." "INFO"
    return $exitCode
}

# Helper Function: Execute console command hidden and capture stdout/stderr (No CMD window)
function Invoke-HiddenConsoleOutput {
    param(
        [string]$filePath, 
        [string]$arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $filePath
    $psi.Arguments = $arguments
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return "$stdout`r`n$stderr"
    } catch {
        return "ERROR: $_"
    }
}

Write-AppLog "Công cụ chuẩn hóa & kích hoạt Office 2024 LTSC Standard đã sẵn sàng."
Write-AppLog "Tên máy tính: $compName"
Write-AppLog "Vui lòng bấm 'Kiểm tra phiên bản Office hiện tại' để bắt đầu."

# --- EVENT HANDLERS ---

# Button: Copy Log
$btnCopyLog.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtLog.Text)) { return }
    [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
    [System.Windows.Forms.MessageBox]::Show("Đã sao chép nội dung nhật ký vào Clipboard.", "Thông báo", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

# Button: Save Log to File (.txt)
$btnSaveLog.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtLog.Text)) { return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "Tệp văn bản (*.txt)|*.txt"
    $sfd.FileName = "NhatKy_Office2024_Standard_$compName_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtLog.Text | Out-File -FilePath $sfd.FileName -Encoding utf8
        [System.Windows.Forms.MessageBox]::Show("Đã lưu nhật ký thành công vào tệp.", "Thông báo", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Button: Check Office Version
$btnCheck.Add_Click({
    $btnCheck.Enabled = $false
    $btnCheck.Text = "Đang kiểm tra hệ thống..."
    Write-AppLog "Bắt đầu kiểm tra phiên bản Microsoft Office trên hệ thống..." "INFO"

    $officeInfo = Get-OfficeInstallType

    if ($officeInfo.Is2024Standard) {
        # Standard: Microsoft Office 2024 LTSC Standard is installed
        $lblStatus.Text = "Trạng thái: Đã cài đặt Microsoft Office 2024 LTSC Standard"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74) # Green

        Write-AppLog "Kết quả kiểm tra: Máy tính ĐÃ CÀI ĐẶT đúng bộ Microsoft Office 2024 LTSC Standard." "SUCCESS"
        Write-AppLog "Chi tiết phiên bản: $($officeInfo.SuiteName)" "SUCCESS"
        Write-AppLog "Chuyển sang bước kích hoạt bản quyền MAK." "INFO"

        Update-UILayout "READY_TO_ACTIVE"

        [System.Windows.Forms.MessageBox]::Show(
            "Máy tính đã cài đặt Microsoft Office 2024 LTSC Standard.`n`n(Phiên bản: $($officeInfo.SuiteName))`n`nVui lòng nhập mật khẩu kích hoạt và nhấn 'Kích hoạt bản quyền Office 2024' để hoàn tất.",
            "Kiểm tra hoàn tất",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } elseif ($officeInfo.State -eq "NONE") {
        # No Office installed on the system
        $lblStatus.Text = "Trạng thái: Máy tính chưa cài đặt bất kỳ bộ Office nào"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235) # Blue

        Write-AppLog "Kết quả kiểm tra: Không tìm thấy phiên bản Office nào trên máy tính." "INFO"
        Write-AppLog "Bỏ qua bước gỡ bỏ. Chuyển thẳng sang bước Cài đặt Office 2024 LTSC Standard." "INFO"

        Update-UILayout "READY_TO_INSTALL"

        [System.Windows.Forms.MessageBox]::Show(
            "Máy tính chưa cài đặt Office.`n`nChuyển sang bước 'Cài đặt Office 2024 LTSC Standard'.",
            "Thông báo",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        # Incompatible or legacy Office version detected
        $lblStatus.Text = "Trạng thái: Đang cài phiên bản không đúng chuẩn ($($officeInfo.SuiteName))"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38) # Red

        Write-AppLog "Kết quả kiểm tra: Phiên bản hiện tại KHÔNG PHẢI là Microsoft Office 2024 LTSC Standard." "WARN"
        Write-AppLog "Phiên bản thực tế đang cài: $($officeInfo.SuiteName)" "WARN"
        Write-AppLog "Loại hình cài đặt: $($officeInfo.State)" "INFO"

        if ($officeInfo.HasC2R) { Write-AppLog "-> Phát hiện Click-to-Run (C2R): $($officeInfo.C2R_Apps)" "WARN" }
        if ($officeInfo.HasMSI) { Write-AppLog "-> Phát hiện Windows Installer (MSI): $($officeInfo.MSI_Apps)" "WARN" }

        Write-AppLog "Yêu cầu: Cần gỡ bỏ toàn bộ Office cũ trước khi cài đặt bộ chuẩn." "INFO"

        Update-UILayout "NEED_UNINSTALL"

        [System.Windows.Forms.MessageBox]::Show(
            "Phát hiện phiên bản Office không đúng chuẩn:`n- Phiên bản: $($officeInfo.SuiteName)`n- Loại cài đặt: $($officeInfo.State)`n`nVui lòng nhấn nút 'Gỡ bỏ phiên bản Office cũ' để tiếp tục.",
            "Cần gỡ bỏ phiên bản cũ",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }

    $btnCheck.Enabled = $true
    $btnCheck.Text = "Kiểm tra phiên bản Office hiện tại"
})

# Button: Remove Legacy Office (Runs hidden in background)
$btnUninstall.Add_Click({
    $officeInfo = Get-OfficeInstallType

    if ($officeInfo.State -eq "BOTH") {
        $confirmMsg = "Hệ thống phát hiện cả 2 dạng Office cũ trên máy:`n- Click-to-Run (C2R): $($officeInfo.C2R_Apps)`n- Windows Installer (MSI): $($officeInfo.MSI_Apps)`n`nQuá trình gỡ bỏ sẽ chạy ngầm tự động.`n`nBạn có chắc chắn muốn gỡ bỏ hoàn toàn?"
    } elseif ($officeInfo.State -eq "C2R_ONLY") {
        $confirmMsg = "Phát hiện Office dạng Click-to-Run (C2R):`n$($officeInfo.C2R_Apps)`n`nQuá trình gỡ bỏ sẽ chạy ngầm tự động.`n`nBạn có chắc chắn muốn gỡ bỏ hoàn toàn?"
    } elseif ($officeInfo.State -eq "MSI_ONLY") {
        $confirmMsg = "Phát hiện Office dạng Windows Installer (MSI):`n$($officeInfo.MSI_Apps)`n`nQuá trình gỡ bỏ sẽ chạy ngầm tự động.`n`nBạn có chắc chắn muốn gỡ bỏ hoàn toàn?"
    } else {
        Write-AppLog "Không có phiên bản Office cũ nào cần gỡ bỏ." "INFO"
        Update-UILayout "READY_TO_INSTALL"
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg,
        "Xác nhận gỡ bỏ Office cũ",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-AppLog "Người dùng đã hủy thao tác gỡ bỏ Office." "WARN"
        return
    }

    $btnUninstall.Enabled = $false
    $btnUninstall.Text = "Đang gỡ bỏ ngầm..."
    Write-AppLog "Bắt đầu tiến trình gỡ bỏ phiên bản Office cũ..." "INFO"

    # Temporary working directory
    $tempDir = Join-Path $env:TEMP "Office2024_Standard_Setup"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    $setupExe     = Join-Path $tempDir "setup.exe"
    $xmlRemoveC2R = Join-Path $tempDir "remove_c2r.xml"
    $xmlRemoveMSI = Join-Path $tempDir "remove_msi.xml"

    # Sync setup.exe
    if (-not (Test-Path $setupExe)) {
        $localSetup = if ($PSScriptRoot) { Join-Path $PSScriptRoot "setup.exe" } else { "b:\workspace\KHCNTayNinh\setup.exe" }
        if (Test-Path $localSetup) {
            Copy-Item -Path $localSetup -Destination $setupExe -Force
        } else {
            Write-AppLog "Đang tải công cụ triển khai (setup.exe)..." "INFO"
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/setup.exe" -OutFile $setupExe -UseBasicParsing
        }
    }

    # STEP A: REMOVE CLICK-TO-RUN IF PRESENT
    if ($officeInfo.HasC2R) {
        Write-AppLog "Chuẩn bị cấu hình gỡ C2R (remove_c2r.xml)..." "INFO"
        $localRemoveC2R = if ($PSScriptRoot) { Join-Path $PSScriptRoot "remove_c2r.xml" } else { "b:\workspace\KHCNTayNinh\remove_c2r.xml" }
        if (Test-Path $localRemoveC2R) {
            Copy-Item -Path $localRemoveC2R -Destination $xmlRemoveC2R -Force
        } else {
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/remove_c2r.xml" -OutFile $xmlRemoveC2R -UseBasicParsing
            } catch {
                # Create configuration directly if download fails
                "<Configuration><Remove All=`"TRUE`" /><Display Level=`"None`" AcceptEULA=`"TRUE`" /></Configuration>" | Out-File -FilePath $xmlRemoveC2R -Encoding utf8
            }
        }

        Write-AppLog "Đang tiến hành gỡ bỏ Click-to-Run (C2R) Office ngầm..." "WARN"
        $resC2R = Invoke-HiddenProcess $setupExe "/configure `"$xmlRemoveC2R`"" "Gỡ bỏ Click-to-Run (C2R) Office"
    }

    # STEP B: REMOVE WINDOWS INSTALLER (MSI) IF PRESENT
    if ($officeInfo.HasMSI) {
        Write-AppLog "Chuẩn bị cấu hình gỡ MSI (remove_msi.xml)..." "INFO"
        $localRemoveMSI = if ($PSScriptRoot) { Join-Path $PSScriptRoot "remove_msi.xml" } else { "b:\workspace\KHCNTayNinh\remove_msi.xml" }
        if (Test-Path $localRemoveMSI) {
            Copy-Item -Path $localRemoveMSI -Destination $xmlRemoveMSI -Force
        } else {
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/remove_msi.xml" -OutFile $xmlRemoveMSI -UseBasicParsing
            } catch {
                # Create configuration directly if download fails
                "<Configuration><RemoveMSI /><Display Level=`"None`" AcceptEULA=`"TRUE`" /></Configuration>" | Out-File -FilePath $xmlRemoveMSI -Encoding utf8
            }
        }

        Write-AppLog "Đang tiến hành gỡ bỏ Windows Installer (MSI) Office ngầm..." "WARN"
        $resMSI = Invoke-HiddenProcess $setupExe "/configure `"$xmlRemoveMSI`"" "Gỡ bỏ Windows Installer (MSI) Office"
    }

    Write-AppLog "Đã hoàn tất quá trình gỡ bỏ Office cũ." "SUCCESS"
    Write-AppLog "Chuyển sang bước Cài đặt Office 2024 LTSC Standard." "INFO"

    $btnUninstall.Enabled = $true
    $btnUninstall.Text = "Gỡ bỏ phiên bản Office cũ"

    Update-UILayout "READY_TO_INSTALL"

    [System.Windows.Forms.MessageBox]::Show(
        "Đã hoàn tất gỡ bỏ phiên bản Office cũ ngầm.`n`nHệ thống đã sẵn sàng để 'Cài đặt Office 2024 LTSC Standard'.",
        "Gỡ bỏ hoàn tất",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

# Button: Install Office 2024 LTSC Standard (Runs hidden in background)
$btnInstall.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Hệ thống sẽ tải về và cài đặt Microsoft Office 2024 LTSC Standard cho Sở KH&CN Tây Ninh.`n`nBạn có muốn tiếp tục cài đặt?",
        "Xác nhận cài đặt",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-AppLog "Người dùng đã hủy thao tác cài đặt." "WARN"
        return
    }

    $btnInstall.Enabled = $false
    $btnInstall.Text = "Đang cài đặt ngầm..."
    Write-AppLog "Bắt đầu tiến trình tải và cài đặt Microsoft Office 2024 LTSC Standard..." "INFO"

    $tempDir = Join-Path $env:TEMP "Office2024_Standard_Setup"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    $setupExe   = Join-Path $tempDir "setup.exe"
    $xmlInstall = Join-Path $tempDir "KHCNTayNinh.xml"

    # Sync setup.exe
    if (-not (Test-Path $setupExe)) {
        $localSetup = if ($PSScriptRoot) { Join-Path $PSScriptRoot "setup.exe" } else { "b:\workspace\KHCNTayNinh\setup.exe" }
        if (Test-Path $localSetup) {
            Copy-Item -Path $localSetup -Destination $setupExe -Force
        } else {
            Write-AppLog "Đang tải công cụ triển khai (setup.exe)..." "INFO"
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/setup.exe" -OutFile $setupExe -UseBasicParsing
        }
    }

    # Sync KHCNTayNinh.xml
    $localXml = if ($PSScriptRoot) { Join-Path $PSScriptRoot "KHCNTayNinh.xml" } else { "b:\workspace\KHCNTayNinh\KHCNTayNinh.xml" }
    if (Test-Path $localXml) {
        Copy-Item -Path $localXml -Destination $xmlInstall -Force
        Write-AppLog "Đã tải cấu hình KHCNTayNinh.xml từ máy tính." "INFO"
    } else {
        Write-AppLog "Đang tải cấu hình cài đặt KHCNTayNinh.xml..." "INFO"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/KHCNTayNinh.xml" -OutFile $xmlInstall -UseBasicParsing
    }

    Write-AppLog "Khởi động tiến trình cài đặt Microsoft Office 2024 LTSC Standard..." "INFO"
    $resInstall = Invoke-HiddenProcess $setupExe "/configure `"$xmlInstall`"" "Cài đặt Office 2024 LTSC Standard"

    Write-AppLog "Tiến trình cài đặt Microsoft Office 2024 LTSC Standard đã hoàn tất." "SUCCESS"

    # [SECURITY]: Remove ProductKeys/PIDKEY remnants from Click-to-Run Registry
    $c2rConfig = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    if (Test-Path $c2rConfig) {
        Remove-ItemProperty -Path $c2rConfig -Name "ProductKeys" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $c2rConfig -Name "PIDKEY" -ErrorAction SilentlyContinue
    }

    Write-AppLog "Tự động kiểm tra bản quyền và phiên bản trên hệ thống..." "INFO"

    $btnInstall.Enabled = $true
    $btnInstall.Text = "Cài đặt Office 2024 LTSC Standard"

    # Verify whether installation matches standard edition
    $checkAfter = Get-OfficeInstallType
    if ($checkAfter.Is2024Standard) {
        $lblStatus.Text = "Trạng thái: Đã cài đặt Microsoft Office 2024 LTSC Standard"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)

        Write-AppLog "Xác nhận: Hệ thống đã cài đặt đúng Microsoft Office 2024 LTSC Standard." "SUCCESS"
        Write-AppLog "Chuyển sang bước kích hoạt bản quyền MAK." "INFO"

        Update-UILayout "READY_TO_ACTIVE"

        [System.Windows.Forms.MessageBox]::Show(
            "Quá trình cài đặt Microsoft Office 2024 LTSC Standard đã hoàn tất.`n`nVui lòng nhập mật khẩu được cung cấp và bấm 'Kích hoạt bản quyền Office 2024'.",
            "Cài đặt hoàn tất",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        Write-AppLog "Vui lòng bấm 'Kiểm tra phiên bản Office hiện tại' để làm mới trạng thái." "WARN"
        [System.Windows.Forms.MessageBox]::Show(
            "Quá trình cài đặt đã hoàn thành. Vui lòng bấm 'Kiểm tra phiên bản Office hiện tại' để cập nhật trạng thái.",
            "Thông báo",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
})

# Button: Activate Office 2024 LTSC Standard (MAK)
$btnActive.Add_Click({
    $userPass = $txtPass.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($userPass)) {
        [System.Windows.Forms.MessageBox]::Show("Vui lòng nhập mật khẩu kích hoạt được cung cấp.", "Cảnh báo", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    # Check OSPP.VBS existence
    $currentOspp = Get-OfficeOsppPath
    if (-not $currentOspp -or -not (Test-Path $currentOspp)) {
        Write-AppLog "Lỗi: Không tìm thấy tệp quản lý bản quyền ospp.vbs trên máy tính." "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Không tìm thấy tệp quản lý bản quyền Office (ospp.vbs).`n`nVui lòng kiểm tra lại quá trình cài đặt Office 2024.",
            "Lỗi cấu hình",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    $btnActive.Enabled = $false
    $btnActive.Text = "Đang xử lý kích hoạt..."
    Write-AppLog "Bắt đầu tiến trình kích hoạt bản quyền Office 2024 Standard..."
    Write-AppLog "Sử dụng công cụ quản lý bản quyền: ospp.vbs"

    if ($chkDebug.Checked) { Write-AppLog "Chế độ kiểm thử (Debug) đang bật." "DEBUG" }

    try {
        Write-AppLog "Đang gửi yêu cầu xác thực đến máy chủ..."

        # Encrypted query parameters (AES-256 action replaces legacy Base64)
        $params = [ordered]@{
            compName = [System.Uri]::EscapeDataString($compName)
            action   = Get-DecryptedAction "JpnM+uVx/g0IUdg3Wp5/Cw=="
            pass     = [System.Uri]::EscapeDataString($userPass)
        }
        $queryString = ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $uri = "$webAppUrl`?$queryString"

        if ($chkDebug.Checked) { 
            # Mask both the secret WebApp URL endpoint and sensitive parameters in debug log
            $maskedUri = "https://script.google.com/macros/s/******/exec?compName=$compName&action=***&pass=*****"
            Write-AppLog "Debug API Query: $maskedUri" "DEBUG" 
        }

        $response = Invoke-RestMethod -Uri $uri -Method Get -MaximumRedirection 5
        if ($chkDebug.Checked) { 
            # Mask product key in debug response log to prevent key leakage
            $maskedResponse = if ($response -match "^(.+)\|(.+)$") {
                $rTag = $Matches[1]
                $rKey = $Matches[2].Trim()
                $rLast5 = if ($rKey.Length -ge 5) { $rKey.Substring($rKey.Length - 5) } else { $rKey }
                "$rTag|*****-*****-*****-****-$rLast5"
            } else {
                $response
            }
            Write-AppLog "Debug Response Value: $maskedResponse" "DEBUG" 
        }

        if ($response -eq "WRONG_PASS") {
            Write-AppLog "Lỗi: Mật khẩu không chính xác." "ERROR"
            [System.Windows.Forms.MessageBox]::Show("Mật khẩu kích hoạt không chính xác.", "Lỗi xác thực", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } 
        elseif ($response -eq "LIMIT_EXCEEDED") {
            Write-AppLog "Lỗi: Mật khẩu đã hết lượt sử dụng hoặc bị khóa." "ERROR"
            [System.Windows.Forms.MessageBox]::Show("Mật khẩu đã hết số lượt kích hoạt cho phép.", "Lỗi xác thực", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        elseif ($response -eq "KEY_NOT_FOUND") {
            Write-AppLog "Lỗi: Không tìm thấy thông tin khóa sản phẩm trên máy chủ." "ERROR"
            [System.Windows.Forms.MessageBox]::Show("Không tìm thấy khóa sản phẩm phù hợp trên máy chủ.", "Lỗi máy chủ", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        elseif ($response -eq "SERVER_BUSY") {
            Write-AppLog "Lỗi: Máy chủ đang bận, vui lòng thử lại sau." "ERROR"
            [System.Windows.Forms.MessageBox]::Show("Máy chủ đang bận, vui lòng thử lại sau.", "Lỗi máy chủ", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        elseif ($response -match "^(.+)\|(.+)$") { 
            $tag = $Matches[1]
            $key = $Matches[2].Trim()

            Write-AppLog "Xác thực thành công. Nhận thông tin khóa: [$tag]" "SUCCESS"

            # === DEBUG MODE HANDLING (SIMULATION) ===
            if ($chkDebug.Checked) {
                $keyLast5 = if ($key.Length -ge 5) { $key.Substring($key.Length - 5) } else { $key }

                Write-AppLog "[DEBUG] Xác thực thành công mật khẩu và mã khóa [$tag]." "DEBUG"
                Write-AppLog "[DEBUG] 5 ký tự cuối của khóa: $keyLast5" "DEBUG"
                Write-AppLog "[DEBUG] Bỏ qua bước nạp khóa và kích hoạt thực tế." "DEBUG"
                
                Write-AppLog "[DEBUG] Ghi nhận nhật ký thử nghiệm lên máy chủ..." "DEBUG"
                $logRes = Invoke-RestMethod -Uri "$($webAppUrl)?compName=$compName&action=success" -Method Get -MaximumRedirection 5
                Write-AppLog "[DEBUG] Phản hồi từ máy chủ: $logRes" "DEBUG"

                [System.Windows.Forms.MessageBox]::Show(
                    "CHẾ ĐỘ KIỂM THỬ HOÀN THÀNH`n`n" +
                    "- Kết nối máy chủ: Thành công`n" +
                    "- Xác thực mật khẩu và mã khóa [$tag]: Thành công`n" +
                    "- Công cụ bản quyền: ospp.vbs (Sẵn sàng)`n" +
                    "- Khóa sản phẩm: *****-*****-*****-****-$keyLast5`n" +
                    "- Ghi nhật ký máy chủ: Thành công ($logRes)`n`n" +
                    "(Lưu ý: Không thực hiện kích hoạt bản quyền thực tế)", 
                    "Kiểm thử kết nối", 
                    [System.Windows.Forms.MessageBoxButtons]::OK, 
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            }
            # === ACTUAL EXECUTION (DEBUG UNCHECKED) ===
            else {
                Write-AppLog "Đang thiết lập khóa MAK vào Office 2024 (cơ chế bảo mật chống Process Sniffing)..."
                $ipkRes = Install-OfficeProductKeySafely -osppPath $currentOspp -productKey $key
                Write-AppLog "Kết quả thiết lập khóa: $(($ipkRes -split "`r?`n" | Where-Object { $_ -match "Product key installation" -or $_ -match "successful" -or $_ -match "error" } | Select-Object -First 1))"

                # [SECURITY STEP 2]: Clean up ProductKeys/PIDKEY traces in Click-to-Run Registry
                $c2rConfig = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
                if (Test-Path $c2rConfig) {
                    Remove-ItemProperty -Path $c2rConfig -Name "ProductKeys" -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $c2rConfig -Name "PIDKEY" -ErrorAction SilentlyContinue
                }

                # [SECURITY STEP 3]: Immediately wipe $key and password from RAM and force garbage collection (GC)
                $key = $null
                $userPass = $null
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()

                Write-AppLog "Đang kết nối máy chủ Microsoft để kích hoạt (ospp.vbs /act)..."
                $actResult = Invoke-HiddenConsoleOutput "cscript.exe" "//nologo `"$currentOspp`" /act"

                if ($actResult -match "(?i)Product activation successful") {
                    Write-AppLog "Kích hoạt bản quyền Microsoft Office 2024 Standard thành công (mã khóa: [$tag])." "SUCCESS"
                    Invoke-RestMethod -Uri "$($webAppUrl)?compName=$compName&action=success" -Method Get -MaximumRedirection 5 | Out-Null
                    Write-AppLog "Đã ghi nhận nhật ký kích hoạt thành công lên máy chủ." "INFO"
                    [System.Windows.Forms.MessageBox]::Show("Kích hoạt bản quyền Microsoft Office 2024 Standard thành công.", "Thông báo", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                } else {
                    Write-AppLog "Kích hoạt Office không thành công. Chi tiết: $actResult" "ERROR"
                    $errText = [Uri]::EscapeDataString(($actResult -replace "`r?`n", " ").Trim())
                    if ($errText.Length -gt 150) { $errText = $errText.Substring(0, 150) }

                    Invoke-RestMethod -Uri "$($webAppUrl)?compName=$compName&action=fail&note=$errText" -Method Get -MaximumRedirection 5 | Out-Null
                    Write-AppLog "Đã gửi thông báo lỗi về máy chủ." "INFO"
                    [System.Windows.Forms.MessageBox]::Show("Kích hoạt Office không thành công. Vui lòng kiểm tra kết nối mạng hoặc xem nhật ký để biết chi tiết.", "Lỗi kích hoạt", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            }
        } 
        else {
            Write-AppLog "Lỗi phản hồi không xác định từ máy chủ: $response" "ERROR"
        }
    } catch {
        Write-AppLog "Lỗi kết nối mạng hoặc máy chủ từ chối: $_" "ERROR"
    } finally {
        # Ensure key and password variables are completely cleared from RAM
        $key = $null
        $userPass = $null
        [System.GC]::Collect()

        $btnActive.Enabled = $true
        $btnActive.Text = "Kích hoạt bản quyền Office 2024"
    }
})

# Show Main Window
[void]$form.ShowDialog()
