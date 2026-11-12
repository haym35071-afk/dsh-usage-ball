' DSH 用量悬浮窗：静默启动，不留控制台窗口
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "widget.ps1")
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = here
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & script & """", 0, False
