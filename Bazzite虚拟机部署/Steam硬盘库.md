# PVE + Bazzite 直通硬盘添加 Steam 游戏库

> ⚠️ **方案状态**:Bazzite 游戏 VM 已退役(2026-09,流程沿革见 [Windows虚拟机部署/Windows10-11虚拟机部署指南.md](../Windows虚拟机部署/Windows10-11虚拟机部署指南.md) §11)。本篇作为 **Linux 桌面客机 + Flatpak Steam + 直通盘**操作案例存档,通用直通姿势以 [显卡直通](../显卡直通.md) / [硬盘直通](../硬盘直通.md) 为准。
>
> 存档日期：2026-06-28
>
> 来源：DeepSeek 对话分享 `846945okfrhgwkq7se`
>
> 环境：Proxmox VE + Bazzite 虚拟机 + 直通物理硬盘

---

## 1. 问题概述

在 PVE 中将物理硬盘直通给 Bazzite 虚拟机并挂载后，**Steam 大屏模式（游戏模式）下找不到"添加游戏库"按钮**，无法将直通硬盘上的游戏目录添加到 Steam 中。

### 根因

1. **Steam 新版大屏 UI 隐藏了手动浏览路径功能**，默认只允许添加官方支持的外部硬盘或 SD 卡
2. **Bazzite 的 Steam 以 Flatpak 沙盒运行**，对自定义挂载目录无默认读写权限
3. **显卡直通导致 PVE 控制台黑屏**，无法直接操作桌面模式

---

## 2. 解决方案总览

```
问题链：
Steam 大屏模式无添加按钮
  → 切到桌面模式添加
    → 桌面模式手柄不好用
      → 用 PVE NoVNC 物理键鼠
    → 桌面模式黑屏（直通显卡）
      → 临时禁用直通显卡 + 标准 VGA
        → 卡在游戏模式启动
          → Ctrl+Alt+F3 切 TTY / GRUB 加参数 3
  → Flatpak 权限不足
    → flatpak override --filesystem
```

---

## 3. 核心操作步骤

### 步骤 1：临时禁用直通显卡，进入 PVE 控制台

1. PVE → 关机 Bazzite 虚拟机
2. **⚠️ PVE GUI 的 PCI 设备没有「启用」勾选项**——禁用/恢复显卡用命令行(回退法详见 [显卡直通](../显卡直通.md) §6):
   ```bash
   qm stop <vmid> && qm set <vmid> -delete hostpci0 && qm set <vmid> -vga std && qm start <vmid>
   ```
3. **硬件 → 显示 → 设为「标准 VGA (std)」**(如未随 2 一并设置)
4. 开机

> **原理**：禁用物理显卡后，Bazzite 会自动回退到 PVE 虚拟显卡输出，PVE 控制台就能看到画面。

### 步骤 2：绕过游戏模式进入桌面模式

禁用显卡后，Gamescope（游戏模式）因无 GPU 硬件加速会卡死。需要强制进入桌面模式。

#### 方法 A：Ctrl+Alt+F3 切 TTY（推荐）

1. 等引导完成，PVE 控制台卡在黑屏或卡在 Bazzite 标志
2. 按 **Ctrl+Alt+F3**
3. 进入纯文本登录界面（TTY），用 Bazzite 用户名/密码登录
4. 执行：
   ```bash
   sudo steamos-session-select desktop
   ```
5. 系统会切换到桌面模式，PVE 控制台显示 KDE 桌面

#### 方法 B：GRUB 引导加 `3` 参数

1. 重启虚拟机，在 GRUB 菜单出现时按 **e** 键
2. 找到以 `linux` 开头的行
3. 光标移到行末，追加一个空格 + 数字 **`3`**
4. 按 **Ctrl+X** 或 **F10** 启动
5. 进入命令行登录界面后，执行：
   ```bash
   sudo steamos-session-select desktop && startx
   ```

---

### 步骤 3：确认硬盘挂载路径

在桌面模式打开终端（Konsole）：

```bash
df -h
```

找到直通硬盘的挂载路径，例如：
- `/mnt/games`
- `/run/media/live/games`

**记下完整路径**。

---

### 步骤 4：Flatpak 赋予 Steam 文件系统权限

Bazzite 的 Steam 以 Flatpak 沙盒运行，需显式授权才能访问自定义目录：

```bash
flatpak override --user --filesystem=/你的挂载路径 com.valvesoftware.Steam
```

示例（若硬盘挂载在 `/mnt/games`）：

```bash
flatpak override --user --filesystem=/mnt/games com.valvesoftware.Steam
```

执行完毕后，重启 Steam 或注销再登录。

---

### 步骤 5：Steam 桌面模式添加游戏库

1. 双击打开 Steam 客户端
2. 左上角 **Steam → 设置 → 存储**
3. 右上角当前盘符旁点击 **+ 号** → **"让我在另一个位置选择"**
4. 浏览到你的挂载路径，点击 **添加**
5. 存储列表中出现新盘符，说明游戏库已成功添加

---

### 步骤 6：恢复显卡直通

1. 关机 Bazzite 虚拟机
2. 命令行恢复直通(GUI 无「启用」勾选,详见 [显卡直通](../显卡直通.md)):
   ```bash
   qm stop <vmid> && qm set <vmid> -hostpci0 <显卡地址>,pcie=1,x-vga=1 && qm set <vmid> -vga none && qm start <vmid>
   ```
3. 开机，将 HDMI/DP 线接到直通显卡的物理输出

---

## 4. 桌面模式下 Xbox 手柄操作

### 手柄模拟键鼠（默认映射）

| 手柄操作    | 映射功能     |
| ----------- | ------------ |
| 右摇杆      | 移动鼠标光标 |
| 右扳机 (RT) | 鼠标左键     |
| 左扳机 (LT) | 鼠标右键     |
| A 键        | 回车键       |

### 手柄无法控制鼠标的排查

1. 确保 Steam 客户端正在运行（系统托盘有 Steam 图标）
2. 如果 Steam 卡死，终端执行：`killall -9 steam` 后重新打开
3. 检查 Steam 设置 → 控制器 → 桌面配置 → 确保启用了**官方桌面配置**
4. **推荐**：直接用 PVE 网页控制台（NoVNC）+ 物理键鼠操作，效率最高

---

## 5. PVE 控制台黑屏原理

| 阶段                | 输出目标       | PVE 控制台 |
| ------------------- | -------------- | ---------- |
| BIOS/GRUB 引导      | 所有显示设备   | ✅ 有画面   |
| 进入 Bazzite 系统后 | 直通的物理 GPU | ❌ 黑屏     |

**原因**：Bazzite 的 Gamescope 窗口管理器检测到直通显卡后，独占接管图形输出，关闭虚拟 VGA。

### 正常状态（有显卡直通）

- PVE 控制台黑屏 = **正常**，不是故障
- 游戏画面/桌面应看**物理显卡连接的显示器**
- 远程管理用 **SSH** 或 **Moonlight/Sunshine 串流**

---

## 6. 命令速查

```bash
# 确认硬盘挂载路径
df -h

# Flatpak 放行目录
flatpak override --user --filesystem=/mnt/games com.valvesoftware.Steam

# 强制切换到桌面模式（TTY 中执行）
sudo steamos-session-select desktop

# 强制杀死卡死的 Steam
killall -9 steam

# 重启 Bazzite 硬件服务
sudo systemctl restart bazzite-hardware-setup
```

---

## 7. 总结

Steam 大屏模式无法添加直通硬盘为游戏库，核心原因是 **Steam 隐藏了浏览按钮 + Flatpak 沙盒权限限制 + 显卡直通导致无法操作桌面模式**。

**完整操作流程**：

1. 临时禁用直通显卡 → 标准 VGA 亮机
2. Ctrl+Alt+F3 切 TTY → `steamos-session-select desktop` 进入桌面
3. `flatpak override --filesystem` 授权
4. Steam 设置 → 存储 → 添加硬盘路径
5. 恢复显卡直通 → 看物理显示器

一次配置，永久生效。