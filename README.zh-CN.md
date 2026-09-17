# Qubic 矿工安装脚本

简体中文 | [English](README.md)

这是适用于 Linux x86_64 的 Bash 安装脚本，支持 QLI、JetSki 和 Minerlab 矿池。每次运行配置一个矿池，下载对应矿工并在后台启动。脚本使用普通用户权限，不安装系统服务，也不设置开机启动。

## 直接运行

```bash
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && bash -c "$miner_script"
```

这条命令直接从 GitHub 运行脚本，不保存项目副本。矿工下载、配置和日志会保存在 `$HOME/qubic-miner`。首次运行先选择语言，再按提示选择矿池和设备。请使用普通用户，不要用 root 执行安装。

提示输入 `miner 名称` 或 `worker 名称` 时，直接回车使用方括号中的主机名；输入 `ip` 自动使用本机 IPv4；也可以直接输入自定义名称或 IP。自动选 IP 失败时，检查网络接口或手动输入名称。

该命令会立即执行当前 `main` 分支。若要先检查确切代码，请从固定提交下载脚本，阅读后再运行。

已有本地脚本时，运行 `./miner-install.sh`。想先预览配置和命令，可运行 `./miner-install.sh --dry-run`：它不会下载矿工、改写文件或启动进程，但可能读取少量上游发布信息。

终端中会用颜色区分标题、操作、警告和错误；设置 `NO_COLOR=1` 可关闭颜色，重定向输出时也不会写入颜色代码。

## 高级：无交互运行

替换示例中的身份信息，然后**只选一条**运行。每条命令都会从 GitHub 获取脚本，不需要克隆或保存项目。

```bash
# QLI：PPS，CPU + GPU；也可把地址换成 access token
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- qli 0 YOUR_60_LETTER_QUBIC_ADDRESS alias --cpu --gpu --pps --yes --lang=zh
```

```bash
# JetSki：PPLNS，CPU + GPU
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- jetski YOUR_60_LETTER_QUBIC_WALLET alias 8 --cpu --gpu --pplns --yes --lang=zh
```

```bash
# Minerlab：CPU + GPU
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- minerlab YOUR_USERNAME 8 alias --cpu --gpu --yes --lang=zh
```

`--` 把后面的参数交给安装脚本；`--yes` 跳过交互确认，但仍会校验下载文件。可先给选中的命令加上 `--dry-run` 预演，确认后去掉它正式安装。如果已经保存了脚本，直接使用 `./miner-install.sh` 加同样的参数即可。若已有矿工在运行，`--yes` 默认拒绝继续；只有你明确添加 `--stop-existing` 才会先停止它。

多设备管理时，可以删掉示例中的 `alias` 并加上 `--alias-ip`，让矿工名使用本机 IPv4。JetSki 也可以直接写成 `jetski YOUR_60_LETTER_QUBIC_WALLET 8 --alias-ip`，第二个位置参数此时是线程数。

## 选择矿池

| 矿池 | 需要提供的身份信息 | 矿工 | 模式 |
| --- | --- | --- | --- |
| QLI | Access token 或 60 位 Qubic 地址 | `qli-Client` | PPS 或 Solo |
| JetSki | 60 位 Qubic 钱包地址 | `qubjetski-Client` | PPLNS 或 Solo |
| Minerlab | Minerlab 用户名 | `qlab-miner`（QLAB.Z） | CPU、GPU 或同时使用 |

`8` 是 CPU 线程数；`0` 表示自动。QLI 的 access token 若放在非交互命令中，可能出现在 shell 历史或进程列表；使用真实 token 时请注意保护。

## 完整参数

本地脚本使用 `./miner-install.sh <矿池> [位置参数] [选项]`。上面的远程命令在 `bash -c "$miner_script" --` 后使用同一套参数；不指定矿池时进入交互选择。

| 矿池 | 位置参数 | 默认值和要求 |
| --- | --- | --- |
| QLI | `qli <threads> <identity> [alias]` | `identity` 为 access token 或 60 位大写 Qubic 地址；`alias` 默认主机名。使用 `--ignore-threads N` 时改为 `qli <identity> [alias]`，不要再传线程数。 |
| JetSki | `jetski <wallet> [worker] [threads]` | `wallet` 为 60 位大写 Qubic 地址；`worker` 默认主机名，且应在矿池中唯一；线程数省略时自动。使用 `--alias-ip` 时，也可以写成 `jetski <wallet> [threads]`。 |
| Minerlab | `minerlab <username> [threads] [alias]` | `username` 必填；`alias` 默认主机名；启用 CPU 且省略线程数时默认使用 `nproc-2`（至少 1）。 |

QLI 和 JetSki 默认启用 CPU、关闭 GPU；Minerlab 默认关闭 CPU、启用 GPU。QLI 默认 PPS，JetSki 默认 PPLNS。线程数和 `--ignore-threads` 的值必须是不带前导零的非负整数；位置参数中的线程数 `0` 表示自动，`--ignore-threads 0` 表示不预留线程。

QLI 的 access token 会检查格式和有效期。JetSki 的 `worker`、Minerlab 的 `alias` 只能使用字母、数字、点、下划线和短横线，最长 64 位；Minerlab 的 `username` 还允许 `@`，最长 128 位。

### 通用选项

| 选项 | 作用 |
| --- | --- |
| `--help` / `-h` | 显示脚本帮助。 |
| `--lang=zh` / `--lang=en` | 本次运行使用指定语言；`--lang=cn` 等同中文。 |
| `--change-lang` | 交互选择并保存语言，然后退出；搭配 `--dry-run` 时不保存。 |
| `--set-lang=zh` / `--set-lang=en` | 直接保存语言，然后退出；也接受空格形式和中文别名 `cn`。搭配 `--dry-run` 时不保存。 |
| `--dry-run` | 只预演，不下载矿工或改写文件；可能读取上游发布元数据。 |
| `--yes` / `-y` | 跳过交互确认；必需信息要通过位置参数或环境变量提供，hash 不匹配仍会拒绝安装。 |
| `--no-start` | 安装并写配置，但不启动矿工。 |
| `--status` | 查看运行状态，可在前面指定矿池。 |
| `--monitor` / `--logs` | 查看日志，可在前面指定矿池。 |
| `--stop` | 停止当前或指定矿池的矿工。 |
| `--stop-existing` | 安装前明确允许停止已运行的已知矿工；常与 `--yes` 配合。 |
| `--force-download` | 不复用已有下载或二进制，重新下载。 |

`--status`、`--monitor`、`--stop` 是独立操作，不能与安装选项组合。

### 挖矿选项

| 选项 | 适用矿池与作用 |
| --- | --- |
| `--cpu` / `--no-cpu` | 全部矿池；启用或关闭 CPU。 |
| `--gpu` / `--no-gpu` | 全部矿池；启用或关闭 GPU。Minerlab 始终拒绝同时关闭 CPU/GPU；QLI 在命令行指定矿池或使用 `--yes` 时拒绝，JetSki 在 `--yes` 时拒绝。 |
| `--alias-ip` | 全部矿池；用本机默认出站网卡的 IPv4 作为 alias/worker 名称，覆盖手填或环境变量中的名称。取不到时尝试本机其他 IPv4，仍失败则报错；不会查询公网 IP。IP 变化后需重新运行脚本更新名称。 |
| `--ignore-threads N` | 全部矿池；CPU 线程数设为 `nproc-N`，要求 `N` 小于 CPU 总线程数，不能与 `--no-cpu` 同用。QLI 的位置参数顺序见上表。 |
| `--use-avx2` | QLI、Minerlab；启用 CPU 时将其版本设为 AVX2，也接受 `avx2`。 |
| `--gpu-version CUDA` / `--gpu-version AMD` | 全部矿池；指定 GPU 版本，需要启用 GPU。 |
| `--gpu-cards LIST` | 全部矿池；启用 GPU 时指定 GPU index，逗号分隔，每项为 `-1` 或非负整数，例如 `-1,-1,0`。Minerlab 还接受 `all`。 |
| `--pps` / `--solo` | QLI；选择 PPS 或 Solo。 |
| `--pplns` / `--solo` | JetSki；选择 PPLNS 或 Solo 包。 |
| `--auto-update` / `--no-auto-update` | 仅 QLI；在配置中写入 `autoUpdate=true/false`；未指定时省略该字段。 |

### 环境变量

自动化运行也可以使用以下变量；位置参数和命令行选项优先于相应环境变量。布尔值接受 `1/0`、`true/false`、`yes/no`、`y/n` 或 `on/off`（不区分大小写）。

| 范围 | 变量 |
| --- | --- |
| 通用 | `MINER_POOL`（`qli`、`jetski`、`minerlab`）、`THREADS`（CPU 线程数）。未明确指定语言时会参考系统 `LANG`。 |
| QLI 身份 | `QLI_ACCESS_TOKEN`、`QLI_QUBIC_ADDRESS`。 |
| QLI 设置 | `QLI_ALIAS`、`QLI_PPS`、`QLI_CPU`、`QLI_GPU`、`QLI_GPU_VERSION`、`QLI_GPU_CARDS`、`QLI_AUTO_UPDATE`、`QLI_USE_AVX2`。 |
| JetSki | `JETSKI_WALLET`、`JETSKI_WORKER`、`JETSKI_MODE`（`pplns`/`solo`）、`JETSKI_PPLNS`、`JETSKI_CPU`、`JETSKI_GPU`、`JETSKI_GPU_VERSION`、`JETSKI_GPU_CARDS`。 |
| Minerlab | `MINERLAB_USERNAME`、`MINERLAB_WORKER`、`MINERLAB_CPU`、`MINERLAB_GPU`、`MINERLAB_GPU_VERSION`、`MINERLAB_GPU_CARDS`、`MINERLAB_USE_AVX2`。 |

若同时设置 `JETSKI_MODE` 与 `JETSKI_PPLNS`，后者优先；命令行的 `--pplns` 或 `--solo` 优先于两者。

环境变量中的 access token 也可能被同一用户的其他进程读取，请避免在公开日志中打印它。

## 核对下载文件

安装新矿工前，脚本会显示下载 URL、发布方参考地址、文件的实际 SHA-256、可获得的预期 SHA-256 及来源，并显示对比结果。交互模式会在校验后请你确认；hash 不一致始终拒绝安装。`--yes` 只跳过确认，不跳过校验。如果发布方没有提供 hash，显示的摘要仅是本地完整性记录。

可以对照发布方页面核查来源：[QLI 客户端](https://github.com/qubic-li/client)、[JetSki 矿工](https://github.com/jtskxx/JETSKI-QUBIC-POOL)、[Minerlab 安装脚本](https://dl.minerlab.io/qlab-install.sh)。hash 一致表示文件与发布的摘要一致，不能证明闭源矿工或其后续下载的 worker 没有恶意行为。

## 管理矿工

脚本同一时间只允许此目录中的一个已知矿工运行。流式运行结束时，它会打印可复用的状态和停止命令。如果本地保存了脚本，也可以运行：

```bash
./miner-install.sh --status
./miner-install.sh --monitor
./miner-install.sh --stop
```

`--no-start` 只安装和写配置，不启动。`--force-download` 重新下载并替换已验证的本地矿工。切换矿池时，如果需要停止已有矿工，交互确认默认是“否”；非交互 `--yes` 模式则必须显式加上 `--stop-existing`。查看日志时按 Ctrl+C 只会退出查看器，后台矿工仍会运行；需要停止时使用 `--stop`。

运行文件保存在工作目录下的 `miners/` 和 `downloads/`，不会纳入本仓库。公开 `appsettings.json`、access token 或日志前请先检查并脱敏。

## 测试与打包

```bash
tests/miner-install-tests.sh
tests/miner-install-integration.sh
scripts/package-release.sh 1.0.0
```

测试使用隔离的模拟文件，不会连接矿池进行真实挖矿。打包脚本会先运行测试，再在 `dist/` 生成源码压缩包和 SHA-256 文件。更新记录见 [CHANGELOG.md](CHANGELOG.md)。

本项目原创代码和文档采用 [MIT License](LICENSE)。下载的矿工客户端与 worker 属于各自发布方，不包含在源码压缩包中。
