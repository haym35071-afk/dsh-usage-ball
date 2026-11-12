# 在当前目录的安装位置创建桌面 / 开始菜单快捷方式
$ErrorActionPreference = 'SilentlyContinue'
$dest = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $dest 'start.vbs'
if (-not (Test-Path $target)) { exit 1 }

$shell = New-Object -ComObject WScript.Shell
$places = @(
  [Environment]::GetFolderPath('Desktop'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH 用量悬浮球')
)
foreach ($dir in $places) {
  if (-not $dir) { continue }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lnk = Join-Path $dir 'DSH 用量悬浮球.lnk'
  $shortcut = $shell.CreateShortcut($lnk)
  $shortcut.TargetPath = 'wscript.exe'
  $shortcut.Arguments = '"' + $target + '"'
  $shortcut.WorkingDirectory = $dest
  $shortcut.Description = 'DSH 用量悬浮球'
  $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
  $shortcut.Save()
}
