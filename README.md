# PVE 笔记与常用脚本

管理**一切与 Proxmox VE(PVE)平台相关的笔记与常用脚本**的个人知识库——收录平台教程、实测经验、踩坑记录、决策档案,以及配套的一键脚本,不绑定某一特定用途。

当前收录的内容以**虚拟化直通与虚拟机部署**为主干:宿主机 **PCIe 显卡 / USB / 硬盘直通**的通用指南、**Windows 10/11 与 Bazzite Deck** 虚拟机从建机到接入直通设备的完整部署流程、宿主侧遥控开关机等,其中多数以作者家用主机实测为准。组织方式面向持续增长:**平台级通用文档放顶层,按用途/客户机归类的方案放子目录(各自带 README 索引)**——后续新增主题按同一结构追加即可。

所有脚本均带 `--dry-run` 干跑与确认闸门。

## 实测环境(笔记的参考环境)

下表是作者个人主机,各文档中的命令、硬件 ID 与参数均以此环境**实测为准**;环境不同时按实际情况调整,勿照抄。

| 项目 | 配置 |
| --- | --- |
| 虚拟化平台 | Proxmox VE 9.2(单节点) |
| CPU | Intel Core i3-12100(Intel IOMMU) |
| 显卡(直通) | AMD Radeon RX 6650 XT(`1002:73ef`,PCIe 03:00.0;同卡音频 `1002:ab28` 03:00.1) |
| 数据盘(直通) | WD Blue 1TB(`ata-WDC_WD10EZEX-08WN4A0`)整盘直通 |
| USB(直通) | Xbox 无线适配器 `045e:02fe`;Flirc 红外接收器(宿主侧遥控开关机) |
| BIOS | VT-d、Above 4G Decoding、ErP Ready |
| VMID 约定 | Bazzite = **100**,Windows = **200** |

## 当前内容与方案状态

> 以下为**当前已收录**的主题及其状态;仓库本身不限此范围。

| 主题 | 状态 | 入口 |
| --- | --- | --- |
| Bazzite Deck 游戏虚拟机 | 🚧 **重建中**(2026-09-05 起改 KVM 全虚拟化;LXC 无法显卡独占直通) | [Bazzite虚拟机部署/](Bazzite虚拟机部署/README.md) |
| Windows 10/11 虚拟机部署 | ✅ **现行**(通用 Windows 客机流程;曾定位的「客厅影音 HTPC」用途已放弃,决策档案见指南 §11) | [Windows虚拟机部署/](Windows虚拟机部署/README.md) |
| 直通盘加 Steam 游戏库(Flatpak 权限案例) | 🗄 已退役,保留作通用「Linux 桌面客机 + 直通盘」案例 | [Bazzite虚拟机部署/Steam硬盘库.md](Bazzite虚拟机部署/Steam硬盘库.md) |
| 显卡 / 硬盘 / USB 直通、遥控开关机 | ✅ 通用经验,长期有效 | 见下方「通用基础」 |

## 通用基础(平台级文档,与客户机无关)

首次接触直通先读这四份——所有客户机部署指南均以此为前置:

| 文件 | 说明 |
| --- | --- |
| [显卡直通.md](显卡直通.md) | GPU PCIe 直通通用指南:宿主一次性准备 / IOMMU 核对 / 挂载 / **回退维护法** / 排错 |
| [硬盘直通.md](硬盘直通.md) | 整盘直通(by-id)与 SATA 控制器直通通用指南,含客户机侧使用与数据安全 |
| [Xbox直通.md](Xbox直通.md) | USB 设备直通通用姿势(Xbox 无线适配器完整案例,含 Linux xone 驱动深度排错) |
| [Flirc遥控开关机.md](Flirc遥控开关机.md) | 宿主侧遥控开关虚拟机通用方案:电视遥控器 → Flirc → triggerhappy → PVE API(单键 toggle) |

## 目录结构与扩展约定

**约定**:通用能力(直通、电源管理、日常运维等)→ 顶层放文档、[Scripts/](Scripts/) 放脚本;特定方案(某客机系统、某用途)→ 新建子目录,内含 README 索引 + 主文档 + 配套脚本,同构追加。

| 位置 | 内容 | 说明 |
| --- | --- | --- |
| [Windows虚拟机部署/](Windows虚拟机部署/README.md) | Windows 10/11 虚拟机部署 | README 索引 + ⭐ [唯一部署文档](Windows虚拟机部署/Windows10-11虚拟机部署指南.md)(流程/踩坑速查/命令速查/§11 决策档案)+ [win11-htpc-deploy.sh](Windows虚拟机部署/win11-htpc-deploy.sh) 建机脚本 |
| [Bazzite虚拟机部署/](Bazzite虚拟机部署/README.md) | Bazzite Deck 游戏虚拟机(重建中) | README 索引 + ⭐ [Bazzite部署指南.md](Bazzite虚拟机部署/Bazzite部署指南.md)(建机 → 安装 → 直通接入 → 点亮配置)+ [bazzite-deploy.sh](Bazzite虚拟机部署/bazzite-deploy.sh)(宿主建机)/ [bazzite-init.sh](Bazzite虚拟机部署/bazzite-init.sh)(客机内初始化) |
| [Scripts/](Scripts/) | 直通脚本家族(与客户机无关,多目录共用) | [attach-all.sh](Scripts/attach-all.sh) 组合接入(显卡+音频+USB+直通盘+开机自启);[attach-gpu.sh](Scripts/attach-gpu.sh) / [attach-usb.sh](Scripts/attach-usb.sh) / [attach-disk.sh](Scripts/attach-disk.sh) 为 attach/detach 原语(含回退法) |

## 两阶段部署模型

已收录的虚拟机部署统一走同一套可复用流水线:

1. **阶段 A(宿主,一键脚本建机)**——[win11-htpc-deploy.sh](Windows虚拟机部署/win11-htpc-deploy.sh) 或 [bazzite-deploy.sh](Bazzite虚拟机部署/bazzite-deploy.sh):q35/OVMF/VirtIO 全参数创建 VM(Windows 另含 Secure Boot + TPM 2.0),**不挂任何直通**;
2. **noVNC 安装系统**(指南对应章节;Windows 需在安装器里加载 `vioscsi` 驱动);
3. **阶段 B(宿主,VM 关机后)**——[Scripts/attach-all.sh](Scripts/attach-all.sh) 一次接入显卡/音频/USB/直通盘并设开机自启。PCIe 直通**必须冷启动**生效;需要 noVNC 维护时用原语 `detach` **回退摘卡**即可。

> 完整命令见对应子目录 README 的「快速开始」(Bazzite / Windows 各有独立入口,不在顶层重复)。

## 历史沿革

- **2026-06** 初版部署与实测:Win11 客厅 HTPC 与 Bazzite 游戏 VM 并行验证(Xbox、直通盘等案例均此期实测,详见 [Xbox直通.md](Xbox直通.md));
- **2026-06-28** 存档「直通盘添加 Steam 游戏库」排错案例([Steam硬盘库.md](Bazzite虚拟机部署/Steam硬盘库.md));
- **2026-09-05** 大规模重构:**放弃「Win11 客厅影音 HTPC」定位**(遥控只配客厅化 UI,流媒体回归电视原生 App;结论与教训存档于 [Windows 指南 §11](Windows虚拟机部署/Windows10-11虚拟机部署指南.md));Windows 部署文档单文档化合并;Flirc 方案重构为单键 toggle 通用版;**Bazzite 改用 KVM 全虚拟化重建**。
