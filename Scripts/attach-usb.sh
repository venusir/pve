#!/usr/bin/env bash
# =============================================================================
# attach-usb.sh —— USB 设备直通原语脚本(attach|detach)
#
# attach: 按 VID:PID 挂载到空闲 usbN 口(默认 usb3=0 兼容旧写法,USB3 通路用 --usb3)
# detach: 移除指定 VID:PID 的直通行
# 通用 USB 直通细节见 PVE/USB直通.md
#
# 用法:
#   ./attach-usb.sh --vmid 200                               # 交互列出宿主可选 USB 设备
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe            # 按 VID:PID 直选
#   ./attach-usb.sh --vmid 200 --vidpid 045e:02fe --usb3     # 走 xHCI(USB3)通路
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
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)
[[ "$STATUS" == "running" ]] && die "VM $VMID 运行中——直通配置要求完全关机后再开机,请先 qm stop $VMID"

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

# 交互列选:未指定 --vidpid 时列出宿主可选 USB 设备
if [[ -z "$VIDPID" ]]; then
    echo "[信息] 宿主可选 USB 设备(排除 root hub 与本 VM 已挂):"
    declare -a CAND_VID=() CAND_DESC=() CAND_BUSY=()
    used_vp="$(grep -hE '^usb[0-9]+:.*host=[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' /etc/pve/qemu-server/*.conf 2>/dev/null | sed -E 's/.*host=([0-9a-fA-F]{4}:[0-9a-fA-F]{4}).*/\1/' | sort -u || true)"
    i=0
    while IFS= read -r line; do
        [[ "$line" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+):[[:space:]]+ID[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})[[:space:]]+(.*) ]] || continue
        bus=${BASH_REMATCH[1]}
        dev=${BASH_REMATCH[2]}
        vp=${BASH_REMATCH[3]}
        desc=${BASH_REMATCH[4]}
        [[ "$vp" == 1d6b:* ]] && continue                           # root hub/主机控制器
        grep -qE "^usb[0-9]+:.*host=${vp//:/:}" "$CONF" && continue # 已配给本 VM
        busy=""
        grep -q "^${vp}$" <<< "$used_vp" && busy="已被其他 VM 占用"
        CAND_VID+=("$vp"); CAND_DESC+=("$desc"); CAND_BUSY+=("$busy")
        printf '  [%d] %s %s (Bus %s Dev %s)%s\n' "$i" "$vp" "$desc" "$bus" "$dev" "${busy:+ ($busy)}"
        i=$((i + 1))
    done < <(lsusb 2>/dev/null)
    [[ $i -gt 0 ]] || die "宿主无可选 USB 设备(先插设备,或 --vidpid 直选)"
    read -r -p "输入编号(其他键退出): " sel
    if [[ "$sel" =~ ^[0-9]+$ && $sel -lt $i ]]; then
        [[ -n "${CAND_BUSY[$sel]}" ]] && die "该设备已被其他 VM 占用,拒绝双挂"
        VIDPID="${CAND_VID[$sel]}"
    else
        echo "已取消。"; exit 0
    fi
fi
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
qm set "$VMID" "-usb${IDX}" "host=${VIDPID}${SUFFIX}"
log "已挂载 usb${IDX}(配置改动需完全关机再开机生效)"
