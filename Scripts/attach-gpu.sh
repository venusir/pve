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
#   ./attach-gpu.sh --vmid 200 --gpu 03:00.0           # 非自动检测型号时指定
#   ./attach-gpu.sh --vmid 200 --no-xvga               # 不作为主显示
#   ./attach-gpu.sh --vmid 200 --dry-run
#   ./attach-gpu.sh --vmid 200 --debug
# =============================================================================
set -euo pipefail

VMID=""
ACTION="attach"
GPU_ADDR=""
AUDIO_ID="1002:ab28"
XVGA=1
DRY_RUN=0
DEBUG=0
rc=0

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)   [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --gpu)    [[ $# -ge 2 ]] || die "--gpu 需要参数值"; GPU_ADDR="$2"; shift 2 ;;
        --audio-id) [[ $# -ge 2 ]] || die "--audio-id 需要参数值"; AUDIO_ID="$2"; shift 2 ;;
        --no-xvga) XVGA=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        attach|detach) ACTION="$1"; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

echo "[启动] $(date '+%F %T') | $(basename "$0") $ACTION | VMID=${VMID:-<未指定>}"
if [[ $DEBUG -eq 1 ]]; then PS4='+[${LINENO}] '; set -x; fi
trap 'echo "[失败] 终止于第 $LINENO 行: $BASH_COMMAND(状态 $?)" >&2' ERR
trap 'rc=$?; echo "[退出] $(date "+%F %T") 状态 $rc"' EXIT

[[ $EUID -eq 0 ]] || die "请以 root 运行"
[[ -n "$VMID" ]] || die "缺少 --vmid"
CONF="/etc/pve/qemu-server/$VMID.conf"
[[ -e "$CONF" ]] || die "VMID $VMID 配置文件不存在"
STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)
[[ "$STATUS" == "running" ]] && die "VM $VMID 运行中——直通配置要求完全关机后再开机,请先 qm stop $VMID"

list_vfio_gpus() {   # 被 vfio-pci 接管的显示类设备(PCI 地址列表)
    local addr
    while read -r addr; do
        [[ -n "$addr" ]] || continue
        lspci -nnk -s "$addr" 2>/dev/null | grep -q 'Kernel driver in use: vfio-pci' && echo "$addr"
    done < <(lspci -nn | awk '/VGA compatible controller|Display controller|3D controller/{print $1}')
}
gpu_desc() { lspci -nn -s "$1" 2>/dev/null | sed -E \
    's/^[0-9a-f:.]+ //;
     s/^VGA compatible controller: //; s/^Display controller: //; s/^3D controller: //;
     s/\(rev [0-9a-f]+\)//; s/\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]//g;
     s/[[:space:]]+/ /g' | xargs; }
find_slot_audio() {  # 同槽位(bus:slot)的音频功能 —— 同卡 HDMI/DP 音频
    local slot=${1%.*}
    lspci -nn | awk -v s="$slot" '$1 ~ "^" s "[.][0-9a-f]+$" && /Audio device/{print $1; exit}'
}
detect_audio() {     # 兜底:全局按 AUDIO_ID(默认 1002:ab28)查找音频功能
    lspci -nn | awk -v id="$AUDIO_ID" '$0 ~ "\\[" id "\\]" {print $1; exit}' 2>/dev/null || true
}
is_igpu() {          # Intel 集成显卡(HD/UHD/Iris 型号;独立 Arc 不含这些字样)
    lspci -nn -s "$1" 2>/dev/null | grep -qiE 'Intel Corporation.*(UHD Graphics|HD Graphics|Iris|Graphics Adapter)'
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
    grep -q '^hostpci0:' "$CONF" && die "conf 已有 hostpci0($(grep '^hostpci0:' "$CONF" | head -1))——如需换卡请先 detach"
    # 显卡:未指定 --gpu 时自动检测(vfio 接管);检测到多张时交互列选
    if [[ -z "$GPU_ADDR" ]]; then
        mapfile -t gpus < <(list_vfio_gpus)
        if [[ ${#gpus[@]} -eq 0 ]]; then
            die "未检测到被 vfio-pci 接管的显卡,请先配置 VFIO(见 显卡直通.md 第 2 节),或 --gpu <地址> 指定"
        elif [[ ${#gpus[@]} -eq 1 ]]; then
            GPU_ADDR="${gpus[0]}"
        else
            echo "[信息] 检测到多张 vfio 显卡,请选择:"
            for k in "${!gpus[@]}"; do
                busy_note=""
                [[ -n "${busy_vm[${gpus[$k]#0000:}]+x}" ]] && busy_note="(已被 VM ${busy_vm[${gpus[$k]#0000:}]} 占用)"
                printf '  [%d] %s %s%s\n' "$k" "${gpus[$k]}" "$(gpu_desc "${gpus[$k]}")" "${busy_note:+ $busy_note}"
            done
            read -r -p "输入编号(其他键退出): " sel
            [[ "$sel" =~ ^[0-9]+$ && $sel -lt ${#gpus[@]} ]] || { echo "已取消。"; exit 0; }
            GPU_ADDR="${gpus[$sel]}"
        fi
    fi
    lspci -nn -s "$GPU_ADDR" >/dev/null 2>&1 || die "PCI 地址无效: $GPU_ADDR"
    if ! lspci -nnk -s "$GPU_ADDR" 2>/dev/null | grep -q 'vfio-pci'; then
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
        echo "⚠ [核显] $GPU_ADDR 为 Intel 集成显卡,直通注意:"
        echo "    1. 宿主显示:若宿主无独显输出,直通后宿主将无画面(仅 Web/串口管理)"
        echo "    2. x-vga=1 对核显兼容性差:客机黑屏时改跑 --no-xvga,客户机装 Intel 驱动后接管"
        echo "    3. 核显 HDMI/DP 音频不在本卡槽位(走 PCH HD Audio 等),需另配音频直通"
        echo "    4. 自动检测/候选列表没看到核显 = 未被 vfio-pci 接管,先加 vfio.conf 绑定(见 显卡直通.md §2)"
    fi
    echo "将执行:"
    echo "  hostpci0 = $GPU_ADDR,pcie=1$([ $XVGA -eq 1 ] && echo ',x-vga=1')"
    [[ -n "$AUDIO_ADDR" ]] && echo "  hostpci1 = $AUDIO_ADDR,pcie=1(音频)" || echo "  (未检测到音频功能,跳过)"
    [[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
    read -r -p "确认接入?输入 Y 继续: " ans
    [[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
    qm set "$VMID" -hostpci0 "$GPU_ADDR,pcie=1$([ $XVGA -eq 1 ] && echo ',x-vga=1')"
    if [[ -n "$AUDIO_ADDR" ]] && ! grep -q "^hostpci1:" "$CONF"; then
        qm set "$VMID" -hostpci1 "$AUDIO_ADDR,pcie=1"
    fi
    log "显卡直通完成。建议将显示置 none(attach-all 或 qm set -vga none)"
else
    echo "将执行 detach:移除显卡/音频直通并恢复 std 显示"
    [[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
    read -r -p "确认移除?输入 Y 继续: " ans
    [[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
    grep -q "^hostpci0:" "$CONF" && qm set "$VMID" -delete hostpci0
    grep -q "^hostpci1:" "$CONF" && qm set "$VMID" -delete hostpci1
    qm set "$VMID" -vga std
    log "已回退:noVNC 应恢复画面(需冷启动生效)"
fi
