$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
  exit
}
$driver = Join-Path $PSScriptRoot 'DisplayDriver\viogpudo.inf'
& pnputil.exe /add-driver $driver /install
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw ('Display driver installation failed: ' + $LASTEXITCODE) }
Write-Host 'ARM64 VirtIO GPU driver staged/installed. Run Install.cmd as the normal desktop user to update the guest agent.'
Write-Host 'Restart Windows from the WindowVM app after updating the engine.'
Read-Host 'Press Enter to close'
