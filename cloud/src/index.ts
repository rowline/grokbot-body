import { BodyDurableObject } from "./body-do";
import { handleMcp } from "./mcp";
import { JOB_PROMPT, toolNames } from "./manifest";
import { PairingIndex } from "./pairing-do";
import { handleSetupWake, setupPageHtml } from "./setup-page";

export { BodyDurableObject, PairingIndex };

function cors(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, x-body-token, x-connector-key");
  headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  return new Response(response.body, { status: response.status, headers });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return cors(new Response(null, { status: 204 }));
    }

    const url = new URL(request.url);
    try {
      if (url.pathname === "/" || url.pathname === "/health") {
        return cors(
          Response.json({
            ok: true,
            service: "grokbot-body",
            mcp: "/mcp",
            setup: "/setup",
            job_prompt: JOB_PROMPT,
            tools: toolNames(),
          }),
        );
      }
      if (url.pathname === "/setup") {
        return cors(
          new Response(setupPageHtml(url.origin), {
            headers: { "content-type": "text/html; charset=utf-8" },
          }),
        );
      }
      if (url.pathname === "/setup/wake") {
        return cors(await handleSetupWake(request, env));
      }
      const mcpMatch = url.pathname.match(/^\/mcp(?:\/([^/]+))?\/?$/);
      if (mcpMatch) {
        return cors(await handleMcp(request, env, mcpMatch[1] || ""));
      }
      const wsMatch = url.pathname.match(/^\/body\/([^/]+)\/ws$/);
      if (wsMatch) {
        const bodyId = decodeURIComponent(wsMatch[1]);
        const stub = env.BODY.getByName(bodyId);
        return stub.fetch(request);
      }
      const clipPost = url.pathname.match(/^\/body\/([^/]+)\/clip$/);
      if (clipPost && request.method === "POST") {
        const bodyId = decodeURIComponent(clipPost[1]);
        return cors(await env.BODY.getByName(bodyId).fetch(request));
      }
      const clipGet = url.pathname.match(/^\/clip\/([^/]+)\/([^/]+)$/);
      if (clipGet && request.method === "GET") {
        const bodyId = decodeURIComponent(clipGet[1]);
        return cors(await env.BODY.getByName(bodyId).fetch(request));
      }
      return cors(Response.json({ error: "not found" }, { status: 404 }));
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      console.error(JSON.stringify({ message: "unhandled error", error: message, path: url.pathname }));
      return cors(Response.json({ error: "internal error" }, { status: 500 }));
    }
  },
} satisfies ExportedHandler<Env>;
