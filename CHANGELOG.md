# Changelog

## [Unreleased]

### Added

- **GrokBot Body 新仓库**：从 Funthing DIY 只带走 DockKit 和相机，做成给某一个 Grok Bot 用的身体。屏幕换成会变形的 Orb，手机出站连 Cloudflare，不再经过家里的 Mac 网关。_by Rollin&Claude_
- **能力清单与配对**：`describe_body` 是合同；6 位配对码认领一个 Bot，第二个 Bot 没有 token 调不动。_by Rollin&Claude_
- **注册 Bundle ID**：开发者账号 UUCT5KCPPB 上建了 `com.rollin.GrokBotBody`，Xcode 自动签名能编过真机包。_by Rollin&Claude_
- **TestFlight 首包 build 1**：补了 1024 不透明图标和加密声明，`CFBundlePackageType` 写成 APPL，已传到 App Store Connect，What to Test 已写上。_by Rollin&Claude_
- **加上嘴**：手机麦/喇叭经 Cloudflare 接到 Grok Voice，听和说时 Orb 会变脸，转头工具仍打同一具身体。_by Rollin&Claude_
- **嘴改成交给绑定的 Bot**：拆掉 Grok Voice 旁路。手机只做听写和朗读，`wait_for_speech` / `speak` 由那个 Bot 调用。_by Rollin&Claude_
- **办公室按住说话**：默认不一直听。按住球体说话、松手发给绑定的 Bot；绑定页可切到一直听。_by Rollin&Claude_
- **Orb 表情系列**：绑定页可切 Grok Bot 那种白球槽眼变形（出错变感叹号、思考绕彩带），原来的暗球白眼还留着。App 图标按白球黑槽眼重画。_by Rollin&Claude_
- **开源眼环 + 听写可见**：脸改用 nasawz/GrokBot 的 48 点眼环弹簧变形，对照 iduu/grokbot-animation。按住说话会显示原文，以及已交给 Bot / 未值班。_by Rollin&Claude_
- **Bot 操作有反馈**：转头、拍照、跟着人会在手机上写出正在做什么；拍照闪一下并露出缩略图。绑定页列出身体能力：跟着人有，录像没有。_by Rollin&Claude_
- **短视频 record_video**：Bot 可录 1–12 秒 MP4，手机红点倒数，上传后返回链接。绑定页可关掉。_by Rollin&Claude_
- **按住录像存相册**：手势可切按住录像，松手存到相册；Bot 录的也会进相册。思考绕彩带、出错变感叹号、hex 变六边形。_by Rollin&Claude_
- **晃动和转头有表情**：陀螺仪让眼睛跟着手机倾斜；晃一下会愣住；云台转动时切到「看」的表情。_by Rollin&Claude_
- **用力连晃会发晕**：短时间里使劲晃几下，球会打转、眼珠旋、绕彩带，一两秒再回来。_by Rollin&Claude_
- **听写回执改口**：没有 wait_for_speech 时显示「已记下 · 现在没在听」，不再写成未值班。电脑端拍照不代表它在听。_by Rollin&Claude_
- **认领后自动听、横竖屏适应**：wait_for_speech 默认等到 50 秒，做完拍照转头也提示立刻再听；话会记下最多 3 分钟。界面随设备自动横竖屏，相机方向跟着转。_by Rollin&Claude_
- **对着身体说话能续上 Bot**：wait_for_speech 一次最多约 18 秒，工具回执改成白话命令立刻再听；没人等的时候若登记了 webhook 会叫醒 Bot。_by Rollin&Claude_
- **陀螺仪不乱抖脸**：坐下时记一个安静姿态，小晃忽略；真转头、真摇晃才动眼睛。_by Rollin&Claude_
- **嘴用 Grok 音色**：Bot 还是决定说什么。云端 TTS 合成 Eve/Ara 等声音，手机只播；没密钥时仍用系统声。_by Rollin&Claude_
- **Grok 音色改成手机自选**：绑定页可贴自己的 xAI 密钥，不贴就用系统声。密钥进钥匙串，不过云。官方音色没有免密钥的办法。_by Rollin&Claude_
- **语音控支架在本地，默认跟人脸**：吸上云台就开追踪。说左转、点头、跟着我，电机当场动；纯指令不再交给 Bot。_by Rollin&Claude_
- **没在听也能叫醒 Bot**：绑定页可贴 webhook routine 的网址和密钥。人对着手机说话时，云端去按这个门铃，Bot 醒来再听。不贴就仍是只有它正在听才接得住。_by Rollin&Claude_
- **减少闪退**：追踪不再被状态回调反复开关；相机平时不占麦克风；预览图不再每帧压 JPEG；陀螺仪不再整页刷新。_by Rollin&Claude_
- **身体上说的话写进 Bot 对话框**：听到原话后 Bot 要把句子和回答写进对话，电脑这边能看见；没人说话仍不往对话框灌。_by Rollin&Claude_
- **发晕会自己好**：连晃发晕大约两秒后解除，晕着时不再被续上。_by Rollin&Claude_
- **门铃一次设好**：绑定页按 1–4 步复制说明、贴网址；电脑打开 `/setup` 也能贴。设完显示已接通，重绑不用重设。_by Rollin&Claude_
- **认领后不用记 token**：Custom Connector 改贴绑定页里那条带密钥的地址。之后工具自己找到这具身体，不再靠 Bot 记住 session_token 或岗位说明。_by Rollin&Claude_
- **TestFlight build 9**：门铃一次设好、发晕大约两秒后自己好、Connector 带密钥后 Bot 不用记 token。_by Rollin&Claude_
- **README 能照着绑**：根目录说明改成一次绑好、门铃、听和说、自己跑云；并推到 GitHub。_by Rollin&Claude_
