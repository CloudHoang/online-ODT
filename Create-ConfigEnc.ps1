# ==============================================================================
# CÔNG CỤ TẠO VÀ MÃ HÓA CẤU HÌNH TỪ XA (CONFIG.ENC) CHO GITHUB
# Dự án: Kích hoạt Microsoft Office 2024 LTSC - Sở KH&CN Tây Ninh
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   CÔNG CỤ TẠO TỆP CẤU HÌNH BẢO MẬT (config.enc) CHO GITHUB     " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Công cụ này sẽ đóng gói đồng thời 2 đường dẫn nhạy cảm thành tệp"
Write-Host "mã hóa 'config.enc' để bạn đẩy lên kho lưu trữ GitHub."
Write-Host ""

# Giá trị mặc định hiện tại
$defaultWebApp = "https://script.google.com/macros/s/AKfycbxpy_kT8E4WSV1rhWgbZ2-35f_IdxHwMVCSOMPfPVHnFsZZuJc8P3fPUkxVqpzmpvNXrw/exec"
$defaultScript = "https://raw.githubusercontent.com/CloudHoang/online-ODT/main/KHCNTayNinh_Office_Active.ps1"

# 1. Nhập WebApp URL
Write-Host "1. Nhập Google Apps Script Web App URL:" -ForegroundColor Green
Write-Host "   [Mặc định: $defaultWebApp]" -ForegroundColor DarkGray
$inputWebApp = Read-Host "   Nhập URL (hoặc nhấn Enter để dùng mặc định)"
$finalWebApp = if ([string]::IsNullOrWhiteSpace($inputWebApp)) { $defaultWebApp } else { $inputWebApp.Trim() }

Write-Host ""

# 2. Nhập Script URL
Write-Host "2. Nhập GitHub Raw Script URL:" -ForegroundColor Green
Write-Host "   [Mặc định: $defaultScript]" -ForegroundColor DarkGray
$inputScript = Read-Host "   Nhập URL (hoặc nhấn Enter để dùng mặc định)"
$finalScript = if ([string]::IsNullOrWhiteSpace($inputScript)) { $defaultScript } else { $inputScript.Trim() }

Write-Host ""
Write-Host "--- THÔNG TIN CẤU HÌNH ĐÃ CHỌN ---" -ForegroundColor Cyan
Write-Host "-> webAppUrl: $finalWebApp"
Write-Host "-> scriptUrl: $finalScript"
Write-Host "---------------------------------" -ForegroundColor Cyan

# 3. Tạo cấu trúc dữ liệu JSON
$configObject = [ordered]@{
    webAppUrl = $finalWebApp
    scriptUrl = $finalScript
    updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

$jsonText = $configObject | ConvertTo-Json -Compress

# 4. Mã hóa Base64 UTF-8
$jsonBytes  = [System.Text.Encoding]::UTF8.GetBytes($jsonText)
$encPayload = [System.Convert]::ToBase64String($jsonBytes)

# 5. Xuất ra tệp config.enc cùng thư mục
$outputFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot "config.enc" } else { Join-Path (Get-Location) "config.enc" }
[System.IO.File]::WriteAllText($outputFile, $encPayload, [System.Text.Encoding]::ASCII)

Write-Host ""
Write-Host "[THÀNH CÔNG] Đã tạo tệp cấu hình mã hóa thành công!" -ForegroundColor Green
Write-Host "-> Vị trí tệp: $outputFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "--- NỘI DUNG MÃ HÓA CỦA config.enc ---" -ForegroundColor DarkCyan
Write-Host $encPayload -ForegroundColor White
Write-Host "--------------------------------------" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "HƯỚNG DẪN TIẾP THEO:" -ForegroundColor Yellow
Write-Host "1. Đẩy tệp 'config.enc' này lên nhánh 'main' của repo GitHub (CloudHoang/online-ODT)."
Write-Host "2. Đường dẫn công khai sẽ là:"
Write-Host "   https://raw.githubusercontent.com/CloudHoang/online-ODT/main/config.enc" -ForegroundColor Cyan
Write-Host "3. Bất cứ khi nào bạn muốn đổi Google Sheet hay link Script, chỉ cần chạy lại"
Write-Host "   công cụ này và đẩy tệp config.enc mới lên GitHub!"
Write-Host ""
pause
