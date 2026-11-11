param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:LOCALAPPDATA 'WindowVM'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$backup = Join-Path $directory 'proxy-before-windowvm.json'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$names = @('ProxyEnable','ProxyServer','ProxyOverride','AutoConfigURL')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;
public static class WindowVMProxy {
  [StructLayout(LayoutKind.Sequential)] struct List { public int Size; public IntPtr Connection; public int Count, Error; public IntPtr Options; }
  [DllImport("wininet.dll",EntryPoint="InternetSetOptionW",SetLastError=true)] static extern bool Set(IntPtr h,int option,ref List list,int size);
  [DllImport("wininet.dll",EntryPoint="InternetQueryOptionW",SetLastError=true)] static extern bool Query(IntPtr h,int option,ref List list,ref int size);
  [DllImport("wininet.dll",EntryPoint="InternetSetOptionW",SetLastError=true)] static extern bool Refresh(IntPtr h,int option,IntPtr data,int size);
  public static int Flags() {
    IntPtr option=Marshal.AllocHGlobal(16);
    try {
      Marshal.WriteInt32(option,0,10); Marshal.WriteInt32(option,4,0); Marshal.WriteInt64(option,8,0);
      List list=new List();list.Size=Marshal.SizeOf(typeof(List));list.Count=1;list.Options=option;int size=list.Size;
      if (!Query(IntPtr.Zero,75,ref list,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
      return Marshal.ReadInt32(option,8);
    } finally { Marshal.FreeHGlobal(option); }
  }
  public static void Apply(int flags,string server,string bypass,string pac) {
    IntPtr options=Marshal.AllocHGlobal(64);
    IntPtr[] strings={Marshal.StringToHGlobalUni(server ?? ""),Marshal.StringToHGlobalUni(bypass ?? ""),Marshal.StringToHGlobalUni(pac ?? "")};
    try {
      for(int i=0;i<4;i++) {
        Marshal.WriteInt32(options,i*16,i+1);Marshal.WriteInt32(options,i*16+4,0);
        Marshal.WriteIntPtr(options,i*16+8,i==0 ? new IntPtr(flags) : strings[i-1]);
      }
      List list=new List();list.Size=Marshal.SizeOf(typeof(List));list.Count=4;list.Options=options;
      if (!Set(IntPtr.Zero,75,ref list,list.Size)) throw new Win32Exception(Marshal.GetLastWin32Error());
      Refresh(IntPtr.Zero,39,IntPtr.Zero,0);Refresh(IntPtr.Zero,37,IntPtr.Zero,0);
    } finally { foreach(IntPtr value in strings) Marshal.FreeHGlobal(value);Marshal.FreeHGlobal(options); }
  }
}
'@
if ($Restore) {
  if (!(Test-Path -LiteralPath $backup)) { throw 'No previous proxy backup exists.' }
  $old = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
  $flags = if ($null -ne $old.connectionFlags) { [int]$old.connectionFlags } else { 1 }
  [WindowVMProxy]::Apply($flags,[string]$old.ProxyServer.value,[string]$old.ProxyOverride.value,[string]$old.AutoConfigURL.value)
  foreach ($name in $names) {
    if ($old.$name.present) {
      $type = if ($name -eq 'ProxyEnable') { 'DWord' } else { 'String' }
      New-ItemProperty -Path $key -Name $name -Value $old.$name.value -PropertyType $type -Force | Out-Null
    } else { Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue }
  }
} else {
  $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bridge.json') -Raw | ConvertFrom-Json
  if (!$config.proxy.server) { throw 'No explicit HTTP/HTTPS host system proxy. Enable the Mac system proxy and restart the VM first.' }
  Write-Host ('Testing host proxy: ' + $config.proxy.testProxy)
  $result = & curl.exe --silent --show-error --proxy $config.proxy.testProxy --max-time 20 --output NUL --write-out '%{http_code}' https://www.google.com/generate_204
  if ($LASTEXITCODE -ne 0 -or $result -ne '204') { throw ('Host proxy HTTPS test failed: ' + $result) }
  if (!(Test-Path -LiteralPath $backup)) {
    $current = Get-ItemProperty -Path $key
    $old = @{ connectionFlags = [WindowVMProxy]::Flags() }
    foreach ($name in $names) {
      $property = $current.PSObject.Properties[$name]
      $old[$name] = @{ present = ($null -ne $property); value = $(if ($property) { $property.Value } else { $null }) }
    }
    $old | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backup -Encoding UTF8
  }
  # Migrate a backup created by the initial registry-only installer.
  $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
  if ($null -eq $saved.connectionFlags) {
    $flags = 1 -bor ([WindowVMProxy]::Flags() -band 8)
    if ($saved.ProxyEnable.value) { $flags = $flags -bor 2 }
    if ($saved.AutoConfigURL.value) { $flags = $flags -bor 4 }
    $saved | Add-Member -NotePropertyName connectionFlags -NotePropertyValue $flags
    $saved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backup -Encoding UTF8
  }
  [WindowVMProxy]::Apply(3,[string]$config.proxy.server,[string]$config.proxy.bypass,'')
  if (([WindowVMProxy]::Flags() -band 2) -eq 0) { throw 'Windows did not activate the native browser proxy.' }
  Write-Host 'Native Windows LAN connection proxy enabled.'
  New-ItemProperty -Path $key -Name ProxyEnable -Value 1 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $key -Name ProxyServer -Value $config.proxy.server -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $key -Name ProxyOverride -Value $config.proxy.bypass -PropertyType String -Force | Out-Null
  Remove-ItemProperty -Path $key -Name AutoConfigURL -ErrorAction SilentlyContinue
  Write-Host ('Windows browser/system proxy: ' + $config.proxy.server)
  Write-Host 'PASS: HTTPS through host proxy returned HTTP 204. Local VM/host addresses bypass the proxy.'
}
Write-Host 'Proxy settings applied for the current user. RestoreProxy.cmd restores the previous values.'
Read-Host 'Press Enter to close'
