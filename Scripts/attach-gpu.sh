#!/usr/bin/env bash
# =============================================================================
# attach-gpu.sh —— GPU 直通原语脚本(attach|detach)
#
# attach: 添加 hostpci0(显卡,pcie=1,x-vga=1)+ hostpci1(音频)
# detach: 移除直通并恢复虚拟显示(std)——即"回退法"
# 通用直通细节与排错见 PVE/显卡直通.md
#
# 用法:
#   ./attach-gpu.sh --vmid 200 attach                  # 默认动作,可省略
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

detect_gpu() {
    lspci -nn | awk '/\[1002:73ef\]/{print $1; exit}' 2>/dev/null || true
}
detect_audio() {
    lspci -nn | awk -v id="$AUDIO_ID" '$0 ~ "\\[" id "\\]" {print $1; exit}' 2>/dev/null || true
}

if [[ "$ACTION" == "attach" ]]; then
    [[ -z "$GPU_ADDR" ]] && GPU_ADDR=$(detect_gpu)
    [[ -n "$GPU_ADDR" ]] || die "未自动检测到显卡,请 --gpu <地址> 指定"
    if ! lspci -nnk -s "$GPU_ADDR" 2>/dev/null | grep -q 'vfio-pci'; then
        die "显卡 $GPU_ADDR 未被 vfio-pci 接管,请先配置(见 显卡直通.md 第 2 节)"
    fi
    AUDIO_ADDR=$(detect_audio)
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
