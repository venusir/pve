#!/usr/bin/env bash
# =============================================================================
# win11-htpc-deploy.sh —— PVE 一键创建 Windows 11 虚拟机(建机阶段)
#
# 适用:Proxmox VE 8.x/9.x,配合 Windows部署指南.md(第 4 节)使用
#
# 本脚本创建(不包含系统安装后的直通接入,那一步由 Scripts/attach-all.sh 负责):
#   q35 + OVMF(UEFI) + Secure Boot(pre-enrolled keys) + TPM 2.0
#   VirtIO SCSI + IO Thread + host CPU + VirtIO 网卡 + Win11/virtio-win 双光驱
#
# 安全承诺:
#   - VMID 已被占用时拒绝创建,绝不覆盖任何现有 VM
#   - 不执行任何删除/格式化操作
#
# 用法:
#   ./win11-htpc-deploy.sh [参数]
#
# 参数(均有默认值):
#   --vmid N          虚拟机 ID(默认 200;被占用时自动顺延找空闲号)
#   --name NAME       VM 名称(默认 win11-htpc)
#   --memory MB       内存 MB(默认 16384)
#   --cores N         CPU 核数(默认 4)
#   --disk-size G     系统盘大小 GB(默认 128)
#   --win-iso FILE    Windows 11 ISO 文件名(自动检测,无需手填)
#   --virtio-iso FILE virtio-win ISO 文件名(自动检测,缺失时自动下载)
#   --storage NAME    VM 磁盘/EFI/TPM 存储(自动检测 local-lvm 等)
#   --iso-store NAME  ISO 所在存储(自动检测 local)
#   --bridge NAME     网卡桥接(自动检测 vmbr0)
#   --dry-run         只打印参数与将执行的 qm create,不实际创建
#   --debug           开启 set -x 逐步执行跟踪(定位静默退出问题时用)
#   -h, --help        帮助
# =============================================================================
set -euo pipefail

# ---- 可调默认值 -------------------------------------------------------------
VMID_DEFAULT=200
VMNAME="win11-htpc"
MEMORY=16384
CORES=4
DISK_SIZE=128

# ---- 参数解析 ---------------------------------------------------------------
VMID=""
WIN_ISO=""
VIRTIO_ISO=""
STORAGE=""
ISO_STORE=""
BRIDGE=""
DRY_RUN=0
DEBUG=0
rc=0

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)         [[ $# -ge 2 ]] || die "--vmid 需要参数值"; VMID="$2"; shift 2 ;;
        --name)         [[ $# -ge 2 ]] || die "--name 需要参数值"; VMNAME="$2"; shift 2 ;;
        --memory)       [[ $# -ge 2 ]] || die "--memory 需要参数值"; MEMORY="$2"; shift 2 ;;
        --cores)        [[ $# -ge 2 ]] || die "--cores 需要参数值"; CORES="$2"; shift 2 ;;
        --disk-size)    [[ $# -ge 2 ]] || die "--disk-size 需要参数值"; DISK_SIZE="$2"; shift 2 ;;
        --win-iso)      [[ $# -ge 2 ]] || die "--win-iso 需要参数值"; WIN_ISO="$2"; shift 2 ;;
        --virtio-iso)   [[ $# -ge 2 ]] || die "--virtio-iso 需要参数值"; VIRTIO_ISO="$2"; shift 2 ;;
        --storage)      [[ $# -ge 2 ]] || die "--storage 需要参数值"; STORAGE="$2"; shift 2 ;;
        --iso-store)    [[ $# -ge 2 ]] || die "--iso-store 需要参数值"; ISO_STORE="$2"; shift 2 ;;
        --bridge)       [[ $# -ge 2 ]] || die "--bridge 需要参数值"; BRIDGE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --debug)        DEBUG=1; shift ;;
        -h|--help)      usage ;;
        *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
done

# ---- 运行横幅与调试陷阱(任何一步失败都会打印行号,杜绝静默退出) ---------------
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

# 自动找空闲 VMID(默认 200 起)
if [[ -z "$VMID" ]]; then
    VMID=$VMID_DEFAULT
    while qm list | awk '{print $1}' | grep -qw "$VMID"; do
        VMID=$((VMID + 1))
        [[ $VMID -le 300 ]] || die "200-300 区间无空闲 VMID"
    done
fi
qm list | awk '{print $1}' | grep -qw "$VMID" && die "VMID $VMID 已被占用,拒绝覆盖(请换 --vmid)"
# 重名检查
if qm list | awk '{print $2}' | grep -qiw "$VMNAME"; then
    die "已存在同名虚拟机 $VMNAME,请换 --name"
fi

# 检测存储:优先 lvmthin(性能好),其次 zfspool,再次 dir
pick_store() {  # $1=存储类型;找到则输出名称返回 0,否则返回 1
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

# 检测 ISO 存储与 ISO 目录
if [[ -z "$ISO_STORE" ]]; then
    ISO_STORE=$(pvesm status --content iso 2>/dev/null | awk 'NR>1{print $1; exit}')
    [[ -n "$ISO_STORE" ]] || die "未找到可用 ISO 存储,请用 --iso-store 指定"
fi
# ISO 存储挂载路径:目录类存储从 storage.cfg 读 path(pvesm path 需要"存储:卷"格式,不能只传存储名)
ISO_PATH=$(awk -v t="$ISO_STORE:" '$1==t {f=1} f && $1=="path" {print $2; exit}' /etc/pve/storage.cfg || true)
if [[ -z "$ISO_PATH" && "$ISO_STORE" == "local" && -d /var/lib/vz ]]; then
    ISO_PATH="/var/lib/vz"
fi
[[ -n "$ISO_PATH" ]] || die "无法确定存储 $ISO_STORE 的挂载路径,请检查 /etc/pve/storage.cfg 或用 --iso-store 指定目录类存储"
ISO_DIR="$ISO_PATH/template/iso"
mkdir -p "$ISO_DIR" || die "无法创建 ISO 目录: $ISO_DIR"
echo "[信息] ISO 存储 $ISO_STORE → 目录 $ISO_DIR"

# 检测/下载 ISO
detect_iso() {  # $1=glob 模式;输出首个匹配文件名;找不到输出为空并返回 0(避免 set -e 静默击杀)
    local found
    found=$(find "$ISO_DIR" -maxdepth 1 -name "$1" 2>/dev/null | head -n 1 || true)
    [[ -n "$found" ]] || return 0
    basename "$found"
}

if [[ -z "$WIN_ISO" ]]; then
    WIN_ISO=$(detect_iso '*[Ww]in*.iso')
    if [[ -z "$WIN_ISO" ]]; then
        echo "[提示] $ISO_DIR 下未找到 Windows 11 镜像。"
        echo "       请到 Microsoft 官网下载 Windows 11 ISO,用 Web UI 上传到 $ISO_STORE 存储后重跑本脚本。"
        exit 1
    fi
fi
[[ -f "$ISO_DIR/$WIN_ISO" ]] || die "Windows ISO 不存在: $ISO_DIR/$WIN_ISO"
echo "[信息] Windows ISO: $WIN_ISO"

if [[ -z "$VIRTIO_ISO" ]]; then
    VIRTIO_ISO=$(detect_iso 'virtio-win*.iso')
fi
if [[ -z "$VIRTIO_ISO" ]]; then
    VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    echo "[信息] 未找到 virtio-win ISO,将自动下载(stable 版,约 600MB):"
    echo "       $VIRTIO_URL"
    [[ $DRY_RUN -eq 1 ]] || read -r -p "确认下载?输入 Y 继续: " dl_ans
    if [[ $DRY_RUN -ne 1 ]] && [[ "$dl_ans" != "Y" && "$dl_ans" != "y" ]]; then
        echo "已取消,请手动下载后上传到 $ISO_STORE 再运行。"; exit 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        VIRTIO_ISO="virtio-win.iso(待下载)"
    else
        log "下载 virtio-win ..."
        curl -fL --retry 3 -o "$ISO_DIR/virtio-win.iso" "$VIRTIO_URL"
        VIRTIO_ISO="virtio-win.iso"
    fi
fi
[[ $DRY_RUN -eq 1 ]] || [[ -f "$ISO_DIR/$VIRTIO_ISO" ]] || die "virtio-win ISO 不存在: $ISO_DIR/$VIRTIO_ISO"
echo "[信息] virtio-win ISO: $VIRTIO_ISO"

# 检测桥接
if [[ -z "$BRIDGE" ]]; then
    BRIDGE=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | head -n 1 || true)
    [[ -z "$BRIDGE" ]] && BRIDGE="vmbr0"
fi

# 内存提示
TOTAL_MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ $MEMORY -gt $((TOTAL_MEM_MB * 75 / 100)) ]]; then
    echo "[警告] 分配内存 ${MEMORY}MB 超过宿主机物理内存 ${TOTAL_MEM_MB}MB 的 75%,如宿主还跑着其他 VM/LXC 请调低 --memory"
fi

# ---- 参数总览 ---------------------------------------------------------------
echo "============================================================"
echo "将创建 Windows 11 虚拟机:"
echo "  VMID          : $VMID"
echo "  名称          : $VMNAME"
echo "  内存 / 核心   : ${MEMORY}MB / ${CORES} 核(CPU type=host)"
echo "  系统盘        : ${STORAGE}:${DISK_SIZE}G(VirtIO SCSI + IO Thread)"
echo "  EFI/TPM       : ${STORAGE}(OVMF 4M + Secure Boot / TPM 2.0)"
echo "  Windows ISO   : $ISO_STORE:iso/$WIN_ISO"
echo "  virtio ISO    : $ISO_STORE:iso/$VIRTIO_ISO"
echo "  网卡          : virtio @ $BRIDGE"
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
    --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=1" \
    --tpmstate0 "$STORAGE:1,version=v2.0" \
    --ostype win11 \
    --scsihw virtio-scsi-single \
    --scsi0 "$STORAGE:$DISK_SIZE,iothread=1" \
    --net0 virtio,bridge="$BRIDGE" \
    --ide2 "$ISO_STORE:iso/$WIN_ISO,media=cdrom" \
    --ide0 "$ISO_STORE:iso/$VIRTIO_ISO,media=cdrom" \
    --boot 'order=ide2;scsi0' \
    --agent enabled=1

log "创建完成,验证配置:"
qm config "$VMID" | grep -E '^(name|bios|machine|efidisk0|tpmstate0|ostype|scsihw|scsi0|net0|ide0|ide2|boot|agent)'

echo
log "下一步:"
echo "  1. Web UI 打开该 VM 的 noVNC 控制台 → 启动"
printf '  2. 按文档第 5 节安装 Windows(磁盘不可见时加载 virtio-win 的 vioscsi\\w11\\amd64)\n'
echo "  3. 装完系统后运行直通接入(客机无关,Scripts/ 家族):"
echo "     bash /root/scripts/attach-all.sh --vmid $VMID"
