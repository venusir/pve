# PVE 下部署 Windows 10/11 虚拟机

> 本目录收录在 Proxmox VE 上部署 Windows 虚拟机(10/11)的**单文档流程、一键脚本与实测经验**。

## 目录内容

| 文件 | 说明 |
| --- | --- |
| [Windows部署指南.md](Windows部署指南.md) | ⭐ 唯一部署文档:主流程 + 踩坑表 + 命令速查(从部署直接开始看这篇) |
| [win11-htpc-deploy.sh](win11-htpc-deploy.sh) | 阶段 A:一键建机脚本(OVMF/TPM2.0/VirtIO 全参数) |
| [attach-all.sh](../Scripts/attach-all.sh) | 阶段 B:一键接入直通设备(显卡/音频/USB/盘/自启;客机无关,含 gpu/usb/disk 原语) |

## 快速开始

```bash
# 1. 上传系统 ISO 到 PVE(大文件用 scp,别用浏览器)
scp .\Win11.iso root@<PVE-IP>:/var/lib/vz/template/iso/

# 2. 阶段 A:一键建机(先 dry-run 审阅)
bash win11-htpc-deploy.sh --dry-run
bash win11-htpc-deploy.sh

# 3. noVNC 安装系统(按指南第 5 节,磁盘不可见时加载 vioscsi 驱动)

# 4. 拉取直通脚本并接入(系统装好、关机后)
mkdir -p /root/scripts && cd /root/scripts
for s in attach-gpu attach-usb attach-disk attach-all; do curl -fLO "https://raw.githubusercontent.com/venusir/wiki/main/PVE/scripts/$s.sh"; done
bash /root/scripts/attach-all.sh --vmid 200 --dry-run
bash /root/scripts/attach-all.sh --vmid 200
```

## 关联文档(上层目录)

- [显卡直通](../显卡直通.md) — 通用:显卡 PCIe 直通(宿主准备/挂载/回退/排错)
- [硬盘直通](../硬盘直通.md) — 通用:整盘/控制器直通与客户机侧使用
- [USB直通](../USB直通.md) — 通用:USB 直通姿势 + Xbox 适配器完整案例(含 Linux xone 深度排错)
- [Flirc遥控开关机](../Flirc遥控开关机.md) — PVE API 遥控开机/关机方案
