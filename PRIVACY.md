# 隐私说明

DSH 用量悬浮球是一个**纯本地**的小工具。

## 它读取什么

- `%USERPROFILE%\.dsh\sessions` 下的会话日志（JSONL + zstd），用于统计 token 用量与费用
- 当前前台 DeepSeek Harness 窗口的位置和大小，用于把小球贴在窗口里

## 它写入什么

只写自己的安装目录：

- `state.json`：聚合后的用量快照
- `.cache.json`：按会话文件 mtime/size 的增量缓存
- `pos.json`：小球位置、缩放、收起/展开状态
- `widget.log`：启动与错误诊断

## 它不做什么

- 不读取、不上传你的对话内容
- 不读取 API Key、登录令牌、余额
- 不向任何服务器发送数据（唯一会打开的网页是你主动点击的官方用量页）
- 不修改 DSH 的任何文件或配置
- 不申请管理员权限

## 卸载

1. 右键小球 →「退出悬浮窗」
2. 删除 `%LOCALAPPDATA%\DshUsageBall`
3. 删除桌面 / 开始菜单快捷方式
4. 如开过自启：运行安装目录里的 `uninstall-autostart.cmd`
