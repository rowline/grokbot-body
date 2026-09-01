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
  "身体有人说话了。立刻 wait_for_speech。把听到的原话写进对话框，用 speak 在手机上读出回答，然后再听。不要编。";

export const JOB_PROMPT = [
  "你有一个物理身体：用户桌上的 iPhone + 云台。",
  "人主要对着手机说话。听到以后必须把原话写进这个对话框，再写出你的回答，电脑这边才能看见这场对话。",
  "不要问「你还在吗」。heard=false 时不要往对话框写字，立刻再 wait_for_speech。",
  "认领成功后立刻 wait_for_speech。不必记住 session_token，工具会自己找到这具身体。",
  "主循环：wait_for_speech → 把听到的话写进对话 → 需要时转头、换脸、跟着人、拍照或录像 → speak 在手机上读出你的回答 → 立刻再 wait_for_speech。",
  "wait_for_speech 一次最多约 18 秒，超时必须马上再调。这是你听人说话的唯一入口。",
  "若被 webhook 叫醒：context 里就是原话。把这句写进对话，wait_for_speech 核对，speak 回答后再听。",
  "吸上支架后手机默认人脸追踪。人对着手机说左转、点头、跟着我，电机会当场转，不必再调 control_dock / set_tracking。电脑对话框里要转头再用这些工具。",
  "看一眼用 get_frame。短视频用 record_video，最长 12 秒，返回 url。",
  "换脸：think 绕彩带，error 变成感叹号，hex 变成六边形。",
  "不要编用户说了什么。没返回 ok 的动作，不能说已经做完。不要让人把 token 或岗位说明再贴一遍。",
].join("\n");

export function isExpression(name: string): boolean {
  return (MANIFEST.expressions as string[]).includes(name);
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
