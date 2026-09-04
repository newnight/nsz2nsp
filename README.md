# Nsz

> ⚡ **Powered by AI** — This project was built through human–AI collaboration (WorkBuddy): core decompression logic, byte-level tests, and the GUI were all AI-assisted.
> ⚡ **Powered by AI** — 本项目由 AI（WorkBuddy）与人类协作完成，从核心解压逻辑、字节级测试到 GUI 均为 AI 辅助开发。

A native macOS NSZ / NCZ decompressor (NSZ → NSP, NCZ → NCA) with a drag & drop GUI, a Finder right-click Quick Action, and a CLI.
一款 macOS 原生的 NSZ / NCZ 解压工具（NSZ → NSP，NCZ → NCA），提供拖拽 GUI、Finder 右键一键解压和 CLI 三种使用方式。

Pure Swift + SPM with the zstd library vendored as source — zero third-party dependencies.
纯 Swift + SPM 实现，zstd 解压库直接内嵌源码，无任何第三方依赖。

## Features / 特性

- Full NSZ → NSP / NCZ → NCA decompression, supporting both solid and block compression modes.
- 完整 NSZ → NSP / NCZ → NCA 解压，支持 solid 与 block 两种压缩模式。

- Zero-hole corruption scan: detects contiguous zero regions in the compressed stream (a typical sign of download/transfer corruption) before extraction and warns you up front.
- 零洞损坏扫描：解压前扫描压缩流中的连续全零区（下载/传输损坏的典型特征），提前告警，避免产出损坏文件。

- SHA-256 verification: every NCA is hash-checked after decompression.
- SHA-256 哈希校验：逐 NCA 校验解压结果。

- Rename on conflict: if the output already exists, a timestamp suffix is added (`Game 2026-09-04 23.04.12.nsp`) — never overwrites.
- 重名自动改名：输出文件已存在时按时间加后缀（`Game 2026-09-04 23.04.12.nsp`），绝不覆盖。

- Three ways to use:
- 三种使用方式：
  - 🖱️ Drag & drop GUI: drop files to decompress, with a live progress bar.
  - 🖱️ 拖拽 GUI：拖入文件即解压，实时进度条。
  - 📂 Finder Quick Action: right-click → Quick Actions → "解压 NSZ" (auto-registered when the app launches).
  - 📂 Finder 右键：快速操作「解压 NSZ」（App 启动时自动注册/更新）。
  - ⌨️ CLI: `nszcli <file.nsz> [-o dir] [--no-scan] [--overwrite]`.
  - ⌨️ CLI：`nszcli <file.nsz> [-o 输出目录] [--no-scan] [--overwrite]`。

- Dual architecture: separate Apple Silicon (arm64) and Intel (x86_64) builds.
- 双架构：Apple Silicon（arm64）与 Intel（x86_64）独立构建。

## Install / 安装

Download the zip for your Mac from the [Releases](../../releases) page:
前往 [Releases](../../releases) 页面下载对应架构的 zip：

| Chip / 芯片 | File / 文件 |
|---|---|
| Apple Silicon (M-series) / Apple Silicon（M 系列） | `Nsz-arm64.zip` |
| Intel | `Nsz-x86_64.zip` |

Unzip, drag `Nsz.app` into Applications, then launch it once:
解压后将 `Nsz.app` 拖入「应用程序」，打开一次即可：

- Right-click a `.nsz` / `.ncz` file → Open With → Nsz.
- Finder 中右键 `.nsz` / `.ncz` 文件 → 「打开方式」→ Nsz。
- Right-click → Quick Actions → "解压 NSZ" (registered automatically after first launch).
- Finder 右键 → 快速操作 → 「解压 NSZ」（首次打开 App 后自动注册）。

> Unsigned app note: if macOS blocks the first launch, right-click the app → Open, or allow it under System Settings → Privacy & Security.
> 未签名提示：首次打开如提示无法验证开发者，请右键 App → 打开，或到 系统设置 → 隐私与安全性 中点「仍要打开」。

## Usage / 使用

### GUI

Drop one or more `.nsz` / `.ncz` files; output goes next to the source files with a live progress bar and verification results at the bottom.
拖入一个或多个 `.nsz` / `.ncz` 文件，解压到文件所在目录，底部显示实时进度与校验结果。

Corrupted files raise a ⚠️ zero-hole warning before extraction starts.
损坏文件会在解压前给出 ⚠️ 零洞警告。

### CLI

```bash
nszcli <file.nsz|file.ncz> [-o outputDir] [--no-scan] [--overwrite]
```

- `-o` — output directory (defaults to the input file's directory).
- `-o` — 指定输出目录（默认解压到文件所在目录）。

- `--no-scan` — skip the zero-hole pre-scan.
- `--no-scan` — 跳过零洞预扫描。

- `--overwrite` — overwrite existing output (default is timestamp rename).
- `--overwrite` — 覆盖已存在的输出文件（默认按时间改名）。

## Building from Source / 从源码构建

Requires macOS 13+ and Swift 5.9+ (Xcode Command Line Tools).
要求：macOS 13+，Swift 5.9+（Xcode Command Line Tools）。

```bash
git clone <repo>
cd nszcli

swift build -c release          # CLI + library / CLI + 库
./make_app.sh                   # build Nsz.app for the host architecture / 出包本机架构的 Nsz.app
ARCH=x86_64 ./make_app.sh       # cross-compile the Intel build / 交叉编译 Intel 版

./tests/run_tests.sh            # byte-level regression tests (5 cases) / 字节级回归测试（5 个用例）
```

The app bundle lands in `build/Nsz.app`.
产物位于 `build/Nsz.app`。

## Technical Notes / 技术说明

- PFS0 container: entry offsets are parsed as "relative to the data start" (per the official spec).
- PFS0 容器：entry offset 按「相对数据区起点」语义解析（与官方规范一致）。

- NCZ layout: `0x4000` NCA header + `NCZSECTN` section table + optional `NCZBLOCK` + zstd stream; cryptoType 3/4 sections are AES-CTR re-encrypted with NCA absolute-offset addressing; the gap before the first section is handled as a plaintext FakeSection.
- NCZ 结构：`0x4000` NCA 头 + `NCZSECTN` section 表 + 可选 `NCZBLOCK` + zstd 流；cryptoType 3/4 的 section 按 NCA 绝对偏移寻址做 AES-CTR 重加密，首 section 前的间隙自动按明文 FakeSection 处理。

- zstd: vendored [zstd](https://github.com/facebook/zstd) single-file amalgamated source (`Sources/Czstd`) — no Homebrew or system dependency, builds out of the box.
- zstd：内嵌 [zstd](https://github.com/facebook/zstd) 单文件 amalgamated 源码（`Sources/Czstd`），无 Homebrew / 系统库依赖，开箱即编译。

## License & Credits / 许可与致谢

- This project's code is released under the [MIT License](LICENSE).
- 本项目代码以 [MIT](LICENSE) 协议开源。

- The vendored zstd library is copyright Facebook / Zstandard contributors, licensed under [BSD 3-Clause](https://github.com/facebook/zstd/blob/dev/LICENSE).
- 内嵌的 zstd 库版权归 Facebook / Zstandard 作者所有，遵循 [BSD 3-Clause](https://github.com/facebook/zstd/blob/dev/LICENSE) 协议。

- Image assets were generated by Doubao AI.
- 图片资源由豆包（Doubao）AI 生成。
