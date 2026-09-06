# PVE + Flirc 遥控开关机虚拟机(通用方案)

> 方案状态:原方案 2026-06-28(DeepSeek 对话存档),2026-09-05 **重构通用化**——单键 toggle、单一脚本、最小权限 Token,消除原版三份重复脚本
> 适用:Proxmox VE 8.x/9.x;任意虚拟机(示例 VMID 200)
> 链路:Flirc(红外→按键)→ triggerhappy(监听)→ PVE API Token(开关机)

> 关系说明:本文是**宿主侧电源管理**,长期有效。虚拟机内用遥控操作媒体/应用的方案已随客厅 HTPC 方案放弃(桌面网页不支持 d-pad 遥控),详见 [Windows虚拟机部署/Windows10-11虚拟机部署指南.md](Windows虚拟机部署/Windows10-11虚拟机部署指南.md) §11。

---

## 1. 方案概述

将遥控器按键(如红色键)经 Flirc 映射为键盘键 `KEY_F12`,triggerhappy 在宿主机监听后调用开关机脚本,脚本按 VM 当前状态自动执行**启动或优雅关机**——同一颗键即 toggle,天然防重复启动。

```
遥控按键 → Flirc(KEY_F12)→ triggerhappy → flirc-remote-power.sh → PVE API
                                                                      ├─ stopped → start(启动)
                                                                      └─ running → shutdown(ACPI 优雅关机)
```

### 方案优势

- 无需网络、红外延迟低、宿主机 24h 运行不受影响
- Flirc 键位存于设备内部,即插即用
- 单键 toggle,不存在"重复按多次启动请求"

---

## 2. 配置前置

### 2.1 映射 Flirc 按键(Windows 电脑上一次完成)

1. 安装 [Flirc GUI](https://flirc.tv/software) → 插入 Flirc
2. **Controllers → Full Keyboard** → 虚拟键盘上点 **F12**(或自定义)
3. 提示时按下遥控器目标键 → `Recorded Successfully`
4. File → Save Configuration(可选备份)→ 拔出,插 PVE 宿主 USB
   - **注意**:选遥控器上不常用键(红色键/Favorites),避免与电视原功能冲突

### 2.2 安装并验证 triggerhappy

```bash
apt update && apt install -y triggerhappy evtest

# 确认 Flirc 设备与按键
ls /dev/input/by-id/*flirc*
# 例:/dev/input/by-id/usb-flirc.tv_flirc_xxxx-if01-event-kbd
evtest /dev/input/by-id/usb-flirc.tv_flirc_xxxx-if01-event-kbd
# 按遥控键,预期输出 code 88 (KEY_F12);记录键名,Ctrl+C 退出
```

### 2.3 创建最小权限 API Token(主流程,推荐)

1. Web UI → **Datacenter → Permissions → Users** → 添加用户:`flirc@pve`(密码随意,API 用不到)
2. **Permissions → Add**:Path 填 `/vms/<VMID>`(如 `/vms/200`),用户 `flirc@pve`,角色 `PVEVMAdmin`——只授权这一台 VM 的电源管理
3. **API Tokens → Add**:用户 `flirc@pve`,Token ID `remote`,**勾选 Privilege Separation** → Add
4. **⚠️ 立即复制保存 Secret**(仅显示一次)

记录:Token ID = `flirc@pve!remote`,Secret = `xxxxxxxx-xxxx-...`

> 更简单但**不推荐**:root@pam Token 且不勾权限分离(继承全部权限)——方便但违背最小权限。

---

## 3. 开关机脚本(单一通用脚本)

```bash
nano /usr/local/bin/flirc-remote-power.sh
```

粘贴(替换配置区 5 个值):

```bash
#!/usr/bin/env bash
# flirc-remote-power.sh —— PVE 遥控开关机通用脚本(triggerhappy 调用)
# 用法:flirc-remote-power.sh [start|stop|toggle|status]  默认 toggle
# ===== 配置区(按实际修改) =====
VM_ID="200"                                   # 目标虚拟机 ID
PVE_HOST="localhost"                          # PVE 主机(本地用 localhost)
NODE_NAME="localhost"                         # PVE 节点名(单节点=主机名)
TOKEN_ID="flirc@pve!remote"                   # API Token ID
SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" # API Token Secret
LOG_FILE="/var/log/flirc-power.log"
# ==============================

log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG_FILE"; }

api_get() {
    curl --silent --insecure \
      -H "Authorization: PVEAPIToken=$TOKEN_ID=$SECRET" \
      "https://$PVE_HOST:8006/api2/json/nodes/$NODE_NAME/qemu/$VM_ID/$1"
}

api_post() {
    curl --silent --insecure -X POST \
      -H "Authorization: PVEAPIToken=$TOKEN_ID=$SECRET" \
      "https://$PVE_HOST:8006/api2/json/nodes/$NODE_NAME/qemu/$VM_ID/$1"
}

current_state() {   # 输出 running / stopped / 未知
    local resp state
    resp=$(api_get "status/current")
    state=$(echo "$resp" | grep -o '"status":"[a-z]*"' | head -n1 | cut -d'"' -f4)
    echo "${state:-未知}"
}

do_action() {       # $1=API 动作 start|shutdown;$2=动作名
    local resp
    log INFO "$2 请求 VM $VM_ID"
    resp=$(api_post "status/$1")
    if echo "$resp" | grep -q '"data":null'; then
        log INFO "$2 已执行:$resp"
    else
        log ERROR "$2 失败:$resp"
    fi
}

ACTION="${1:-toggle}"
STATE=$(current_state)

case "$ACTION" in
    status)
        echo "VM $VM_ID 状态: $STATE";;
    start)
        if [ "$STATE" = "running" ]; then log INFO "已在运行,忽略"; else do_action start 启动; fi;;
    stop)
        if [ "$STATE" = "stopped" ]; then log INFO "已停止,忽略"; else do_action shutdown 关机; fi;;
    toggle)
        if [ "$STATE" = "running" ]; then do_action shutdown 关机
        elif [ "$STATE" = "stopped" ]; then do_action start 启动
        else log ERROR "状态异常($STATE),未动作"; fi;;
    *)
        echo "用法:$0 [start|stop|toggle|status]"; exit 1;;
esac
```

赋予执行权限(含 Secret,仅 root 可读):

```bash
chmod 700 /usr/local/bin/flirc-remote-power.sh
```

### 手动测试

```bash
/usr/local/bin/flirc-remote-power.sh status    # 应输出当前状态
/usr/local/bin/flirc-remote-power.sh toggle    # 开关切换
cat /var/log/flirc-power.log                    # 查看动作与结果
```

---

## 4. triggerhappy 规则

**单键 toggle(推荐)**:

```bash
echo "KEY_F12 1 /usr/local/bin/flirc-remote-power.sh toggle" > /etc/triggerhappy/triggers.d/flirc-power.conf
```

**双键拆分(可选)**:F12 启动 + F11 关机(两个文件):

```bash
echo "KEY_F12 1 /usr/local/bin/flirc-remote-power.sh start" > /etc/triggerhappy/triggers.d/flirc-start.conf
echo "KEY_F11 1 /usr/local/bin/flirc-remote-power.sh stop"  > /etc/triggerhappy/triggers.d/flirc-stop.conf
```

生效:

```bash
systemctl restart triggerhappy
systemctl enable triggerhappy
```

> 规则热加载:改动后需 restart;键名须与 2.2 中 evtest 记录一致。

---

## 5. 验证与排错

| 现象 | 可能原因 | 排查 |
| --- | --- | --- |
| 按遥控器无反应 | Flirc 未识别 | `lsusb \| grep -i flirc`;回 Flirc GUI 重学键位 |
| evtest 能捕获但 VM 不动 | triggerhappy 未运行/规则没加载 | `systemctl status triggerhappy`;`cat /etc/triggerhappy/triggers.d/flirc-power.conf` |
| 日志报 401 | Token ID/Secret 错或未授权该 VM | 核对 §2.3 记录;检查 `/vms/<VMID>` 权限 |
| 手动脚本正常、遥控器失败 | triggerhappy 环境 | `journalctl -u triggerhappy -e` |
| 状态显示"未知" | API 不可达/JSON 异常 | 手动 `curl` 调试;查看日志原文 |
| 开机时 PCI reset 警告 | 直通设备正常现象 | 忽略,不影响启动 |

---

## 6. 安全与加固

1. **Secret 不入版本库**:本脚本含密钥,只放宿主机;仓库内文档用占位符
2. **脚本权限**:`chmod 700`(仅 root 可读)
3. **Token 最小权限**:§2.3 专用用户 + `/vms/<VMID>` 路径授权;如需管多台 VM,将授权 Path 改为 `/` + `PVEVMAdmin`,或逐个 VM 授权
4. **--insecure 说明**:localhost 直连场景可接受;如对外暴露 API 请换有效 SSL 证书并去掉该参数
5. **(可选)日志轮转**:`/etc/logrotate.d/flirc-power` 配一行 `rotate 7 daily compress` 即可

---

## 7. 附录:探索历程(原版存档)

- 演进:BIOS USB 唤醒(需关机宿主)→ PCIe USB 控制器直通(宿主失联)→ SPICE USB 重定向(宿主无法监听)→ evsieve(参数语法兼容性差)→ triggerhappy(qm/pvesh 无会话认证上下文,exit 255)→ **triggerhappy + API Token** ✅
- 关键教训:服务环境下无 PVE 会话票证,qm/pvesh 不可用,curl REST API + Token 彻底绕过会话依赖
- 原方案全文(含逐版本脚本与详细调试)见 git 历史:commit `c7ac0ba` 之前的 `Flirc遥控启动虚拟机.md`
