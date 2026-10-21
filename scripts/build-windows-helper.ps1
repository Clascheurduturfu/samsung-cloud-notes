$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot)
try {
    $iconPath = Join-Path (Get-Location) 'Assets/AppIcon.ico'
    $noticesPath = Join-Path (Get-Location) 'docs/third-party'
    $licensePath = Join-Path (Get-Location) 'LICENSE'
    $noticeSummary = Join-Path (Get-Location) 'docs/THIRD_PARTY_NOTICES.md'
    python -m PyInstaller --noconfirm --clean --onefile --windowed --name SamsungNotesConnection --icon $iconPath --add-data "$iconPath;Assets" --add-data "$noticesPath;notices" --add-data "$licensePath;notices" --add-data "$noticeSummary;notices" --collect-all frida --hidden-import win32crypt --distpath dist/windows --workpath dist/windows-build --specpath dist scripts/connection_helper.py
    if ($LASTEXITCODE -ne 0) { throw 'Windows helper build failed' }
} finally { Pop-Location }
