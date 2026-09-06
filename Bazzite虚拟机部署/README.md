# PVE Bazzite 虚拟机部署

## 目录内容

| 文件 | 说明 |
| --- | --- |
| [Bazzite部署指南.md](Bazzite部署指南.md) | ⭐ 完整部署教程:建机 → 安装 → 直通接入 → 点亮与配置 → 排错 |
| [bazzite-deploy.sh](bazzite-deploy.sh) | 宿主侧一键建机脚本(dry-run/确认闸门,LINUX 客机版) |
| [bazzite-init.sh](bazzite-init.sh) | Bazzite 客机内一键初始化(直通盘 ext4+挂载 / sshd / Steam 权限) |

**直通接入统一使用** [Scripts/attach-all.sh](../Scripts/attach-all.sh)(客机无关;另有 attach-gpu/usb/disk 原语)——指南 §6 有用法。

## 快速开始

```bash
# 1. 建机(宿主)
bash bazzite-deploy.sh --dry-run && bash bazzite-deploy.sh

# 2. noVNC 安装(指南 §4)→ 启用 sshd(§5)

# 3. 拉取直通脚本并接入(关机状态,宿主)
mkdir -p /root/scripts && cd /root/scripts
for s in attach-gpu attach-usb attach-disk attach-all; do curl -fLO "https://raw.githubusercontent.com/venusir/wiki/main/PVE/scripts/$s.sh"; done
bash /root/scripts/attach-all.sh --vmid 100 --dry-run && bash /root/scripts/attach-all.sh --vmid 100

# 4. 客机内初始化(SSH)
sudo ./bazzite-init.sh --disk /dev/disk/by-id/<盘>
```

## 通用参考(客户机无关,PVE 顶层)

- [显卡直通](../显卡直通.md) — GPU PCIe 直通/回退法
- [硬盘直通](../硬盘直通.md) — 整盘/控制器直通
- [Xbox直通](../Xbox直通.md) — USB 直通(含 Linux xone 深度排错)
- [Flirc遥控开关机](../Flirc遥控开关机.md) — 宿主侧遥控电源管理
- [Windows虚拟机部署/](../Windows虚拟机部署/) — Windows 客机完整流程(VM 创建/直通姿势互通)
