$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'WindowVM'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ClipboardAgent.ps1') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bridge.json') -Destination $destination -Force
$displayControl = Join-Path $PSScriptRoot 'DisplayControl.cs'
if (Test-Path -LiteralPath $displayControl) { Copy-Item -LiteralPath $displayControl -Destination $destination -Force }
$displayDriver = Join-Path $PSScriptRoot 'DisplayDriver'
if (Test-Path -LiteralPath $displayDriver) { Copy-Item -LiteralPath $displayDriver -Destination $destination -Recurse -Force }
$agent = Join-Path $destination 'ClipboardAgent.ps1'
# Startup folder runs in the current user's interactive session; no administrator required.
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $startup 'WindowVM Clipboard.lnk'))
$link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$link.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agent + '"'
$link.WindowStyle = 7
$link.WorkingDirectory = $destination
$link.Save()
# Replace only our previously launched agent after a host port/token update.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
  $_.ProcessId -ne $PID -and $_.CommandLine -like ('*' + $agent + '*')
} | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
Start-Process -FilePath $link.TargetPath -ArgumentList $link.Arguments -WindowStyle Hidden
Write-Host 'Clipboard installed. It starts automatically when you sign in.'
Write-Host 'To remove: delete WindowVM Clipboard.lnk from shell:startup, then sign out.'
Read-Host 'Press Enter to close'
