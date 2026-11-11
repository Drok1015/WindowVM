# Runs as the interactive Windows user in an STA PowerShell process.
Add-Type -AssemblyName System.Windows.Forms
Set-Location -LiteralPath $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bridge.json') -Raw | ConvertFrom-Json
$headers = @{ Authorization = ('Bearer ' + $config.token) }
$url = 'http://10.0.2.2:' + $config.port + '/clipboard'
$displayControl = Join-Path $PSScriptRoot 'DisplayControl.cs'
if (Test-Path -LiteralPath $displayControl) { Add-Type -Path $displayControl }
$displayId = ''
$displayDevice = $null
$lastDisplayAttempt = [DateTime]::MinValue
$lastClipboardPoll = [DateTime]::MinValue
$version = -1
$lastText = ''
$initialized = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
while ($true) {
  if ((Test-Path -LiteralPath $displayControl) -and (([DateTime]::UtcNow - $lastDisplayAttempt).TotalMilliseconds -ge 200)) {
    $lastDisplayAttempt = [DateTime]::UtcNow
    try {
      $display = Invoke-RestMethod -Uri ($url.Replace('/clipboard','/display')) -Headers $headers -TimeoutSec 2 -Proxy $null
      if ($display -and $display.id -ne $displayId) {
        $ack = @{ id = $display.id; width = 0; height = 0; success = $false; error = $null }
        try {
          if ($display.width -lt 640 -or $display.width -gt 3840 -or $display.height -lt 480 -or $display.height -gt 2160) { throw 'Invalid display dimensions' }
          if (!$displayDevice) { $displayDevice = [WindowVMDisplay]::EnsurePrimary() }
          [WindowVMDisplay]::SetSize($displayDevice, [int]$display.width, [int]$display.height)
          $actual = [WindowVMDisplay]::Current($displayDevice)
          $ack.width = $actual[0]; $ack.height = $actual[1]
          $ack.success = ($actual[0] -eq $display.width -and $actual[1] -eq $display.height)
          if (!$ack.success) { $ack.error = 'Driver did not apply requested resolution' }
        } catch { $ack.error = $_.Exception.Message; $displayDevice = $null }
        $json = $ack | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri ($url.Replace('/clipboard','/display')) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $utf8.GetBytes($json) -TimeoutSec 2 -Proxy $null | Out-Null
        if ($ack.success) { $displayId = $display.id }
        else { $lastDisplayAttempt = [DateTime]::UtcNow.AddSeconds(2) }
      }
    } catch { }
  }
  if (([DateTime]::UtcNow - $lastClipboardPoll).TotalMilliseconds -lt 700) { Start-Sleep -Milliseconds 100; continue }
  $lastClipboardPoll = [DateTime]::UtcNow
  try {
    $local = [System.Windows.Forms.Clipboard]::GetText()
    # An empty guest clipboard must not overwrite the host clipboard on first connection.
    if ($initialized -and $local -cne $lastText -and $utf8.GetByteCount($local) -le 524288) {
      $payload = @{ baseVersion = $version; text = $local } | ConvertTo-Json -Compress
      $remote = Invoke-RestMethod -Uri $url -Method Put -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $utf8.GetBytes($payload) -TimeoutSec 3 -Proxy $null
    } else {
      $remote = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 3 -Proxy $null
    }
    if ($remote.version -ne $version -or [string]$remote.text -cne $local) {
      # If the clipboard changes during a network request, retry rather than clobber it.
      if ([System.Windows.Forms.Clipboard]::GetText() -cne $local) { continue }
      if ([string]::IsNullOrEmpty($remote.text)) {
        [System.Windows.Forms.Clipboard]::Clear()
      } else {
        [System.Windows.Forms.Clipboard]::SetText([string]$remote.text)
      }
    }
    $version = [int]$remote.version
    $lastText = [System.Windows.Forms.Clipboard]::GetText()
    $initialized = $true
  } catch {
    # A stale write is discarded. Reconnect and fetch the latest host revision.
    $initialized = $false
    $lastClipboardPoll = [DateTime]::UtcNow.AddSeconds(1)
  }
  Start-Sleep -Milliseconds 100
}
