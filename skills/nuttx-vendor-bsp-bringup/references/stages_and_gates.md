# 阶段划分、门禁与证据等级

> 换芯片/换板子时，按 S0→S6 顺序推进。任何阶段没有拿到**真机证据**就不要标记完成。
> 脚本：`scripts/bsp_state.sh`（状态与门禁）、`scripts/validate_stage.sh`（产物检查）。

## 1. 证据等级（Evidence Level）

BSP 工作最大的自欺是"编译过了"当成"跑通了"。本 skill 用 6 级证据约束结论：

| 等级 | 含义 | 典型证据 |
|------|------|----------|
| `none` | 还没动手 | — |
| `build` | 编译通过 | `build.sh` 退出 0、生成 `nuttx`/`nuttx.elf` |
| `pack` | 打包出可烧录镜像 | `.img`/`.itb` 生成，地址与入口一致 |
| `boot` | 真机出现启动日志或提示符 | 串口出现打点序列 / `NuttShell (NSH)` |
| `device` | 真机出现设备节点或框架注册 | `ls /dev` 有节点、`ifconfig` 有网卡、`ps` 有任务 |
| `data` | 真机完成数据面验证 | 读写一致、事件回调、收发包、出声/录音、画面显示 |

规则：
- **只有 `data` 级别才能对外说"某某功能已实现/已验证"。**
- `build`/`pack` 只能说明"编译与打包链路通了"。
- 结论要写清等级，例如"以太网已到 `device`（`ifconfig` 有 `eth0`），`data` 待补 ping"。

## 2. 阶段总表

| 阶段 | 目标 | 交付物 | 通过所需证据 | 典型卡点 |
|------|------|--------|--------------|----------|
| **S0** | 资料与参考对表 | 同系列差异表、可复用/必须重写文件清单、引脚与外设清单 | `none`（文档） | 直接抄同系列寄存器表 |
| **S1** | 仓库骨架与构建打通 | chip 目录、board 目录、defconfig、ld.script、Make.defs/CMakeLists、Kconfig、manifest 映射 | `build` | 只链代码不改 Kconfig/Make.defs，构建根本不带该芯片 |
| **S2** | SoC 最小闭环 | 启动入口、中断、tick、heap、早期串口 | `boot` | 时钟/中断基址错 → 死在 `nx_start` 前后且无任何日志 |
| **S3** | 最小 NSH | 完整 defconfig、board early/late hook、console | `device`（提示符 + 命令可执行） | 串口只出不进；只出横幅但按键无反应 |
| **S4** | 板级基础外设 | 存储链路 + 控制类外设 + 每外设一条测试命令 | `device`（节点出现）→ `data`（读写/事件正确） | 设备节点出现但数据不对；挂载失败 |
| **S5** | 显示与输入 | framebuffer、面板/背光、触摸或按键、input 注册 | `data`（画面可见、事件上报） | 背光时序、面板初始化、坐标/ID 配置 |
| **S6** | 音频/网络/上层 | 音频采播、有线/无线网络、UI/演示应用 | `data` | DMA 数据面、PHY 链路、固件下载 |

## 3. 每阶段详细门禁

### S1 构建打通

必须同时满足（`validate_stage.sh <repo> S1`）：
- 启动汇编 + 中断源 + 串口源存在；
- defconfig、`ld.script`/`*.ld`、板级 `Make.defs` 存在；
- 芯片/板级至少有一处构建接入（`Make.defs` 的 `CSRCS` 或 CMake 的 `SRCS`/`target_sources`）；
- 板级 bringup/boot 源存在。

卡点：
- vendor 树的顶层 `Kconfig`/`Make.defs` 只认已支持的芯片，**只把新芯片目录放进去不会被编译**。要么补映射，要么走自定义芯片机制（见 `board_port_wiring.md`）。
- Kconfig 里 `select` 一类的改动**必须干净重建**（删掉构建缓存目录），增量构建不会重新展开 Kconfig，`.config` 还是旧值。

### S2 SoC 最小闭环

必须同时满足（`validate_stage.sh <repo> S2`）：
- `__start` 入口；`up_irqinitialize`；中断分发路径（`irq_attach`/`riscv_dispatch_irq`）；
- `up_timer_initialize`；`up_allocate_heap`/`umm_initialize`；`up_putc`；
- defconfig 选中定制芯片与 console 串口。

判定顺序（有依赖，别跳）：
1. 先让**第一条汇编**直写串口发送寄存器（不依赖栈、gp、CSR、C 运行时）——能打出字符，就同时证明了跳转地址和串口基址。
2. 再验证中断控制器与 timer 的**基址**，这两个写错会表现为"什么都没有"而不是报错。
3. 最后才谈 heap / 调度。

### S3 最小 NSH

必须同时满足（`validate_stage.sh <repo> S3`）：
- `CONFIG_SYSTEM_NSH=y`、`CONFIG_INIT_ENTRYPOINT="nsh_main"`；
- `board_early_initialize`/`board_late_initialize` 已实现；
- 至少一个内置应用（`CONFIG_BUILTIN=y`）可供验证；
- 建议开 `CONFIG_FS_PROCFS=y`，否则 `ps`/`free` 不可用。

**"最小 NSH 起来了"的判定门槛**（三条同时满足才算）：
1. 同一串口出现 `NuttShell (NSH)` 横幅；
2. 出现 `nsh>` 提示符且 `read()` 会阻塞等待输入；
3. 输入 `help` 回车能打印命令列表（能打字 = 串口接收中断 + 任务上下文切换都正常）。

只出横幅不算起来；只出不进最常见的原因是 TX 完成中断/缓冲排空逻辑写错（见 `debug_playbook.md`）。

### S4 板级基础外设

必须同时满足（`validate_stage.sh <repo> S4`）：
- 存储链路有痕迹（MTD/MMCSD）；
- 控制类外设注册 ≥2 类（watchdog/rtc/i2c/pwm/buttons）；
- **每个测试应用都有 README**（记录功能目标、依赖、步骤、预期、实测）。

顺序要求：存储 → 文件系统 → 总线 → 控制类 → DMA。文件系统没通之前不要做依赖资源文件的上层功能。

### S5 显示与输入

- framebuffer 注册 + 背光/显示电源控制；
- input 设备注册（按键/触摸）；
- 判定用 `data`：画面真的出来、事件真的上报（不是"节点存在"就算完）。

### S6 音频/网络/上层

- 音频：DMA 通路 + 采集/播放都用标准框架（`nxrecorder`/`nxplayer`），不要做私有 ioctl；
- 网络：`ifconfig` 有网卡 → DHCP 拿地址 → ping 通 → 才能做 HTTP/应用；
- 上层：UI/演示应用建立在 S5 稳定之后。

## 4. 状态机用法

```bash
# 接手一个已推进到 S3 的仓
scripts/bsp_state.sh init S3

# 某阶段拿到真机证据后再标记完成（等级必须如实填）
scripts/bsp_state.sh complete S3 device
scripts/bsp_state.sh log S3 "UART0 出现 nsh>，help 正常输出"
scripts/bsp_state.sh note S3 "console=ttyS0; baud=115200"

# 进入下一阶段前做门禁（前置阶段证据不足会 exit 2）
scripts/bsp_state.sh gate S4 && scripts/validate_stage.sh <repo> S4

scripts/bsp_state.sh status
```

## 5. 阶段边界（不要越界）

- S3 未达标前，不碰显示/触摸/音频/UI：这些会掩盖真正的 SoC 问题。
- S4 存储未稳定前，不引入大资源文件/复杂 UI。
- S5 framebuffer 未稳定前，不进入完整 UI 框架；先保证"刷屏正确"。
- 每个阶段结束都要**回归上一阶段**（例如做完 I2C 后重跑 `hello`，确认 UART/调度没被破坏）。
