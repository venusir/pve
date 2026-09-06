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
#   ./attach-usb.sh --vmid 200 --log-file /root/attach.log
#   ./attach-usb.sh --vmid 200 --dry-run / --debug
# =============================================================================
set -euo pipefail

VMID=""
VIDPID=""
ACTION="attach"
USB3=0
DRY_RUN=0
DEBUG=0
LOG_FILE="/var/log/pve-attach-usb.log"
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

verify_key() {  # $1=conf 键名(如 usb0);写入后回读确认
    local line
    line=$(qm config "$VMID" | grep -E "^$1:" || true)
    if [[ -n "$line" ]]; then
        ok "conf 已写入: $line"
    else
        die "回读 conf 未见 $1:,可能未生效;可用备份还原($BKUP)"
    fi
}

verify_gone() {  # $1=conf 键名(如 usb0);移除后确认已消失
    if qm config "$VMID" | grep -qE "^$1:"; then
        die "回读 conf 仍存在 $1:,移除未生效;可用备份还原($BKUP)"
    fi
    ok "conf 已移除 $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)   [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --vidpid) [[ $# -ge 2 ]] || die "--vidpid 需要参数值"; VIDPID="$2"; shift 2 ;;
        --usb3)   USB3=1; shift ;;
        --log-file) [[ $# -ge 2 ]] || die "--log-file 需要参数值"; LOG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) awk 'NR>2 { if (/^# ====/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        attach|detach) ACTION="$1"; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

info "===== $0 $ACTION 启动(VMID=${VMID:-<未指定>},VID:PID=${VIDPID:-交互选择},DRY_RUN=$DRY_RUN) ====="
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
require lsusb "usbutils"
[[ -z "$VIDPID" || "$VIDPID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || die "--vidpid 格式无效: $VIDPID(应为 VVVV:PPPP,如 045e:02fe)"

if [[ "$ACTION" == "detach" ]]; then
    [[ -n "$VIDPID" ]] || die "detach 需要 --vidpid 指定要移除的设备"
    LINE=$(grep -E "^usb[0-9]+:.*host=${VIDPID//:/:}" "$CONF" || true)
    [[ -n "$LINE" ]] || die "conf 中未找到 host=$VIDPID 的直通行"
    KEY=${LINE%%:*}
    info "将移除: $LINE"
    [[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
    ask_confirm "确认移除?输入 Y 继续: " || { info "已取消。"; exit 0; }
    backup_conf
    qm_apply -delete "$KEY"
    verify_gone "$KEY"
    ok "已移除 $KEY"
    exit 0
fi

# 交互列选:未指定 --vidpid 时列出宿主可选 USB 设备
if [[ -z "$VIDPID" ]]; then
    info "宿主可选 USB 设备(排除 root hub 与本 VM 已挂):"
    declare -a CAND_VID=() CAND_DESC=() CAND_BUSY=() CAND_LOC=()
    declare -A vp_count=()
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
        CAND_LOC+=("Bus $bus Dev $dev")
        vp_count["$vp"]=$(( ${vp_count["$vp"]:-0} + 1 ))
        printf '  [%d] %s %s (%s)%s\n' "$i" "$vp" "$desc" "Bus $bus Dev $dev" "${busy:+ ($busy)}"
        i=$((i + 1))
    done < <(lsusb 2>/dev/null)
    [[ $i -gt 0 ]] || die "宿主无可选 USB 设备(先插设备,或 --vidpid 直选)"
    if ! read -r -p "输入编号(其他键退出): " sel; then
        warn "输入流已结束,取消。"
        exit 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ && $sel -lt $i ]]; then
        [[ -n "${CAND_BUSY[$sel]}" ]] && die "该设备已被其他 VM 占用,拒绝双挂"
        VIDPID="${CAND_VID[$sel]}"
        info "已选择: $VIDPID ${CAND_DESC[$sel]}(${CAND_LOC[$sel]})"
        if [[ ${vp_count["$VIDPID"]:-0} -gt 1 ]]; then
            warn "宿主存在 ${vp_count["$VIDPID"]} 台同 VID:PID 设备,直通后按同型号匹配,无法精确到端口;"
            warn "    如确实多台同款需区分,请物理插拔区分,或改用 QEMU hostbus/hostaddr 指定端口直通。"
        fi
    else
        info "已取消。"; exit 0
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
info "将执行: usb${IDX} = host=${VIDPID}${SUFFIX}"
[[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
ask_confirm "确认接入?输入 Y 继续: " || { info "已取消。"; exit 0; }
backup_conf
qm_apply "-usb${IDX}" "host=${VIDPID}${SUFFIX}"
verify_key "usb${IDX}"
ok "已挂载 usb${IDX}(配置改动需完全关机再开机生效)"
exit 0
