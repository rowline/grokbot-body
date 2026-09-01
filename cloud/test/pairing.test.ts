/// <reference types="@cloudflare/vitest-pool-workers" />
import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

async function callTool(name: string, args: Record<string, unknown>) {
  const response = await SELF.fetch("https://example.com/mcp", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name, arguments: args },
    }),
  });
  const body = (await response.json()) as {
    result: { structuredContent: Record<string, unknown>; isError?: boolean };
  };
  return body.result.structuredContent;
}

describe("binding", () => {
  it("health lists MCP tools", async () => {
    const response = await SELF.fetch("https://example.com/health");
    const body = (await response.json()) as { ok: boolean; tools: string[] };
    expect(body.ok).toBe(true);
    expect(body.tools).toContain("claim_body");
    expect(body.tools).toContain("describe_body");
    expect(body.tools).toContain("set_expression");
    expect(body.tools).toContain("wait_for_speech");
    expect(body.tools).toContain("set_wake_hook");
  });

  it("initialize tells the bot to keep listening on the phone", async () => {
    const response = await SELF.fetch("https://example.com/mcp", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
    });
    const body = (await response.json()) as { result: { instructions: string } };
    expect(body.result.instructions).toContain("wait_for_speech");
    expect(body.result.instructions).toContain("webhook");
    expect(body.result.instructions).toContain("不必记住");
    expect(body.result.instructions).not.toContain("每次身体工具都带 session_token");
  });

  it("tools/list includes speech wake hook", async () => {
    const response = await SELF.fetch("https://example.com/mcp", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }),
    });
    const body = (await response.json()) as { result: { tools: Array<{ name: string }> } };
    const names = body.result.tools.map((tool) => tool.name);
    expect(names).toContain("wait_for_speech");
    expect(names).toContain("set_wake_hook");
    expect(names).toContain("speak");
  });

  it("rejects a made-up pairing code", async () => {
    const result = await callTool("claim_body", {
      code: "000000",
      bot_label: "Desk Buddy",
    });
    expect(result.ok).toBe(false);
  });

  it("describe without a token is refused", async () => {
    const result = await callTool("describe_body", {});
    expect(result.ok).toBe(false);
  });

  it("remembers the claimed body id for connector calls", async () => {
    await env.PAIRING.getByName("index").setActiveBody("iphone-desk-1");
    expect(await env.PAIRING.getByName("index").getActiveBody()).toBe("iphone-desk-1");
    await env.PAIRING.getByName("index").clearActiveBodyIf("someone-else");
    expect(await env.PAIRING.getByName("index").getActiveBody()).toBe("iphone-desk-1");
    await env.PAIRING.getByName("index").clearActiveBodyIf("iphone-desk-1");
    expect(await env.PAIRING.getByName("index").getActiveBody()).toBe("");
  });

  it("connector key is stable and does not unlock an unclaimed body", async () => {
    const key = await env.PAIRING.getByName("index").getConnectorKey();
    expect(key.length).toBeGreaterThan(20);
    const again = await env.PAIRING.getByName("index").getConnectorKey();
    expect(again).toBe(key);

    const response = await SELF.fetch(`https://example.com/mcp/${key}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "describe_body", arguments: {} },
      }),
    });
    const body = (await response.json()) as {
      result: { structuredContent: Record<string, unknown> };
    };
    expect(body.result.structuredContent.ok).toBe(false);
    expect(String(body.result.structuredContent.error || "")).toContain("认领");
  });

  it("setup page lists doorbell steps", async () => {
    const response = await SELF.fetch("https://example.com/setup");
    const html = await response.text();
    expect(response.headers.get("content-type")).toContain("text/html");
    expect(html).toContain("门铃一次设好");
    expect(html).toContain("当 webhook 响起");
    expect(html).toContain("/setup/wake");
  });

  it("setup wake with a live pairing code stores the hook", async () => {
    await env.PAIRING.getByName("index").register("482193", "iphone-desk-1", Date.now() + 60_000);
    const response = await SELF.fetch("https://example.com/setup/wake", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        code: "482193",
        url: "https://hooks.example.com/wake",
        secret: "s3cret",
      }),
    });
    const body = (await response.json()) as { ok: boolean; wake_ready?: boolean };
    expect(body.ok).toBe(true);
    expect(body.wake_ready).toBe(true);
    const status = (await env.BODY.getByName("iphone-desk-1").getStatus()) as {
      wake_ready: boolean;
    };
    expect(status.wake_ready).toBe(true);
  });

  it("setup wake rejects a bad code", async () => {
    const response = await SELF.fetch("https://example.com/setup/wake", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        code: "000000",
        url: "https://hooks.example.com/wake",
      }),
    });
    const body = (await response.json()) as { ok: boolean };
    expect(body.ok).toBe(false);
  });

  it("a second token cannot drive an unclaimed body", async () => {
    const result = await callTool("control_dock", {
      session_token: "no-such-body.deadbeef",
      action: "nod",
    });
    expect(result.ok).toBe(false);
  });

  it("claim then control without the phone online fails closed", async () => {
    await env.PAIRING.getByName("index").register("482193", "iphone-desk-1", Date.now() + 60_000);
    const claimed = await callTool("claim_body", {
      code: "482193",
      bot_label: "Desk Buddy",
    });
    expect(claimed.ok).toBe(false);
    expect(String(claimed.error || "")).toContain("不在线");
  });
});
