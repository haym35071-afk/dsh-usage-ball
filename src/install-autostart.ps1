# 开机自启：在启动文件夹里放一个指向 start.vbs 的快捷方式
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'DSH 用量悬浮窗.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = 'wscript.exe'
$shortcut.Arguments = '"' + (Join-Path $here 'start.vbs') + '"'
$shortcut.WorkingDirectory = $here
$shortcut.Description = 'DSH 用量悬浮窗'
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
$shortcut.Save()
Write-Output "已加入开机自启：$lnk"
