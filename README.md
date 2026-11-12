# XWRT

基于 ImmortalWrt `owrt` 分支的 OpenWrt 固件编译入口。仓库只保存 XWRT 自己的 CI、目标配置和构建时设置；上游源码在 GitHub Actions 中按需拉取，不复制上游源码树。

## 构建

1. 打开 GitHub Actions 的 **XWRT Build**。
2. 选择 `X86` 或 `ROCKCHIP`。
3. 可选地填写额外的 `.config` 配置行。
4. 运行工作流并从 Artifacts 下载配置或固件。

工作流对应的构建链路为：拉取 `VIKINGYFY/immortalwrt` 的 `owrt` 分支、应用 `Config/` 配置、运行 `Scripts/Settings.sh`、`make defconfig`、下载依赖并编译。`test_only` 可用于只生成配置文件。

## 目录

- `.github/workflows/build.yml`：手动/变更触发的构建工作流。
- `Config/`：平台与通用配置，保持与 OpenWRT-CI 的配置职责一致，但内容按 XWRT 需求重新整理。
- `Scripts/Settings.sh`：XWRT 默认主机名、地址、Wi-Fi 和 LuCI 设置。
- `Files/OpenAppFilter/`：OAF 内置中文特征库（构建时覆盖插件自带特征库并补充应用图标）。

## 许可证

本仓库新增文件采用 MIT License。ImmortalWrt 上游代码遵循其自身许可证。
