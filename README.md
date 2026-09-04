# Codex计费

把 Codex 的 7 天剩余额度直接放进 macOS 菜单栏。抬眼就能看到，不用打开 Codex，也不用再点进账户页面。

菜单栏默认显示 `7d余XX%`。点击后可以查看下一次重置时间、同步时间，切换 7 天或 5 小时窗口，也可以打开更完整的用量详情。项目同时提供 WidgetKit 桌面小组件。

## 为什么做它

额度信息很重要，查看入口却离正在做的事有点远。一次查询往往要切窗口、打开页面、找到用量区域。Codex计费把这个高频数字放到屏幕顶部，查看额度只需要一眼。

## 功能

- macOS 菜单栏常驻显示 Codex 7 天剩余比例
- 显示额度重置时间和最近同步时间
- 兼容 Plus 与 Pro 返回的 5 小时、7 天窗口，缺失的窗口会自动隐藏
- 读取本机 Codex 会话日志，汇总今日 Token 和最近 7 天数据
- 提供小号、中号桌面小组件
- 三套低干扰视觉主题
- 现实主义铜珠沙漏 App 图标
- 本机运行，不上传会话内容或用量快照

## 环境要求

- macOS 14 或更高版本
- 已安装并登录 Codex 桌面应用或 Codex CLI
- Apple Command Line Tools 或 Xcode

## 构建

```bash
git clone https://github.com/fyrenlab/codex-usage-menubar.git
cd codex-usage-menubar
chmod +x build.sh
./build.sh --install
```

构建脚本只使用 macOS 自带工具和 Swift 框架，不需要安装第三方依赖。它会进行本机临时签名，在 `dist/` 中只生成 `Codex计费.app.zip`，避免 macOS 把项目构建物误注册成第二个应用。使用 `--install` 时，正式应用会安装到 `~/Applications/Codex计费.app`。

如果系统首次启动时拦截本机构建的应用，请在 Finder 中右键应用并选择“打开”。桌面小组件可以从 macOS 的“编辑小组件”面板中添加。

运行兼容性检查：

```bash
./test.sh
```

额度窗口按接口返回的实际时长识别，不把 `primary` 固定当作 5 小时，也不把其他模型的独立额度混入主 Codex。OpenAI 当前说明 Plus 和 Pro 的本地消息使用 5 小时窗口，同时可能叠加每周限制；具体返回窗口仍以账户为准。[OpenAI Docs](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan)

## 数据与隐私

应用通过本机 Codex 可执行文件读取当前额度，并从 `~/.codex/sessions` 汇总本地 Token 记录。桌面小组件读取的只是保存在 `~/Library/Application Support/AIUsageDesklet/usage.json` 中的汇总快照。

项目不包含账号令牌、API Key、会话正文或个人路径，不会把数据发送到自建服务器。Codex 自身的登录与联网行为仍由 Codex 客户端负责。

当前读取方式依赖 Codex 的本地日志格式和 `app-server` 接口。Codex 更新后如果字段发生变化，应用可能需要同步适配。

## 项目结构

```text
Sources/AIUsageDesklet.swift          菜单栏应用、详情页与数据读取
Widget/AIUsageDeskletWidget.swift     WidgetKit 桌面小组件
build.sh                              无第三方依赖的构建与安装脚本
assets/AppIcon-master.png             铜珠沙漏图标母版
```

## 小红书发布素材

- [小红书介绍文案](XIAOHONGSHU.md)
- [3:4 封面图](assets/xhs-cover-codex-usage-menubar.png)

## 许可证

[MIT](LICENSE)

Codex计费是社区项目，与 OpenAI 没有隶属或官方授权关系。Codex 是 OpenAI 的商标。
