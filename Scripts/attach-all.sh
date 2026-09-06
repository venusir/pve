#!/usr/bin/env bash
# =============================================================================
# attach-all.sh —— 直通设备组合接入(显卡+音频+USB+直通盘+自启)
#
# 调用同目录原语:attach-gpu.sh / attach-usb.sh / attach-disk.sh
# 并完成:vga none(画面走直通卡)、startup order=1(开机自启)
# 与客机系统无关(Windows / Linux 通用),名字不带客机即因此
#
# 用法:
#   ./attach-all.sh --vmid 200 --dry-run                 # 先审
#   ./attach-all.sh --vmid 200 --vidpid 045e:02fe        # 接入(Xbox 适配器默认例子)
#   ./attach-all.sh --vmid 200 --skip-usb --skip-disk    # 只做显卡+显示+自启
#   ./attach-all.sh --vmid 200 --no-startup
# =============================================================================
set -euo pipefail

VMID=""
VIDPID="045e:02fe"
SKIP_GPU=0
SKIP_USB=0
SKIP_DISK=0
NO_STARTUP=0
DRY_RUN=0
DEBUG=0
rc=0

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)      [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --vidpid)    [[ $# -ge 2 ]] || die "--vidpid 需要参数值"; VIDPID="$2"; shift 2 ;;
        --skip-gpu)  SKIP_GPU=1; shift ;;
        --skip-usb)  SKIP_USB=1; shift ;;
        --skip-disk) SKIP_DISK=1; shift ;;
        --no-startup) NO_STARTUP=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --debug)     DEBUG=1; shift ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

echo "[启动] $(date '+%F %T') | $(basename "$0") | VMID=${VMID:-<未指定>}"
echo "[启动] 组件: GPU${SKIP_GPU:+[跳过]} / USB${SKIP_USB:+[跳过]}(VID:PID=$VIDPID) / DISK${SKIP_DISK:+[跳过]} / vga none / startup${NO_STARTUP:+[跳过]}"
if [[ $DEBUG -eq 1 ]]; then PS4='+[${LINENO}] '; set -x; fi
trap 'echo "[失败] 终止于第 $LINENO 行: $BASH_COMMAND(状态 $?)" >&2' ERR
trap 'rc=$?; echo "[退出] $(date "+%F %T") 状态 $rc"' EXIT

[[ $EUID -eq 0 ]] || die "请以 root 运行"
[[ -n "$VMID" ]] || die "缺少 --vmid"
CONF="/etc/pve/qemu-server/$VMID.conf"
[[ -e "$CONF" ]] || die "VMID $VMID 配置文件不存在"
STATUS=$(qm status "$VMID" | awk '{print $2}' || true)
if [[ "$STATUS" == "running" ]]; then
    die "VM 运行中,必须先关机(直通配置要求冷启动)"
fi

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
COMMON=()
[[ $DRY_RUN -eq 1 ]] && COMMON+=(--dry-run)
[[ $DEBUG -eq 1 ]] && COMMON+=(--debug)

# 先汇总干跑:每个原语 dry-run 一轮,再统一确认执行
if [[ $DRY_RUN -eq 1 ]]; then
    echo "=== 各组件 dry-run ==="
    [[ $SKIP_GPU -eq 0 ]] && bash "$SELF_DIR/attach-gpu.sh" --vmid "$VMID" "${COMMON[@]}"
    [[ $SKIP_USB -eq 0 ]] && bash "$SELF_DIR/attach-usb.sh" --vmid "$VMID" --vidpid "$VIDPID" "${COMMON[@]}"
    [[ $SKIP_DISK -eq 0 ]] && bash "$SELF_DIR/attach-disk.sh" --vmid "$VMID" "${COMMON[@]}"
    echo "=== 组合附加项 ==="
    echo "  vga none(画面走直通卡);startup order=1$([ $NO_STARTUP -eq 1 ] && echo '(跳过)')"
    echo "[信息] attach-all dry-run 完成,未做修改。"
    exit 0
fi

read -r -p "确认接入全部组件?输入 Y 继续,其他键退出: " ans
[[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }

# 备份 conf
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /root/backup
cp "$CONF" "/root/backup/vm-$VMID-attach-$TS.conf" && log "conf 已备份:/root/backup/vm-$VMID-attach-$TS.conf"

[[ $SKIP_GPU -eq 0 ]] && bash "$SELF_DIR/attach-gpu.sh" --vmid "$VMID" "${COMMON[@]}"
[[ $SKIP_USB -eq 0 ]] && bash "$SELF_DIR/attach-usb.sh" --vmid "$VMID" --vidpid "$VIDPID" "${COMMON[@]}"
[[ $SKIP_DISK -eq 0 ]] && bash "$SELF_DIR/attach-disk.sh" --vmid "$VMID" "${COMMON[@]}"

log "显示置 none(画面完全走直通卡)"
qm set "$VMID" -vga none

if [[ $NO_STARTUP -eq 0 ]]; then
    log "设置开机自启 startup order=1"
    qm set "$VMID" -startup order=1
fi

echo
log "接入完成。核对:"
qm config "$VMID" | grep -E '^(hostpci|usb[0-9]+:|scsi[1-9]+:|vga|startup)'
echo "  启动 VM 后 noVNC 黑屏 = 正常;画面在直通卡物理输出。"
