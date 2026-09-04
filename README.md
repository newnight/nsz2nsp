# Nsz

一款 macOS 原生的 NSZ / NCZ 解压工具（NSZ → NSP，NCZ → NCA），提供拖拽 GUI、Finder 右键一键解压和 CLI 三种使用方式。纯 Swift + SPM 实现，zstd 解压库直接内嵌源码，**无任何第三方依赖**。

> ⚡ Powered by AI — 本项目由 AI（WorkBuddy）与人类协作完成，从核心解压逻辑、字节级测试到 GUI 均为 AI 辅助开发。

## 特性

- **NSZ → NSP / NCZ → NCA** 完整解压，支持 solid 与 block 两种压缩模式
- **零洞损坏扫描**：解压前扫描压缩流中的连续全零区（下载/传输损坏的典型特征），提前告警，避免产出损坏文件
- **SHA-256 哈希校验**：逐 NCA 校验解压结果
- **重名自动改名**：输出文件已存在时按时间加后缀（`Game 2026-09-04 23.04.12.nsp`），绝不覆盖
- **三种使用方式**：
  - 🖱️ 拖拽 GUI：拖入文件即解压，实时进度条
  - 📂 Finder 右键：快速操作「解压 NSZ」（App 启动时自动注册/更新）
  - ⌨️ CLI：`nszcli <file.nsz> [-o 输出目录] [--no-scan] [--overwrite]`
- **双架构**：Apple Silicon（arm64）与 Intel（x86_64）独立构建

## 安装

前往 [Releases](../../releases) 页面下载对应架构的 zip：

| 芯片 | 文件 |
|---|---|
| Apple Silicon（M 系列） | `Nsz-arm64.zip` |
| Intel | `Nsz-x86_64.zip` |

解压后将 `Nsz.app` 拖入「应用程序」，**打开一次**即可：

- Finder 中右键 `.nsz` / `.ncz` 文件 → 「打开方式」→ Nsz
- Finder 右键 → 快速操作 → 「解压 NSZ」（首次打开 App 后自动注册）

> 未签名提示：首次打开如提示无法验证开发者，请右键 App → 打开，或到 系统设置 → 隐私与安全性 中点「仍要打开」。

## 使用

### GUI

拖入 `.nsz` / `.ncz` 文件（可多个），解压到文件所在目录，底部显示实时进度与校验结果。损坏文件会在解压前给出 ⚠️ 零洞警告。

### CLI

```bash
nszcli <file.nsz|file.ncz> [-o 输出目录] [--no-scan] [--overwrite]
```

- `-o`：指定输出目录（默认解压到文件所在目录）
- `--no-scan`：跳过零洞预扫描
- `--overwrite`：覆盖已存在的输出文件（默认按时间改名）

## 从源码构建

要求：macOS 13+，Swift 5.9+（Xcode Command Line Tools）。

```bash
git clone <repo>
cd nszcli

swift build -c release          # CLI + 库
./make_app.sh                   # 出包本机架构的 Nsz.app
ARCH=x86_64 ./make_app.sh       # 交叉编译 Intel 版

./tests/run_tests.sh            # 字节级回归测试（5 个用例）
```

产物位于 `build/Nsz.app`。

## 技术说明

- **PFS0 容器**：entry offset 按「相对数据区起点」语义解析（与官方规范一致）
- **NCZ 结构**：`0x4000` NCA 头 + `NCZSECTN` section 表 + 可选 `NCZBLOCK` + zstd 流；cryptoType 3/4 的 section 按 NCA 绝对偏移寻址做 AES-CTR 重加密，首 section 前的间隙自动插 FakeSection（明文）
- **zstd**：内嵌 [zstd](https://github.com/facebook/zstd) 单文件 amalgamated 源码（`Sources/Czstd`），无 Homebrew / 系统库依赖，开箱即编译
- 解压核心抽为 `NszCore` 库，CLI 与 GUI 共用，进度事件回调式输出

## License

[MIT](LICENSE)
