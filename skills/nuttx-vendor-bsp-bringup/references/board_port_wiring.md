# 板级接入：目录、构建系统、manifest 与打包

> 目标：把新芯片/新板子的代码放进 vendor 树并被正确编译，同时**不动上游生产仓库**。
> 这一段决定"后面所有代码是否真的参与了构建"。

## 目录

1. [代码该放哪里](#1-代码该放哪里)
2. [让构建系统认识新芯片](#2-让构建系统认识新芯片)
3. [defconfig 必备项](#3-defconfig-必备项)
4. [链接脚本](#4-链接脚本)
5. [pinmux 与系统时钟](#5-pinmux-与系统时钟)
6. [board 初始化 hook 与时序](#6-board-初始化-hook-与时序)
7. [应用与内置命令](#7-应用与内置命令)
8. [打包与镜像](#8-打包与镜像)
9. [接手检查清单](#9-接手检查清单)

---

## 1. 代码该放哪里

按内核的分层放置，不要把所有东西堆在一个文件：

```text
<team_repo>/
├── chip/<soc>/                 # SoC 层：启动、中断、tick、串口、各外设 lower half
│   ├── <soc>_head.S            #   启动入口（第一条指令）
│   ├── <soc>_start.c           #   C 入口/初始化顺序
│   ├── <soc>_irq.c             #   异常与中断分发
│   ├── <soc>_serial.c          #   串口 lower half + 早期 console
│   ├── <soc>_boot.c            #   heap/时钟等
│   ├── <soc>_<periph>.c        #   外设 lower half（i2c/pwm/fb/gmac/sdmc/...）
│   ├── include/                #   SoC 私有头（基址、IRQ 号、寄存器）
│   ├── Kconfig
│   ├── Make.defs               #   传统 make 接入
│   └── CMakeLists.txt          #   CMake 接入（openvela 主用）
├── board/<soc>/<board>/
│   ├── configs/<cfg>/defconfig
│   ├── scripts/ld.script
│   ├── scripts/Make.defs
│   ├── src/board_boot.c        #   early/late hook
│   ├── src/board_bringup.c     #   在 late 里注册各外设
│   ├── src/pinmux.c
│   ├── src/sys_clk.c
│   ├── pack/                   #   自有分区表/打包输入
│   └── Kconfig
└── app/<name>/                 # 每外设一个测试命令 + README
```

分层职责（沿用 openvela 约定）：
- **chip 层**：寄存器级 lower half + SoC 定义；不要在这里写板子特有的引脚/器件。
- **board 层**：defconfig、链接脚本、pinmux、时钟选择、early/late 初始化、驱动注册。
- **app 层**：验证命令，走标准 VFS/框架，不做私有 ioctl 通道。

**边界纪律**：只改自己的仓。需要改公共仓库时，不要直接改生产目录，走 fork + PR（或用 manifest 的链接机制把代码挂进编译树）。

## 2. 让构建系统认识新芯片

新芯片"代码放进 vendor 但没被编译"通常有三个原因：

1. **vendor 顶层 Kconfig 只列了同系列芯片**（例如只有 `ARCH_CHIP_D12X`），新芯片没有条目；
2. **顶层 Make.defs 只在 `CONFIG_ARCH_CHIP_<旧芯片>=y` 时 include 对应子目录**；
3. **NuttX 的 `ARCH_CHIP` 映射表里没有新名字**，配置期会落到 dummy，报 `arch//include` 之类空路径错误。

两种接入方式，优先第一种：

### A. 自定义芯片（推荐，零上游改动）
用 `CONFIG_ARCH_CHIP_CUSTOM*` / `CONFIG_ARCH_BOARD_CUSTOM*` 指向自己的目录：

```text
CONFIG_ARCH_CHIP_CUSTOM=y
CONFIG_ARCH_CHIP_CUSTOM_NAME="<vendor>_<soc>"
CONFIG_ARCH_CHIP_CUSTOM_DIR="../vendor/<vendor>/chips/<soc>"
CONFIG_ARCH_CHIP_CUSTOM_DIR_RELPATH=y
CONFIG_ARCH_BOARD_CUSTOM=y
CONFIG_ARCH_BOARD_CUSTOM_NAME="<board>"
CONFIG_ARCH_BOARD_CUSTOM_DIR="../vendor/<vendor>/boards/<soc>/<board>"
CONFIG_ARCH_BOARD_CUSTOM_DIR_RELPATH=y
```

配套要求：
- chip 目录要有 `CMakeLists.txt`（CMake 流程靠 `add_subdirectory(${NUTTX_CHIP_ABS_DIR})` 收源码，不依赖 vendor 顶层 Make.defs）；
- 板级要有 `scripts/Make.defs` + 链接脚本（CMake 流程用 `set_property(GLOBAL PROPERTY LD_SCRIPT ...)`）；
- Kconfig 要能被接到构建的 dummy Kconfig 上，并让 `ARCH_CHIP="<soc>"` 真的生成。

### B. 用 manifest 的 `<linkfile>` 把工作目录挂进编译树
团队仓里的 `chip/`、`board/`、`app/` 通过 `<linkfile>` 软链到 openvela 工作树的目标位置，**生产仓库零改动**：

```xml
<project path="contest2026_xxx_team" name="contest2026_xxx_team">
  <linkfile src="chip/<soc>"        dest="vendor/<vendor>/chips/<soc>"/>
  <linkfile src="board/<soc>/<board>" dest="vendor/<vendor>/boards/<soc>/<board>"/>
  <linkfile src="app/<app>"         dest="packages/demos/contest2026_xxx_<app>"/>
</project>
```

要点：
- 新增工作目录后**要补一条 `<linkfile>`**，否则构建看不到；
- 链接是软链，编译在工作区根目录进行；
- 用 `<linkfile>` + 自定义芯片机制可以做到"上游公共目录一行不改"。

### 构建后端注意
- 优先用 CMake 流程（例：`./build.sh <board-config-path> --cmake -j8`）。传统 Make 流程下，chip 侧是否被收源码取决于 vendor 顶层 `Make.defs` 的条件，改起来更麻烦。
- **Kconfig 的 `select`/依赖改动后必须干净重建**（删掉该配置的构建输出目录）。增量构建不会重新展开 Kconfig，`.config` 仍是旧值，会出现"改了配置但行为没变"的假象（栈大小改动就曾因此看起来无效）。
- 传统 Make 流程里 `Make.defs` 与 `CMakeLists.txt` 两份清单都要维护，容易漂移；加文件后两边都加，并用 `bsp_scan.sh` 核对。

## 3. defconfig 必备项

最小 NSH 配置的关键项（按需取用）：

```text
CONFIG_ARCH_RISCV=y                      # 或对应架构
CONFIG_ARCH_CHIP_CUSTOM=y
CONFIG_ARCH_CHIP_CUSTOM_NAME="..."
CONFIG_ARCH_CHIP_CUSTOM_DIR="..."
CONFIG_ARCH_CHIP_CUSTOM_DIR_RELPATH=y
CONFIG_ARCH_BOARD_CUSTOM=y
CONFIG_ARCH_BOARD_CUSTOM_NAME="..."
CONFIG_ARCH_BOARD_CUSTOM_DIR="..."
CONFIG_ARCH_BOARD_CUSTOM_DIR_RELPATH=y
CONFIG_INIT_ENTRYPOINT="nsh_main"
CONFIG_SYSTEM_NSH=y
CONFIG_BUILTIN=y                         # 让 app/ 里的命令能在 NSH 调用
CONFIG_BOARD_EARLY_INITIALIZE=y
CONFIG_BOARD_LATE_INITIALIZE=y
CONFIG_FS_PROCFS=y                       # ps/free/fdinfo 依赖
CONFIG_<SOC>_SERIAL_CONSOLE=y            # console 串口
CONFIG_SYSLOG_DEFAULT=y
CONFIG_SYSLOG_DEVPATH="/dev/ttyS0"       # 必须与驱动注册的节点一致
CONFIG_RAM_START=0x...                   # 与链接脚本一致
CONFIG_RAM_SIZE=...
```

检查点：
- console 与 syslog 的设备名要一致，且都能在驱动里找到注册点；
- 每加一个外设，在 defconfig 里加对应 `CONFIG_*`，并在 board bringup 里加注册调用——两边成对出现；
- 引脚冲突要在 defconfig/文档里显式取舍（例如同一引脚既能做按键又能做 I2S 时钟，只能选一个），不要隐藏冲突；
- **精简配置会连带砍功能**：省空间的选项往往同时关掉一批 shell 命令和 procfs 信息项，表现为"驱动好了但 `ifconfig`/`ps` 用不了"。需要哪些诊断与网络命令就显式打开，并始终以生成的 `.config` 为准；
- "命令 `help` 里有、执行却 not found"通常不是驱动问题，而是 shell 内置命令的集成 bug（见 `debug_playbook.md` 第 5 节）。

## 4. 链接脚本

- 明确 `MEMORY` 区域与 `ORIGIN/LENGTH`，保留区（bootloader/前级占用）要显式扣掉；
- 段顺序会影响入口地址（见 `boot_and_core.md` 的地址一致性）；
- 导出堆边界符号并 `ASSERT`；
- 栈与堆的边界要清楚，避免重叠；
- 改完链接脚本**必须同步核对打包描述里的 load/entry**。

传统 Make 流程还需要 `scripts/Make.defs` 指定工具链前缀、`-march/-mabi`、优化与告警开关。注意别用一堆 `-Wno-error=` 把真正的类型错误压掉——上游风格是要过 checkpatch 的。

## 5. pinmux 与系统时钟

- 引脚复用：集中在一个 `pinmux.c` 里，按外设分组，写清"引脚 → 功能号 → 所属外设"；
- 系统时钟：不要默认沿用同系列芯片的时钟树表。**同系列≠同频同源**：核对每个外设的时钟源、分频、门控寄存器与复位位；
- 时钟使能与去复位顺序：先开时钟再出复位，反了会出现"寄存器写得进、数据出不来"；
- 复用同系列的时钟/reset 表时，把它当成"待逐项核对的草稿"，而不是可直接使用的实现。

## 6. board 初始化 hook 与时序

```
nx_start()
  ├── drivers_early_initialize()   # 不能阻塞、不能用堆
  ├── drivers_initialize()
  ├── board_early_initialize()     # 不能阻塞
  └── board_late_initialize()      # 调度器已就绪，可阻塞、可访问总线
      └── board_app_initialize()
          └── board_bringup()      # 注册各外设
```

- **需要总线访问（I2C/SPI）与文件系统的注册，放在 `board_late_initialize()` 或更晚**；early 阶段阻塞会死锁。
- early 只做最基础的硬件准备（且要避免重配前级已经配好的东西）。
- 长耗时初始化（挂载、联网）建议丢给 worker 线程，不要卡住 bringup。
- 注册顺序按依赖：总线 → 器件 → 依赖器件的框架设备 → 文件系统 → 上层。
- bringup 里每一步都要打日志并检查返回值，失败要能看出是哪一步。

## 7. 应用与内置命令

- 每个外设配一个测试命令，放 `app/<name>/`，接入方式：
  - `Kconfig`：`config LVX_USE_DEMO_<TEAM>_<NAME>`，默认按需；
  - `CMakeLists.txt`：`nuttx_add_application(NAME <cmd> SRCS <file>.c STACKSIZE ...)`；
  - 传统 Make 流程还要 `Make.defs`/`Makefile`；
  - manifest 加 `<linkfile>` 到 `packages/demos/...`。
- 命令要有：默认参数、边界检查（时长/频率范围）、`PASS/FAIL` 结论行、以及退出时释放资源（例如 PWM `PWMIOC_STOP`）。
- 每个命令配 README：功能目标 / 依赖模块 / 测试步骤 / 预期结果 / 实测结果 / 已知限制。

## 8. 打包与镜像

- 打包脚本尽量**显式传参**（板名 + 芯片名），不要依赖它自己从 `.config` 猜；
- 打包前清干净产物目录，避免把上一次的镜像当成新的；
- 核对产物：镜像大小、时间戳、哈希；入口地址与 `.its`/`image_cfg` 一致；
- 分区表这类"由脚本生成再参与打包"的中间文件，若脚本按旧配置生成，会静默用错分区尺寸——把自算结果放进自己的板级 `pack/` 目录；
- 有些打包步骤（例如可选的稀疏镜像转换）失败但退出码为 0，属非阻塞；确认最终 `.img` 是否真的生成。

## 9. 接手检查清单

- [ ] `bsp_scan.sh <repo>` 跑过，知道自己有什么、缺什么
- [ ] chip/board/app 目录结构清楚，分层没有混
- [ ] manifest `<linkfile>` 覆盖了所有工作目录
- [ ] defconfig 的 chip/board 自定义路径、console、syslog、RAM 区间正确
- [ ] `Make.defs` 与 `CMakeLists.txt` 的源码清单一致
- [ ] 链接脚本导出了堆边界并核对过入口地址
- [ ] board late 初始化里每个注册都有日志与错误检查
- [ ] 每加一个文件后做一次干净重建（尤其是动过 Kconfig 之后）
