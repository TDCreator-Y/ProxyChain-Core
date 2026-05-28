# 🎯 ProxyChain Core

**ProxyChain Core** 是一款基于 `Flutter` + `Rust` 的全平台双重代理级联客户端。专为高阶网络需求用户（如跨境电商、海外社媒运营）打造，旨在提供一套稳定、安全且易于管理的网络隔离与固定 IP 伪装方案。

## ✨ 核心特性 (Features)

*   **双重代理链路 (Dual-Node Relay)**：
    *   **第一跳 (Entry Node)**：常规 VPN/机场节点，负责突破物理网络封锁与跨国路由优化。
    *   **第二跳 (Exit Node)**：纯净独享 ISP 节点，负责最终业务请求的真实、固定 IP 伪装。
*   **全局 TUN 虚拟网卡接管**：底层接管操作系统网络流量，防止流量泄漏。
*   **跨平台原生体验**：采用彻底解耦架构。前端使用 Flutter 呈现极佳的 UI/UX，后端基于 Rust `Tokio` 异步运行时实现极致并发性能与低内存占用。
*   **无缝双向通信**：借助 `flutter_rust_bridge (FRB V2)` 实现前后端强类型、低延迟的无缝通信。

---

## 🏗️ 架构设计 (Architecture)

项目采用 **Monorepo** 结构，贯彻“核心驱动（Rust） + 表现层（Flutter）”彻底解耦的核心思想。

```text
ProxyChain-Core/
├── core_rust/                  # 【Rust 底层核心层】
│   ├── Cargo.toml
│   └── src/
│       ├── api/                # FRB 暴露给前端的公共接口
│       └── lib.rs              # Rust 核心库入口
├── lib/                        # 【Flutter 表现层】
│   ├── src/rust/               # FRB 自动生成的 Dart 绑定代码 (不可手动修改)
│   └── main.dart               # App 启动入口
├── docs/                       # 项目规划与任务清单
├── init_project.ps1            # Windows 桌面端一键初始化及编译脚本
├── flutter_rust_bridge.yaml    # FRB V2 配置文件
└── pubspec.yaml                # Flutter 依赖配置
```

---

## 🚀 快速开始 (Getting Started)

### 1. 环境准备 (Prerequisites)

*   **Flutter SDK**: `^3.x` (请确保 `flutter/bin` 已添加到系统环境变量)
*   **Rust Toolchain**: `rustc 1.95.0` 或更高版本
*   **C++ 构建工具**: Windows 需安装 Visual Studio C++ build tools

### 2. 初始化项目

在 Windows 桌面端，你可以直接运行提供的 PowerShell 脚本，它会自动配置依赖并生成 Dart-Rust 桥接代码：

```powershell
# 在 PowerShell 中执行
.\init_project.ps1
```

*注意：如果在执行桥接代码生成（`flutter_rust_bridge_codegen generate`）时遇到 Rust 宏展开相关的操作系统权限错误（如 `Uncategorized, message: "操作成功完成"`），请暂时关闭杀毒软件或添加白名单，并手动运行 `cargo install cargo-expand`。*

### 3. 编译与运行

在本地根目录执行：

```bash
flutter run -d windows
```

如果配置无误，屏幕正中央将会显示来自 Rust 核心的问候语：`Hello, Flutter Developer! From Rust`。

---

## 🛠️ 开发计划 (Roadmap)

我们遵循“底层先行，UI 后接，逐步联调”的策略，项目规划分为以下阶段：

- [x] **阶段一：基础设施搭建** - 跑通 Flutter 与 Rust 混合编译环境与双向通信。
- [ ] **阶段二：数据模型** - 定义节点 (ProxyNode) 与代理链 (ProxyChain) 的强类型数据结构。
- [ ] **阶段三：Rust 核心代理逻辑** - 实现双节点 Relay 路由逻辑，Tokio 嵌套 TCP Stream 转发。
- [ ] **阶段四：Flutter UI 开发** - 构建 Dashboard 与双层节点链路构建器 (Chain Builder)。
- [ ] **阶段五：联调与 TUN 流量接管** - 开启底层 TUN 虚拟网卡，抓取原始 IP 数据包，打通全局流量。
- [ ] **阶段六：订阅与持久化** - 实现 Base64/YAML 订阅拉取与本地状态 (Isar) 保存。
- [ ] **阶段七：打包发布** - Release 构建与全平台权限配置。

> 详情请查阅 `docs/开发任务清单.md`。

---

## 📚 技术栈 (Tech Stack)

*   **UI 框架**: [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
*   **系统内核**: [Rust](https://www.rust-lang.org/) (Edition 2024)
*   **通信桥梁**: [flutter_rust_bridge V2](https://cjycode.com/flutter_rust_bridge/)
*   **状态管理**: [Riverpod](https://riverpod.dev/)
*   **网络接管**: [tun](https://crates.io/crates/tun) / wintun
*   **异步运行**: [Tokio](https://tokio.rs/)

---

## 📄 许可证 (License)

本项目仅供学习与技术交流使用。
