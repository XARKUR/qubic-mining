# Changelog

## Unreleased

- JetSki Linux 安装改用官方无版本号的 `qubjetski-latest.tar.gz`，PPLNS/Solo 通过配置参数切换；旧 PPLNS/版本化包自动迁移，并固定当前包 SHA-256 作为离线校验回退。
- 安装器启动时在环境检查前显示 QOOLS ASCII 标识。
- 新增 `--alias-ip`；交互式矿工名提示也可输入 `ip`，用本机 IPv4 命名矿工，适用于 QLI、JetSki 和 Minerlab。
- 新下载矿工后展示来源 URL、发布方参考地址、实际/预期 SHA-256 及对比结果；交互模式确认后才安装，`--yes` 保持自动化行为，hash 不一致仍直接拒绝。
- 在 README 中说明下载来源和校验边界；发布包 SHA-256 改为可移植的相对文件名，CI 的 checkout Action 固定到准确提交。
- 项目原创源码和文档采用 MIT License；第三方矿工客户端与 worker 继续遵循各自上游条款。
- 完成真实上游无启动安装验证；固定已审查的 QLI 3.8.10 SHA-256，并将离线版本检查回退更新到 3.8.10。
- 拒绝符号链接运行目录和安装锁，为归档增加重复条目、条目数量、单文件及总解压大小限制。
- 本地参数校验先于上游查询，精简非交互下载日志，并让 dry-run 与 no-start 结果明确区分“读取发布元数据”“完成安装”和“已经启动”。
- 清理 ShellCheck 警告，并避免发布包源码摘要文件在生成时参与自己的输入列表。
- 提供 QLI、JetSki 和 Minerlab 的单文件轻量安装流程。
- Minerlab 迁移到独立 QLAB.Z 4.1 客户端和新版配置 schema，不再使用 QLI accessToken profile。
- 增加参数校验、下载来源白名单、SHA-256 完整性校验和安全解压。
- 增加原子配置替换、安装锁、精确进程识别、状态、监控和有界停止。
- 修复 JetSki 在 PPLNS/Solo 之间切换时复用错误模式包的问题。
- 修复停止旧矿工失败后仍改写正式配置和安装文件的问题。
- 拒绝会产生无效 JSON 的前导零线程数。
- 移除旧 systemd/sudo 安装入口和发布树中的第三方闭源二进制。
- 增加 GitHub Actions 测试和固定白名单发布打包脚本。
- 快速回归测试复制安装器到 `/tmp` 沙箱运行，真实 miner 正在运行时不会触发单实例保护造成误报。
- 支持从 GitHub Raw 流式运行，并在未保存脚本文件时输出可复用的远程状态和停止命令。
- 根目录提供中文 `README.zh-CN.md` 和英文 `README.md`，发布包同时包含两种语言。
