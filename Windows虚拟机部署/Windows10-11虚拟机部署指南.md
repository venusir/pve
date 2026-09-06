# PVE 部署 Windows 10/11 虚拟机指南(单文档版)

> 适用:Proxmox VE 8.x/9.x;Windows 10 / Windows 11
> 实测环境:i3-12100 + RX 6650 XT + PVE 9.2 + 两阶段脚本
> 关联(顶层 PVE 通用直通指南):[显卡直通](../显卡直通.md) / [硬盘直通](../硬盘直通.md) / [USB直通](../USB直通.md)

---

## 1. 总览

```
宿主机前置(§2) → 镜像与版本选择(§3) → 阶段A 建机脚本(§4) → noVNC 装系统(§5)
  → 系统配置五连(§6) → 阶段B 接入直通(§7) → 点亮画面与收尾(§8)
  → 踩坑速查(§9) → 命令速查(§10)
```

- 脚本:**win11-htpc-deploy.sh**(Windows 建机)、**[Scripts/attach-all.sh](../Scripts/attach-all.sh)**(直通接入,客机无关;另有 gpu/usb/disk 原语)——使用前拉 GitHub 最新版
- Windows 10 与 11 差异已内嵌标注

## 2. 宿主机前置(一次性)

```bash
# 内核参数生效 + IOMMU 启用(预期有 DMAR/IOMMU 输出)
dmesg | grep -i -e DMAR -e IOMMU | head -3
# 待直通显卡已被 vfio-pci 接管
lspci -nnk | grep -A3 -iE 'VGA|Display controller'
```

未配置过直通的机器按以下就位(Intel 示例;详见 [显卡直通](../显卡直通.md)):
1. BIOS:开 **VT-d**、**Above 4G Decoding**(大显存卡必需)、ErP(可选)
2. `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT` 追加 `intel_iommu=on iommu=pt initcall_blacklists=sysfb_init nomodeset` → `update-grub` → 重启
3. `/etc/modprobe.d/vfio.conf` 写 `options vfio-pci ids=<显卡ID>,<音频ID>`(以 `lspci -nn` 实测为准),`/etc/modules` 加 `vfio vfio_iommu_type1 vfio_pci` → `update-initramfs -u -k all` → 重启
4. 验证:`lspci -nnk` 显示 `Kernel driver in use: vfio-pci`

## 3. 镜像与版本选择

### 3.1 下载

- 微软官网下载 Win10/11 **ISO 磁盘映像**(不是 Media Creation Tool)
- 版本选择注意:
  - 微软消费者版镜像(如 `Win11_25H2_Chinese_Simplified...iso`)**只含家庭版/专业版系列,不含企业版**;企业版镜像走 Eval Center(90 天评估,到期非正版)或组织 VL 渠道
  - **远程桌面(RDP)主机功能仅专业版/企业版及以上**;家庭版装好也没有 RDP,只能第三方远程(RustDesk/ToDesk)——有远程需求直接装专业版

### 3.2 上传

- **⚠️ 大文件别用浏览器上传**(进度条卡 100% 的经典坑)——scp 直传:

```powershell
scp .\Win11.iso root@<PVE-IP>:/var/lib/vz/template/iso/
```

- **⚠️ ISO 目录里保留多个 Windows 镜像时,deploy 自动检测可能选错**——只留要用的那份,或用 `--win-iso` 显式指定

## 4. 阶段 A:一键建机

```bash
bash win11-htpc-deploy.sh --dry-run    # 核对 ISO/存储/VMID
bash win11-htpc-deploy.sh              # 输 Y 创建
```

创建内容:q35 + OVMF(UEFI)+ Secure Boot 预置密钥 + TPM 2.0 + host CPU + VirtIO SCSI(IO Thread)+ VirtIO 网卡 + QEMU Agent + 双光驱(系统 ISO + virtio-win,后者缺失自动下载)。

**参数**:`--vmid`(默认 200 自动顺延)/ `--memory` / `--cores` / `--disk-size` / `--win-iso` / `--storage` / `--iso-store` / `--debug`。

**Windows 10 用户**:脚本 `ostype` 固定为 win11,建机后补一条 `qm set <vmid> -ostype win10` 即可,其余通用(Win10 建议同样 q35+OVMF+TPM 一套,便于以后直升 Win11)。

**⚠️ 脚本异常先核对版本**(脚本持续迭代,使用前确认是最新版):

```bash
grep -c storage.cfg win11-htpc-deploy.sh        # ≥1 为新版
```

## 5. noVNC 安装系统

1. Web UI → VM → 控制台(noVNC)→ 启动
2. **磁盘不可见是正常的**(无 VirtIO 驱动):「加载驱动程序」→ virtio-win 光驱 → `vioscsi\w11\amd64`(Win10 用 `\w10\` 目录;旧版 ISO 为 `viostor\w11\amd64`)
3. **⚠️⚠️ 选盘警告(最易翻车)**:有直通盘时,安装程序会把无分区表的直通盘显示为**未分配空间**:

| 安装程序列出的盘 | 大小 | 处置 |
| --- | --- | --- |
| QEMU 虚拟盘 | 系统盘容量(如 128G) | ✅ 删除分区 → 新建 → 安装 |
| 直通盘(显示为未分配) | 实际容量(如 931G) | ❌ **绝不选中**——那是数据盘,留给装完后由磁盘管理处理 |

   → 判断只看容量。
4. OOBE 卡联网:`Shift+F10` → `OOBE\BYPASSNRO` → 回车自动重启 →「我没有 Internet 连接」→ 建**本地账户**(自动登录需要)。个别版本命令无效用注册表法:
   ```cmd
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f
   shutdown /r /t 0
   ```
5. 装完自动重启时 **OVMF 可能再次进安装器**:进桌面后立即移除安装 ISO(§6.3);安装期间 noVNC 分辨率低属正常

## 6. 系统配置五连(noVNC 桌面)

1. **VirtIO 全量驱动**:virtio-win 光驱根目录 `virtio-win-gt-x64.msi` → 重启(含网卡 NetKVM/balloon/QEMU Agent)
2. **验证 QEMU Agent**:
   ```cmd
   sc query QEMU-GA
   ```
   - 服务缺失(实测 MSI 装完无报错仍可能缺)→ 光驱 `qemu-ga\` 目录找独立 MSI 补装:
     ```cmd
     dir D:\qemu-ga
     msiexec /i D:\qemu-ga\x86_64\qemu-ga-x86_64.msi
     ```
   - 仍缺**可跳过**(只影响面板 IP/优雅关机,不阻塞部署)
3. **摘安装 ISO + 引导顺序**(宿主):`qm set <vmid> -delete ide2` + `qm set <vmid> -boot order=scsi0`
4. **自动登录**(可选,常开场景推荐):
   - 解锁被 Win11 隐藏的 netplwiz 勾选框:
     ```cmd
     reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 0 /f
     ```
     → `netplwiz` 取消勾选「要使用本计算机,用户必须输入用户名和密码」→ 输密码两次
   - 失效则注册表三件套(**`DefaultUserName` 必须与 `net user` 账户名完全一致**,否则重启仍问密码):
     ```cmd
     reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
     reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d <账户名> /f
     reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d <密码> /f
     ```
   - 若仍回锁屏:**删除 Windows Hello PIN**(与自动登录冲突的已知问题);重启验证
5. **远程管理(RDP)**:
   - 专业版/企业版:设置 → 系统 → 远程桌面 → 开;或命令行:
     ```cmd
     reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
     netsh advfirewall firewall set rule group="远程桌面" new enable=Yes
     ```
   - 远程连接用 **`mstsc /admin`**(附着控制台会话,管理直通机不黑屏;普通 RDP 会话无 GPU 加速且破坏 HDCP)
   - 家庭版:无 RDP 主机,用 RustDesk/ToDesk 等第三方

## 7. 阶段 B:接入直通设备(关机状态)

物理准备:HDMI/DP 接直通显卡口;USB 设备插宿主。

> 脚本获取:见目录 README 快速开始(拉取到 /root/scripts 后运行)
```bash
bash /root/scripts/attach-all.sh --vmid <vmid> --dry-run    # 先审
bash /root/scripts/attach-all.sh --vmid <vmid>              # 输 Y;交互选直通盘
```

自动完成:显卡直通(x-vga=1,pcie=1)+ HDMI 音频 + 显示置 none + USB 设备 + 直通盘 + 开机自启。

**成功标志**(`qm config <vmid>`):

```text
hostpci0: <显卡>,pcie=1,x-vga=1
hostpci1: <音频>,pcie=1
vga: none
usb0: host=<VID:PID>...
scsi1: /dev/disk/by-id/<盘>
startup: order=1
```

**通用化适配**:
- 非 6650 XT 显卡:脚本按 ID 检测 `1002:73ef`/`1002:ab28`,其他型号先 `--gpu <地址>` 指定;音频另行添加
- 其他 USB 设备:`qm set <vmid> -usbN host=<VID:PID>`;整盘直通:`qm set <vmid> -scsiN /dev/disk/by-id/<盘>`(详见 PVE 顶层三份直通指南)

**⚠️ 注意事项**:
- USB/PCI 配置改动**必须完全关机再开机**(重启不生效)
- 显示置 none 后 **noVNC 黑屏 = 正常**,画面走直通卡物理输出
- **PVE GUI 的 PCI 设备没有「启用」勾选**——回退 noVNC 用命令行(摘卡/恢复):
  ```bash
  qm stop <vmid> && qm set <vmid> -delete hostpci0 && qm set <vmid> -vga std && qm start <vmid>
  qm stop <vmid> && qm set <vmid> -hostpci0 <地址>,pcie=1,x-vga=1 && qm set <vmid> -vga none && qm start <vmid>
  ```
- 仅摘显卡保留音频时 QEMU 报 `Cannot reset device ... depends on group N` 警告**无害,忽略**
- **显卡驱动先行再挂卡**:趁显卡未挂(noVNC 状态)先把厂商驱动(AMD Adrenalin 等)装好,首次点亮容错最高

## 8. 点亮画面与 Windows 收尾

1. `qm start <vmid>` → 画面在物理显示器(noVNC 黑屏正常);RDP 可全程远程操作
2. 设备管理器确认:显卡 / HDMI 音频(AMD High Definition Audio)/ USB 设备三项在位
3. 显示设置:显示器原生分辨率;音量输出选 HDMI
4. **磁盘管理**(`Win+X`):直通盘显示"未初始化"或"脱机" → 右键**联机**(如脱机)→ 初始化 **GPT** → 新建卷 **NTFS** → 分配盘符(数据清空发生在此,确认无保留再动手)
5. 若画面异常:先确认线/输入源 → 回退法(§7)排查;驱动问题重装后恢复直通

## 9. 踩坑速查

| # | 坑 | 现象 | 解决 |
| --- | --- | --- | --- |
| 1 | 浏览器上传大 ISO | 进度条卡 100% | scp 直传 `/var/lib/vz/template/iso/` |
| 2 | 脚本静默退出/路径报错 | 零输出直接消失 / pvesm path 失败 | `--debug` 跟踪;核对版本(§4) |
| 3 | attach 找不到 VM | 报"未找到 win11-htpc" | 核对版本(§4);或 `--vmid` 显式指定 |
| 4 | 安装器看不到磁盘 | 选择磁盘页空白 | virtio-win 光驱 `vioscsi\w11\amd64`(Win10 用 w10) |
| 5 | 选错安装盘 | 装到直通数据盘上 | 只看容量:虚拟盘 vs 直通盘(§5) |
| 6 | OOBE 卡联网 | 无法下一步 | `OOBE\BYPASSNRO` / 注册表 BypassNRO |
| 7 | 自动登录仍要密码 | 重启回到锁屏 | 解锁 netplwiz;DefaultUserName 与账户名一致;**删 Windows Hello PIN** |
| 8 | 转微软账户后密码失效 | 本地密码登不进 + BitLocker 恢复界面 | 本地账户 + 关闭设备加密;恢复密钥在 account.microsoft.com |
| 9 | Guest Agent 未运行 | PVE 面板不显示 IP | 补装光驱 `qemu-ga\` 下 MSI;非必需可跳过 |
| 10 | noVNC 无法连接 | 打开控制台报连不上服务器 | 关旧控制台页签;`systemctl restart pveproxy` |
| 11 | 直通后无画面 | 电视/显示器黑 | 回退法(§7)排查;驱动先行再挂卡 |
| 12 | 显示器一段时间后自动断开 | 画面丢失无法恢复 | Windows 电源:屏幕/睡眠设**从不**;PCIe ASPM 关闭 |
| 13 | USB 设备感叹号/失联 | 手柄等不见 | 冷启动 VM;宿主重插;必要时去掉 `usb3=0` |
| 14 | 重启又进安装界面 | OVMF 光驱优先引导 | 装完移除安装 ISO + `boot order=scsi0` |
| 15 | 无原生 RDP | 远程桌面不可用 | 需专业版/企业版;家庭版用第三方远程(§3.1) |

## 10. 命令速查

```bash
# 阶段 A / B
bash win11-htpc-deploy.sh --dry-run && bash win11-htpc-deploy.sh
bash /root/scripts/attach-all.sh --vmid <vmid> --dry-run && bash /root/scripts/attach-all.sh --vmid <vmid>

# 回退/恢复直通
qm stop <vmid> && qm set <vmid> -delete hostpci0 && qm set <vmid> -vga std && qm start <vmid>
qm stop <vmid> && qm set <vmid> -hostpci0 <地址>,pcie=1,x-vga=1 && qm set <vmid> -vga none && qm start <vmid>

# USB / 盘直通(关机状态)
qm set <vmid> -usb0 host=<VID:PID>
qm set <vmid> -scsi1 /dev/disk/by-id/<盘>

# 挂/摘安装 ISO、引导顺序
qm set <vmid> -ide2 local:iso/<镜像>,media=cdrom
qm set <vmid> -boot 'order=ide2;scsi0'
qm set <vmid> -delete ide2 && qm set <vmid> -boot order=scsi0

# conf 核对
qm config <vmid> | grep -E '^(hostpci|usb|vga|scsi|startup|boot|agent|ostype)'
```

---

## 关联文档

- [README.md](README.md) — 目录索引与快速开始
- [显卡直通](../显卡直通.md) / [硬盘直通](../硬盘直通.md) / [USB直通](../USB直通.md) — PVE 通用直通指南(客户机无关)
- [Flirc遥控开关机](../Flirc遥控开关机.md) — PVE API 遥控开机/关机方案
