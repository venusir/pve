# PVE USB 设备直通通用指南(Xbox 无线适配器完整案例)

> 通用性:USB 直通姿势适用于任意 USB 设备;Xbox 无线适配器(`045e:02fe`)为完整案例(§3)
> **脚本化**:挂载/移除可用 [Scripts/attach-usb.sh](Scripts/attach-usb.sh)(省略 --vidpid 时自动列选宿主设备;attach|detach)
> 实测环境:PVE 9.2;Xbox 无线适配器 + Series X|S 手柄;Windows 与 Linux 双客户机经验
> 关联:显卡直通见 [显卡直通.md](显卡直通.md),硬盘直通见 [硬盘直通.md](硬盘直通.md)

---

## 1. USB 直通通用姿势(任意 USB 设备)

```bash
# 1) 宿主确认设备在(记下 VID:PID)
lsusb
# 例:Bus 001 Device 010: ID 045e:02fe Microsoft Corp. Xbox Wireless Adapter for Windows
#     ↑ Xbox 无线适配器是本机最常用案例,其特殊性见 §3

# 2) 挂给虚拟机(VID:PID 方式最稳,端口号会漂移)
qm set <vmid> -usb0 host=<VID:PID>            # 默认走 xHCI(USB3 通路)
qm set <vmid> -usb0 host=<VID:PID>,usb3=0     # 强制 USB2 通路(部分设备/Linux 客户机需要)

# 3) 验证
qm config <vmid> | grep usb
```

**铁律**:
- USB/PCI 配置改动后**必须完全关机再开机**(重启不生效)
- 同一 USB 设备**不能同时配给两个 VM**(占用冲突)
- 设备物理拔插后,VM 内可能失联 → 冷启动恢复
- **宿主驱动可能"抢走"已直通设备**:即使直通成功,宿主已加载的驱动也会先占用,表现为客户机里看不到设备 → 见 §2;宿主侧黑名单处理示例见 §3.4
- 键鼠/手柄等输入设备经 **RDP 不转发输入**,须在控制台会话(物理显示或 `mstsc /admin`)使用

## 2. 通用排错流程(客户机看不到设备)

```
设备在客户机里看不到?
  ├─ 宿主 lsusb 有设备吗? 没有 → 物理连接问题;或宿主驱动抢占(黑名单示例见 §3.4)
  ├─ conf 里 usbN 在吗?       没有 → 重新挂载(§1)
  └─ 都在 → VM 冷启动 → 客户机 lsusb / 设备管理器复查
仍不行?
  ├─ 软重置设备:usbreset <VID:PID>(需 usbutils)
  ├─ 物理拔插 10 秒 / 换 USB 口(避开 USB3 设备射频干扰)
  └─ 设备带专属客户机驱动/固件(无线手柄适配器、数位板等)→ 查该设备案例,见 §3
```

## 3. 案例:Xbox 无线适配器(手柄)直通

> 通用挂载与排错姿势见 §1-2;本栏目只讲该设备的**特殊性**——型号识别、配对、客户机驱动链路。适配器本质是普通 USB 设备(枚举 `045e:02fe` / `045e:02e6`),无任何特殊挂载参数。

### 3.1 型号与配对

| 型号 | USB ID | 说明 |
| --- | --- | --- |
| 现行款(小圆润) | `045e:02fe` | Series 世代,最常见 |
| 初代(大块头 2015) | `045e:02e6` | Xbox One 时代 |

**⚠️ 配对键位置(最容易搞错的点)**:手柄的配对键**不是 Xbox logo 键**——是手柄**顶部边缘、USB 口旁的小圆凸钮**。长按 logo 只是开关机,按顶部小圆钮 logo 灯才会快闪进入配对。

配对流程:按适配器侧圆键(快闪)→ 30cm 内按住手柄顶部小圆钮 → 灯常亮即连上(以后开机自动回连)。

**固件与电池提醒**:配对失败先排除两件事——①换全新碱性电池(电压不足表现为"能闪连不上");②固件过旧(Windows 下用 Xbox Accessories 有线刷手柄固件、可选更新装适配器驱动包)。

**配对失败的排查顺序**:换电池 → 确认按的是顶部小圆钮(不是 logo 键)→ 换 USB2 口/远离 USB3 设备(射频干扰)→ 冷启动 / 去掉 `usb3=0` 换通路 → Windows 侧:可选更新/Xbox Accessories 更新固件 → Linux 侧:xone 固件链(§3.3)→ **裸机 A/B 测试**:适配器插真 Windows 电脑试配——能配 = VM 链路问题,不能配 = 固件/硬件问题(数据线刷手柄固件或换适配器)。

### 3.2 Windows 客户机细节

- 原生免驱;设备出现在设备管理器 → **网络适配器**分类(正常!它按网络设备枚举,不提供网络功能)
- 配对/固件:见 §3.1;Xbox Accessories(微软商店)识别与更新

### 3.3 Linux 客户机(xone/xow 驱动)深度排错

> 案例背景:Linux 桌面客户机实测(xone/xow 驱动),排错链路对任何 Linux 客机通用。
> 典型症状:驱动已加载(`lsmod` 有 xone_dongle)、设备已绑定,但 `/sys/class/xone/` 不存在、无法进入配对。根因是**固件加载链断裂**——SELinux 阻止 → 固件文件缺失/路径不对 → 驱动初始化失败,常叠加宿主驱动抢占。

**链路 ① 宿主禁用 mt76 冲突驱动(PVE 宿主执行)**

```bash
sudo tee /etc/modprobe.d/blacklist-mt76.conf << 'EOF'
blacklist mt76
blacklist mt76x2u
blacklist mt76x2_common
blacklist mt76x02_usb
blacklist mt76_usb
blacklist mt76x02_lib

install mt76 /bin/false
install mt76x2u /bin/false
install mt76x2_common /bin/false
install mt76x02_usb /bin/false
install mt76_usb /bin/false
install mt76x02_lib /bin/false
EOF
sudo update-initramfs -u -k all && sudo reboot
lsmod | grep mt76        # 重启后应无输出
```

只影响 MediaTek 芯片 USB 无线网卡,不影响键鼠/U 盘。

**链路 ② 固件提取与放置(Linux 客机内)**

```bash
# 1. 提取工具 + 微软驱动包解出固件
sudo rpm-ostree install cabextract      # 发行版对应包管理器安装
curl -L -o driver.cab 'http://download.windowsupdate.com/c/msdownload/update/driver/drvs/2017/07/1cd6a87c-623f-4407-a52d-c31be49e925c_e19f60808bdcbfbd3c3df6be3e71ffc52e43261e.cab'
cabextract -F FW_ACC_00U.bin driver.cab
mv FW_ACC_00U.bin xow_dongle.bin

# 2. 放置固件(不可变根文件系统如 Bazzite 不能写 /lib/firmware,用可写路径)
sudo mkdir -p /usr/local/lib/firmware
sudo cp xow_dongle.bin /usr/local/lib/firmware/

# 3. 路径兜底:软链接覆盖驱动可能查找的所有文件名
sudo ln -sf /usr/local/lib/firmware/xow_dongle.bin /etc/firmware/xow_dongle.bin
sudo ln -sf /usr/local/lib/firmware/xow_dongle.bin /etc/firmware/xow_dongle_045e_02fe.bin
sudo ln -sf /usr/local/lib/firmware/xow_dongle.bin /etc/firmware/xow_dongle_045e_02e6.bin
```

**链路 ③ SELinux 放行(仅 SELinux 发行版,如 Fedora 系)**

```bash
# 临时验证
sudo setenforce 0 && 重新插拔适配器 && ls /sys/class/xone/

# 永久解决(audit2allow 生成策略模块)
sudo rpm-ostree install policycoreutils-python-utils
sudo ausearch -c 'xone-dongle' --raw | sudo audit2allow -M my-xone
sudo semodule -i my-xone.pp
```

**链路 ④ 驱动/硬件复位**

```bash
sudo usbreset 045e:02fe                      # 软重置适配器(需 usbutils)
# 重新绑定驱动
echo "9-1:1.0" | sudo tee /sys/bus/usb/drivers/xone-dongle/unbind
sleep 2
echo "9-1:1.0" | sudo tee /sys/bus/usb/drivers/xone-dongle/bind
```

硬件卡死终极方案:BIOS 开启 **ErP Ready(S4+S5)**(Advanced → APM Configuration)——关机/休眠彻底切断 USB 端口供电,强制适配器硬件复位。注意这是 PVE 宿主物理 BIOS 设置,不是虚拟机 BIOS。

**验证成功标志**

```bash
ls /sys/class/xone/                 # 出现 dongle0
echo 1 | sudo tee /sys/class/xone/dongle0/led   # 强制进配对(替代物理按键)
```

LED 快闪后按住手柄顶部配对键即可连接。

**关键经验**(教训表)

| 经验 | 说明 |
| --- | --- |
| 驱动已加载 ≠ 正常工作 | `lsmod` 有输出也可能因固件未加载而无 dongle0 |
| 只读根文件系统 | 固件放 `/usr/local/lib/firmware/` 而非 `/lib/firmware/` |
| 宿主驱动会抢占 | 即使直通,宿主已加载驱动也可能先占用 |
| SELinux 静默阻止 | `Permission firmware_load` 不会显示在 dmesg 的 xone 过滤里 |
| ErP Ready 治卡死 | 适配器休眠/重启后不工作的社区验证终极方案 |

### 3.4 宿主侧冲突与卡死(速查)

- **mt76 抢占**:枚举正常但客机拿不到设备 → 宿主黑名单(mt76 全家桶,命令见 §3.3 链路①)
- **适配器卡死**:拔插 10 秒 / `usbreset 045e:02fe` / BIOS ErP Ready(§3.3 链路④)

## 4. 关联文档

- [Windows虚拟机部署/Windows10-11虚拟机部署指南.md](Windows虚拟机部署/Windows10-11虚拟机部署指南.md) — 完整 Windows 部署流程
- [显卡直通.md](显卡直通.md) / [硬盘直通.md](硬盘直通.md)
- [Bazzite虚拟机部署/](Bazzite虚拟机部署/) — Linux 客机(Bazzite)部署与手柄使用
