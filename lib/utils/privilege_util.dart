import 'dart:io';

class PrivilegeUtil {
  /// 检查当前进程是否有管理员/Root权限，如果没有，则尝试提权重启并退出当前进程。
  /// 返回 true 表示已经拥有权限，可以继续执行。
  /// 返回 false 表示没有权限，正在执行提权重启，调用方应停止后续逻辑。
  static Future<bool> checkAndElevate() async {
    if (await isElevated()) {
      return true;
    }

    if (Platform.isMacOS) {
      final executable = Platform.resolvedExecutable;
      // 在 macOS 上使用 osascript 请求输入密码并以 root 权限重启当前程序
      final script =
          'do shell script "\"$executable\"" with administrator privileges';
      Process.run('osascript', ['-e', script]);
      // 等待新进程启动后，退出当前非特权进程
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } else if (Platform.isWindows) {
      // Windows 端已经在 runner.exe.manifest 中配置了 requireAdministrator。
      // 如果仍走到这里（例如调试模式下运行），可以尝试通过 PowerShell 的 Start-Process 提权重启
      final executable = Platform.resolvedExecutable;
      Process.run('powershell', [
        '-Command',
        'Start-Process',
        '-FilePath',
        '"$executable"',
        '-Verb',
        'RunAs',
      ]);
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } else if (Platform.isLinux) {
      // Linux 下通常使用 pkexec 或类似工具，这里暂留扩展
      final executable = Platform.resolvedExecutable;
      Process.run('pkexec', [executable]);
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    }

    return false;
  }

  /// 检查当前是否具备管理员权限
  static Future<bool> isElevated() async {
    if (Platform.isWindows) {
      try {
        final result = await Process.run('net', ['session']);
        return result.exitCode == 0;
      } catch (e) {
        return false;
      }
    } else {
      try {
        final result = await Process.run('id', ['-u']);
        return result.stdout.toString().trim() == '0';
      } catch (e) {
        return false;
      }
    }
  }
}
