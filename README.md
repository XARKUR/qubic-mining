# Qubic Miner Installer

[简体中文](README.zh-CN.md) | English

A Bash installer for QLI, JetSki, and Minerlab on Linux x86_64. It configures one pool per run, downloads the corresponding miner, and starts it in the background. It runs as a regular user and does not install a system service or enable startup at boot.

## Run without cloning

```bash
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && bash -c "$miner_script"
```

The script runs from GitHub without saving a copy of this project. Miner downloads, configuration, and logs are kept in `$HOME/qubic-miner`. On the first run, choose a language, then follow the pool and device prompts. Use a regular user account, not root.

This command immediately executes the current `main` branch. If you want to inspect the exact script first, download it from a fixed commit and read it before running it.

If you already have the script locally, run `./miner-install.sh`. Use `./miner-install.sh --dry-run` to preview the configuration and commands without downloading a miner, changing files, or starting a process. A dry run may read small upstream release metadata.

## Advanced: non-interactive run

Replace the identity placeholder, then run **one** of these commands. Each command fetches the script from GitHub without cloning or saving the project.

```bash
# QLI: PPS, CPU + GPU; an access token can replace the address
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- qli 0 YOUR_60_LETTER_QUBIC_ADDRESS alias --cpu --gpu --pps --yes --lang=en
```

```bash
# JetSki: PPLNS, CPU + GPU
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- jetski YOUR_60_LETTER_QUBIC_WALLET alias 8 --cpu --gpu --pplns --yes --lang=en
```

```bash
# Minerlab: CPU + GPU
mkdir -p "$HOME/qubic-miner" && cd "$HOME/qubic-miner" && \
  miner_script=$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh) && \
  bash -c "$miner_script" -- minerlab YOUR_USERNAME 8 alias --cpu --gpu --yes --lang=en
```

The `--` passes the remaining arguments to the installer. `--yes` skips prompts but still checks downloaded files. Add `--dry-run` to your chosen command to preview it, then remove the flag to install. If you saved the script locally, use `./miner-install.sh` with the same arguments. With `--yes`, an existing running miner blocks installation unless you explicitly add `--stop-existing`.

## Choose a pool

| Pool | Identity to provide | Miner | Modes |
| --- | --- | --- | --- |
| QLI | Access token or 60-letter Qubic address | `qli-Client` | PPS or Solo |
| JetSki | 60-letter Qubic wallet | `qubjetski-Client` | PPLNS or Solo |
| Minerlab | Minerlab username | `qlab-miner` (QLAB.Z) | CPU, GPU, or both |

`8` is the CPU thread count; `0` selects automatic threads. A QLI access token passed in a non-interactive command may be visible in shell history or the process list; protect your real token.

## Complete parameter reference

The local syntax is `./miner-install.sh <pool> [positional arguments] [options]`. The remote examples use the same arguments after `bash -c "$miner_script" --`. Without a pool, the installer starts its interactive flow.

| Pool | Positional arguments | Defaults and requirements |
| --- | --- | --- |
| QLI | `qli <threads> <identity> [alias]` | `identity` is an access token or 60-letter uppercase Qubic address; `alias` defaults to the hostname. With `--ignore-threads N`, use `qli <identity> [alias]` and omit the positional thread count. |
| JetSki | `jetski <wallet> [worker] [threads]` | `wallet` is a 60-letter uppercase Qubic address; `worker` defaults to the hostname and should be unique in the pool; omitted threads mean automatic. |
| Minerlab | `minerlab <username> [threads] [alias]` | `username` is required; `alias` defaults to the hostname; with CPU enabled, omitted threads default to `nproc-2` (at least 1). |

QLI and JetSki default to CPU on and GPU off; Minerlab defaults to CPU off and GPU on. QLI defaults to PPS and JetSki to PPLNS. Thread counts and `--ignore-threads` values must be non-negative integers without leading zeroes; a positional thread count of `0` means automatic, while `--ignore-threads 0` reserves no threads.

QLI access tokens are checked for format and expiry. JetSki `worker` and Minerlab `alias` accept letters, digits, dot, underscore, and dash, up to 64 characters; Minerlab `username` also accepts `@`, up to 128 characters.

### General options

| Option | Effect |
| --- | --- |
| `--help` / `-h` | Show script help. |
| `--lang=zh` / `--lang=en` | Select the language for this run; `--lang=cn` also selects Chinese. |
| `--change-lang` | Ask for and save a language preference, then exit; with `--dry-run`, do not save. |
| `--set-lang=zh` / `--set-lang=en` | Save a language preference and exit; the space-separated form and Chinese alias `cn` also work. With `--dry-run`, do not save. |
| `--dry-run` | Preview without downloading a miner or changing files; may read upstream release metadata. |
| `--yes` / `-y` | Skip prompts; provide required values as arguments or environment variables. A hash mismatch still blocks installation. |
| `--no-start` | Install and write configuration without starting the miner. |
| `--status` | Show status, optionally for a specified pool. |
| `--monitor` / `--logs` | Show logs, optionally for a specified pool. |
| `--stop` | Stop the current or specified pool's miner. |
| `--stop-existing` | Explicitly allow stopping a running known miner before installation; commonly used with `--yes`. |
| `--force-download` | Download again instead of reusing the local archive or binary. |

`--status`, `--monitor`, and `--stop` are separate actions and cannot be combined with installation options.

### Mining options

| Option | Pools and effect |
| --- | --- |
| `--cpu` / `--no-cpu` | All pools; enable or disable CPU. |
| `--gpu` / `--no-gpu` | All pools; enable or disable GPU. Minerlab always rejects both CPU/GPU off; QLI rejects it when the pool is named on the command line or with `--yes`, and JetSki rejects it with `--yes`. |
| `--ignore-threads N` | All pools; use `nproc-N` CPU threads. `N` must be smaller than the CPU count and cannot be used with `--no-cpu`. QLI changes its positional order as shown above. |
| `--use-avx2` | QLI and Minerlab; select the AVX2 version with CPU enabled. Bare `avx2` is also accepted. |
| `--gpu-version CUDA` / `--gpu-version AMD` | All pools; select a GPU version, with GPU enabled. |
| `--gpu-cards LIST` | All pools; with GPU enabled, specify comma-separated GPU indices, each `-1` or a non-negative integer, such as `-1,-1,0`. Minerlab also accepts `all`. |
| `--pps` / `--solo` | QLI; choose PPS or Solo. |
| `--pplns` / `--solo` | JetSki; choose the PPLNS or Solo package. |
| `--auto-update` / `--no-auto-update` | QLI only; write `autoUpdate=true/false` to configuration; the field is omitted by default. |

### Environment variables

Automation can also use these variables. Positional arguments and command-line options take precedence over their corresponding environment variables. Boolean values accept `1/0`, `true/false`, `yes/no`, `y/n`, or `on/off`, case-insensitively.

| Scope | Variables |
| --- | --- |
| General | `MINER_POOL` (`qli`, `jetski`, `minerlab`) and `THREADS` (CPU threads). System `LANG` is used when no language is otherwise selected. |
| QLI identity | `QLI_ACCESS_TOKEN`, `QLI_QUBIC_ADDRESS`, `QLI_PAYOUT_ID` (legacy alias), in fallback order. |
| QLI settings | `QLI_ALIAS`, `QLI_PPS`, `QLI_CPU`, `QLI_GPU`, `QLI_GPU_VERSION`, `QLI_GPU_CARDS`, `QLI_AUTO_UPDATE`, `QLI_USE_AVX2`. |
| JetSki | `JETSKI_WALLET`, `JETSKI_WORKER`, `JETSKI_MODE` (`pplns`/`solo`), `JETSKI_PPLNS`, `JETSKI_CPU`, `JETSKI_GPU`, `JETSKI_GPU_VERSION`, `JETSKI_GPU_CARDS`. |
| Minerlab | `MINERLAB_USERNAME`, `MINERLAB_WORKER`, `MINERLAB_CPU`, `MINERLAB_GPU`, `MINERLAB_GPU_VERSION`, `MINERLAB_GPU_CARDS`, `MINERLAB_USE_AVX2`. |

If both `JETSKI_MODE` and `JETSKI_PPLNS` are set, the latter takes precedence; command-line `--pplns` or `--solo` overrides either one.

An access token in an environment variable may also be readable by other processes owned by the same user. Avoid printing it in public logs.

## Check the download

Before installing a new miner, the script shows its download URL, a publisher reference, the downloaded SHA-256, the expected SHA-256 and its source when available, and the comparison result. Interactive runs ask you to confirm after this check. A hash mismatch always stops the installation; `--yes` skips the prompt but not the check. If the publisher provides no hash, the displayed digest is only a local integrity record.

You can compare the source with the publishers' own pages: [QLI client](https://github.com/qubic-li/client), [JetSki miner](https://github.com/jtskxx/JETSKI-QUBIC-POOL), and [Minerlab installer](https://dl.minerlab.io/qlab-install.sh). Matching a publisher's hash checks file consistency; it does not prove that a closed-source miner or a worker it downloads later is free of malicious behavior.

## Manage a miner

The installer allows one known miner from this directory to run at a time. At the end of a streamed run, it prints commands you can reuse for status and stopping. With a local copy of the script:

```bash
./miner-install.sh --status
./miner-install.sh --monitor
./miner-install.sh --stop
```

`--no-start` installs and configures without starting. `--force-download` replaces a verified local miner with a fresh download. In non-interactive `--yes` mode, an existing running miner is stopped only if you also pass `--stop-existing`. Pressing Ctrl+C while viewing logs exits the viewer; the miner continues in the background until you stop it.

Runtime files live in `miners/` and `downloads/` under the working directory and are excluded from this repository. Do not publish your `appsettings.json`, access tokens, or logs without reviewing them.

## Test and package

```bash
tests/miner-install-tests.sh
tests/miner-install-integration.sh
scripts/package-release.sh 1.0.0
```

The tests use isolated fixtures, not live mining. The release script runs them and creates a source archive and SHA-256 file in `dist/`. See [CHANGELOG.md](CHANGELOG.md) for changes.

The original code and documentation are under the [MIT License](LICENSE). Downloaded miner clients and workers belong to their respective publishers and are not included in the source archive.
