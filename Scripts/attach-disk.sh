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
# =============================================================================
set -euo pipefail

VMID=""
DISK=""
ACTION="attach"
SCSI_IDX=""
DRY_RUN=0
DEBUG=0
rc=0

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)  [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --disk)  [[ $# -ge 2 ]] || die "--disk 需要参数值"; DISK="$2"; shift 2 ;;
        --scsi-index) [[ $# -ge 2 ]] || die "--scsi-index 需要参数值"; SCSI_IDX="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --debug)   DEBUG=1; shift ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    echo "将移除: $LINE(仅移除引用,不触碰数据)"
    [[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
    read -r -p "确认移除?输入 Y 继续: " ans
    [[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
    qm set "$VMID" -delete "$KEY"
    log "已移除 $KEY(盘回到宿主可用)"
    exit 0
fi

# 交互选择候选盘(未挂载整盘,排除宿主在用)
if [[ -z "$DISK" ]]; then
    echo "[信息] 候选整盘(排除宿主已挂载):"
    candidates=()
    i=0
    for d in /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-* /dev/disk/by-id/usb-*; do
        [[ -e "$d" ]] || continue
        case "$d" in *-part*) continue ;; esac
        findmnt -n "$d" >/dev/null 2>&1 && continue
        candidates+=("$d")
        printf '  [%d] %s (%s)\n' "$i" "$d" "$(lsblk -dno SIZE "$d" 2>/dev/null || echo ?)"
        i=$((i + 1))
    done
    [[ ${#candidates[@]} -gt 0 ]] || die "无候选盘"
    read -r -p "输入编号(其他键退出): " sel
    if [[ "$sel" =~ ^[0-9]+$ && $sel -lt ${#candidates[@]} ]]; then
        DISK="${candidates[$sel]}"
    else
        echo "已取消。"; exit 0
    fi
fi
[[ -e "$DISK" ]] || die "盘不存在: $DISK"
findmnt -n "$DISK" >/dev/null 2>&1 && die "盘被宿主挂载,拒绝直通"
find_disk_line | grep -q . && die "该盘已在直通中"

if [[ -z "$SCSI_IDX" ]]; then
    SCSI_IDX=0
    while grep -qE "^scsi${SCSI_IDX}:" "$CONF"; do SCSI_IDX=$((SCSI_IDX + 1)); done
fi
echo "将执行: scsi${SCSI_IDX} = $DISK(整盘直通,不格式化)"
[[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run 结束。"; exit 0; }
read -r -p "确认接入?输入 Y 继续: " ans
[[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }
qm set "$VMID" -scsi${SCSI_IDX} "$DISK"
log "已挂载 scsi${SCSI_IDX};客户机内初始化(格式化/挂载)见对应客机 init 脚本"
