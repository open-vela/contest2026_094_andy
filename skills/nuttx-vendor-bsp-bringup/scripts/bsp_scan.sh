#!/bin/bash
# bsp_scan.sh — 盘点一个 vendor BSP 适配仓的当前状态
# 契约：成功 exit 0（报告打到 stdout），参数错误 exit 2
#
# 用法：
#   bsp_scan.sh <team_repo_dir> [--quiet]
#
# 输出 7 个区块：
#   1. 目录结构（chip / board / app）
#   2. SoC 核心文件（启动/中断/串口/tick/heap）
#   3. 板级文件（defconfig / ld.script / Make.defs / bringup）
#   4. Kconfig 与 defconfig 开关
#   5. 已注册设备（register_driver / *_register / /dev 节点字面量）
#   6. 测试应用与 README 覆盖率
#   7. 打包与镜像产物
#
# 用途：接手一个仓、或换芯片复用本 skill 时，先跑一遍确定“现在到底有什么”，
#       避免 AI 凭印象假设某个驱动已经存在。

set -u

REPO="${1:-}"
QUIET="${2:-}"
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
  echo "ERROR: 用法 bsp_scan.sh <team_repo_dir> [--quiet]；目录不存在：${REPO:-<空>}" >&2
  exit 2
fi

say() { [ "$QUIET" = "--quiet" ] || printf '%s\n' "$*"; }
hr()  { say ""; say "== $* =="; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

REPO_ABS="$(cd "$REPO" && pwd)"
say "# BSP scan: $REPO_ABS"

# ---------- 1. 目录结构 ----------
hr "1. 目录结构"
CHIP_DIRS=$(find "$REPO_ABS/chip" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sort)
BOARD_DIRS=$(find "$REPO_ABS/board" -type d -name 'configs' -prune -o -type d -name 'src' -print 2>/dev/null | sort)
APP_DIRS=$(find "$REPO_ABS/app" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

if [ -n "$CHIP_DIRS" ]; then
  while IFS= read -r d; do say "chip:  ${d#$REPO_ABS/}  ($(count_files "$d") files)"; done <<< "$CHIP_DIRS"
else
  say "chip:  (无 chip/ 目录)"
fi
if [ -n "$BOARD_DIRS" ]; then
  while IFS= read -r d; do say "board: ${d#$REPO_ABS/}  ($(count_files "$d") files)"; done <<< "$BOARD_DIRS"
else
  say "board: (无 board/**/src 目录)"
fi
say "app:   $(printf '%s ' $APP_DIRS >/dev/null; [ -n "$APP_DIRS" ] && find "$REPO_ABS/app" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ' || echo 0) 个顶层应用目录"

# ---------- 2. SoC 核心文件 ----------
hr "2. SoC 核心文件"
scan_core() {
  local pat="$1" label="$2"
  local hits
  hits=$(find "$REPO_ABS/chip" -type f -name "$pat" 2>/dev/null | sed "s#$REPO_ABS/##" | sort)
  if [ -n "$hits" ]; then
    while IFS= read -r h; do say "  [x] $label: $h"; done <<< "$hits"
  else
    say "  [ ] $label: 未找到（$pat）"
  fi
}
scan_core '*_head.S'      "启动入口汇编"
scan_core '*_start.c'     "启动 C 入口"
scan_core '*_irq.c'       "中断/异常"
scan_core '*_serial.c'    "串口 console"
scan_core '*_clk*.c'      "时钟"
scan_core '*_reset*.c'    "reset"
scan_core '*_boot.c'      "boot/heap 相关"

# 关键符号（在整个仓内搜）
for sym in up_irqinitialize up_enable_irq up_timer_initialize up_allocate_heap up_putc; do
  n=$(grep -rIl --include='*.c' --include='*.h' --include='*.S' -w "$sym" "$REPO_ABS" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then say "  [x] 符号 $sym （$n 个文件）"; else say "  [ ] 符号 $sym 未出现"; fi
done

# ---------- 3. 板级文件 ----------
hr "3. 板级文件"
check_file() {
  local f="$1" label="$2"
  if [ -f "$REPO_ABS/$f" ]; then say "  [x] $label: $f"; else say "  [ ] $label: 缺少 $f"; fi
}
find "$REPO_ABS/board" -name defconfig 2>/dev/null | while IFS= read -r d; do
  say "  [x] defconfig: ${d#$REPO_ABS/}"
done
find "$REPO_ABS/board" -name 'ld.script' -o -name '*.ld' 2>/dev/null | head -5 | while IFS= read -r d; do
  say "  [x] 链接脚本: ${d#$REPO_ABS/}"
done
find "$REPO_ABS/board" -name 'Make.defs' 2>/dev/null | head -5 | while IFS= read -r d; do
  say "  [x] Make.defs: ${d#$REPO_ABS/}"
done
BRINGUP=$(find "$REPO_ABS/board" -name '*bringup*.c' -o -name '*boot*.c' 2>/dev/null | head -5)
if [ -n "$BRINGUP" ]; then
  while IFS= read -r d; do say "  [x] bringup: ${d#$REPO_ABS/}"; done <<< "$BRINGUP"
else
  say "  [ ] bringup: 未找到 board bringup 文件"
fi
PINMUX=$(find "$REPO_ABS/board" -name 'pinmux*.c' 2>/dev/null | head -3)
[ -n "$PINMUX" ] && say "  [x] pinmux: yes" || say "  [ ] pinmux: 未找到 pinmux*.c"

# ---------- 4. Kconfig 与 defconfig ----------
hr "4. Kconfig 与 defconfig"
KCONFIGS=$(find "$REPO_ABS" -name Kconfig -not -path '*/.git/*' 2>/dev/null | sed "s#$REPO_ABS/##" | sort)
say "Kconfig 文件: $(echo "$KCONFIGS" | grep -c . ) 个"
[ -n "$KCONFIGS" ] && echo "$KCONFIGS" | sed 's/^/  /' | head -10
DEPTH=$(find "$REPO_ABS/board" -name defconfig 2>/dev/null | head -1)
if [ -n "$DEPTH" ]; then
  say "defconfig 关键开关（$DEPTH）："
  for sym in CONFIG_SYSTEM_NSH CONFIG_INIT_ENTRYPOINT CONFIG_ARCH_CHIP_CUSTOM \
             CONFIG_ARCH_BOARD_CUSTOM CONFIG_BUILTIN CONFIG_FS_PROCFS; do
    v=$(grep -E "^$sym=" "$DEPTH" 2>/dev/null | head -1)
    [ -n "$v" ] && say "  [x] $v" || say "  [ ] $sym 未设置"
  done
  say "  defconfig 中 '=y' 项: $(grep -c '=y$' "$DEPTH" 2>/dev/null)"
fi

# ---------- 5. 已注册设备 ----------
hr "5. 已注册设备与节点"
REG=$(grep -rhoE '\b(register_driver|register_blockdriver|register_mtddriver|[a-z0-9_]+_register)\s*\(' \
        --include='*.c' "$REPO_ABS" 2>/dev/null | sed 's/[[:space:]]*($//' | sort | uniq -c | sort -rn | head -25)
[ -n "$REG" ] && say "$REG" || say "  (未发现 register 调用)"
NODES=$(grep -rhoE '"/dev/[A-Za-z0-9_./-]+"' --include='*.c' --include='*.h' "$REPO_ABS" 2>/dev/null \
        | tr -d '"' | sort -u)
if [ -n "$NODES" ]; then
  say "代码中出现的 /dev 节点："
  echo "$NODES" | sed 's/^/  /'
fi

# ---------- 6. 应用与文档覆盖率 ----------
hr "6. 测试应用与 README 覆盖率"
MISSING=0; TOTAL=0
if [ -d "$REPO_ABS/app" ]; then
  while IFS= read -r d; do
    name="$(basename "$d")"
    TOTAL=$((TOTAL + 1))
    if [ -f "$d/README.md" ]; then
      say "  [x] app/$name (README)"
    else
      say "  [ ] app/$name 缺少 README.md"
      MISSING=$((MISSING + 1))
    fi
  done < <(find "$REPO_ABS/app" -mindepth 1 -maxdepth 1 -type d | sort)
fi
say "应用总数: $TOTAL，缺 README: $MISSING"

# ---------- 7. 打包产物 ----------
hr "7. 打包与镜像产物"
find "$REPO_ABS" -name '*.its' -o -name '*.img' -o -name '*.itb' 2>/dev/null | sed "s#$REPO_ABS/##" | head -10 | sed 's/^/  /'
PACKSH=$(find "$REPO_ABS" -name 'pack*.sh' 2>/dev/null | head -3)
[ -n "$PACKSH" ] && say "$PACKSH" | sed "s#$REPO_ABS/#  pack 脚本: #" || say "  (无 pack 脚本)"

# ---------- 汇总 ----------
hr "汇总"
say "chip 文件数:  $(count_files "$REPO_ABS/chip")"
say "board 文件数: $(count_files "$REPO_ABS/board")"
say "app 目录数:   $TOTAL（缺 README $MISSING）"
if [ "$MISSING" -gt 0 ]; then
  say "提示：每个 app 都应有一份 README，记录功能目标/依赖/步骤/预期/实测，否则无法作为回归清单。"
fi
exit 0
