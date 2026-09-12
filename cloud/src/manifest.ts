import capabilityManifest from "../../body/capability_manifest.json";
import expressionVocab from "../../body/expression_vocab.json";

export const MANIFEST = capabilityManifest;
export const EXPRESSIONS = expressionVocab;

export const BINDING_TOOLS = [
  {
    name: "claim_body",
    description:
      "Bind this conversation to a physical phone body using the 6-digit pairing code shown on the phone. After a successful claim, later body tools use this body automatically. Do not ask the person to store a token.",
  },
  {
    name: "unbind_body",
    description: "Release the current binding. The phone will show as unbound.",
  },
] as const;

export const WAKE_ROUTINE_PROMPT =
  "身体有人说话了。立刻 wait_for_speech。把听到的原话写进对话框。开口最多一两句要点，长文和完成后的全文只写对话框。然后再听。不要编。";

export const JOB_PROMPT = [
  "你有一个物理身体：用户桌上的 iPhone + 云台。",
  "人主要对着手机说话。听到以后必须把原话写进这个对话框，再写出你的回答，电脑这边才能看见这场对话。",
  "speak 只说一两句短的。长内容、报告、完成后的全文只写在对话框，不要往外念。",
  "拍照、转头、录像这类任务做完，不要把结果 speak 出来。身体若开了「任务完成出声」，会自己说一句短的，比如拍好了。",
  "不要问「你还在吗」。heard=false 时不要往对话框写字，立刻再 wait_for_speech。",
  "认领成功后立刻 wait_for_speech。不必记住 session_token，工具会自己找到这具身体。",
  "主循环：wait_for_speech → 把听到的话写进对话 → 需要时转头、换脸、跟着人、拍照或录像 → 需要开口时 speak 一两句要点 → 立刻再 wait_for_speech。",
  "wait_for_speech 一次最多约 18 秒，超时必须马上再调。这是你听人说话的唯一入口。",
  "若被 webhook 叫醒：context 里就是原话。把这句写进对话，wait_for_speech 核对，要点一两句可以 speak，长文只写对话框，然后再听。",
  "吸上支架后手机默认人脸追踪。人对着手机说左转、点头、跟着我，电机会当场转，不必再调 control_dock / set_tracking。电脑对话框里要转头再用这些工具。",
  "看一眼用 get_frame。短视频用 record_video，最长 12 秒，返回 url。",
  "换脸：think 绕彩带，error 变成感叹号，hex 变成六边形。还可以开心、生气、困倦、得意、大笑、难过、害怕、怀疑、困惑、羞怯、无趣、兴奋。",
  "不要编用户说了什么。没返回 ok 的动作，不能说已经做完。不要让人把 token 或岗位说明再贴一遍。",
].join("\n");

export function canonicalizeExpression(name: string): string | null {
  if ((MANIFEST.expressions as string[]).includes(name)) return name;
  const mapped = (EXPRESSIONS.mood_map as Record<string, string>)[name];
  if (mapped && (MANIFEST.expressions as string[]).includes(mapped)) return mapped;
  return null;
}

export function isExpression(name: string): boolean {
  return canonicalizeExpression(name) != null;
}

export function isDockAction(action: string): boolean {
  return (MANIFEST.dock_actions as string[]).includes(action);
}

export function toolNames(): string[] {
  return [
    ...BINDING_TOOLS.map((t) => t.name),
    ...MANIFEST.tools.map((t) => t.name),
  ];
}

export function mcpTools() {
  const binding = BINDING_TOOLS.map((tool) => ({
    name: tool.name,
    description: tool.description,
    inputSchema: {
      type: "object",
      properties:
        tool.name === "claim_body"
          ? {
              code: { type: "string", description: "6-digit pairing code on the phone" },
              bot_label: {
                type: "string",
                description: "Human-readable name of this Bot, for the phone screen",
              },
              session_token: { type: "string" },
            }
          : {
              session_token: { type: "string" },
            },
      required: tool.name === "claim_body" ? ["code", "bot_label"] : [],
    },
  }));

  const body = MANIFEST.tools.map((tool) => ({
    name: tool.name,
    description: tool.description,
    inputSchema: {
      type: "object",
      properties: {
        session_token: {
          type: "string",
          description: "Optional. After claim, the connector URL already identifies this body.",
        },
        ...inputProperties(tool.name),
      },
      required: requiredArgs(tool.name),
    },
  }));

  return [...binding, ...body];
}

function inputProperties(name: string): Record<string, unknown> {
  switch (name) {
    case "set_expression":
      return {
        name: { type: "string", enum: MANIFEST.expressions },
        intensity: { type: "number" },
        hold_ms: { type: "number" },
      };
    case "control_dock":
      return { action: { type: "string", enum: MANIFEST.dock_actions } };
    case "set_tracking":
      return { enabled: { type: "boolean" } };
    case "wait_for_speech":
      return {
        timeout_ms: {
          type: "number",
          description: "wait milliseconds, default 18000, max 22000",
        },
      };
    case "set_wake_hook":
      return {
        url: {
          type: "string",
          description: "HTTPS webhook URL of your speech-wake routine",
        },
        secret: {
          type: "string",
          description: "Optional sender key or whsec_ signing secret",
        },
      };
    case "record_video":
      return {
        duration_s: {
          type: "number",
          description: "1 to 12 seconds, default 6",
        },
      };
    case "speak":
      return { text: { type: "string" } };
    default:
      return {};
  }
}

function requiredArgs(name: string): string[] {
  switch (name) {
    case "set_expression":
      return ["name"];
    case "control_dock":
      return ["action"];
    case "set_tracking":
      return ["enabled"];
    case "speak":
      return ["text"];
    case "set_wake_hook":
      return ["url"];
    default:
      return [];
  }
}
