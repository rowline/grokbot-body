import { WAKE_ROUTINE_PROMPT } from "./manifest";
import { asBody, asPairing } from "./rpc";

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function setupPageHtml(origin: string): string {
  const wake = `${origin}/setup/wake`;
  const prompt = escapeHtml(WAKE_ROUTINE_PROMPT);
  return `<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>GrokBot Body 门铃</title>
  <style>
    :root { color-scheme: light; }
    body { font: 16px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; margin: 0; background: #f4f1ea; color: #1c1917; }
    main { max-width: 36rem; margin: 0 auto; padding: 28px 20px 64px; }
    h1 { font-size: 22px; margin: 0 0 8px; }
    h2 { font-size: 17px; margin: 28px 0 8px; }
    p, li { color: #44403c; }
    ol { padding-left: 1.2em; }
    code, .box { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
    .box { display: block; white-space: pre-wrap; background: #fff; border: 1px solid #d6d3d1; border-radius: 10px; padding: 12px; margin: 8px 0 12px; }
    button, input { font: inherit; }
    button { background: #1c1917; color: #fff; border: 0; border-radius: 10px; padding: 8px 14px; cursor: pointer; }
    button.secondary { background: #fff; color: #1c1917; border: 1px solid #d6d3d1; }
    label { display: block; margin: 12px 0 4px; font-size: 14px; }
    input { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #d6d3d1; border-radius: 10px; background: #fff; }
    .row { display: flex; gap: 8px; flex-wrap: wrap; margin: 8px 0 16px; }
    .ok { color: #166534; }
    .err { color: #b91c1c; }
  </style>
</head>
<body>
<main>
  <h1>门铃一次设好</h1>
  <p>设完以后，人对着手机说话就能叫醒 Bot。网址和密钥只在电脑上能看见，所以在这页贴。</p>

  <h2>1. Connector</h2>
  <ol>
    <li>打开手机绑定页，复制「连接地址」。</li>
    <li>Grok Bot → Settings → Plugins → Custom Connector，名称填 GrokBot Body。</li>
    <li>Server URL 贴那条带密钥的地址，只贴一次。</li>
  </ol>

  <h2>2. 认领</h2>
  <ol>
    <li>手机屏幕下方是 6 位配对码。</li>
    <li>对要当灵魂的那个 Bot 说：用配对码 XXXXXX 认领身体。</li>
  </ol>

  <h2>3. 门铃</h2>
  <ol>
    <li>电脑打开这个 Bot → 自动化 → 新建。</li>
    <li>触发选「当 webhook 响起」。</li>
    <li>说明贴下面这段。</li>
    <li>打开触发卡片，把网址和密钥填进本页表单。手机绑定页上的 6 位码，认领前是配对码，认领后是门铃码。</li>
  </ol>
  <p class="box" id="prompt">${prompt}</p>
  <div class="row">
    <button type="button" class="secondary" id="copy">复制说明</button>
  </div>

  <form id="form">
    <label for="code">手机上的 6 位码</label>
    <input id="code" name="code" inputmode="numeric" autocomplete="off" maxlength="6" required />
    <label for="url">webhook 网址</label>
    <input id="url" name="url" type="url" autocomplete="off" required placeholder="https://..." />
    <label for="secret">发送密钥，选填</label>
    <input id="secret" name="secret" type="password" autocomplete="off" />
    <div class="row">
      <button type="submit">保存门铃</button>
    </div>
    <p id="status"></p>
  </form>
</main>
<script>
  const promptText = document.getElementById("prompt").textContent;
  document.getElementById("copy").onclick = async () => {
    await navigator.clipboard.writeText(promptText);
    document.getElementById("copy").textContent = "已复制";
  };
  document.getElementById("form").onsubmit = async (event) => {
    event.preventDefault();
    const status = document.getElementById("status");
    status.textContent = "正在保存";
    status.className = "";
    try {
      const response = await fetch(${JSON.stringify(wake)}, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          code: document.getElementById("code").value,
          url: document.getElementById("url").value,
          secret: document.getElementById("secret").value,
        }),
      });
      const body = await response.json();
      if (body.ok) {
        status.textContent = "门铃已接通。手机绑定页应显示已接通。";
        status.className = "ok";
      } else {
        status.textContent = body.error || "没保存住";
        status.className = "err";
      }
    } catch (error) {
      status.textContent = "没保存住";
      status.className = "err";
    }
  };
</script>
</body>
</html>`;
}

export async function handleSetupWake(
  request: Request,
  env: Env,
): Promise<Response> {
  if (request.method !== "POST") {
    return Response.json({ ok: false, error: "method not allowed" }, { status: 405 });
  }
  let payload: { code?: string; url?: string; secret?: string };
  try {
    payload = (await request.json()) as { code?: string; url?: string; secret?: string };
  } catch {
    return Response.json({ ok: false, error: "需要 JSON" }, { status: 400 });
  }
  const code = String(payload.code || "").trim();
  if (!/^\d{6}$/.test(code)) {
    return Response.json({ ok: false, error: "需要 6 位码" }, { status: 400 });
  }
  const found = await asPairing(env.PAIRING.getByName("index")).lookupBody(code);
  if (!found) {
    return Response.json({ ok: false, error: "6 位码无效或已过期" }, { status: 400 });
  }
  const result = await asBody(env.BODY.getByName(found.bodyId)).setWakeHook(
    String(payload.url || ""),
    String(payload.secret || ""),
  );
  return Response.json(result, { status: result.ok === false ? 400 : 200 });
}
