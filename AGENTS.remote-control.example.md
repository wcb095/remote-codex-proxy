# Personal workflows

## Codex Remote Control — unified start on demand

- When the user expresses that they want to connect to, control, view, or use the other computer through Codex Remote Control, treat that request as authorization to start the already-installed unified remote stack on this PC. Typical wording includes “远程控制”, “连接另一台电脑”, “启动远控”, “我要远程控制”, “打开远程连接”, and equivalent wording.
- Start it with:

  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ZhangZJ\AppData\Local\CodexRemoteSystemProxy\app\CodexRemoteProxy.ps1" -Action StartUnified`

- `StartUnified` must bring up and verify both required local components:
  - the controller tunnel on `127.0.0.1:443`;
  - the `codex-chatgpt-web` Responses bridge on `127.0.0.1:17841`.
- Treat the operation as ready only when both listeners are present and managed by the expected processes.
- If `17841` is already served by the expected `codex-chatgpt-web` process, reuse it rather than starting a duplicate.
- If `443` is already served by the expected remote tunnel, reuse it rather than starting a duplicate.
- If either port is occupied by an unrelated process, report the PID and stop; do not terminate the unrelated process automatically.
- If startup fails because the local proxy is unavailable, tell the user to enable Clash “System Proxy”; do not enable Clash TUN or change Clash configuration automatically.
- Start the stack only after the user expresses remote-control intent. Never create or restore a login startup entry, scheduled task, Windows service, or other automatic start mechanism for this stack.
- Do not reinstall or reconfigure controller mode merely to start a stopped stack. Use `-Action StartUnified` first; diagnose only if it fails.
