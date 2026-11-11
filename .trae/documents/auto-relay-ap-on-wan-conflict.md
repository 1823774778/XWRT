# Context

当上级路由的 LAN 通过 **XWRT 的 WAN 口**接入，且上级 DHCP 租约所在网段与 XWRT 当前 LAN 网段重叠时，设备目前只会执行 Router Tool 的普通网段避让逻辑；用户希望系统自动完成 LuCI「网络 → 接口 → 全局网络选项 → 中继 AP 模式」的完整切换，而不是只写入 `router-tool.main.ap_mode=1`。自动切换必须复用 Router Tool 的拓扑、快照、事务和网络重载语义，并且不能覆盖已被用户手工配置的主路由设置。

# Recommended approach

1. **确保 Router Tool 被编入 IPQ60XX 固件**
   - 在 `Config/IPQ60XX.txt` 显式加入 `CONFIG_PACKAGE_luci-app-router-tool=y`。
   - 在 `.github/workflows/build.yml` 的 `make defconfig` 后检查该选项，保持亚瑟/雅典娜设备选择断言不变。
   - 保持 feed 安装先于 `Scripts/Settings.sh`，让构建期补丁始终作用于实际上游源码。

2. **在上游 Router Tool 中增加可复用的服务端 Relay AP 计划逻辑**
   - 通过 `Scripts/Settings.sh` 在 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/` 生成/补丁 `relay_ap.uc`，将 LuCI `router-tool.js::enableAp()` 的关键配置动作整理为可由后台调用的函数：校验 WAN/ LAN 纯以太网拓扑、创建或更新 bridge、将 `network.wan` 设为 `proto=none` 并禁用、将 `network.lan/wan6` 改为上游 DHCP、禁用本机 DHCP、把 AP 无线网络归并到 LAN、应用 `relay_ap` 防火墙规则、生成 `ap_state` 快照并设置 `ap_mode=1`。
   - 所有变更先写入同一个 UCI cursor/事务，快照保存的是切换前的完整可恢复状态；禁止只设置 `ap_mode` 而没有 `ap_state`。
   - 保留现有 LuCI 手动切换路径的保存/应用语义；自动路径调用同一套后端动作，避免只复制一个标志位造成 AP 模式半切换。

3. **在 `router-tool-auto` 的现有锁和事务链路中自动触发**
   - 在 `root/usr/libexec/router-tool-auto` 中加载 `/etc/board.json` 和 `auto.json`，在现有 `/var/lock/router-tool.lock`、`/tmp/.uci/*` 检查和 pending transaction 恢复之后执行判断。
   - 仅支持明确的 WAN 上联：读取 `network.interface.wan` 的实时状态，要求接口已 up、当前 WAN 协议匹配、存在有效 IPv4 地址/掩码；不把旧租约或 LAN 自身地址当作上级信息。
   - 仅当同时满足以下条件时自动启用：当前未处于 AP 模式、WAN 为非 PPPoE 的上联角色、LAN 与 WAN 租约网段确实重叠、Router Tool 快照未标记 `manual_lan`、不存在未应用 UCI 改动/未完成事务、设备拓扑通过自动 AP 校验。
   - 自动触发应放在旧 `avoidSubnetConflict()` 之前；成功启用 AP 后跳过普通的换网段逻辑，避免先把 LAN 改到其他网段再切 AP。
   - 上游 DHCP 尚未完成、拓扑未知、不是纯以太网或存在用户手工配置时只记录一次原因并等待下一次 WAN/interface 事件，不修改配置。

4. **增加幂等与用户接管保护**
   - 成功后以 `ap_mode=1`、有效 `ap_state` 和自动来源/上游网段标记作为完成条件；后续事件只校验，不重复生成快照或重复提交。
   - 用户在 LuCI 中关闭自动开启的 Relay AP 后，记录人工关闭标志；同一上游网段下不自动重新打开。用户手工修改 LAN、WAN、VLAN、无线绑定或防火墙后，沿用 `snapshot.uc` 的 `manual_lan`/自定义选项判断，不覆盖配置。
   - 升级迁移沿用 `90-router-tool-migrate`；不为无历史状态的保留配置伪造“出厂基线”。掉电或提交失败时沿用 `transaction.uc` 恢复，恢复期间不再次启动自动切换。
   - 使用现有 `init.d/router-tool` 根据变更配置重载 netifd、firewall、odhcpd、dnsmasq；不新增独立守护进程或第二套热插拔重载链路。

5. **构建期补丁必须可验证**
   - `Settings.sh` 对 `relay_ap.uc`、`router-tool-auto` 和必要的 LuCI 关闭 AP/人工接管路径使用唯一锚点替换；上游结构变化或任一关键文件缺失时使构建失败，不静默跳过。
   - 构建结束前检查：`luci-app-router-tool` 已选中、后台入口包含自动 Relay AP 判断、自动成功路径设置 `ap_mode` 与 `ap_state`，普通 `avoidSubnetConflict()` 不会在自动切换成功前抢先执行。

# Critical files

- `Config/IPQ60XX.txt`：显式选入 Router Tool。
- `.github/workflows/build.yml`：feed 时序、`defconfig` 包检查和现有设备断言。
- `Scripts/Settings.sh`：对上游 Router Tool 应用成组、可失败的构建期补丁。
- 上游 `package/emortal/luci-app-router-tool/root/usr/libexec/router-tool-auto`：WAN 状态读取、自动判断入口、锁/事务/重载链路。
- 上游 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/relay_ap.uc`：新增的服务端 Relay AP 配置计划与快照逻辑。
- 上游 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/auto.uc`：现有 `subnet()`、`overlaps()`、`manual_lan` 和 `avoidSubnetConflict()` 的复用/调用顺序。
- 上游 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/snapshot.uc`、`transaction.uc`：手工配置识别、快照校验和掉电恢复。
- 上游 `package/emortal/luci-app-router-tool/htdocs/luci-static/resources/tools/router-tool.js`：手动关闭 AP 时记录人工接管，保持页面保存语义。

# Verification

- 静态检查：`bash -n Scripts/Settings.sh`、`shellcheck`、`git diff --check`、`actionlint`，并验证 Settings 补丁重复执行不会重复插入代码。
- 使用真实 `owrt` feed 源码运行 `Settings.sh` 两次，确认 Router Tool 包存在且自动入口、`relay_ap.uc`、人工关闭标志均已补丁。
- 用同版本 ucode/模拟 UCI 状态覆盖：WAN `192.168.10.1/24` 与本机 LAN `192.168.10.1/24` 冲突时一次性生成完整 AP 配置和 `ap_state`；不同网段不触发；WAN 未获取租约不触发；PPPoE 主路由不触发；手工 LAN/未确认拓扑不触发；重复 interface 事件不重复切换。
- 验证 AP 配置包含 bridge、WAN 禁用、LAN/wan6 DHCP、本机 DHCP 禁用、无线归并 LAN、relay_ap 防火墙和可恢复快照；关闭 AP 后能恢复原配置。
- 运行 `make defconfig`/`test_only`，确认 `CONFIG_PACKAGE_luci-app-router-tool=y`、两款 IPQ60XX 设备仍被选中；完成固件后在实机仅通过 WAN 接入上级 LAN，检查是否自动获得上级地址、旧管理地址失效后新地址可访问、DHCP 不重复、拔线不会循环切换。
