# Changelog

## [Unreleased]

### Fixed

- **按住说话不再把话丢在屏幕上**：松手后识别报错不会取消提交；「嗯」也会交给 Bot。一直听可以再说同一句，识别结束后会按当前模式决定要不要再开麦。_by Rollin&Claude_
- **点头完成后脸会回来**：动作表情只在云台还在动时显示，不再被「点头完成」卡住。_by Rollin&Claude_
- **没人接的话写进 Durable Object**：休眠后下一次 wait_for_speech 还能拿到。配对码过期会自己换一枚并推到手机。_by Rollin&Claude_
- **门铃和认领不能再靠猜 6 位数**：认领必须走带密钥的连接地址；猜错大约 20 次会先停几分钟。录像链接带一次性查询令牌。_by Rollin&Claude_
- **12 秒录像不再被云端先判超时**：云端等到 90 秒。Bot 的 speak 不再裁成 24 字；任务完成出声不会挡住 Bot 再说同一句。_by Rollin&Claude_
- **追踪字符串 false 不再被当成开**：`set_tracking` 把 `"false"` / `"0"` 当关。拍照以 MCP 图片回给 Bot，工具正文里不再带 session_token。_by Rollin&Claude_
- **本机填 http 云地址能连上**：允许局域网明文；听写重启、WebSocket 重连、相机录像加麦改到采集队列，减少卡住和双连接。_by Rollin&Claude_
- **TestFlight build 14**：听写不再丢话、点头后面部会回来、认领必须带密钥、录像超时放宽、speak 念全文。_by Rollin&Claude_
- **听写不再拆 tap 闪退**：先停引擎再卸 tap，格式不合法就不装；蓝牙听写改走扬声器。相机等真正跑起来再交给 DockKit。_by Rollin&Claude_
- **TestFlight build 15**：修按住说话 / 一直听闪退。_by Rollin&Claude_
- **横屏字幕不再挡住按住说话**：听写原文收到左侧窄栏，文字不接点击；去掉会抢手势的滚动区。_by Rollin&Claude_
- **重启 App 仍会开跟随**：手机已经吸在座上时，启动和回到前台会再检查并打开人脸追踪。_by Rollin&Claude_
- **TestFlight build 16**：重启仍开跟随；横屏字幕不挡按住说话。_by Rollin&Claude_
- **吸上云台开 app 就闪退**：`setAngularVelocity` 在系统人脸追踪开着时是 fatalError（「API violation: setting velocity only supported when system tracking disabled」），是 trap 不是抛错，`try?` 挡不住。开跟随的第一行就是它，而云台吸上时系统追踪本来就开着，于是必崩。所有动速度/动姿态的调用前都先确认追踪是关的，中途被打开就按「被打断」回报。_by Rollin&Claude_
- **跟着人不自动开**：启动时 scenePhase 先于 boot() 变 active，DockKit 监听被建在相机跑起来之前，那条流收不到 docked，跟随就一直不开；重复 `restartListening` 还会把正要送达的 docked 事件取消掉。改成相机就绪才建流、5 秒内不重开流。绑定页把云台状态和 DockKit 明细显示出来，连不上时屏幕上能看见卡在哪一步。_by Rollin&Claude_
- **支架没动就不再报「完成」**：动作开始前先取消排队中的「跟回去」——它会在动作执行到一半重新打开人脸追踪，云台立刻转回人脸，看上去就是没动。关不掉追踪、云台没回报执行完、动作被追踪覆盖，现在都按失败回给 Bot 和语音，不再拿「云台还吸着」当成功。`set_tracking` 同样等追踪真的打开才说好了。_by Rollin&Claude_

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
- **云地址改成手填**：App 不再默认连某一条 Worker。绑定页「云」填自己部署的地址；文档里去掉了个人云通道。_by Rollin&Claude_
- **脸改成 Bloub 那种**：轮廓按径向剖面变形，过渡用 ease-out，去掉弹簧。手指在屏幕上搓脸，眼睛跟着看、身体被按扁，松手再缓回来。_by Rollin&Claude_
- **TestFlight build 10**：Bloub 脸、搓脸、云地址改手填。_by Rollin&Claude_
- **回答不连播、长句能看完**：同一句 12 秒内不重播；屏幕上的话可滚动，不再只显示三行。_by Rollin&Claude_
- **任务完成出声可选**：绑定页可开关。开了只说一句短的（拍好了、点头完成）；长内容写在对话框，不往外念。_by Rollin&Claude_
- **TestFlight build 11**：不连播、长句可滑看、任务完成出声可选。_by Rollin&Claude_
- **系统声改挑高级音色**：没开 Grok 时不再默认压缩版婷婷。自动用已下载的高级/增强中文声（雨舒、力穆优先）；绑定页可选、可试听。压缩音色会提示去系统设置下载增强或高级。_by Rollin&Claude_
- **脸可以选形状、颜色、表情**：绑定页按 Grok Bot 那套自定义：8 种外形、12 种颜色、16 种休息脸。Bot 还能换成生气、大笑、得意这些。_by Rollin&Claude_
- **TestFlight build 12**：系统声改挑高级/增强中文音色，绑定页可选可试听；脸可改形状、颜色、休息表情。云地址仍须自己填。_by Rollin&Claude_
- **选脸能点着、预览能看见**：绑定页脸的形状/颜色/表情改成芯片，不再用 Form 网格和会翻页的选择器；预览放在深色底上。没联网时不再变成感叹号，休息脸还在。_by Rollin&Claude_
- **TestFlight build 13**：绑定页选脸改成芯片，形状/颜色/表情点得着，预览放深色底；断网时不再变感叹号。_by Rollin&Claude_
