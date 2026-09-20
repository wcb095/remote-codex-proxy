# Remote Codex Proxy

Windows helper for routing Codex Remote Control through a Clash-compatible HTTP system proxy without requiring Clash TUN.

用于在 Windows 上让 Codex 远程控制通过 Clash 兼容的 HTTP 系统代理连接，并尽量避免依赖 Clash TUN。

> [!IMPORTANT]
> OpenAI documents Remote Control, device pairing, account/workspace requirements, and host availability, but it does **not** document the two proxy modes in this repository as supported product configurations. These are version-dependent compatibility workarounds verified on specific Windows Codex desktop builds. See the [official Remote connections documentation](https://learn.chatgpt.com/docs/remote-connections) and the [official stable environment-variable list](https://learn.chatgpt.com/docs/config-file/environment-variables).

> [!IMPORTANT]
> OpenAI 官方文档说明了远控、设备配对、账号/工作区和主机在线要求，但**没有**把本项目的两种代理方式列为正式产品配置。它们是针对特定 Windows Codex 桌面版本实测得到的兼容方案。请同时参阅[官方远程连接说明](https://learn.chatgpt.com/docs/remote-connections)和[官方稳定环境变量清单](https://learn.chatgpt.com/docs/config-file/environment-variables)。

## 中文说明

### 先判断这台电脑的角色

```text
这台电脑要连接并控制另一台电脑吗？
        │
        ├─ 是：设置 > 连接 > 控制其他设备
        │      使用“控制端强制模式”
        │
        └─ 否：这台电脑要允许另一台电脑控制
               设置 > 连接 > 控制此电脑
               优先使用“被控端轻量模式”
```

两种模式不能在同一台电脑上同时启用。脚本会检测并拒绝混合配置。

### 模式一：控制端强制模式

适用于以下现象：

- Codex 桌面本身可以使用；
- “控制其他设备”能看到目标设备，但显示 `Opening handshake has timed out`；
- 打开 Clash TUN 后恢复，关闭 TUN 后失败；
- 仅设置 `HTTPS_PROXY` 与 `respect_system_proxy` 仍然失败。

链路：

```text
Codex 远控 WebSocket
        ↓ hosts: chatgpt.com -> 127.0.0.1
本地 127.0.0.1:443 TLS 字节转发器
        ↓ HTTP CONNECT
Windows/Clash 系统代理
        ↓
chatgpt.com:443
```

该模式会：

- 自动读取 Windows 当前 HTTP/HTTPS 系统代理，不写死 Clash 端口；
- 自动查找系统 Node.js 或 Codex 自带 Node.js；
- 仅在回环地址 `127.0.0.1:443` 监听；
- 只向 hosts 增加带 `# CodexRemoteProxyTool` 标记的一行；
- 不创建登录启动项、计划任务或 Windows 服务；需要远控时按需启动；
- 在修改 hosts 前保存备份；
- 写 hosts 前完成代理连通和 TLS 握手验证。

转发器只复制仍然加密的 TLS 字节，不终止 TLS，不读取或记录账号令牌、对话、项目文件或远控内容。

### 模式二：被控端轻量模式

适用于开启“控制此电脑”的主机。它会自动执行：

```text
用户环境变量：
HTTPS_PROXY=http://系统代理地址:端口

~/.codex/config.toml：
[features]
respect_system_proxy = true # CodexRemoteProxyTool
```

脚本会保留原来的 `HTTPS_PROXY` 和 `respect_system_proxy` 状态，撤销时只恢复自己修改的内容。如果检测到用户在启用后又手动修改了这些值，脚本会保留较新的用户修改并报告冲突，不会强行覆盖。

轻量模式不会设置 `HTTP_PROXY`、`NO_PROXY` 或 `NODE_USE_ENV_PROXY`。启用或撤销后，必须完全退出 Codex（包括后台进程）再重新启动。

轻量模式不能替代已经验证必须使用强制模式的控制端。

### 使用方法

前置条件：

1. Windows 已安装并登录 ChatGPT/Codex 桌面应用；
2. 两台设备使用同一 ChatGPT 账号和工作区，并已完成远控配对；
3. Clash 已打开“系统代理”；
4. 系统代理必须提供 HTTP CONNECT，Clash mixed-port/HTTP 端口通常满足；
5. TUN 可以保持关闭。

操作：

1. 下载本仓库全部文件，并保持四个运行文件位于同一目录；
2. 双击 `remote-codex-proxy.cmd`；
3. 根据电脑角色选择控制端强制模式或被控端轻量模式；
4. 控制端模式修改 hosts 时会出现 UAC，请核对后确认；
5. 被控端轻量模式启用后，完全退出并重新启动 Codex；
6. 以后需要远控时，选择“立即启动控制端隧道”；不使用时可选择“停止控制端隧道”；
7. 使用菜单中的“检查状态”确认结果；
8. 需要恢复时，选择对应模式的撤销项。

控制端首次启用后，后续需要连接时只需运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action Start
```

`Start` 只启动当前会话所需的本地隧道，不会创建登录启动项。完全不再需要时可使用 `-Action Stop` 暂停隧道，或使用 `DisableController` 同时撤销 hosts 等控制端配置。

也可以直接使用 PowerShell：

```powershell
# 控制端强制模式
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action EnableController
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action Start
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action Stop
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action DisableController

# 被控端轻量模式
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action EnableHost
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action DisableHost

# 状态与自检
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action SelfTest
```

### 本地状态和备份

运行时数据存放在：

```text
%LOCALAPPDATA%\CodexRemoteSystemProxy
├─ app\                         # 控制端安装后的运行副本
├─ backups\                     # hosts 与 config.toml 备份
├─ state.json                   # 控制端强制模式状态
├─ light-state.json             # 被控端轻量模式恢复状态
├─ tunnel.pid
├─ tunnel.stdout.log
└─ tunnel.stderr.log
```

撤销操作会保留备份和日志，便于排查。仓库本身不包含这些运行数据。

### 常见问题

#### Windows System Proxy is disabled

先在 Clash 中打开“系统代理”。本工具不会替你修改 Clash 节点或规则。

#### `127.0.0.1:443` 已被占用

IIS、开发服务器或其他代理可能已经监听 443。脚本会显示占用 PID 并停止，不会结束无关进程。

#### Node.js was not found

先打开一次 Codex，让其运行时安装完成；或者安装 Node.js 18 及以上版本。

#### `config.toml` 有重复 `[features]` 或重复键

脚本不会猜测应该修改哪一段。请先手动合并重复配置，再重新运行。

#### 被控设备仍然没有出现

检查：

- 两台设备是否使用同一账号和工作区；
- 被控端是否开启“允许其他设备连接”；
- 被控端是否在线、未睡眠，并已完全重启 Codex；
- 工作区管理员是否允许 Remote Control；
- 是否需要重新配对设备。

### 实测矩阵

| 角色 | 方案 | TUN | 结果 |
|---|---|---:|---|
| 控制端，“控制其他设备” | hosts + 本地 443 + 系统代理 | 关闭 | 成功 |
| 被控端，“控制此电脑” | `HTTPS_PROXY` + `respect_system_proxy` | 关闭 | 成功 |
| 控制端，“控制其他设备” | 仅轻量方案 | 关闭 | 失败，设备不可读取 |

应用更新后内部网络实现可能改变。如果原本可用的方案失效，请先运行状态检查，并重新对比开启/关闭 TUN 的行为。

## English

### Choose the correct role

- **Controller**: this PC opens **Settings > Connections > Control other devices**. Use controller forced mode when Remote Control times out without TUN.
- **Host**: this PC opens **Settings > Connections > Control this PC** and accepts incoming control. Try host light mode first.

The tool refuses to enable both modes on the same computer.

### Controller forced mode

This mode maps `chatgpt.com` to loopback, listens on `127.0.0.1:443`, and forwards encrypted TLS bytes through the current Windows HTTP proxy using CONNECT. It never terminates TLS and does not log credentials, chats, project files, or Remote Control payloads.

It automatically detects the system proxy and Node.js, verifies the proxy and TLS path before editing hosts, and backs up hosts. It does not install a login startup entry, scheduled task, or Windows service. Run `-Action Start` whenever remote access is needed.

### Host light mode

This mode sets the current user's `HTTPS_PROXY` to the detected Windows system proxy and adds `features.respect_system_proxy = true` to `~/.codex/config.toml`. It records previous values and restores only tool-owned changes.

Completely exit Codex, including background processes, and restart it after enabling or disabling host light mode.

### Quick start

1. Enable **System Proxy** in Clash. TUN may remain off.
2. Keep `remote-codex-proxy.cmd`, `CodexRemoteProxy.ps1`, and `tunnel.cjs` together.
3. Double-click `remote-codex-proxy.cmd`.
4. Select the mode matching this computer's role.
5. Later, select **Start controller tunnel now** whenever remote access is needed, and **Stop controller tunnel** when it is no longer needed.
6. Use **Show status** to verify the result.
7. Use the matching disable option to restore the previous configuration.

After controller mode has been enabled once, start the tunnel on demand with:

```powershell
powershell -ExecutionPolicy Bypass -File .\CodexRemoteProxy.ps1 -Action Start
```

Use `-Action Stop` to stop only the current tunnel process without removing the controller configuration.

### Safety and compatibility

- The listener binds only to `127.0.0.1`.
- Controller mode changes only its marked hosts line and uses an on-demand local tunnel; it creates no automatic startup mechanism.
- Host mode preserves newer user edits instead of overwriting them during rollback.
- No credentials, tokens, logs, backups, or machine-specific paths are included in this repository.
- These workarounds may stop working after a desktop app update because they are not documented OpenAI proxy modes.

## Files

| File | Purpose |
|---|---|
| `remote-codex-proxy.cmd` | Bilingual interactive launcher |
| `CodexRemoteProxy.ps1` | Controller and host configuration, status, rollback, and self-test |
| `tunnel.cjs` | Loopback-only TLS byte tunnel used by controller forced mode |
| `README.md` | Chinese and English documentation |
| `LICENSE` | MIT License |

## License

MIT
