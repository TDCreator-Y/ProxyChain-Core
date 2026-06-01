# Debug Session: windows-admin-script

- Status: OPEN
- Symptom: `run_windows_admin.ps1` 运行后报错，且管理员 PowerShell 窗口自动关闭，无法完整查看错误输出。
- Scope: 先添加最小化保活与日志，随后复现、定位根因、修复并验证。

## Hypotheses

1. 管理员重启流程将参数转发给 `powershell.exe` 时，参数引用或剩余参数拼接方式有问题，导致脚本在重启后阶段异常。
2. `flutter` 命令解析或 PATH 继承在提权后的进程中失效，导致 `Get-FlutterCommand` 抛错。
3. `flutter run -d windows` 或 `flutter build windows` 在项目环境中失败，但脚本缺少显式异常捕获和持久化日志，因此窗口直接关闭。
4. 脚本退出码与 `finally` / `exit` 配合方式导致错误信息来不及保留，用户只能观察到窗口闪退。
5. 项目根目录、工作目录或附加参数传递与真实执行环境不一致，触发下游命令错误。

## Evidence

1. 首轮插桩复现显示脚本在 `Write-Log -> Add-Content` 阶段失败，原因为 `Start-Transcript` 与事件日志写入同一文件导致文件占用。
2. 修正日志冲突后，父进程提权链路正常，管理员子进程成功启动并解析到 `flutter.bat`。
3. 管理员子进程首次真实失败点位于 `flutter run -d windows` 的 Rust 编译阶段，日志包含：
   - `error[E0425]: cannot find type Ipv4Addr in this scope`
   - `error[E0603]: struct FakeIpState is private`
   - `error[E0616]: field ... of struct FakeIpState is private`
4. 直接执行 `flutter_rust_bridge_codegen generate` 同样失败，报 `Os { code: 0, kind: Uncategorized, message: "操作成功完成。" }`，说明自动重生桥接代码在当前 Windows 环境不可依赖。
5. 手工补齐 FRB 生成 Rust 文件的 `Ipv4Addr` 引用，并公开 `FakeIpState` 后，`flutter run -d windows` 成功启动应用，`flutter build windows` 成功产出可执行文件。

## Fixes

1. `run_windows_admin.ps1`
   - 新增事件日志与转录日志
   - 新增统一异常捕获、退出码记录、失败位置记录
   - 默认退出前暂停，支持 `-NoPause`
   - 修复提权后未透传 `-NoPause` 的问题
2. `core_rust/src/api/tun_proxy.rs`
   - 将 `FakeIpState` 及其字段公开，满足现有 FRB 生成代码访问要求
3. `core_rust/src/frb_generated.rs`
   - 补充 `std::net::Ipv4Addr` 导入，修复生成文件缺失类型引用

## Plan

1. 给脚本添加非业务逻辑的调试插桩：日志、错误捕获、暂停保活。
2. 运行脚本并记录完整输出、退出码、报错节点。
3. 根据证据确认假设，实施最小修复。
4. 重复验证管理员窗口保活与正常执行路径。

## Status

- Current: FIXED
- Cleanup: 保留调试日志增强，便于后续排障；未移除调试痕迹。
