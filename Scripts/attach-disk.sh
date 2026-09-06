#!/usr/bin/env bash
# =============================================================================
# attach-disk.sh —— 整盘直通原语脚本(attach|detach)
#
# attach: 把物理盘以整盘方式挂到空闲 scsiN(需 --disk by-id 或交互选择)
# detach: 移除指定盘的直通行(不触碰数据)
# 通用直通细节见 PVE/硬盘直通.md;客户机内格式化/挂载另行处理
#
# 用法:
#   ./attach-disk.sh --vmid 200 --disk /dev/disk/by-id/ata-XXXX
#   ./attach-disk.sh --vmid 200                                  # 交互列出候选盘
#   ./attach-disk.sh --vmid 200 --disk /dev/disk/by-id/ata-XXXX detach
#   ./attach-disk.sh --vmid 200 --scsi-index 2
#   ./attach-disk.sh --vmid 200 --log-file /root/attach.log
# =============================================================================
set -euo pipefail

VMID=""
DISK=""
ACTION="attach"
SCSI_IDX=""
DRY_RUN=0
DEBUG=0
LOG_FILE="/var/log/pve-attach-disk.log"
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

verify_key() {  # $1=conf 键名(如 scsi3);写入后回读确认
    local line
    line=$(qm config "$VMID" | grep -E "^$1:" || true)
    if [[ -n "$line" ]]; then
        ok "conf 已写入: $line"
    else
        die "回读 conf 未见 $1:,可能未生效;可用备份还原($BKUP)"
    fi
}

verify_gone() {  # $1=conf 键名(如 scsi3);移除后确认已消失
    if qm config "$VMID" | grep -qE "^$1:"; then
        die "回读 conf 仍存在 $1:,移除未生效;可用备份还原($BKUP)"
    fi
    ok "conf 已移除 $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)  [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --disk)  [[ $# -ge 2 ]] || die "--disk 需要参数值"; DISK="$2"; shift 2 ;;
        --scsi-index) [[ $# -ge 2 ]] || die "--scsi-index 需要参数值"; SCSI_IDX="$2"; shift 2 ;;
        --log-file) [[ $# -ge 2 ]] || die "--log-file 需要参数值"; LOG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) awk 'NR>2 { if (/^# ====/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        attach|detach) ACTION="$1"; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

info "===== $0 $ACTION 启动(VMID=${VMID:-<未指定>},DISK=${DISK:-交互选择},DRY_RUN=$DRY_RUN) ====="
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

find_disk_line() {  # 按真实设备路径归一化匹配 conf 中的直通行(by-id 与 sdX 等价)
    local line path tgt
    tgt=$(readlink -f "$DISK" 2>/dev/null || echo "$DISK")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path=$(echo "$line" | sed -E 's/^[a-z0-9]+[0-9]*: ([^,]+).*/\1/')
        if [[ "$path" == /dev/* ]] && [[ "$(readlink -f "$path" 2>/dev/null || echo "$path")" == "$tgt" ]]; then
            echo "$line"
            return 0
        fi
    done < <(grep -E '^(scsi|sata|ide|virtio)[0-9]+: /dev/' "$CONF" || true)
    return 1
}

if [[ "$ACTION" == "detach" ]]; then
    [[ -n "$DISK" ]] || die "detach 需要 --disk 指定要移除的盘"
    LINE=$(find_disk_line)
    [[ -n "$LINE" ]] || die "conf 中未找到该盘直通行"
    KEY=${LINE%%:*}
    info "将移除: $LINE(仅移除引用,不触碰数据)"
    [[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
    ask_confirm "确认移除?输入 Y 继续: " || { info "已取消。"; exit 0; }
    backup_conf
    qm_apply -delete "$KEY"
    verify_gone "$KEY"
    ok "已移除 $KEY(盘回到宿主可用)"
    exit 0
fi

# attach 前必需工具
require lsblk "util-linux"
require findmnt "util-linux"

# 交互选择候选盘(整盘,排除宿主在用;标注已被其他 VM 直通的盘)
if [[ -z "$DISK" ]]; then
    # 收集其他 VM conf 中已直通的真实盘路径(by-id 与 sdX 归一化对比)
    busy_paths=()
    for f in /etc/pve/qemu-server/*.conf; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$CONF" ]] && continue
        while IFS= read -r line; do
            path=$(echo "$line" | sed -E 's/^[a-z0-9]+[0-9]*: ([^,]+).*/\1/')
            [[ "$path" == /dev/* ]] && busy_paths+=("$(readlink -f "$path" 2>/dev/null || echo "$path")")
        done < <(grep -E '^(scsi|sata|ide|virtio)[0-9]+: /dev/' "$f" || true)
    done
    is_busy() {
        local tgt="$1" p
        for p in "${busy_paths[@]}"; do [[ "$p" == "$tgt" ]] && return 0; done
        return 1
    }
    info "候选整盘(by-id 全家族,排除宿主已挂载):"
    candidates=()
    busy_flags=()
    i=0
    # 通用发现:遍历 by-id,仅收 lsblk TYPE=disk 的整盘(ata/nvme/usb/wwn/scsi…均支持)
    while IFS= read -r name; do
        d="/dev/disk/by-id/$name"
        [[ -e "$d" ]] || continue
        typ=$(lsblk -dno TYPE "$d" 2>/dev/null || true)
        [[ "$typ" == "disk" ]] || continue
        findmnt -n "$d" >/dev/null 2>&1 && continue
        candidates+=("$d")
        b=0; is_busy "$(readlink -f "$d" 2>/dev/null || echo "$d")" && b=1
        busy_flags+=("$b")
        model=$(lsblk -dno MODEL "$d" 2>/dev/null | xargs || true)   # 可含空格,统一去首尾空白
        serial=$(lsblk -dno SERIAL "$d" 2>/dev/null | xargs || true)
        size=$(lsblk -dno SIZE "$d" 2>/dev/null || echo ?)
        name_str="$model${serial:+ [$serial]}"
        [[ -z "$name_str" ]] && name_str=$(basename "$d")            # 兜底:无型号信息时用 by-id 短名
        printf '  [%d] %s (%s)%s\n' "$i" "$name_str" "$size" "$([ "$b" -eq 1 ] && echo ' ← 已被其他 VM 直通')"
        i=$((i + 1))
    done < <(ls -1 /dev/disk/by-id/ 2>/dev/null || true)
    [[ ${#candidates[@]} -gt 0 ]] || die "无候选整盘(确认盘已连接且为整块盘,或以 --disk 直指)"
    if ! read -r -p "输入编号(其他键退出): " sel; then
        warn "输入流已结束,取消。"
        exit 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ && $sel -lt ${#candidates[@]} ]]; then
        [[ ${busy_flags[$sel]} -eq 1 ]] && die "该盘已被其他 VM 直通,拒绝双挂(数据安全)"
        DISK="${candidates[$sel]}"
    else
        info "已取消。"; exit 0
    fi
fi
[[ -e "$DISK" ]] || die "盘不存在: $DISK"
typ=$(lsblk -dno TYPE "$DISK" 2>/dev/null || true)
[[ "$typ" == "disk" ]] || die "目标不是整盘(TYPE=${typ:-未知})。整盘直通请用整块盘 by-id,不要用分区/阵列设备"
findmnt -n "$DISK" >/dev/null 2>&1 && die "盘被宿主挂载,拒绝直通"
find_disk_line | grep -q . && die "该盘已在直通中"

if [[ -z "$SCSI_IDX" ]]; then
    SCSI_IDX=0
    while grep -qE "^scsi${SCSI_IDX}:" "$CONF"; do SCSI_IDX=$((SCSI_IDX + 1)); done
else
    [[ "$SCSI_IDX" =~ ^[0-9]+$ ]] || die "--scsi-index 必须是非负整数: $SCSI_IDX"
fi
info "将执行: scsi${SCSI_IDX} = $DISK(整盘直通,不格式化)"
[[ $DRY_RUN -eq 1 ]] && { info "dry-run 结束,未做修改。"; exit 0; }
ask_confirm "确认接入?输入 Y 继续: " || { info "已取消。"; exit 0; }
backup_conf
qm_apply "-scsi${SCSI_IDX}" "$DISK"
verify_key "scsi${SCSI_IDX}"
ok "已挂载 scsi${SCSI_IDX};客户机内初始化(格式化/挂载)见对应客机 init 脚本"
exit 0
