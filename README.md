# GrokBot Body

给 Grok Bot 里**某一个 Bot** 装上的身体：iPhone + DockKit 云台 + 屏幕上的 Orb。

大脑是绑定的那个 Bot。手机只做脸、耳朵（系统听写）和嘴（朗读 Bot 的话）。手机出站连你自己部署的 Cloudflare Worker，运行时不需要家里的 Mac。

没有公共云通道。每人部署自己的 Worker，再在 App 绑定页「云」填那个地址。

原 Funthing DIY 仓库没有改。

## 目录

| 路径 | 内容 |
|---|---|
| `ios/GrokBotBody` | iPhone App |
| `cloud/` | Cloudflare Worker，一台身体一个 Durable Object |
| `body/` | 能力清单和表情词表（唯一出处） |
| `docs/binding.md` | 配对、门铃、MCP 工具 |

## 需要

- iPhone。云台用 Belkin DockKit（例如 Flow 2 Pro），没有云台也能听、说、换脸、拍照。
- 能加 Custom Connector 的 Grok Bot。
- 自己的 Cloudflare 账号，用来部署 Worker。
- 装 App：用 Xcode 打开 `ios/GrokBotBody.xcodeproj` 装到真机，Team 换成你的 Apple ID。第一次允许相机、麦克风、相册。

## 自己跑云

```bash
cd cloud
npm install
npm test
npx wrangler deploy
```

记下部署后的地址，形如 `https://<worker名>.<你的子域>.workers.dev`。

本地调试：

```bash
cd cloud
npx wrangler dev
```

手机绑定页云地址填 `http://<这台 Mac 的局域网 IP>:8787`。

## 一次绑好

1. iPhone 打开 GrokBot Body。绑定页「云」填上一步的 Worker 地址，点「保存并重连」。本地调试填 `http://<Mac局域网IP>:8787`。
2. 屏幕下方出现 6 位配对码，十分钟内有效。绑定页复制「连接地址」（带密钥，形如 `https://<你的worker>/mcp/<密钥>`）。
3. Grok Bot → Settings → Plugins → Custom Connector：
   - Name: GrokBot Body
   - Server URL: 贴第 2 步那条地址，只贴一次
4. 对要当灵魂的那个 Bot 说：

   用配对码 482193 认领身体。认领后立刻 wait_for_speech。

5. 手机屏幕改成「已绑定 · …」。
6. 按下一节把门铃设一次。之后 Bot 不用记 token，也不用再贴岗位说明。

旧的 `/mcp` 地址仍能用，但 Bot 忘了 token 就会调不动。请改成绑定页里那条带密钥的地址。Connector 是账号级的，所有 Bot 都能看见；锁是配对码加上连接地址里的密钥。

解绑：绑定页点「解绑」，或让已绑定的 Bot 调用 `unbind_body`。门铃网址还留在身体上，重绑后不用重设，除非点了「关掉门铃」。

## 门铃

没在听时，对着手机说话要能叫醒 Bot。设一次即可。

电脑打开 `https://<你的worker>/setup`，或按手机绑定页「门铃」：

1. 电脑打开这个 Bot → 自动化 → 新建。
2. 触发选「当 webhook 响起」。
3. 说明贴这段：

   身体有人说话了。立刻 wait_for_speech。把听到的原话写进对话框，用 speak 在手机上读出回答，然后再听。不要编。

4. 打开触发卡片，复制网址和密钥（只在电脑上能看见）。
5. 贴进 setup 页或手机绑定页。setup 页要填手机上的 6 位码：认领前是配对码，认领后是门铃码。

保存后绑定页显示「门铃 · 已接通」。屏幕若显示「已记下 · 现在没在听」，就是这一回合停了；门铃接通后对着手机说话会再叫醒。

## 对着手机说话

默认「按住说话」：按住球体说话，松手发给绑定的 Bot。办公室用这个。安静环境可在绑定页切到「一直听」——周围说话也会收进去。「按住录像」松手存到相册。

听到的原话和 Bot 的回答应写进 Grok Bot 对话框。手机默认用系统声。绑定页可贴自己的 xAI 密钥，开口才换成 Grok 音色（Eve / Ara / Leo / Rex / Sal）。密钥留在手机，不过云。没有密钥就没有 Grok 声。

`wait_for_speech` 一次最多约 18 秒，没人说话也必须马上再调。认领成功后应自己开始这个循环。

对着手机说左转、右转、转圈、点头、摇头、抬头、低头、跟着我、别跟着、停下，支架当场动，纯指令不交给 Bot。吸上云台默认人脸追踪。

左上角「在听 / 在说」表示身体正在听或正在读 Bot 的话。

- **已交给 Bot**：正在听，或门铃已按过。
- **已记下 · 现在没在听**：话到云了，但没人在等，门铃也还没接通。电脑里打字让 Bot 拍照、转头，只是在调工具，不等于在听。

## 脸

绑定页「脸」可以切：

- **Orb**：白球、槽眼。思考绕彩带，出错变成感叹号，`hex` 变成六边形。
- **暗球**：黑球白眼，同一套变形。

眼睛跟着手机倾斜。轻轻晃一下会愣住；故意连着用力晃会发晕，大约两秒后自己好。云台转动时切到「看」。

图标是白球黑槽眼，跟 Grok Bot 同一套语言，不是同一张图。

## 身体能干什么

| 能力 | 说明 |
|---|---|
| 听和说 | `wait_for_speech` / `speak` |
| 换脸 | `set_expression` |
| 转头点头 | `control_dock`：左转、右转、转圈、点头、摇头、抬头、低头 |
| 跟着人 | `set_tracking`，吸上云台默认开 |
| 拍一张 | `get_frame`，绑定页可关。图只在这一次工具返回里走，不落盘 |
| 录像 | `record_video`，1–12 秒 MP4，绑定页可关。过云的片子暂存在 Durable Object 里，每具身体只留最近 4 段 |
| 门铃 | 日常用绑定页或 `/setup`，不要靠 Bot 记网址 |

Bot 转头、拍照、录像、跟着人时，手机屏幕会写出正在做什么。拍照会闪一下并露出缩略图；录像时左上角红点倒数。

工具名和参数见 `docs/binding.md`。

## 第三方

屏幕上的 Orb（48 点眼环、球面投影、弹簧变形）移植自 [nasawz/GrokBot](https://github.com/nasawz/GrokBot)，BSD 3-Clause。对照过 [iduu/grokbot-animation](https://github.com/iduu/grokbot-animation)。说明见 `THIRD_PARTY.md`。

本仓库不是 xAI 官方产品。
