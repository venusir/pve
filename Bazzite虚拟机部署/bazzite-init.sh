#!/usr/bin/env bash
# =============================================================================
# bazzite-init.sh —— Bazzite 客机内一键初始化(直通游戏盘 + sshd + Steam 权限)
#
# 适用:Bazzite(Deck/Desktop 均可),以 sudo 在 Bazzite 内执行
# 配合 Bazzite部署指南.md 第 6 节使用;安全前提见下方
#
# 功能:
#   1. 直通盘格式化 ext4(仅显式确认;--skip-format 跳过)与持久挂载
#   2. 挂载点属主交给使用用户(Steam 库需要写权限)
#   3. sshd 启用(远程管理通道;缺失时提示 rpm-ostree 安装)
#   4. Steam 为 Flatpak 形态时授予文件系统权限(com.valvesoftware.Steam)
#
# 安全承诺:
#   - 格式化前必须输入 YES,并校验目标为块设备且未被挂载
#   - --skip-format 时不触碰文件系统
#
# 用法:
#   sudo ./bazzite-init.sh --disk /dev/disk/by-id/<盘>
#   sudo ./bazzite-init.sh --disk /dev/sdb --mount /var/mnt/games
#   sudo ./bazzite-init.sh --disk /dev/sdb --skip-format   # 盘已有文件系统,仅挂载
#   sudo ./bazzite-init.sh --disk /dev/sdb --user deck     # 指定 Steam 属主用户
#   ./bazzite-init.sh --dry-run --disk /dev/sdb
# =============================================================================
set -euo pipefail

DISK=""
MOUNT="/var/mnt/games"
TARGET_USER=""
SKIP_FORMAT=0
NO_CHOWN=0
DRY_RUN=0
DEBUG=0
rc=0

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

die() { echo "[错误] $*" >&2; exit 1; }
log() { echo "[步骤] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)        [[ $# -ge 2 ]] || die "--disk 需要参数值"; DISK="$2"; shift 2 ;;
        --mount)       [[ $# -ge 2 ]] || die "--mount 需要参数值"; MOUNT="$2"; shift 2 ;;
        --user)        [[ $# -ge 2 ]] || die "--user 需要参数值"; TARGET_USER="$2"; shift 2 ;;
        --skip-format) SKIP_FORMAT=1; shift ;;
        --no-chown)    NO_CHOWN=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --debug)       DEBUG=1; shift ;;
        -h|--help)     usage ;;
        *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
done

echo "[启动] $(date '+%F %T') | $(basename "$0") | 宿主机名: $(hostnamectl --static 2>/dev/null || hostname)"
echo "[启动] 干跑(不执行): $([ $DRY_RUN -eq 1 ] && echo 是 || echo 否)"

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
[[ $EUID -eq 0 ]] || die "请以 root 运行(sudo)"
[[ -n "$DISK" ]] || die "缺少 --disk(示例:--disk /dev/disk/by-id/ata-XXXX)"
[[ -e "$DISK" ]] || die "设备不存在: $DISK"
[[ -b "$DISK" ]] || die "不是块设备: $DISK(请传整盘或分区路径)"

# 未被挂载
if findmnt -n "$DISK" >/dev/null 2>&1; then
    die "设备已被挂载,拒绝操作: $(findmnt -n -o TARGET "$DISK")"
fi

# 属主用户自动检测(首个 /home 目录)
if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER=$(ls -1 /home 2>/dev/null | head -n 1 || true)
fi
if [[ -z "$TARGET_USER" ]]; then
    NO_CHOWN=1
    echo "[信息] 未检测到 /home 用户,跳过 chown(Steam 库权限请手动处理)"
fi

# ---- 动作总览 ---------------------------------------------------------------
echo "============================================================"
echo "Bazzite 初始化计划:"
echo "  设备      : $DISK($(lsblk -dno SIZE "$DISK" 2>/dev/null || echo ?))"
if [[ $SKIP_FORMAT -eq 1 ]]; then
    echo "  格式化    : 跳过(--skip-format,保留现有文件系统)"
else
    echo "  格式化    : mkfs.ext4(⚠️ 数据将被清空!)"
fi
echo "  挂载点    : $MOUNT(/etc/fstab 持久化,UUID 方式)"
echo "  属主      : ${TARGET_USER:-<跳过>}"
echo "  sshd      : 启用(systemctl)"
echo "  Steam权限 : Flatpak 形态时 flatpak override"
echo "============================================================"

[[ $DRY_RUN -eq 1 ]] && { echo "[信息] dry-run:仅展示计划,未做任何修改。"; exit 0; }

# ---- 格式化(需显式 YES)------------------------------------------------------
if [[ $SKIP_FORMAT -eq 0 ]]; then
    echo
    read -r -p "即将格式化 $DISK,数据将全部清空!输入 YES(全大写)继续: " ans
    [[ "$ans" == "YES" ]] || { echo "未确认,已取消。"; exit 0; }
    log "mkfs.ext4 $DISK ..."
    mkfs.ext4 -F "$DISK"
else
    log "跳过格式化(--skip-format)"
fi

# ---- 挂载(持久)--------------------------------------------------------------
log "挂载 $DISK → $MOUNT"
mkdir -p "$MOUNT"
UUID=$(blkid -s UUID -o value "$DISK" | head -n 1)
if [[ -z "$UUID" ]]; then
    echo "[警告] 未取到 UUID,改用设备路径写入 fstab(设备名漂移风险)"
    echo "$DISK $MOUNT ext4 defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
else
    echo "UUID=$UUID $MOUNT ext4 defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
fi
systemctl daemon-reload
mount "$MOUNT" || die "挂载失败(mount $MOUNT),检查 fstab 与文件系统"

if [[ $NO_CHOWN -eq 0 && -n "$TARGET_USER" ]]; then
    log "设置属主 ${TARGET_USER} → $MOUNT"
    chown -R "$TARGET_USER":"$TARGET_USER" "$MOUNT"
fi

# ---- sshd -------------------------------------------------------------------
if systemctl list-unit-files | grep -q '^sshd.service'; then
    log "启用 sshd"
    systemctl enable --now sshd
else
    echo "[提示] 镜像未含 openssh-server,如需要远程管理请执行:"
    echo "       sudo rpm-ostree install openssh-server && sudo systemctl enable --now sshd && reboot"
fi

# ---- Steam 权限(仅 Flatpak 形态)---------------------------------------------
if command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -qi 'com.valvesoftware.Steam'; then
    log "Steam(Flatpak)授权访问 $MOUNT"
    flatpak override --user --filesystem="$MOUNT" com.valvesoftware.Steam
else
    echo "[信息] 未检测到 Flatpak 版 Steam(Deck 镜像 Steam 通常为系统原生),无需 override"
fi

echo
log "初始化完成。下一步:"
echo "  1. 重启或注销,进入桌面模式:Steam → 设置 → 存储 → 添加 $MOUNT 为游戏库"
echo "     (完整步骤参考同目录 Steam硬盘库.md)"
echo "  2. 游戏库目录建议:先手动建 $MOUNT/SteamLibrary 再添加"
