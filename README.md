<div align="center">

# PixLume

> 一款为 HarmonyOS 开发的原生轻量级 Pixiv 第三方客户端

![HarmonyOS](https://img.shields.io/badge/HarmonyOS-ArkTS-green)
![API](https://img.shields.io/badge/API-24%2B-blue)
[![Release](https://img.shields.io/github/v/release/SYTKILLER/PixLume?logo=github)](https://github.com/SYTKILLER/PixLume/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

</div>

## ✨ 项目简介

PixLume 旨在为鸿蒙用户提供原生流畅的插画与小说浏览体验。它基于 ArkTS / TypeScript 开发，深度整合了 HarmonyOS 的系统能力与 UI 特性，通过 API 模块实现了账号登录、推荐浏览、搜索发现与用户互动等完整功能。

## 🚀 核心功能

- **🔐 登录**
    - 支持账号密码与 Refresh Token 双重登录方式（请确保能够正确访问 Pixiv）。
    - 内置智能 Token 刷新机制，无需频繁重新登录，保持长期在线状态。
- **🎨 探索与发现**
    - **推荐流**：根据个人喜好智能推荐插画与漫画。
    - **排行榜**：一键浏览日榜、周榜、月榜。
    - **搜索**：支持关键词、标签精准搜索与多图作品识别；「猜你喜欢」从你的收藏标签中随机推荐灵感。
- **🖼️ 沉浸式浏览**
    - 插画与小说双形态内容，均支持沉浸式阅读与暗色模式。
    - **GIF 动图**：详情页原生播放动图，下载自动转码为 GIF 保存至相册。
    - 支持大图预览、手势操作与原图下载。
- **⚡ 直连模式**
    - 网络受限环境下的可选直连链路：启动时自动探测，普通网络不可用时自动切换，接口 / 图片 / 下载三链路全覆盖。
- **❤️ 用户互动**
    - **收藏管理**：支持公开/私密收藏，自定义标签，信息流内直接显示收藏状态。
    - **关注画师**：支持公开/私密关注，实时跟进喜欢的作者。
- **🗂 本地管理**
    - **下载管理**：集中管理下载任务与已下载作品，GIF 作品独立标识，支持再次保存。
    - **小说保存**：小说支持保存 TXT 至本地，可随时再次导出。
    - **历史记录**：随手回顾看过的插画与小说。
- **🧰 关键词工具**
    - 标签关键词自动显示译文，支持本地收藏 / 屏蔽与统一管理。
- **📱 体验优化**
    - **智感握姿**：悬浮操作按钮随左右手握持自动换边，单手更顺手。
    - 底部悬浮页签、沉浸式设计。

## 🎨 视觉设计

<div align="center">
  <img src="assets/app_icon_round.png" alt="PixLume Icon" width="120">
</div>

本项目的应用图标由 **[科蓝](https://github.com/kelanKL)** 设计。

## 🛠 技术栈

- **开发语言**：ArkTS / TypeScript
- **运行环境**：HarmonyOS 6.1.1（API 24）及以上
- **网络请求**：@ohos/axios / RCP
- **本地存储**：Preferences / KV Store
- **开发工具**：DevEco Studio 6.1+（HarmonyOS SDK 6.1.1）

## 📥 下载安装

前往 [GitHub Releases](https://github.com/SYTKILLER/PixLume/releases/latest) 下载最新版本的 HAP 安装包。

> ⚠️ 使用本应用需要你的设备能够访问 Pixiv。

各版本更新内容见 [CHANGELOG.md](CHANGELOG.md)。

## 🧑‍💻 本地构建

1. 克隆本仓库：

    ```bash
    git clone https://github.com/SYTKILLER/PixLume.git
    ```

2. 使用 DevEco Studio 打开项目，等待依赖自动同步完成（或手动执行 `ohpm install`）。
3. 配置签名：`File > Project Structure > Signing Configs`，勾选自动生成签名（调试），或使用自有证书。
4. 连接设备或启动模拟器，点击 Run 运行；也可以使用命令行构建：

    ```bash
    hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
    ```

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 🙏 致谢

本项目的开发离不开开源社区的无私分享与支持，特此感谢以下项目与开发者：

- **[XHXYT/Pixark](https://github.com/XHXYT/Pixark)**：PixLume 的前身项目，感谢原作者 [XHXYT](https://github.com/XHXYT) 的开源贡献。本项目在其代码基础上持续重构、修复并新增功能，最终发展为独立应用。
- **[Pixiv-Shaft](https://github.com/CeuiLiSA/Pixiv-Shaft)**：一款优秀的第三方 Pixiv Android 客户端。PixLume 在界面与交互设计上参考了 Shaft 的设计理念，直连模式的候选节点方案亦来自该项目，感谢 [CeuiLiSA](https://github.com/CeuiLiSA)。
- **[Pixez](https://github.com/Notsfsssf/pixez-flutter)**：一款优秀的第三方 Pixiv Flutter 客户端。Pixez 优雅的 UI 设计和成熟的业务逻辑为项目的架构设计提供了重要的灵感和参考。
- **[PixivPy](https://github.com/upbit/pixivpy)**：强大的 Python 版 Pixiv API 库。其完善的 API 接口定义和签名逻辑，为理解 Pixiv 协议提供了极大的帮助。
- **[HarmonyOS Developer Community]**：感谢鸿蒙社区开发者在技术探索上的贡献。

## ⚠️ 免责声明

- **PixLume** 是一个非官方的第三方客户端，与 Pixiv Inc. 没有任何从属关系。
- 本项目仅供学习交流使用，请勿用于商业用途。使用本软件所产生的一切风险和责任由使用者自行承担。
- 请遵守 Pixiv 官方的服务条款及相关法律法规。

---

## 📄 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。

你可以自由地使用、修改和分发本软件，但所有衍生作品必须以相同的协议（GPLv3）开源。
详见 [LICENSE](LICENSE) 文件或 [GNU GPLv3 官方说明](https://www.gnu.org/licenses/gpl-3.0)。
