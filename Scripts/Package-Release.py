#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo


def main():
    source = Path(os.environ.get("BUILD_DIR", "wrt"))
    config = {}
    for line in (source / ".config").read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value.strip('"')

    board = config["CONFIG_TARGET_BOARD"]
    subtarget = config["CONFIG_TARGET_SUBTARGET"]
    target = os.environ["RELEASE_TARGET"]
    output = source / "bin" / "targets" / board / subtarget
    overview = json.loads((output / "profiles.json").read_text())
    profiles = overview["profiles"]
    if not profiles or overview["target"] != f"{board}/{subtarget}":
        raise ValueError("Missing or mismatched firmware device metadata")
    for device, profile in profiles.items():
        images = [output / image["name"] for image in profile["images"]]
        if not images or any(not image.is_file() or image.stat().st_size == 0 for image in images):
            raise ValueError(f"Missing firmware image for {device}")

    manifests = sorted(output.glob("*.manifest"))
    if not manifests:
        raise ValueError("Missing firmware package manifest")
    packages = set()
    for manifest in manifests:
        for line in manifest.read_text().splitlines():
            if line.strip():
                packages.add(line.split()[0])

    def is_plugin(name):
        return name.startswith(("luci-app-", "luci-theme-"))

    device_plugins = {
        device: sorted(name for name in profile["device_packages"] if is_plugin(name))
        for device, profile in profiles.items()
    }
    special_plugins = {name for names in device_plugins.values() for name in names}
    plugins = sorted(name for name in packages if is_plugin(name) and name not in special_plugins)
    aliases = {
        "jdcloud_re-ss-01": "京东云亚瑟 RE-SS-01",
        "jdcloud_re-cs-02": "京东云雅典娜 RE-CS-02",
    }
    devices = {}
    for device, profile in sorted(profiles.items()):
        title = profile["titles"][0]
        label = title.get("title") or " ".join(
            title[key] for key in ("vendor", "model", "variant") if title.get(key)
        )
        devices[device] = aliases.get(device, label or device)

    timestamp = datetime.fromisoformat(
        (source / "files/etc/xwrt-build-time").read_text().strip()
    ).astimezone(ZoneInfo("Asia/Shanghai"))
    source_branch = os.environ["SOURCE_BRANCH"]
    tag = (
        f"XWRT-{target}-{source_branch.replace('/', '-')}-"
        f"{timestamp:%Y.%m.%d-%H.%M.%S}-"
        f"{os.environ['GITHUB_RUN_ID']}.{os.environ['GITHUB_RUN_ATTEMPT']}"
    )
    if not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
        raise ValueError("Invalid release tag")
    name = f"XWRT {target} · {timestamp:%Y-%m-%d %H:%M:%S} (UTC+8)"
    source_commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    firmware = sorted(artifact for artifact in output.glob("*.bin") if artifact.is_file())
    if not firmware:
        raise ValueError("No .bin firmware images available for release")
    release_dir = Path("release")
    assets = release_dir / "assets"
    assets.mkdir(parents=True, exist_ok=False)
    for artifact in firmware:
        filename = f"{artifact.stem}-{timestamp:%Y-%m-%d-%H.%M.%S}{artifact.suffix}"
        shutil.copy2(artifact, assets / filename)

    repository = os.environ["GITHUB_REPOSITORY"]
    kernel = overview["linux_kernel"]["version"]
    ip = os.environ["WRT_IP"]
    ssid = os.environ["WRT_SSID"]
    notes = [
        f"这是 XWRT 的 {board}/{subtarget} 平台固件，包含下列本次实际编译的设备。",
        "请根据型号选择附件；`sysupgrade` 用于升级，`factory` 用途请按对应设备刷机方式确认。",
        "",
        "设备列表：",
        *[f"- {label}（`{device}`）" for device, label in devices.items()],
        "",
        f"固件源码：{os.environ['SOURCE_REPO']}",
        f"源码分支：{source_branch}",
        f"源码提交：`{source_commit}`",
        f"XWRT 项目：https://github.com/{repository}",
        f"XWRT 提交：`{os.environ['GITHUB_SHA']}`",
        "",
        f"配置：{target}",
        f"平台：{board}/{subtarget}",
        f"内核版本：{kernel}",
        f"构建时间：{timestamp:%Y-%m-%d %H:%M:%S}（Asia/Shanghai）",
        "",
        f"默认登录地址：http://{ip}",
        "默认登录用户：root",
        "默认登录密码：无，请首次登录后设置；保留配置升级沿用原密码。",
        "",
        f"默认 Wi-Fi 名称：{ssid}（有无线硬件时按频段追加后缀，如 {ssid}-2.4G）",
        f"默认 Wi-Fi 密码：{os.environ['WRT_WORD']}",
        "保留配置升级时，网络和 Wi-Fi 设置沿用设备原配置。",
        "",
        "插件列表（根据本次固件的软件包清单生成）：",
        " ".join(f"`{plugin}`" for plugin in plugins) or "无额外 LuCI 插件。",
    ]
    for device, names in device_plugins.items():
        if names:
            notes.append(f"\n{devices[device]} 专用插件：" + " ".join(f"`{item}`" for item in names))
    if (source / "files/etc/apk/config").is_file():
        apk_config = (source / "files/etc/apk/config").read_text().splitlines()
        if "allow-untrusted" in apk_config:
            notes.extend(["", "APK：默认允许未签名的第三方软件包，安装时仍需匹配架构及依赖。"])
    notes.extend([
        "",
        "附件仅包含 `.bin` 固件，文件名末尾为北京时间编译日期和时间（YYYY-MM-DD-HH.MM.SS）。",
        f"构建记录：https://github.com/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "",
    ])
    (release_dir / "release-notes.md").write_text("\n".join(notes))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as handle:
        handle.write(f"tag={tag}\nname={name}\n")
    print(f"Prepared {len(firmware)} .bin firmware assets for {tag}")


if __name__ == "__main__":
    main()
