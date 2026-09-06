#!/usr/bin/env bash
# =============================================================================
# attach-gpu.sh —— GPU 直通原语脚本(attach|detach)
#
# attach: 添加 hostpci0(显卡,pcie=1,x-vga=1)+ hostpci1(音频)
# detach: 移除直通并恢复虚拟显示(std)——即"回退法"
# 通用直通细节与排错见 PVE/显卡直通.md
#
# 用法:
#   ./attach-gpu.sh --vmid 200 attach                  # 默认动作;单卡自动,多卡交互列选
#   ./attach-gpu.sh --vmid 200 detach                  # 回退到 noVNC
#   ./attach-gpu.sh --vmid 200 --gpu 03:00.0           # 非自动检测型号时指定(可带 0000: 前缀)
#   ./attach-gpu.sh --vmid 200 --no-xvga               # 不作为主显示
#   ./attach-gpu.sh --vmid 200 --audio-id 1002:ab28    # 兜底音频 ID
#   ./attach-gpu.sh --vmid 200 --log-file /root/attach.log
#   ./attach-gpu.sh --vmid 200 --dry-run / --debug
# =============================================================================
set -euo pipefail

VMID=""
ACTION="attach"
GPU_ADDR=""
AUDIO_ID="1002:ab28"
XVGA=1
DRY_RUN=0
DEBUG=0
LOG_FILE="/var/log/pve-attach-gpu.log"
rc=0
DIED=0
BKUP=""

# ---- 日志:分级 + 时间戳,终端与日志文件双写 ----------------------------------
logn() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE"; }
info() { logn 信息 "$*"; }
ok()   { logn 完成 "$*"; }
warn() { logn 警告 "$*"; }
die()  { DIED=1; logn 错误 "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1($2),请先安装再运行"; }

ask_confirm() {  # $1=提示语;输入 Y/y 返回 0,取消或输入流结束返回 1
    local ans
    if ! read -r -p "$1" ans; then
        warn "输入流已结束(非交互环境?),按取消处理"
        return 1
    fi
    [[ "$ans" == "Y" || "$ans" == "y" ]]
}

backup_conf() {  # 改动前备份,失败/回滚提示由 EXIT trap 给出
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p /root/backup
    BKUP="/root/backup/vm-$VMID-${0##*/}-$ts.conf"
    cp "$CONF" "$BKUP"
    ok "conf 已备份: $BKUP"
}

qm_apply() {  # 封装 qm set:失败带完整输出
    local out
    info "执行: qm set $VMID $*"
    out=$(qm set "$VMID" "$@" 2>&1) || die "qm set 失败: $out"
    [[ -n "$out" ]] && logn 输出 "$out"
}

verify_key() {  # $1=conf 键名(如 hostpci0);写入后回读确认
    local line
    line=$(qm config "$VMID" | grep -E "^$1:" || true)
    if [[ -n "$line" ]]; then
        ok "conf 已写入: $line"
    else
        die "回读 conf 未见 $1:,可能未生效;可用备份还原($BKUP)"
    fi
}

verify_gone() {  # $1=conf 键名(如 hostpci0);移除后确认已消失
    if qm config "$VMID" | grep -qE "^$1:"; then
        die "回读 conf 仍存在 $1:,移除未生效;可用备份还原($BKUP)"
    fi
    ok "conf 已移除 $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)   [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --gpu)    [[ $# -ge 2 ]] || die "--gpu 需要参数值"; GPU_ADDR="$2"; shift 2 ;;
        --audio-id) [[ $# -ge 2 ]] || die "--audio-id 需要参数值"; AUDIO_ID="$2"; shift 2 ;;
        --no-xvga) XVGA=0; shift ;;
        --log-file) [[ $# -ge 2 ]] || die "--log-file 需要参数值"; LOG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) awk 'NR>2 { if (/^# ====/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        attach|detach) ACTION="$1"; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

info "===== $0 $ACTION 启动(VMID=${VMID:-<未指定>},GPU=${GPU_ADDR:-自动检测},DRY_RUN=$DRY_RUN) ====="
if [[ $DEBUG -eq 1 ]]; then PS4='+[${LINENO}] '; set -x; fi
trap 'rc=$?; if [ $rc -ne 0 ] && [ $DIED -eq 0 ]; then
    logn 失败 "第 $LINENO 行: $BASH_COMMAND(状态 $rc)" >&2
fi
if [ $rc -ne 0 ] && [ -n "$BKUP" ]; then
    echo "[回滚提示] 如需还原配置: cp $BKUP $CONF" >&2
fi
exit $rc' EXIT

[[ $EUID -eq 0 ]] || die "请以 root 运行"
[[ -n "$VMID" ]] || die "缺少 --vmid"
[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid 必须是数字: $VMID"
CONF="/etc/pve/qemu-server/$VMID.conf"
[[ -e "$CONF" ]] || die "VMID $VMID 配置文件不存在"
STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)
[[ "$STATUS" == "running" ]] && die "VM $VMID 运行中——直通配置要求完全关机后再开机,请先 qm stop $VMID"
require qm "proxmox-ve"
require lspci "pciutils"   # 下文统一用 lspci -D:地址含 PCI domain(如 0000:03:00.0),多域主机亦正确

list_vfio_gpus() {  # 被 vfio-pci 接管的显示类设备(含域的 PCI 地址列表)
    local addr
    while read -r addr; do
        [[ -n "$addr" ]] || continue
        lspci -D -nnk -s "$addr" 2>/dev/null | grep -q 'Kernel driver in use: vfio-pci' && echo "$addr"
    done < <(lspci -D -nn | awk '/VGA compatible controller|Display controller|3D controller/{print $1}')
}
gpu_desc() { lspci -D -nn -s "$1" 2>/dev/null | sed -E \
    's/^[0-9a-f:.]+ //;
     s/^VGA compatible controller: //; s/^Display controller: //; s/^3D controller: //;
     s/\(rev [0-9a-f]+\)//; s/\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]//g;
     s/[[:space:]]+/ /g' | xargs; }
find_slot_audio() {  # 同槽位(bus:slot)的音频功能 —— 同卡 HDMI/DP 音频
    local slot=${1%.*}
    lspci -D -nn | awk -v s="$slot" '$1 ~ "^" s "[.][0-9a-f]+$" && /Audio device/{print $1; exit}'
}
detect_audio() {     # 兜底:全局按 AUDIO_ID(默认 1002:ab28)查找音频功能
    lspci -D -nn | awk -v id="$AUDIO_ID" '$0 ~ "\\[" id "\\]" {print $1; exit}' 2>/dev/null || true
}
is_igpu() {          # Intel 集成显卡(HD/UHD/Iris 型号;独立 Arc 不含这些字样)
    lspci -D -nn -s "$1" 2>/dev/null | grep -qiE 'Intel Corporation.*(UHD Graphics|HD Graphics|Iris|Graphics Adapter)'
}

# 已被其他 VM 直通的 PCI 地址映射(hostpciN 首字段,去 0000: 前缀归一化)
declare -A busy_vm=()
for f in /etc/pve/qemu-server/*.conf; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$CONF" ]] && continue
    vmid=${f##*/}; vmid=${vmid%.conf}
    while IFS= read -r line; do
        addr=$(echo "$line" | sed -nE 's/^hostpci[0-9]+: ([0-9a-fA-F:.]+).*/\1/p')
        [[ -n "$addr" ]] && busy_vm["${addr#0000:}"]="$vmid"
    done < <(grep -E '^hostpci[0-9]+: ' "$f" || true)
done

if [[ "$ACTION" == "attach" ]]; then
    [[ -z "$GPU_ADDR" || "$GPU_ADDR" =~ ^(0000:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}(\.[0-9a-fA-F])?$ ]] \
        || die "--gpu 地址格式无效: $GPU_ADDR(应为 B:DD.F,如 03:00.0)"
    grep -q '^hostpci0:' "$CONF" && die "conf 已有 hostpci0($(grep '^hostpci0:' "$CONF" | head -1))——如需换卡请先 detach"
    # 显卡:未指定 --gpu 时自动检测(vfio 接管);检测到多张时交互列选
    if [[ -z "$GPU_ADDR" ]]; then
        mapfile -t gpus < <(list_vfio_gpus)
        if [[ ${#gpus[@]} -eq 0 ]]; then
            die "未检测到被 vfio-pci 接管的显卡,请先配置 VFIO(见 显卡直通.md 第 2 节),或 --gpu <地址> 指定"
        elif [[ ${#gpus[@]} -eq 1 ]]; then
            GPU_ADDR="${gpus[0]}"
            info "自动检测到显卡: $GPU_ADDR $(gpu_desc "$GPU_ADDR")"
        else
            info "检测到多张 vfio 显卡,请选择:"
            for k in "${!gpus[@]}"; do
                busy_note=""
                [[ -n "${busy_vm[${gpus[$k]#0000:}]+x}" ]] && busy_note="(已被 VM ${busy_vm[${gpus[$k]#0000:}]} 占用)"
                printf '  [%d] %s %s%s\n' "$k" "${gpus[$k]#0000:}" "$(gpu_desc "${gpus[$k]}")" "${busy_note:+ $busy_note}"
            done
            if ! read -r -p "输入编号(其他键退出): " sel; then
                warn "输入流已结束,取消。"
                exit 0
            fi
            if [[ "$sel" =~ ^[0-9]+$ && $sel -lt ${#gpus[@]} ]]; then
                GPU_ADDR="${gpus[$sel]}"
            else
                info "已取消。"; exit 0
            fi
        fi
    fi
    lspci -D -nn -s "$GPU_ADDR" >/dev/null 2>&1 || die "PCI 地址无效: $GPU_ADDR"
    if ! lspci -D -nnk -s "$GPU_ADDR" 2>/dev/null | grep -q 'vfio-pci'; then
        die "显卡 $GPU_ADDR 未被 vfio-pci 接管,请先配置(见 显卡直通.md 第 2 节)"
    fi
    # 音频:优先同槽位音频功能(同卡 HDMI/DP 音频),找不到再全局按 AUDIO_ID 查
    AUDIO_ADDR=$(find_slot_audio "$GPU_ADDR")
    [[ -z "$AUDIO_ADDR" ]] && AUDIO_ADDR=$(detect_audio)
    # 归属防护:显卡/音频已被其他 VM 直通则拒绝(hostpci 设备只能归一个 VM)
    if [[ -n "${busy_vm[${GPU_ADDR#0000:}]+x}" ]]; then
        die "显卡 $GPU_ADDR 已被 VM ${busy_vm[${GPU_ADDR#0000:}]} 直通,先移除或选其他设备"
    fi
    if [[ -n "$AUDIO_ADDR" && -n "${busy_vm[${AUDIO_ADDR#0000:}]+x}" ]]; then
        die "音频功能 $AUDIO_ADDR 已被 VM ${busy_vm[${AUDIO_ADDR#0000:}]} 直通,先移除"
    fi
    # 核显特别提醒
    if is_igpu "$GPU_ADDR"; then
        warn "[核显] $GPU_ADDR 为 Intel 集成显卡,直通注意:"
        warn "    1. 宿主显示:若宿主无独显输出,直通后宿主将无画面(仅 Web/串口管理)"
        warn "    2. x-vga=1 对核显兼容性差:客机黑屏时改跑 --no-xvga,客户机装 Intel 驱动后接管"
        warn "    3. 核显 HDMI/DP 音频不在本卡槽位(走 PCH HD Audio 等),需另配音频直通"
        warn "    4. 自动检测/候选列表没看到核显 = 未被 vfio-pci 接管,先加 vfio.conf 绑定(见 显卡直通.md §2)"
    fi
    info "将执行:"
    info "  hostpci0 = $GPU_ADDR,pcie=1$([ $XVGA -eq 1 ] && echo ',x-vga=1')"
    if [[ -n "$AUDIO_ADDR" ]]; then
        info "  hostpci1 = $AUDIO_ADDR,pcie=1(音频)"
    else
        info "  (未检测到音频功能,跳过)"
    fi
    [[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
    ask_confirm "确认接入?输入 Y 继续: " || { info "已取消。"; exit 0; }
    backup_conf
    qm_apply -hostpci0 "$GPU_ADDR,pcie=1$([ $XVGA -eq 1 ] && echo ',x-vga=1')"
    verify_key "hostpci0"
    if [[ -n "$AUDIO_ADDR" ]] && ! grep -q "^hostpci1:" "$CONF"; then
        qm_apply -hostpci1 "$AUDIO_ADDR,pcie=1"
        verify_key "hostpci1"
    fi
    ok "显卡直通完成。建议将显示置 none(attach-all 或 qm set -vga none)"
    exit 0
else
    info "将执行 detach:移除显卡/音频直通并恢复 std 显示"
    [[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
    ask_confirm "确认移除?输入 Y 继续: " || { info "已取消。"; exit 0; }
    backup_conf
    if grep -q "^hostpci0:" "$CONF"; then
        qm_apply -delete hostpci0
        verify_gone "hostpci0"
    else
        info "conf 无 hostpci0,跳过"
    fi
    if grep -q "^hostpci1:" "$CONF"; then
        qm_apply -delete hostpci1
        verify_gone "hostpci1"
    else
        info "conf 无 hostpci1,跳过"
    fi
    qm_apply -vga std
    verify_key "vga"
    ok "已回退:noVNC 应恢复画面(需冷启动生效)"
    exit 0
fi
