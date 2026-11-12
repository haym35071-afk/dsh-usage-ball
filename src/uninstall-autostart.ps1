# 取消开机自启：删掉启动文件夹里的快捷方式
$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'DSH 用量悬浮窗.lnk'
if (Test-Path $lnk) {
  Remove-Item $lnk -Force
  Write-Output "已取消开机自启：$lnk"
} else {
  Write-Output "没有找到自启快捷方式，可能未安装过。"
}
