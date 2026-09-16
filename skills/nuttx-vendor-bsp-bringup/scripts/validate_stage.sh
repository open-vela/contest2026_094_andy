#!/bin/bash
# validate_stage.sh — vendor BSP 阶段闸门检查
# 契约：全部 PASS/WARN → exit 0；出现 FAIL → exit 2 + stderr 说明
#
# 用法：
#   validate_stage.sh <team_repo_dir> <S1|S2|S3|S4|S5|S6>
#
# 设计原则：
#   - 只做“看得见的证据”检查（文件、符号、Kconfig、注册调用、README），不猜。
#   - FAIL = 该阶段声称完成但缺少必要痕迹；WARN = 建议补齐，不阻塞。
#   - 每个阶段都对应 references/stages_and_gates.md 里的验收标准。
#
# 退出码：0 通过；2 有 FAIL；1 参数错误。

set -u

REPO="${1:-}"; STAGE="${2:-}"
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
  echo "ERROR: 用法 validate_stage.sh <team_repo_dir> <S1..S6>；目录不存在：${REPO:-<空>}" >&2
  exit 1
fi
case "$STAGE" in
  S1|S2|S3|S4|S5|S6) ;;
  *) echo "ERROR: 阶段必须是 S1..S6（S0 无产物可查）" >&2; exit 1 ;;
esac

REPO_ABS="$(cd "$REPO" && pwd)"
FAILS=0
pass() { printf '  [PASS] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS + 1)); }

have_file() { [ -f "$REPO_ABS/$1" ]; }
any_file()  { find "$REPO_ABS" -type f \( "$@" \) -not -path '*/.git/*' 2>/dev/null | head -1; }
grep_repo() { grep -rIl --include='*.c' --include='*.h' --include='*.S' --include='Kconfig' \
                 --include='defconfig' --include='CMakeLists.txt' --include='Make.defs' \
                 -E "$1" "$REPO_ABS" 2>/dev/null | head -3; }
has_sym() { [ -n "$(grep_repo "\b$1\b")" ]; }

DEFCONFIG="$(find "$REPO_ABS" -name defconfig 2>/dev/null | head -1)"
cfg() { [ -n "$DEFCONFIG" ] && grep -qE "^$1" "$DEFCONFIG" 2>/dev/null; }
cfg_eq() { [ -n "$DEFCONFIG" ] && grep -qE "^$1" "$DEFCONFIG" 2>/dev/null; }

echo "# validate $STAGE : ${REPO_ABS##*/}"

case "$STAGE" in
  S1)
    [ -n "$(any_file -name '*_head.S' -o -name '*_start.S' -o -name '*_head.s')" ] \
      && pass "启动汇编存在" || fail "缺启动入口汇编（*_head.S / *_start.S）"
    [ -n "$(any_file -name '*_irq.c')" ] && pass "中断源文件存在" || fail "缺中断源文件（*_irq.c）"
    [ -n "$(any_file -name '*_serial.c')" ] && pass "串口源文件存在" || fail "缺串口源文件（*_serial.c）"
    [ -n "$DEFCONFIG" ] && pass "defconfig 存在（${DEFCONFIG#$REPO_ABS/}）" || fail "缺板级 defconfig"
    [ -n "$(any_file -name 'ld.script' -o -name '*.ld')" ] && pass "链接脚本存在" || fail "缺链接脚本（ld.script/*.ld）"
    [ -n "$(any_file -name 'Make.defs')" ] && pass "板级 Make.defs 存在" || fail "缺板级 Make.defs"
    if [ -n "$(any_file -name 'CMakeLists.txt')" ]; then
      if grep -rqE 'list\(APPEND SRCS|set\(SRCS|target_sources' "$REPO_ABS" --include='CMakeLists.txt' 2>/dev/null; then
        pass "CMake 构建接入（SRCS/target_sources）"
      else
        warn "有 CMakeLists.txt 但未见 SRCS/target_sources 接入"
      fi
    else
      fail "缺 CMakeLists.txt（openvela 构建需要）"
    fi
    [ -n "$(any_file -name '*bringup*.c' -o -name '*boot*.c')" ] && pass "板级 bringup/boot 源存在" || fail "缺板级 bringup/boot 源"
    ;;

  S2)
    has_sym '__start'        && pass "启动入口符号 __start" || fail "未见 __start 入口"
    has_sym 'up_irqinitialize' && pass "中断初始化 up_irqinitialize" || fail "未见 up_irqinitialize"
    if has_sym 'irq_attach' || has_sym 'riscv_dispatch_irq' || has_sym 'up_enable_irq'; then
      pass "中断挂接/分发路径存在"
    else
      fail "未见 irq_attach / 分发 / up_enable_irq"
    fi
    has_sym 'up_timer_initialize' && pass "系统 tick 初始化 up_timer_initialize" || fail "未见 up_timer_initialize"
    if has_sym 'up_allocate_heap' || has_sym 'umm_initialize'; then pass "heap 初始化存在"; else fail "未见 up_allocate_heap/umm_initialize"; fi
    if has_sym 'up_putc' || has_sym 'up_puts'; then pass "早期串口输出存在"; else fail "未见 up_putc（早期串口）"; fi
    cfg 'CONFIG_ARCH_CHIP_CUSTOM=y|CONFIG_ARCH_CHIP_[A-Z0-9_]+=y' && pass "定制芯片配置已选" || fail "defconfig 未见 CONFIG_ARCH_CHIP_*"
    if cfg 'CONFIG_[A-Z0-9_]*SERIAL_CONSOLE=y|CONFIG_[A-Z0-9_]*UART[0-9]_SERIAL_CONSOLE=y'; then
      pass "控制台串口已选"
    else
      fail "defconfig 未见 console 串口配置"
    fi
    ;;

  S3)
    cfg 'CONFIG_SYSTEM_NSH=y' && pass "CONFIG_SYSTEM_NSH=y" || fail "defconfig 缺 CONFIG_SYSTEM_NSH=y"
    cfg_eq 'CONFIG_INIT_ENTRYPOINT="nsh_main"' && pass 'INIT_ENTRYPOINT="nsh_main"' || fail 'defconfig 缺 CONFIG_INIT_ENTRYPOINT="nsh_main"'
    cfg 'CONFIG_BUILTIN=y' && pass "CONFIG_BUILTIN=y（可在 NSH 调命令）" || warn "未开 CONFIG_BUILTIN，应用无法在 NSH 直接调用"
    if has_sym 'board_late_initialize' || has_sym 'board_early_initialize'; then
      pass "board early/late initialize 已实现"
    else
      fail "未见 board_early_initialize / board_late_initialize"
    fi
    APP_N=$(find "$REPO_ABS/app" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$APP_N" -gt 0 ]; then pass "存在 $APP_N 个应用目录（供 NSH 验证）"; else warn "app/ 下没有应用，NSH 只能靠 shell 内建命令"; fi
    cfg 'CONFIG_FS_PROCFS=y' && pass "procfs 已开（ps/free 可用）" || warn "未开 procfs，ps/free 等诊断命令不可用"
    ;;

  S4)
    # 文档纪律：每个 app 必须有 README
    MISSING=""
    while IFS= read -r d; do
      [ -f "$d/README.md" ] || MISSING="$MISSING $(basename "$d")"
    done < <(find "$REPO_ABS/app" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if [ -z "$MISSING" ]; then
      pass "全部应用都有 README.md（可作回归清单）"
    else
      fail "以下应用缺 README.md：$MISSING"
    fi

    if has_sym 'register_mtddriver' || cfg 'CONFIG_MTD=y' || cfg 'CONFIG_MMCSD=y'; then
      pass "存储链路痕迹存在（MTD/MMCSD）"
    else
      fail "未见 MTD/MMCSD 存储链路（阶段目标是打通存储）"
    fi
    TYPES=0
    if has_sym 'wd_start' || has_sym 'watchdog_register'; then TYPES=$((TYPES + 1)); fi
    if has_sym 'up_rtc_initialize' || has_sym 'rtc_register'; then TYPES=$((TYPES + 1)); fi
    if has_sym 'i2c_register' || has_sym 'i2c_master_register'; then TYPES=$((TYPES + 1)); fi
    if has_sym 'pwm_register'; then TYPES=$((TYPES + 1)); fi
    if has_sym 'btn_register'; then TYPES=$((TYPES + 1)); fi
    if [ "$TYPES" -ge 2 ]; then pass "控制类外设注册 ≥2 类（watchdog/rtc/i2c/pwm/buttons）"; else fail "控制类外设注册不足 2 类"; fi
    if cfg 'CONFIG_WATCHDOG=y|CONFIG_RTC=y|CONFIG_I2C=y|CONFIG_PWM=y'; then
      pass "至少一类控制外设 Kconfig 已开"
    else
      warn "defconfig 未见 watchdog/rtc/i2c/pwm 开关"
    fi
    ;;

  S5)
    if has_sym 'fb_register' || cfg 'CONFIG_VIDEO_FB=y' || [ -n "$(any_file -name '*_fb.c')" ]; then
      pass "framebuffer 痕迹存在"
    else
      fail "未见 framebuffer（fb_register / CONFIG_VIDEO_FB / *_fb.c）"
    fi
    if has_sym 'btn_register' || has_sym 'touchscreen_register' || has_sym 'gt911' || cfg 'CONFIG_INPUT_[A-Z0-9_]+=y'; then
      pass "input 设备痕迹存在"
    else
      fail "未见 input 设备（buttons/touchscreen）"
    fi
    cfg 'CONFIG_INPUT=y|CONFIG_INPUT_[A-Z0-9_]+=y' && pass "input 框架已开" || warn "defconfig 未见 CONFIG_INPUT*"
    if grep -rqE 'FBIOSET_POWER|backlight|PWM.*backlight' "$REPO_ABS" --include='*.c' 2>/dev/null; then
      pass "背光/显示电源控制存在"
    else
      warn "未见背光控制（FBIOSET_POWER/backlight）"
    fi
    ;;

  S6)
    if cfg 'CONFIG_AUDIO=y' || has_sym 'audio_register'; then
      pass "音频链路痕迹存在"
    else
      fail "未见音频（CONFIG_AUDIO / audio_register）"
    fi
    if cfg 'CONFIG_NET=y' || has_sym 'netdev_register'; then
      pass "网络链路痕迹存在"
    else
      fail "未见网络（CONFIG_NET / netdev_register）"
    fi
    if has_sym 'dhcpc' || cfg 'CONFIG_NETUTILS_DHCPC=y' || has_sym 'webclient' || has_sym 'ping'; then
      pass "至少一个网络应用/协议验证入口"
    else
      warn "未见 DHCP/ping/HTTP 等网络验证入口"
    fi
    if find "$REPO_ABS/app" -maxdepth 1 -type d \( -name '*lvgl*' -o -name '*ui*' -o -name '*recorder*' -o -name '*demo*' \) 2>/dev/null | grep -q .; then
      pass "存在上层交互/演示应用"
    else
      warn "未见 LVGL/UI/演示类应用"
    fi
    ;;
esac

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "RESULT: FAIL ($FAILS 项) — 该阶段尚不能标记完成" >&2
  exit 2
fi
echo "RESULT: PASS"
exit 0
