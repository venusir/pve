#!/usr/bin/env bash
# =============================================================================
# bazzite-deploy.sh —— PVE 一键创建 Bazzite Deck 虚拟机(建机阶段)
#
# 适用:Proxmox VE 8.x/9.x,配合 Bazzite部署指南.md 使用
#
# 创建(Linux 客机,无 TPM/Secure Boot 需求):
#   q35 + OVMF(UEFI,不预置 Secure Boot 密钥)+ host CPU + VirtIO SCSI
#   + VirtIO 网卡 + Bazzite ISO 光驱
# 注:直通设备接入不在此脚本——装完系统后用 Scripts/attach-all.sh(客机无关)
#    (该脚本与客机系统无关,名字为历史遗留)
#
# 安全承诺:VMID 被占用拒绝创建;不执行任何删除操作
#
# 用法:
#   ./bazzite-deploy.sh [参数]
#   --vmid N          虚拟机 ID(默认 100;被占用自动顺延)
#   --name NAME       VM 名称(默认 bazzite)
#   --memory MB       内存 MB(默认 16384,Bazzite 最低 4096)
#   --cores N         CPU 核数(默认 4)
#   --disk-size G     系统盘大小 GB(默认 128)
#   --iso FILE        Bazzite ISO 文件名(自动检测 *azzite*.iso)
#   --storage NAME    VM 磁盘存储(自动检测 local-lvm 等)
#   --iso-store NAME  ISO 所在存储(自动检测 local)
#   --bridge NAME     网卡桥接(自动检测 vmbr0)
#   --dry-run         只打印配置,不创建
#   --debug           开启 set -x 跟踪
#   -h, --help        帮助
# =============================================================================
set -euo pipefail

VMNAME="bazzite"
MEMORY=16384
CORES=4
DISK_SIZE=128

VMID=""
ISO_FILE=""
STORAGE=""
ISO_STORE=""
BRIDGE=""
DRY_RUN=0
DEBUG=0
rc=0

usage() {
    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)      [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --name)      [[ $# -ge 2 ]] || die "--name 需要参数值"; VMNAME="$2"; shift 2 ;;
        --memory)    [[ $# -ge 2 ]] || die "--memory 需要参数值"; MEMORY="$2"; shift 2 ;;
        --cores)     [[ $# -ge 2 ]] || die "--cores 需要参数值"; CORES="$2"; shift 2 ;;
        --disk-size) [[ $# -ge 2 ]] || die "--disk-size 需要参数值"; DISK_SIZE="$2"; shift 2 ;;
        --iso)       [[ $# -ge 2 ]] || die "--iso 需要参数值"; ISO_FILE="$2"; shift 2 ;;
        --storage)   [[ $# -ge 2 ]] || die "--storage 需要参数值"; STORAGE="$2"; shift 2 ;;
        --iso-store) [[ $# -ge 2 ]] || die "--iso-store 需要参数值"; ISO_STORE="$2"; shift 2 ;;
        --bridge)    [[ $# -ge 2 ]] || die "--bridge 需要参数值"; BRIDGE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --debug)     DEBUG=1; shift ;;
        -h|--help)   usage ;;
        *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
done

echo "[启动] $(date '+%F %T') | $(basename "$0") | 参数: $* | 宿主机: $(hostname)"
echo "[启动] 干跑(不执行): $([ $DRY_RUN -eq 1 ] && echo 是 || echo 否) | 调试跟踪: $([ $DEBUG -eq 1 ] && echo 开 || echo 关)"

if [[ $DEBUG -eq 1 ]]; then
    PS4='+[${LINENO}] '
    set -x
fi
err_trap() {
    echo "[失败] 脚本终止于第 $1 行,命令: $2(退出状态 $3)" >&2
}
trap 'err_trap "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'rc=$?; echo "[退出] $(date "+%F %T") $(basename "$0") 结束,状态 $rc"' EXIT

# ---- 预检 -------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "请以 root 运行"
command -v qm >/dev/null || die "未找到 qm,确认这是在 PVE 宿主机上运行"

if [[ -z "$VMID" ]]; then
    VMID=100
    while qm list | awk '{print $1}' | grep -qw "$VMID"; do
        VMID=$((VMID + 1))
        [[ $VMID -le 300 ]] || die "100-300 区间无空闲 VMID"
    done
fi
qm list | awk '{print $1}' | grep -qw "$VMID" && die "VMID $VMID 已被占用,拒绝覆盖(请换 --vmid)"
qm list | awk '{print $2}' | grep -qiw "$VMNAME" && die "已存在同名虚拟机 $VMNAME,请换 --name"

# 存储检测(优先 lvmthin → zfspool → dir)
pick_store() {
    local name type _status _rest
    while read -r name type _status _rest; do
        if [[ "$type" == "$1" ]]; then
            echo "$name"
            return 0
        fi
    done < <(pvesm status --content images 2>/dev/null | tail -n +2)
    return 1
}
if [[ -z "$STORAGE" ]]; then
    STORAGE=$(pick_store lvmthin || pick_store zfspool || pick_store dir || true)
fi
if [[ -z "$STORAGE" ]]; then
    STORAGE=$(pvesm status --content images 2>/dev/null | awk 'NR>1{print $1; exit}' || true)
fi
[[ -n "$STORAGE" ]] || die "未找到可用 VM 存储,请用 --storage 指定"

# ISO 存储与目录
if [[ -z "$ISO_STORE" ]]; then
    ISO_STORE=$(pvesm status --content iso 2>/dev/null | awk 'NR>1{print $1; exit}')
    [[ -n "$ISO_STORE" ]] || die "未找到可用 ISO 存储,请用 --iso-store 指定"
fi
ISO_PATH=$(awk -v t="$ISO_STORE:" '$1==t {f=1} f && $1=="path" {print $2; exit}' /etc/pve/storage.cfg || true)
if [[ -z "$ISO_PATH" && "$ISO_STORE" == "local" && -d /var/lib/vz ]]; then
    ISO_PATH="/var/lib/vz"
fi
[[ -n "$ISO_PATH" ]] || die "无法确定存储 $ISO_STORE 的挂载路径,请检查 /etc/pve/storage.cfg"
ISO_DIR="$ISO_PATH/template/iso"
mkdir -p "$ISO_DIR" || die "无法创建 ISO 目录: $ISO_DIR"
echo "[信息] ISO 存储 $ISO_STORE → 目录 $ISO_DIR"

# Bazzite ISO 检测
if [[ -z "$ISO_FILE" ]]; then
    ISO_FILE=$(find "$ISO_DIR" -maxdepth 1 -iname '*azzite*.iso' 2>/dev/null | head -n 1 || true)
    [[ -n "$ISO_FILE" ]] && ISO_FILE=$(basename "$ISO_FILE")
fi
if [[ -z "$ISO_FILE" ]]; then
    echo "[提示] $ISO_DIR 下未找到 Bazzite 镜像(bazzite-deck-stable-live-amd64.iso)。"
    echo "       请到 https://bazzite.gg 下载后用 scp 上传,或 --iso 指定文件名。"
    exit 1
fi
[[ -f "$ISO_DIR/$ISO_FILE" ]] || die "Bazzite ISO 不存在: $ISO_DIR/$ISO_FILE"
echo "[信息] Bazzite ISO: $ISO_FILE"

# 桥接
if [[ -z "$BRIDGE" ]]; then
    BRIDGE=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | head -n 1 || true)
    [[ -z "$BRIDGE" ]] && BRIDGE="vmbr0"
fi

# 内存提示
TOTAL_MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ $MEMORY -gt $((TOTAL_MEM_MB * 75 / 100)) ]]; then
    echo "[警告] 分配内存 ${MEMORY}MB 超过宿主机物理内存 ${TOTAL_MEM_MB}MB 的 75%,请调低 --memory"
fi

echo "============================================================"
echo "将创建 Bazzite 虚拟机:"
echo "  VMID/名称    : $VMID / $VMNAME"
echo "  内存/核心    : ${MEMORY}MB / ${CORES} 核(CPU type=host)"
echo "  系统盘       : ${STORAGE}:${DISK_SIZE}G(VirtIO SCSI + IO Thread)"
echo "  EFI          : ${STORAGE}(OVMF 4M,不预置 Secure Boot 密钥)"
echo "  Bazzite ISO  : $ISO_STORE:iso/$ISO_FILE"
echo "  网卡         : virtio @ $BRIDGE"
echo "  说明         : 未挂直通设备;装完系统后按指南用 attach 脚本接入"
echo "============================================================"

[[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run:以上为将执行的配置,未创建任何内容。"; exit 0; }

read -r -p "确认创建?输入 Y 继续,其他键退出: " ans
[[ "$ans" == "Y" || "$ans" == "y" ]] || { echo "已取消。"; exit 0; }

# ---- 创建 VM ----------------------------------------------------------------
log "qm create $VMID ..."
qm create "$VMID" \
    --name "$VMNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --sockets 1 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "$STORAGE:1,efitype=4m" \
    --scsihw virtio-scsi-single \
    --scsi0 "$STORAGE:$DISK_SIZE,iothread=1" \
    --net0 virtio,bridge="$BRIDGE" \
    --ide2 "$ISO_STORE:iso/$ISO_FILE,media=cdrom" \
    --boot 'order=ide2;scsi0'

log "创建完成,验证配置:"
qm config "$VMID" | grep -E '^(name|bios|machine|efidisk0|scsihw|scsi0|net0|ide2|boot)'

echo
log "下一步:"
echo "  1. Web UI 打开该 VM 的 noVNC 控制台 → 启动 → 安装 Bazzite(按指南第 4 节)"
echo "  2. 安装完成后按指南:启用 sshd → 关机 → 运行 attach-all.sh 接入直通设备"
echo "     (bash /root/scripts/attach-all.sh --vmid $VMID,详见 Bazzite部署指南.md §6)"
