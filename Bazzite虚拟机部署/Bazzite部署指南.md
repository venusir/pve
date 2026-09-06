# PVE 部署 Bazzite Deck 游戏虚拟机指南

> 适用:PVE 8.x/9.x;**KVM 全虚拟化**(非 LXC——Bazzite 是完整桌面 OS,共享宿主内核的容器无法承载,显卡独占直通亦仅 KVM 支持)
> 实测环境:i3-12100 + RX 6650 XT(03:00.0/03:00.1)+ Xbox 无线适配器(`045e:02fe`)+ WD 1TB 直通盘 + PVE 9.2
> 版本:Bazzite **Deck 游戏版**(`bazzite-deck-stable-live-amd64.iso`,gamescope 手柄优先)

```
前置核对(§2)→ 建机(§3,脚本)→ noVNC 安装(§4)→ sshd 与基础配置(§5)
  → attach 接入直通(§6,复用现成脚本)→ 点亮与系统配置(§7,客机内脚本)→ 收尾(§8)
```

---

## 1. 方案说明

- 目标:客厅/电视旁的 Bazzite 游戏虚拟机——6650 XT 直通出画面、Xbox 手柄无线游玩、WD 1TB 直通为 Steam 游戏库
- **画面承载**:Bazzite 官方仅支持"物理显示器"或 **HDMI/DP 假负载**(虚拟显示驱动不受支持)。本方案以**电视物理直连**为主;若需电视关闭时串流等场景,买一个 HDMI 假负载插在 6650 XT 上即可

## 2. 前置准备

### 2.1 镜像

1. 下载 Bazzite Deck 镜像:<https://bazzite.gg> → Images → **Deck Edition** → amd64(文件 `bazzite-deck-stable-live-amd64.iso`,约 9GB)
2. 上传(大文件 scp,勿用浏览器):
   ```powershell
   scp .\bazzite-deck-stable-live-amd64.iso root@<PVE-IP>:/var/lib/vz/template/iso/
   ```

### 2.2 宿主直通状态核对

```bash
lspci -nnk | grep -A3 -iE 'VGA.*Advanced Micro Devices'   # 03:00.0 → vfio-pci
lsusb | grep -i 045e                                      # Xbox 适配器在位
ls -l /dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_*          # WD 1TB by-id
```

**设备空闲确认**:6650 XT / 适配器 / WD 盘当前不能被其他 VM 引用——若占用,先停用对应 VM 并移除其直通行(通用做法:在该 VM conf 中 `qm set <vmid> -delete hostpci0`、`-delete usb0`、`-delete scsi1` 等;具体被谁占用由你自己处理)。宿主 mt76 黑名单与 VFIO 直通配置需已就位;已配置过则无需重做(异常时回查 [显卡直通](../显卡直通.md) 第 2 节)。

### 2.3 前置脚本

```bash
cd /root
curl -fLO "https://raw.githubusercontent.com/venusir/wiki/main/PVE/Bazzite%E8%99%9A%E6%8B%9F%E6%9C%BA%E9%83%A8%E7%BD%B2/bazzite-deploy.sh"
curl -fLO "https://raw.githubusercontent.com/venusir/wiki/main/PVE/Bazzite%E8%99%9A%E6%8B%9F%E6%9C%BA%E9%83%A8%E7%BD%B2/bazzite-init.sh"
```

## 3. 建机(一键脚本)

```bash
bash bazzite-deploy.sh --dry-run    # 核对:ISO/存储/VMID(默认 100,被占自动顺延)
bash bazzite-deploy.sh              # 输 Y 创建
```

创建内容:q35 + OVMF(UEFI,不预置 Secure Boot 密钥)+ host CPU 4 核 + 16G + 128G VirtIO SCSI(IO Thread)+ VirtIO 网卡 + ISO 光驱;**不挂直通设备、不用 TPM**(Linux 客机无此需求)。

GUI 手动对照关键项:Machine=q35、BIOS=OVMF(UEFI)、磁盘 VirtIO SCSI、CPU host、ISO 挂载;**Secure Boot 不勾**。参数:`--vmid/--name/--memory/--cores/--disk-size/--iso/--storage/--debug`。

## 4. noVNC 安装

1. Web UI → 控制台(noVNC)→ 启动
2. Anaconda 安装器 → 选磁盘时认准 **128G 虚拟盘**(WD 直通盘此时还没挂,无需担心)→ 创建用户与密码 → 安装 → 重启
3. 重启后**摘除安装 ISO**(防再进安装器):`qm set <vmid> -delete ide2 && qm set <vmid> -boot order=scsi0`

## 5. 首启与远程管理(先不开显卡直通!)

首启默认进 gamescope 游戏模式;noVNC 分辨率低属正常。基础配置建议在游戏模式先做,操作不了就切 TTY/桌面:

```bash
# 切 TTY(游戏模式卡住/黑屏时):Ctrl+Alt+F3 → 用安装时创建的用户登录
sudo steamos-session-select desktop    # 需要桌面模式时
```

1. **确认网络**;可选更新 `rpm-ostree update`(或 `ujust update`)
2. **启用 sshd(此后全程 SSH 管理,不再碰控制台)**:
   ```bash
   sudo systemctl enable --now sshd
   ```
   若提示无该服务(部分镜像未含):`sudo rpm-ostree install openssh-server` → 重启 → 再启用
3. 记下 IP(`ip a`);以后管理:SSH 登录即可,游戏画面只走电视

## 6. 接入直通(关机状态,复用现成脚本)

物理准备:HDMI 插 6650 XT 物理口、适配器插宿主、电视开机记下输入源。

```bash
qm stop <vmid>
# 脚本获取(Scripts/ 家族,含 gpu/usb/disk 原语与 attach-all 组合)
mkdir -p /root/scripts && cd /root/scripts
for s in attach-gpu attach-usb attach-disk attach-all; do curl -fLO "https://raw.githubusercontent.com/venusir/wiki/main/PVE/scripts/$s.sh"; done
bash /root/scripts/attach-all.sh --vmid <vmid> --dry-run    # 审:显卡/音频/usb0/盘/vga none/startup
bash /root/scripts/attach-all.sh --vmid <vmid>              # 输 Y;交互选 WD 1TB
```

> attach-all 组合执行:显卡+音频(x-vga=1)、显示 none、Xbox 适配器(--vidpid 省略时交互选择)、直通盘、自启——**客机无关**,Windows/Linux 通用。按需单挂某设备用原语脚本。

**成功标志**(`qm config <vmid>`):

```text
hostpci0: 03:00.0,pcie=1,x-vga=1
hostpci1: 03:00.1,pcie=1
vga: none
usb0: host=045e:02fe,usb3=0
scsi1: /dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_...
startup: order=1
```

## 7. 点亮与系统配置

### 7.1 点亮

```bash
qm start <vmid>
```

电视应出现画面(gamescope 直出);noVNC 黑屏 = 正常。远程验证会话:

```bash
ssh <用户>@<VM-IP>
systemctl --user status gamescope-session-plus@steam.service   # active 即正常
```

无画面 → 先确认线/输入源 → 回退法排查(命令见 [显卡直通](../显卡直通.md) §6);Bazzite 无显卡时进桌面/TTY 的方法见 §5。

### 7.2 游戏盘(WD 1TB)初始化 —— ⚠️ 数据清空点

盘当前为 NTFS,Bazzite 游戏库建议格式化 ext4:

```bash
# Bazzite 内以 sudo 执行(格式化需输 YES;已格式化过则加 --skip-format)
sudo ./bazzite-init.sh --disk /dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_...
```

脚本完成:ext4 格式化(显式确认)→ 挂载 `/var/mnt/games`(fstab UUID 持久化)→ 属主交给你的用户 → sshd → Flatpak Steam 授权。

随后进桌面模式把库加进 Steam,步骤见 **7.2.1**。

#### 7.2.1 桌面模式添加 Steam 游戏库(Flatpak + 手动加库)

大屏(游戏模式)UI 隐藏了手动添加库入口,Steam 又以 Flatpak 沙盒运行——首次需在**桌面模式**加库,一次配置永久生效:

1. **回退摘卡**(若显卡已直通;命令见 [显卡直通](../显卡直通.md) §6)→ 重启后用 noVNC + 键鼠操作。摘卡后 gamescope 无硬件加速可能卡死:按 **Ctrl+Alt+F3** 进 TTY 登录 → `sudo steamos-session-select desktop` 进桌面;
2. **授权挂载目录**(bazzite-init 已对 `/var/mnt/games` 执行过,仅手动换过挂载路径时重跑):
   ```bash
   flatpak override --user --filesystem=/var/mnt/games com.valvesoftware.Steam
   ```
3. 桌面模式打开 Steam → 设置 → 存储 → **+ 添加库** →「让我在另一个位置选择」→ 在 `/var/mnt/games` 下新建并选中 `SteamLibrary` → 添加;
4. 完成加库后恢复直通(`qm stop` → 挂回 hostpci0 + `vga none` → 启动),回游戏模式即可看到新库。

> 桌面模式想用手柄操作:右摇杆=鼠标、RT/LT=左右键、A=回车(需 Steam 在运行);手柄异常直接改用 noVNC 键鼠。

### 7.3 Xbox 手柄

适配器已随 attach 直通。验证与配对:

```bash
ls /sys/class/xone/        # 出现 dongle0 = 驱动正常
```

配对:适配器圆键 → 手柄**顶部小圆钮**(不是 logo 键)。异常时按 [USB直通](../USB直通.md) §3.3 Linux 链路排错(宿主 mt76 黑名单沿用;若固件/SELinux 问题,Bazzite 无 SELinux 默认,主要查固件路径)。

### 7.4 显示细节(可选)

- gamescope 输出分辨率随电视 EDID 自动;需强制时在 Steam 启动选项配 `gamescope -W 3840 -H 2160 -r 60 -- %command%`
- 电视关闭后 gamescope 会话可能退出:保持电视开机,或插 **HDMI 假负载**(官方推荐做法,见 §1)

## 8. 收尾与日常

- **开机自启**:attach 已设 `startup order=1`(宿主开机自动启动本 VM)
- **遥控开关机**:接入宿主侧 Flirc 方案 → 通用脚本 toggle,见 [Flirc遥控开关机](../Flirc遥控开关机.md)(VMID 按实际改)
- **日常管理**:SSH 为主;游戏/画面操作在电视上(手柄)进行
- 串流需求(如另一房间玩):Sunshine/Moonlight 需电视开着或插假负载

## 9. 排错速查

| 现象 | 处理 |
| --- | --- |
| noVNC 黑屏 | 正常!画面在电视;需要控制台时用回退法([显卡直通](../显卡直通.md) §6) |
| 电视无画面 | 线/输入源 → 回退法进系统查驱动/会话日志 |
| 游戏模式黑屏卡住 | Ctrl+Alt+F3 进 TTY;`steamos-session-select desktop` |
| 手柄不识别 | 宿主 lsusb 确认 → dongle0 检查 → [USB直通](../USB直通.md) §3.3 Linux 链路 |
| 游戏盘不显示 | 确认 scsi1 在 conf;SSH 里 `lsblk`;bazzite-init 挂载步骤重跑(--skip-format) |
| 分辨率不对 | 电视 EDID;gamescope -W/-H 参数(§7.4) |
| 关机变重启/挂起异常 | 直通机勿用睡眠;彻底关机走宿主 `qm shutdown` |

## 10. 命令速查

```bash
# 建机 / 接入(宿主)
bash bazzite-deploy.sh --dry-run && bash bazzite-deploy.sh
bash /root/scripts/attach-all.sh --vmid <vmid> --dry-run && bash /root/scripts/attach-all.sh --vmid <vmid>

# 回退 / 恢复直通(宿主)
qm stop <vmid> && qm set <vmid> -delete hostpci0 && qm set <vmid> -vga std && qm start <vmid>
qm stop <vmid> && qm set <vmid> -hostpci0 03:00.0,pcie=1,x-vga=1 && qm set <vmid> -vga none && qm start <vmid>

# 客机内(SSH)
sudo ./bazzite-init.sh --disk /dev/disk/by-id/<盘> [--skip-format]
systemctl --user status gamescope-session-plus@steam.service
ls /sys/class/xone/
```

## 相关文档

- [README.md](README.md) — 目录索引
- [显卡直通](../显卡直通.md) / [硬盘直通](../硬盘直通.md) / [USB直通](../USB直通.md) — PVE 通用直通指南
- [Flirc遥控开关机](../Flirc遥控开关机.md) — 遥控开关 VM
- [Windows虚拟机部署/Windows部署指南.md](../Windows虚拟机部署/Windows部署指南.md) — 另一客机系统参考

## 参考来源

- Bazzite 官方对虚拟显示/假负载立场:https://github.com/ublue-os/bazzite/issues/2200
- Proxmox GPU 直通排错:https://forum.proxmox.com/threads/issues-passing-through-gpu-to-remote-gaming-vm.167641/
- Gamescope 参数与会话:https://botmonster.com/self-hosting/gamescope-desktop-linux-hdr-vrr-fps-limiting-steam/
