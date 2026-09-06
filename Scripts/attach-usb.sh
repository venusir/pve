#!/usr/bin/env bash
# =============================================================================
# attach-usb.sh —— USB 设备直通原语脚本(attach|detach)
#
# attach: 按 VID:PID 挂载到空闲 usbN 口(默认 usb3=0 兼容旧写法,USB3 通路用 --usb3)
# detach: 移除指定 VID:PID 的直通行
# 通用 USB 直通细节见 PVE/Xbox直通.md
#
# 用法:
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe --usb3    # 走 xHCI(USB3)通路
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe detach
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe --dry-run
# =============================================================================
set -euo pipefail

VMID=""
VIDPID=""
ACTION="attach"
USB3=0
DRY_RUN=0
DEBUG=0
rc=0

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)   [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --vidpid) [[ $# -ge 2 ]] || die "--vidpid 需要参数值"; VIDPID="$2"; shift 2 ;;
        --usb3)   USB3=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        attach|detach) ACTION="$1"; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

echo "[启动] $(date '+%F %T') | $(basename "$0") $ACTION | VMID=${VMID:-<未指定>} | VID:PID=${VIDPID:-<未指定>}"
if [[ $DEBUG -eq 1 ]]; then PS4='+[${LINENO}] '; set -x; fi
trap 'echo "[失败] 终止于第 $LINENO 行: $BASH_COMMAND(状态 $?)" >&2' ERR
trap 'rc=$?; echo "[退出] $(date "+%F %T") 状态 $rc"' EXIT

[[ $EUID -eq 0 ]] || die "请以 root 运行"
[[ -n "$VMID" ]] || die "缺少 --vmid"
CONF="/etc/pve/qemu-server/$VMID.conf"
[[ -e "$CONF" ]] || die "VMID $VMID 配置文件不存在"

if [[ "$ACTION" == "detach" ]]; then
    [[ -n "$VIDPID" ]] || die "detach 需要 --vidpid 指定要移除的设备"
    LINE=$(grep -E "^usb[0-9]+:.*host=${VIDPID//:/:}" "$CONF" || true)
    [[ -n "$LINE" ]] || die "conf 中未找到 host=$VIDPID 的直通行"
    KEY=${LINE%%:*}
    echo "将移除: $LINE"
    [[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
    read -r -p "确认移除?输入 Y 继续: " ans
    [[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
    qm set "$VMID" -delete "$KEY"
    log "已移除 $KEY"
    exit 0
fi

[[ -n "$VIDPID" ]] || die "缺少 --vidpid(如 045e:02fe);宿主机先 lsusb 确认设备在"
grep -qE "^usb[0-9]+:.*host=${VIDPID//:/:}" "$CONF" && die "该 VID:PID 已在直通中($(grep -E "usb[0-9]+:.*host=${VIDPID//:/:}" "$CONF"))"
# 宿主确认
lsusb -d "$VIDPID" >/dev/null 2>&1 || die "宿主机未检测到 $VIDPID(lsusb -d 确认)"

# 找空闲 usbN
IDX=0
while grep -qE "^usb${IDX}:" "$CONF"; do IDX=$((IDX + 1)); done
SUFFIX=""
[[ $USB3 -eq 0 ]] && SUFFIX=",usb3=0"
echo "将执行: usb${IDX} = host=${VIDPID}${SUFFIX}"
[[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
read -r -p "确认接入?输入 Y 继续: " ans
[[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
qm set "$VMID" -usb${IDX} "host=${VIDPID}${SUFFIX}"
log "已挂载 usb${IDX}(配置改动需完全关机再开机生效)"
