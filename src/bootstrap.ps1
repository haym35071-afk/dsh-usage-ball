$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'DshUsageBall'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$names = @(
  'widget.ps1', 'collect.mjs', 'config.json', 'start.vbs', 'start.cmd',
  'install-autostart.cmd', 'install-autostart.ps1',
  'uninstall-autostart.cmd', 'uninstall-autostart.ps1',
  'install-shortcuts.ps1', 'README.txt'
)
foreach ($n in $names) {
  $f = Join-Path $src $n
  if (Test-Path $f) { Copy-Item $f (Join-Path $dest $n) -Force }
}

Write-Host ''
Write-Host ('  Installed to ' + $dest) -ForegroundColor Green
Write-Host '  Shortcut: Desktop / Start Menu -> DSH Usage Ball'
Write-Host ''

if ($env:DSH_BALL_TEST -eq '1') { exit 0 }

& powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $dest 'install-shortcuts.ps1')
$vbs = Join-Path $dest 'start.vbs'
$q = [char]34
Start-Process 'wscript.exe' -ArgumentList ($q + $vbs + $q)
Start-Sleep -Seconds 2
