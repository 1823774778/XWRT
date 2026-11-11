# Context

中继/AP 模式接入上级路由时，如果上级 LAN 与本机 LAN 重叠（例如两端都是 `192.168.10.1/24`），当前上游 Router Tool 会把本机地址改到其他 `192.168.x.1` 网段；需求是优先留在上级相同网段，按 `192.168.10.2`、`.3`……顺序选择未占用地址，并在多个地址冲突时继续递增，同时保护主路由模式和用户手工配置。

# Recommended approach

1. 在构建时对上游 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/auto.uc` 做精确、带版本锚点的补丁，复用现有 `subnet()`、`overlaps()`、`synchronize()` 和快照机制，不复制一套独立运行时逻辑。
2. 保持当前 `router-tool-auto` 的 WAN 状态获取链路：在非 AP/中继模式下读取 `network.interface.wan` 的 IPv4 地址和掩码；AP/中继模式由现有 `ap_mode`/快照状态保护，不自动改写 LAN。上级信息未就绪时沿用事件触发重试，不做猜测性改址。
3. 替换 `synchronize()` 中现有的冲突候选循环（当前固定生成 `192.168.${i}.1/24`）为同一上级子网内的主机地址扫描：根据真实网关地址/掩码计算网络范围，`/24` 从 `.2` 到 `.254` 顺序尝试；排除网络地址、广播地址、上级地址、本机当前地址、其他本地接口地址，以及现有上游地址/子网重叠项。优先选择 `.2`，冲突则继续 `.3`、`.4`……，找不到候选时保留当前配置并记录明确错误，不跳到其他网段。
4. 扩展占用判断以复用现有 UCI/状态数据为主：将上游 DHCP 地址、其他接口地址纳入占用集合；在目标系统已有可用 ARP/邻居探测入口时再加入邻居表或 `arping` 检查，工具不可用时采取保守策略，不把 ICMP 失败当作空闲的充分条件。
5. 利用现有 `state.manual_lan`、`lan_context()`、`finish_snapshot()` 和 `router-tool.main.state` 保持用户手工配置：仅当当前模式允许自动处理、快照未标记手工 LAN、且确实发生子网重叠时改址；用户手工修改后后续事件/升级不覆盖。保存事务后继续沿用 Router Tool 的网络重载和地址变更日志。
6. 在 `Scripts/Settings.sh` 中增加对 `auto.uc` 的构建时补丁和唯一性校验；上游代码锚点不匹配时让构建失败，避免生成未生效的固件。必要时只增加一次性兼容脚本，但不实现第二套地址选择算法。
7. 在 `.github/workflows/build.yml` 保持 feed 安装早于 `Settings.sh`，增加构建期检查以确认 Router Tool 补丁已应用；不把上级网络判断放到 CI。`Config/GENERAL.txt` 不新增包开关，先沿用已安装的 Router Tool feed 包。

# Critical files

- `Scripts/Settings.sh`：应用并校验上游 `auto.uc` 补丁。
- `.github/workflows/build.yml`：保持 feed/Settings 时序，并增加补丁生效检查。
- `Config/GENERAL.txt`：确认不强制改变 Router Tool 的上游包选择。
- 上游 `package/emortal/luci-app-router-tool/root/usr/share/router-tool/auto.uc`：复用 `subnet()`、`overlaps()`、`synchronize()` 和 `state.manual_lan` 的地址冲突逻辑。
- 上游 `package/emortal/luci-app-router-tool/root/usr/libexec/router-tool-auto`：确认 WAN 状态获取、AP 模式保护、事务提交和网络重载链路不被破坏。
- 上游 `snapshot.uc`：确认新增/调整状态仍符合已有快照格式和手工配置识别。

# Verification

- 运行 `bash -n Scripts/Settings.sh`、`shellcheck Scripts/Settings.sh`、`git diff --check` 和工作流 `actionlint`。
- 用真实 `owrt` feed 文件执行 Settings 补丁两次，验证补丁幂等、锚点唯一且 `auto.uc` 包含同网段候选逻辑。
- 用同版本 ucode 或上游可用测试环境覆盖：上级 `192.168.10.1/24` 时本机 `.1` -> `.2`；`.2` 占用时 -> `.3`；连续地址占用时继续递增；无重叠时不改；主路由/AP 模式保护；用户手工 LAN 与升级重复运行不改；无可用地址时保留现状并记录失败。
- 执行 `make defconfig`/`test_only` 配置构建，确认 IPQ60XX 两个设备选择不变；完成构建后在真实设备检查 `network.lan.ipaddr`、Router Tool 状态、DHCP 服务和 LuCI 新管理地址。
