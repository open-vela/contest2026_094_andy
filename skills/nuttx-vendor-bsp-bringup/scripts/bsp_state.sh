#!/bin/bash
# bsp_state.sh — vendor BSP bring-up 阶段状态机
# 契约：成功 exit 0（必要时在 stdout 输出状态），失败 exit 2 + stderr
#
# 用法：
#   bsp_state.sh init [stage]                 初始化 .bsp-bringup/state.json（默认 S0）
#   bsp_state.sh complete <stage> <evidence>  标记阶段完成，evidence ∈ none|build|pack|boot|device|data
#   bsp_state.sh gate <stage>                 门禁：前置阶段必须完成且证据等级达标，否则 exit 2
#   bsp_state.sh evidence <stage>             打印该阶段的证据等级
#   bsp_state.sh log <stage> <text...>        追加一条带时间戳的板测记录到 state.json
#   bsp_state.sh status                       打印全部阶段、证据等级与记录条数
#   bsp_state.sh note <stage> <text...>       记录阶段关键决策（覆盖式，键值请用 k=v）
#
# 证据等级（用于阻止“只编译过就宣称验证通过”）：
#   none=0  build=1  pack=2  boot=3  device=4  data=5
#   build  = 编译通过
#   pack   = 打包出可烧录镜像
#   boot   = 真机出现启动日志 / 提示符
#   device = 真机出现设备节点或框架注册（ls /dev、ifconfig 等）
#   data   = 真机完成数据面验证（读写一致、事件回调、收发包、出声/录音）

set -u

DIR=".bsp-bringup"
FILE="$DIR/state.json"

# 阶段定义：S0..S6 与各阶段门禁所需的最低前置证据等级
STAGES=(S0 S1 S2 S3 S4 S5 S6)
STAGE_NAMES=(
  "资料与参考对表"
  "仓库骨架与构建打通"
  "SoC 最小闭环（启动/中断/tick/早期串口）"
  "最小 NSH"
  "板级基础外设（存储/控制）"
  "显示与输入"
  "音频/网络/上层应用"
)
REQUIRED_EVIDENCE=(none build boot device device data data)  # 该阶段“自己”要达标的等级
EVIDENCE_ORDER=(none build pack boot device data)

ev_rank() {
  local i=0
  for e in "${EVIDENCE_ORDER[@]}"; do
    if [ "$e" = "$1" ]; then echo "$i"; return 0; fi
    i=$((i + 1))
  done
  echo "-1"
}

stage_index() {
  local i=0
  for s in "${STAGES[@]}"; do
    if [ "$s" = "$1" ]; then echo "$i"; return 0; fi
    i=$((i + 1))
  done
  echo "-1"
}

require_state() {
  if [ ! -f "$FILE" ]; then
    echo "ERROR: $FILE 不存在。请先运行 'bsp_state.sh init'" >&2
    exit 2
  fi
}

cmd_init() {
  local start="${1:-S0}"
  if [ "$(stage_index "$start")" -lt 0 ]; then
    echo "ERROR: 未知阶段 $start（可选：${STAGES[*]}）" >&2
    exit 2
  fi
  mkdir -p "$DIR"
  START_STAGE="$start" python3 - "$FILE" <<'PY'
import json, os, sys
stages = ["S0", "S1", "S2", "S3", "S4", "S5", "S6"]
names = [
    "资料与参考对表",
    "仓库骨架与构建打通",
    "SoC 最小闭环（启动/中断/tick/早期串口）",
    "最小 NSH",
    "板级基础外设（存储/控制）",
    "显示与输入",
    "音频/网络/上层应用",
]
start = os.environ["START_STAGE"]
started = stages.index(start)
# 之前阶段视为已完成，并按其自身门禁要求补齐证据等级
required = ["none", "build", "boot", "device", "device", "data", "data"]
state = {
    "workflow": "vendor-bsp-bringup",
    "started": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
    "current": start,
    "stages": {
        s: {
            "name": names[i],
            "status": "completed" if i < started else "pending",
            "evidence": required[i] if i < started else "none",
            "notes": {},
            "records": [],
        }
        for i, s in enumerate(stages)
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(f"initialized {sys.argv[1]} at {start}")
PY
}

cmd_complete() {
  local stage="${1:-}" evidence="${2:-none}"
  require_state
  if [ "$(stage_index "$stage")" -lt 0 ]; then
    echo "ERROR: 未知阶段 '$stage'（可选：${STAGES[*]}）" >&2
    exit 2
  fi
  if [ "$(ev_rank "$evidence")" -lt 0 ]; then
    echo "ERROR: 未知证据等级 '$evidence'（可选：${EVIDENCE_ORDER[*]}）" >&2
    exit 2
  fi
  STAGE="$stage" EVIDENCE="$evidence" python3 - "$FILE" <<'PY'
import json, sys
stage, evidence = __import__("os").environ["STAGE"], __import__("os").environ["EVIDENCE"]
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
s = d["stages"][stage]
s["status"] = "completed"
s["evidence"] = evidence
s["completed_at"] = __import__("datetime").datetime.now().isoformat(timespec="seconds")
d["current"] = stage
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print(f"{stage} completed (evidence={evidence})")
PY
}

cmd_gate() {
  local stage="${1:-}"
  require_state
  local idx
  idx="$(stage_index "$stage")"
  if [ "$idx" -lt 0 ]; then
    echo "ERROR: 未知阶段 '$stage'" >&2
    exit 2
  fi
  if [ "$idx" -eq 0 ]; then
    exit 0
  fi
  STAGE="$stage" python3 - "$FILE" <<'PY'
import json, os, sys
order = ["none", "build", "pack", "boot", "device", "data"]
stages = ["S0", "S1", "S2", "S3", "S4", "S5", "S6"]
required = [0, 1, 3, 4, 4, 5, 5]  # 与脚本头部 REQUIRED_EVIDENCE 对应
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
cur = stages.index(os.environ["STAGE"])
failed = []
for i in range(cur):
    s = d["stages"][stages[i]]
    if s["status"] != "completed":
        failed.append(f"{stages[i]} 未完成")
    elif order.index(s.get("evidence", "none")) < required[i]:
        failed.append(
            f"{stages[i]} 证据等级 {s.get('evidence')} 低于要求 {order[required[i]]}"
        )
if failed:
    for m in failed:
        print(f"ERROR: 门禁未通过 -> {m}", file=sys.stderr)
    sys.exit(2)
PY
}

cmd_evidence() {
  local stage="${1:-}"
  require_state
  STAGE="$stage" python3 - "$FILE" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
s = d["stages"].get(os.environ["STAGE"])
if s is None:
    print(f"ERROR: 未知阶段 {os.environ['STAGE']}", file=sys.stderr)
    sys.exit(2)
print(s.get("evidence", "none"))
PY
}

cmd_log() {
  local stage="${1:-}"; shift || true
  local text="$*"
  require_state
  if [ -z "$text" ]; then
    echo "ERROR: 缺少记录内容。用法：bsp_state.sh log <stage> <text>" >&2
    exit 2
  fi
  STAGE="$stage" TEXT="$text" python3 - "$FILE" <<'PY'
import json, os, sys
from datetime import datetime
stage, text = os.environ["STAGE"], os.environ["TEXT"]
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
s = d["stages"].get(stage)
if s is None:
    print(f"ERROR: 未知阶段 {stage}", file=sys.stderr)
    sys.exit(2)
s.setdefault("records", []).append(
    {"ts": datetime.now().isoformat(timespec="seconds"), "text": text}
)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print(f"logged to {stage}: {text}")
PY
}

cmd_note() {
  local stage="${1:-}"; shift || true
  local kv="$*"
  require_state
  STAGE="$stage" KV="$kv" python3 - "$FILE" <<'PY'
import json, os, sys
stage, kv = os.environ["STAGE"], os.environ["KV"]
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
s = d["stages"].get(stage)
if s is None:
    print(f"ERROR: 未知阶段 {stage}", file=sys.stderr)
    sys.exit(2)
notes = s.setdefault("notes", {})
for item in kv.split(";"):
    item = item.strip()
    if "=" in item:
        k, v = item.split("=", 1)
        notes[k.strip()] = v.strip()
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print(f"noted on {stage}: {kv}")
PY
}

cmd_status() {
  require_state
  python3 - "$FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
print(f"workflow: {d['workflow']}   started: {d['started']}   current: {d.get('current')}")
print(f"{'stage':<5}{'status':<11}{'evidence':<9}{'records':<9}name")
for st, s in d["stages"].items():
    print(f"{st:<5}{s['status']:<11}{s.get('evidence','none'):<9}"
          f"{len(s.get('records', [])):<9}{s.get('name','')}")
PY
}

case "${1:-}" in
  init)     shift; cmd_init "$@" ;;
  complete) shift; cmd_complete "$@" ;;
  gate)     shift; cmd_gate "$@" ;;
  evidence) shift; cmd_evidence "$@" ;;
  log)      shift; cmd_log "$@" ;;
  note)     shift; cmd_note "$@" ;;
  status)   cmd_status ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
