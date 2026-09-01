import { JOB_PROMPT, mcpTools } from "./manifest";
import { asBody, asPairing } from "./rpc";

function pairingIndex(env: Env) {
  return asPairing(env.PAIRING.getByName("index"));
}

function bodyOf(env: Env, bodyId: string) {
  return asBody(env.BODY.getByName(bodyId));
}

type JsonRpc = {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
};

function jsonRpcResult(id: JsonRpc["id"], result: unknown): Response {
  return Response.json({ jsonrpc: "2.0", id: id ?? null, result });
}

function jsonRpcError(id: JsonRpc["id"], code: number, message: string): Response {
  return Response.json({
    jsonrpc: "2.0",
    id: id ?? null,
    error: { code, message },
  });
}

function sessionTokenFrom(
  request: Request,
  args: Record<string, unknown>,
): string {
  const header =
    request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ||
    request.headers.get("x-body-token") ||
    "";
  if (header) return header;
  return String(args.session_token || "");
}

function parseBodyIdFromToken(token: string): string | null {
  const parts = token.split(".");
  if (parts.length >= 2 && parts[0] && parts[0] !== "mcp") return parts[0];
  return null;
}

async function connectorCandidates(request: Request, pathKey: string): Promise<string[]> {
  const bearer =
    request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") || "";
  const header = request.headers.get("x-connector-key") || "";
  return [pathKey, bearer, header].map((value) => value.trim()).filter(Boolean);
}

async function hasConnectorAuth(
  env: Env,
  request: Request,
  pathKey: string,
): Promise<boolean> {
  const index = pairingIndex(env);
  for (const candidate of await connectorCandidates(request, pathKey)) {
    if (await index.connectorMatches(candidate)) return true;
  }
  return false;
}

export async function handleMcp(
  request: Request,
  env: Env,
  pathKey = "",
): Promise<Response> {
  if (request.method === "GET") {
    return Response.json({
      name: "grokbot-body",
      version: "0.1.0",
      job_prompt: JOB_PROMPT,
      tools: mcpTools().map((t) => t.name),
    });
  }
  if (request.method !== "POST") {
    return Response.json({ error: "method not allowed" }, { status: 405 });
  }

  let rpc: JsonRpc;
  try {
    rpc = (await request.json()) as JsonRpc;
  } catch {
    return jsonRpcError(null, -32700, "parse error");
  }

  const method = rpc.method || "";
  if (method === "initialize") {
    return jsonRpcResult(rpc.id, {
      protocolVersion: "2025-03-26",
      serverInfo: { name: "grokbot-body", version: "0.1.0" },
      capabilities: { tools: {} },
      instructions: JOB_PROMPT,
    });
  }
  if (method === "notifications/initialized" || method === "initialized") {
    return new Response(null, { status: 204 });
  }
  if (method === "tools/list" || method === "list_tools") {
    return jsonRpcResult(rpc.id, { tools: mcpTools() });
  }
  if (method === "tools/call" || method === "call_tool") {
    const params = rpc.params || {};
    const name = String(params.name || "");
    const args = (params.arguments || params.input || {}) as Record<string, unknown>;
    try {
      const result = { ...(await callTool(name, args, request, env, pathKey)) };
      if (name !== "unbind_body" && result.next == null) {
        result.next = "wait_for_speech";
      }
      return jsonRpcResult(rpc.id, {
        content: [{ type: "text", text: followupText(name, result) }],
        structuredContent: result,
        isError: result.ok === false,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "tool failed";
      return jsonRpcResult(rpc.id, {
        content: [{ type: "text", text: message }],
        isError: true,
      });
    }
  }
  if (method === "ping") {
    return jsonRpcResult(rpc.id, {});
  }
  return jsonRpcError(rpc.id, -32601, `unknown method ${method}`);
}

async function resolveBody(
  args: Record<string, unknown>,
  request: Request,
  env: Env,
  pathKey: string,
): Promise<Record<string, unknown> & { ok: boolean; body?: ReturnType<typeof bodyOf> }> {
  const token = sessionTokenFrom(request, args);
  const bodyIdFromToken = parseBodyIdFromToken(token);
  if (bodyIdFromToken) {
    const secret = token.slice(bodyIdFromToken.length + 1);
    const body = bodyOf(env, bodyIdFromToken);
    const allowed = await body.authorize(secret);
    if (!allowed) {
      return { ok: false, error: "这个身体不认这份绑定" };
    }
    return { ok: true, body };
  }

  if (await hasConnectorAuth(env, request, pathKey)) {
    const active = await pairingIndex(env).getActiveBody();
    if (!active) {
      return { ok: false, error: "还没有认领的身体。先用配对码调用 claim_body。" };
    }
    const body = bodyOf(env, active);
    if (!(await body.isClaimed())) {
      return { ok: false, error: "还没有认领的身体。先用配对码调用 claim_body。" };
    }
    return { ok: true, body };
  }

  return { ok: false, error: "还没有认领的身体。先用配对码调用 claim_body。" };
}

async function callTool(
  name: string,
  args: Record<string, unknown>,
  request: Request,
  env: Env,
  pathKey = "",
): Promise<Record<string, unknown>> {
  if (name === "claim_body") {
    const code = String(args.code || "").trim();
    const label = String(args.bot_label || "").trim();
    if (!/^\d{6}$/.test(code) || !label) {
      return { ok: false, error: "需要 6 位配对码和 bot_label" };
    }
    const found = await pairingIndex(env).lookup(code);
    if (!found) {
      return { ok: false, error: "配对码无效或已过期" };
    }
    const claimed = await bodyOf(env, found.bodyId).claim(label);
    if (!claimed.ok) return claimed;
    return {
      ...claimed,
      session_token: `${found.bodyId}.${String(claimed.session_token)}`,
    };
  }

  const resolved = await resolveBody(args, request, env, pathKey);
  if (!resolved.ok || !resolved.body) {
    return { ok: false, error: String(resolved.error || "还没有认领的身体。先用配对码调用 claim_body。") };
  }
  const body = resolved.body;

  switch (name) {
    case "unbind_body":
      return body.unbind();
    case "describe_body":
      return { ok: true, ...(await body.describe()) };
    case "get_status":
      return { ok: true, ...(await body.getStatus()) };
    case "set_expression":
      return body.setExpression(
        String(args.name || ""),
        Number(args.intensity ?? 0.8),
        Number(args.hold_ms ?? 1800),
      );
    case "control_dock":
      return body.controlDock(String(args.action || ""));
    case "set_tracking":
      return body.setTracking(Boolean(args.enabled));
    case "get_frame":
      return body.getFrame();
    case "record_video":
      return body.recordVideo(Number(args.duration_s ?? 6));
    case "wait_for_speech":
      return body.waitForSpeech(Number(args.timeout_ms ?? 18_000));
    case "speak":
      return body.speak(String(args.text || ""));
    case "set_wake_hook":
      return body.setWakeHook(String(args.url || ""), String(args.secret || ""));
    default:
      return { ok: false, error: `unknown tool ${name}` };
  }
}

function followupText(name: string, result: Record<string, unknown>): string {
  const json = JSON.stringify(result);
  if (name === "unbind_body") return json;
  if (result.ok === false) {
    return `${json}\n出错了。修好后立刻 wait_for_speech，不要停在对话框。`;
  }
  if (name === "wait_for_speech") {
    if (result.heard) {
      return `人对着手机说：「${String(result.text || "")}」。先把这句原话写进对话框，再写出你的回答，并用 speak 在手机上读出来，然后立刻再 wait_for_speech。\n${json}`;
    }
    return `这段没人说话。立刻再调用 wait_for_speech。不要往对话框写字，不要问还在吗。\n${json}`;
  }
  if (name === "claim_body") {
    return `认领成功。立刻 wait_for_speech。人只对着手机说话。不必记住 token。门铃按手机绑定页或电脑打开 /setup 的步骤设一次即可。\n${json}`;
  }
  if (name === "speak") {
    return `说完了。立刻 wait_for_speech。\n${json}`;
  }
  if (name === "set_wake_hook") {
    return `门铃已记下。立刻 wait_for_speech。\n${json}`;
  }
  return `做完了。立刻 wait_for_speech。人不会在对话框里打字。\n${json}`;
}
