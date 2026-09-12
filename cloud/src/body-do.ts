import { DurableObject } from "cloudflare:workers";
import { JOB_PROMPT, MANIFEST, canonicalizeExpression, isDockAction } from "./manifest";
import { decodeWhsec, hmacSha256Base64, randomPairingCode, randomToken, secretsEqual, sha256Hex } from "./crypto";
import { asPairing } from "./rpc";
import { normalizeVoice } from "./tts";

type Pending = {
  resolve: (value: Record<string, unknown>) => void;
  timer: ReturnType<typeof setTimeout>;
};

const PAIRING_TTL_MS = 10 * 60 * 1000;
const DESK_PIN_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const COMMAND_TIMEOUT_MS = 12_000;
const FRAME_TTL_MS = 15_000;
const UTTERANCE_TTL_MS = 180_000;
const SPEECH_WAIT_MAX_MS = 22_000;
const SPEECH_WAIT_DEFAULT_MS = 18_000;
const CLIP_PART = 700_000;
const CLIP_MAX_BYTES = 18 * 1024 * 1024;
const CLIP_KEEP = 4;
const CLIP_RECORD_TIMEOUT_MS = 90_000;

export class BodyDurableObject extends DurableObject<Env> {
  private pending = new Map<string, Pending>();
  private latestFrame: { jpeg: string; at: number } | null = null;
  private latestUtterance: { text: string; at: number } | null = null;
  private speechWaiters = new Map<string, Pending>();
  private speakingText = "";

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS clip_meta (
          id TEXT PRIMARY KEY,
          mime TEXT NOT NULL,
          bytes_len INTEGER NOT NULL,
          created INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS clip_parts (
          id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          PRIMARY KEY (id, seq)
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS clip_token (
          id TEXT PRIMARY KEY,
          token TEXT NOT NULL
        )
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade") !== "websocket") {
      if (request.method === "POST" && url.pathname.endsWith("/clip")) {
        return this.uploadClip(request);
      }
      if (request.method === "GET") {
        const token = url.searchParams.get("t") || "";
        const clip = url.pathname.match(/\/clip\/([^/]+)\/([^/]+)$/);
        if (clip) return this.serveClip(clip[2], token);
        const queryId = url.searchParams.get("clip_id");
        if (queryId) return this.serveClip(queryId, token);
      }
      return Response.json({ error: "expected websocket" }, { status: 426 });
    }

    const deviceSecret =
      url.searchParams.get("device_secret") || request.headers.get("x-device-secret") || "";
    if (!deviceSecret) {
      return Response.json({ error: "missing device_secret" }, { status: 401 });
    }

    const storedHash = this.getMeta("device_secret_hash");
    const incomingHash = await sha256Hex(deviceSecret);
    if (!storedHash) {
      this.setMeta("device_secret_hash", incomingHash);
    } else if (!(await secretsEqual(storedHash, incomingHash))) {
      return Response.json({ error: "device rejected" }, { status: 403 });
    }

    for (const extra of this.ctx.getWebSockets()) {
      try {
        extra.close(1000, "replaced");
      } catch {
        /* ignore */
      }
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    const code = await this.ensurePairingCode();
    const setupCode = this.getMeta("bound_label") ? await this.ensureDeskPin() : code;
    const origin = new URL(request.url).origin;
    const connectorKey = await this.pairing().getConnectorKey();
    pair[1].send(
      JSON.stringify({
        type: "hello",
        body_id: this.bodyId(),
        pairing_code: code,
        pairing_expires_at: Number(this.getMeta("pairing_expires") || 0),
        setup_code: setupCode,
        mcp_url: `${origin}/mcp/${connectorKey}`,
        setup_url: `${origin}/setup`,
        bound_bot: this.boundBot(),
        expression: this.getMeta("expression") || "idle",
        allow_frame: this.getMeta("allow_frame") !== "0",
        allow_video: this.getMeta("allow_video") !== "0",
        voice_ready: true,
        voice_id: this.getMeta("voice_id") || "eve",
        wake_ready: Boolean(this.getMeta("wake_url")),
      }),
    );
    this.broadcastStatus();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let payload: Record<string, unknown>;
    try {
      payload = JSON.parse(message) as Record<string, unknown>;
    } catch {
      return;
    }
    const type = String(payload.type || "");
    if (type === "ack" || type === "frame") {
      const id = String(payload.id || "");
      const waiter = this.pending.get(id);
      if (waiter) {
        clearTimeout(waiter.timer);
        this.pending.delete(id);
        waiter.resolve(payload);
      }
      if (type === "frame" && typeof payload.jpeg === "string") {
        this.latestFrame = { jpeg: payload.jpeg, at: Date.now() };
      }
    }
    if (type === "status") {
      if (typeof payload.expression === "string") {
        this.setMeta("expression", payload.expression);
      }
      if (typeof payload.tracking === "boolean") {
        this.setMeta("tracking", payload.tracking ? "1" : "0");
      }
      if (typeof payload.dock_connected === "boolean") {
        this.setMeta("dock_connected", payload.dock_connected ? "1" : "0");
      }
      if (typeof payload.allow_frame === "boolean") {
        this.setMeta("allow_frame", payload.allow_frame ? "1" : "0");
      }
      if (typeof payload.allow_video === "boolean") {
        this.setMeta("allow_video", payload.allow_video ? "1" : "0");
      }
      if (typeof payload.voice_id === "string") {
        this.setMeta("voice_id", normalizeVoice(payload.voice_id));
      }
    }
    if (type === "refresh_pairing") {
      await this.unbind();
    }
    if (type === "unbind") {
      await this.unbind();
    }
    if (type === "utterance") {
      const text = String(payload.text || "").trim();
      if (text) await this.takeUtterance(text);
    }
    if (type === "set_wake_hook") {
      const result = await this.setWakeHook(String(payload.url || ""), String(payload.secret || ""));
      this.notifyPhone({
        type: "wake_ready",
        ok: result.ok !== false,
        wake_ready: Boolean(this.getMeta("wake_url")),
        error: result.error,
      });
    }
  }

  async webSocketClose(): Promise<void> {
    this.broadcastStatus();
  }

  async describe(): Promise<Record<string, unknown>> {
    return {
      body_id: this.bodyId(),
      online: this.online(),
      bound_bot: this.boundBot(),
      hardware: MANIFEST.hardware,
      expressions: MANIFEST.expressions,
      dock_actions: MANIFEST.dock_actions,
      expression: this.getMeta("expression") || "idle",
      tracking: this.getMeta("tracking") === "1",
      dock_connected: this.getMeta("dock_connected") === "1",
      allow_frame: this.getMeta("allow_frame") !== "0",
      allow_video: this.getMeta("allow_video") !== "0",
    };
  }

  async getStatus(): Promise<Record<string, unknown>> {
    return {
      online: this.online(),
      bound_bot: this.boundBot(),
      expression: this.getMeta("expression") || "idle",
      tracking: this.getMeta("tracking") === "1",
      dock_connected: this.getMeta("dock_connected") === "1",
      last_ack: this.getMeta("last_ack") || null,
      listening: this.speechWaiters.size > 0,
      pending_speech: this.latestUtterance?.text || null,
      wake_ready: Boolean(this.getMeta("wake_url")),
    };
  }

  async claim(botLabel: string): Promise<Record<string, unknown>> {
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    if (await this.isClaimed()) {
      return { ok: false, error: "已经认领过了。先解绑再认领。" };
    }
    const sessionToken = randomToken();
    this.setMeta("session_token_hash", await sha256Hex(sessionToken));
    this.setMeta("bound_label", botLabel.slice(0, 80));
    this.setMeta("bound_at", new Date().toISOString());
    const code = this.getMeta("pairing_code");
    if (code) {
      await this.pairing().remove(code);
    }
    this.setMeta("pairing_code", "");
    this.setMeta("pairing_expires", "0");
    await this.pairing().setActiveBody(this.bodyId());
    try {
      await this.ctx.storage.deleteAlarm();
    } catch {
      /* no alarm */
    }
    const setupCode = await this.ensureDeskPin();
    this.notifyPhone({
      type: "bound",
      bound_bot: this.boundBot(),
      setup_code: setupCode,
    });
    return {
      ok: true,
      session_token: sessionToken,
      body_id: this.bodyId(),
      job_prompt: JOB_PROMPT,
      describe: await this.describe(),
    };
  }

  async unbind(): Promise<Record<string, unknown>> {
    this.setMeta("session_token_hash", "");
    this.setMeta("bound_label", "");
    this.setMeta("bound_at", "");
    await this.pairing().clearActiveBodyIf(this.bodyId());
    await this.pairing().removeBody(this.bodyId());
    this.setMeta("desk_pin", "");
    this.setMeta("desk_expires", "0");
    await this.rotatePairingCode();
    this.notifyPhone({
      type: "unbound",
      pairing_code: this.getMeta("pairing_code"),
      pairing_expires_at: Number(this.getMeta("pairing_expires") || 0),
      setup_code: this.getMeta("pairing_code"),
    });
    return { ok: true };
  }

  async authorize(sessionToken: string): Promise<boolean> {
    const stored = this.getMeta("session_token_hash");
    if (!stored || !sessionToken) return false;
    return secretsEqual(stored, await sha256Hex(sessionToken));
  }

  async isClaimed(): Promise<boolean> {
    return Boolean(this.getMeta("session_token_hash") && this.getMeta("bound_label"));
  }

  async setExpression(name: string, intensity: number, holdMs: number): Promise<Record<string, unknown>> {
    const canonical = canonicalizeExpression(name);
    if (!canonical) {
      return { ok: false, error: "unknown expression" };
    }
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const result = await this.commandPhone({
      type: "set_expression",
      name: canonical,
      intensity,
      hold_ms: holdMs,
    });
    if (result.ok) {
      this.setMeta("expression", canonical);
    }
    return result;
  }

  async controlDock(action: string): Promise<Record<string, unknown>> {
    if (!isDockAction(action)) {
      return { ok: false, error: "unknown dock action" };
    }
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const result = await this.commandPhone({ type: "control_dock", action });
    this.setMeta("last_ack", JSON.stringify(result));
    return result;
  }

  async setTracking(enabled: boolean): Promise<Record<string, unknown>> {
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const result = await this.commandPhone({ type: "set_tracking", enabled });
    if (result.ok) {
      this.setMeta("tracking", enabled ? "1" : "0");
    }
    this.setMeta("last_ack", JSON.stringify(result));
    return result;
  }

  async getFrame(): Promise<Record<string, unknown>> {
    if (this.getMeta("allow_frame") === "0") {
      return { ok: false, error: "用户关闭了看一眼" };
    }
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const result = await this.commandPhone({ type: "get_frame" }, 8000);
    const jpeg = typeof result.jpeg === "string" ? result.jpeg : this.freshFrame();
    if (!jpeg) {
      return { ok: false, error: "没有画面" };
    }
    return {
      ok: true,
      mime: "image/jpeg",
      jpeg_base64: jpeg,
    };
  }

  async recordVideo(durationS: number): Promise<Record<string, unknown>> {
    if (this.getMeta("allow_video") === "0") {
      return { ok: false, error: "用户关闭了录像" };
    }
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const seconds = Math.min(12, Math.max(1, Math.round(durationS || 6)));
    const clipId = crypto.randomUUID();
    const result = await this.commandPhone(
      { type: "record_video", duration_s: seconds, clip_id: clipId },
      CLIP_RECORD_TIMEOUT_MS,
    );
    if (result.ok === false) return result;
    const url = typeof result.url === "string" ? result.url : "";
    if (!url) {
      return { ok: false, error: "录像没有回传" };
    }
    return {
      ok: true,
      url,
      duration_s: seconds,
      bytes: Number(result.bytes || 0),
      mime: "video/mp4",
    };
  }

  async waitForSpeech(timeoutMs: number): Promise<Record<string, unknown>> {
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    const fresh = this.popUtterance();
    if (fresh) {
      this.notifyPhone({ type: "utterance_ack", text: fresh, delivered: true });
      return { ok: true, heard: true, text: fresh, next: "wait_for_speech" };
    }
    this.notifyPhone({ type: "voice_state", state: "listen" });
    this.setMeta("expression", "listen");
    const wait = Math.min(SPEECH_WAIT_MAX_MS, Math.max(1000, timeoutMs || SPEECH_WAIT_DEFAULT_MS));
    const id = crypto.randomUUID();
    const payload = await new Promise<Record<string, unknown>>((resolve) => {
      const timer = setTimeout(() => {
        this.speechWaiters.delete(id);
        resolve({ ok: true, heard: false });
      }, wait);
      this.speechWaiters.set(id, { resolve, timer });
    });
    if (!payload.heard && this.speechWaiters.size === 0) {
      this.notifyPhone({ type: "voice_state", state: "idle" });
      this.setMeta("expression", "idle");
    }
    return { ...payload, next: "wait_for_speech" };
  }

  async speak(text: string): Promise<Record<string, unknown>> {
    const spoken = text.trim();
    if (!spoken) {
      return { ok: false, error: "没有要说的话" };
    }
    if (!this.online()) {
      return { ok: false, error: "身体不在线" };
    }
    if (this.speakingText === spoken) {
      return { ok: true, duplicate: true };
    }
    this.speakingText = spoken;
    this.notifyPhone({ type: "voice_state", state: "speak" });
    this.setMeta("expression", "speak");
    try {
      const result = await this.commandPhone({ type: "speak", text: spoken }, 40_000);
      this.notifyPhone({ type: "voice_state", state: "idle" });
      this.setMeta("expression", "idle");
      return result.ok === false ? result : { ok: true };
    } finally {
      if (this.speakingText === spoken) this.speakingText = "";
    }
  }

  async setWakeHook(url: string, secret: string): Promise<Record<string, unknown>> {
    const trimmed = url.trim();
    if (!trimmed) {
      this.setMeta("wake_url", "");
      this.setMeta("wake_secret", "");
      this.notifyPhone({
        type: "wake_ready",
        ok: true,
        wake_ready: false,
      });
      return { ok: true, wake_ready: false };
    }
    if (!/^https:\/\//i.test(trimmed) || trimmed.length > 2000) {
      return { ok: false, error: "需要 https 门铃地址" };
    }
    let parsed: URL;
    try {
      parsed = new URL(trimmed);
    } catch {
      return { ok: false, error: "门铃地址无效" };
    }
    const host = parsed.hostname.toLowerCase();
    if (host === "localhost" || host === "127.0.0.1" || host.endsWith(".local")) {
      return { ok: false, error: "门铃地址必须公网可访问" };
    }
    this.setMeta("wake_url", trimmed);
    this.setMeta("wake_secret", secret.trim().slice(0, 400));
    this.notifyPhone({
      type: "wake_ready",
      ok: true,
      wake_ready: true,
    });
    return { ok: true, wake_ready: true };
  }

  async pairingCode(): Promise<string> {
    return this.ensurePairingCode();
  }

  private pairing() {
    return asPairing(this.env.PAIRING.getByName("index"));
  }

  private bodyId(): string {
    return this.ctx.id.name || this.ctx.id.toString();
  }

  private online(): boolean {
    return this.ctx.getWebSockets().length > 0;
  }

  private boundBot(): { claimed: boolean; label: string | null; bound_at: string | null } {
    const label = this.getMeta("bound_label");
    return {
      claimed: Boolean(label),
      label: label || null,
      bound_at: this.getMeta("bound_at") || null,
    };
  }

  private getMeta(key: string): string {
    const row = this.ctx.storage.sql
      .exec<{ v: string }>("SELECT v FROM meta WHERE k = ?", key)
      .toArray()[0];
    return row?.v || "";
  }

  private setMeta(key: string, value: string): void {
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)",
      key,
      value,
    );
  }

  private async ensurePairingCode(): Promise<string> {
    const existing = this.getMeta("pairing_code");
    const expires = Number(this.getMeta("pairing_expires") || 0);
    if (existing && expires > Date.now() && !this.getMeta("bound_label")) {
      return existing;
    }
    if (this.getMeta("bound_label")) {
      return "";
    }
    return this.rotatePairingCode();
  }

  private async ensureDeskPin(): Promise<string> {
    const existing = this.getMeta("desk_pin");
    const expires = Number(this.getMeta("desk_expires") || 0);
    if (existing && expires > Date.now() + 24 * 60 * 60 * 1000) {
      return existing;
    }
    const index = this.pairing();
    if (existing) {
      await index.remove(existing);
    }
    let code = randomPairingCode();
    for (let i = 0; i < 5; i += 1) {
      const clash = (await index.lookup(code)) || (await index.lookupDesk(code));
      if (!clash) break;
      code = randomPairingCode();
    }
    const nextExpires = Date.now() + DESK_PIN_TTL_MS;
    await index.registerDesk(code, this.bodyId(), nextExpires);
    this.setMeta("desk_pin", code);
    this.setMeta("desk_expires", String(nextExpires));
    return code;
  }

  private async rotatePairingCode(): Promise<string> {
    const index = this.pairing();
    const previous = this.getMeta("pairing_code");
    if (previous) {
      await index.remove(previous);
    }
    let code = randomPairingCode();
    for (let i = 0; i < 5; i += 1) {
      const clash = (await index.lookup(code)) || (await index.lookupDesk(code));
      if (!clash) break;
      code = randomPairingCode();
    }
    const expires = Date.now() + PAIRING_TTL_MS;
    await index.register(code, this.bodyId(), expires);
    this.setMeta("pairing_code", code);
    this.setMeta("pairing_expires", String(expires));
    try {
      await this.ctx.storage.setAlarm(expires);
    } catch {
      /* alarm optional */
    }
    return code;
  }

  async alarm(): Promise<void> {
    if (this.getMeta("bound_label")) return;
    const expires = Number(this.getMeta("pairing_expires") || 0);
    if (expires && Date.now() < expires - 500) {
      await this.ctx.storage.setAlarm(expires);
      return;
    }
    const code = await this.rotatePairingCode();
    this.notifyPhone({
      type: "hello",
      pairing_code: code,
      pairing_expires_at: Number(this.getMeta("pairing_expires") || 0),
      setup_code: code,
      bound_bot: this.boundBot(),
    });
  }

  private notifyPhone(payload: Record<string, unknown>): void {
    const raw = JSON.stringify(payload);
    for (const socket of this.ctx.getWebSockets()) {
      socket.send(raw);
    }
  }

  private broadcastStatus(): void {
    this.notifyPhone({
      type: "status_sync",
      online: this.online(),
      bound_bot: this.boundBot(),
      expression: this.getMeta("expression") || "idle",
    });
  }

  private freshFrame(): string | null {
    if (!this.latestFrame) return null;
    if (Date.now() - this.latestFrame.at > FRAME_TTL_MS) return null;
    return this.latestFrame.jpeg;
  }

  private commandPhone(
    payload: Record<string, unknown>,
    timeoutMs = COMMAND_TIMEOUT_MS,
  ): Promise<Record<string, unknown>> {
    if (!this.online()) {
      return Promise.resolve({ ok: false, error: "身体不在线" });
    }
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({ ok: false, error: "身体没有回执" });
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
      this.notifyPhone({ ...payload, id });
    });
  }

  private async takeUtterance(text: string): Promise<void> {
    const waiting = this.speechWaiters.size > 0;
    if (waiting) {
      for (const [id, waiter] of this.speechWaiters) {
        clearTimeout(waiter.timer);
        this.speechWaiters.delete(id);
        waiter.resolve({ ok: true, heard: true, text });
      }
      this.storeUtterance(null);
      this.notifyPhone({ type: "utterance_ack", text, delivered: true });
      return;
    }
    this.storeUtterance(text);
    const canWake = Boolean(this.getMeta("wake_url"));
    this.notifyPhone({
      type: "utterance_ack",
      text,
      delivered: false,
      waking: canWake,
    });
    this.ctx.waitUntil(this.wakeBot(text));
  }

  private async wakeBot(text: string): Promise<void> {
    const url = this.getMeta("wake_url");
    if (!url) return;
    const secret = this.getMeta("wake_secret");
    const clipped = text.slice(0, 1800);
    const context =
      `人对着身体说：「${clipped}」。把这句写进对话，立刻 wait_for_speech 核对（或就用这句），写出回答。开口最多一两句要点，长文只写对话框。然后再 wait_for_speech。不要编。`;
    const body = JSON.stringify({ context, event: "speech", text: clipped });
    const headers: Record<string, string> = { "content-type": "application/json" };
    const key = decodeWhsec(secret);
    if (key) {
      const webhookId = crypto.randomUUID();
      const timestamp = String(Math.floor(Date.now() / 1000));
      const signature = await hmacSha256Base64(key, `${webhookId}.${timestamp}.${body}`);
      headers["webhook-id"] = webhookId;
      headers["webhook-timestamp"] = timestamp;
      headers["webhook-signature"] = `v1,${signature}`;
    } else if (secret) {
      headers.authorization = `Bearer ${secret}`;
      headers["x-webhook-key"] = secret;
      headers["x-automation-key"] = secret;
    }
    try {
      const response = await fetch(url, {
        method: "POST",
        headers,
        body,
        signal: AbortSignal.timeout(8000),
      });
      this.notifyPhone({
        type: "wake_result",
        ok: response.ok,
        text,
        status: response.status,
      });
      if (response.ok) {
        this.notifyPhone({ type: "utterance_ack", text, delivered: true });
      }
    } catch {
      this.notifyPhone({ type: "wake_result", ok: false, text });
    }
  }

  private async uploadClip(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const secret = url.searchParams.get("device_secret") || request.headers.get("x-device-secret") || "";
    const clipId = (url.searchParams.get("clip_id") || "").replace(/[^a-zA-Z0-9-]/g, "");
    if (!clipId || clipId.length < 8) {
      return Response.json({ error: "missing clip_id" }, { status: 400 });
    }
    const storedHash = this.getMeta("device_secret_hash");
    const incomingHash = await sha256Hex(secret);
    if (!storedHash || !(await secretsEqual(storedHash, incomingHash))) {
      return Response.json({ error: "device rejected" }, { status: 403 });
    }
    const body = await request.arrayBuffer();
    if (body.byteLength < 32 || body.byteLength > CLIP_MAX_BYTES) {
      return Response.json({ error: "clip too large or empty" }, { status: 413 });
    }
    this.ctx.storage.sql.exec("DELETE FROM clip_parts WHERE id = ?", clipId);
    this.ctx.storage.sql.exec("DELETE FROM clip_meta WHERE id = ?", clipId);
    const bytes = new Uint8Array(body);
    let seq = 0;
    for (let offset = 0; offset < bytes.byteLength; offset += CLIP_PART) {
      const part = bytes.subarray(offset, Math.min(offset + CLIP_PART, bytes.byteLength));
      this.ctx.storage.sql.exec("INSERT INTO clip_parts (id, seq, bytes) VALUES (?, ?, ?)", clipId, seq, part);
      seq += 1;
    }
    const token = randomToken(12);
    this.ctx.storage.sql.exec("DELETE FROM clip_token WHERE id = ?", clipId);
    this.ctx.storage.sql.exec("INSERT INTO clip_token (id, token) VALUES (?, ?)", clipId, token);
    this.ctx.storage.sql.exec(
      "INSERT INTO clip_meta (id, mime, bytes_len, created) VALUES (?, ?, ?, ?)",
      clipId,
      "video/mp4",
      bytes.byteLength,
      Date.now(),
    );
    const extra = this.ctx.storage.sql
      .exec("SELECT id FROM clip_meta ORDER BY created DESC")
      .toArray()
      .slice(CLIP_KEEP) as Array<{ id: string }>;
    for (const row of extra) {
      this.ctx.storage.sql.exec("DELETE FROM clip_parts WHERE id = ?", row.id);
      this.ctx.storage.sql.exec("DELETE FROM clip_meta WHERE id = ?", row.id);
      this.ctx.storage.sql.exec("DELETE FROM clip_token WHERE id = ?", row.id);
    }
    const publicUrl = new URL(request.url);
    publicUrl.pathname = `/clip/${this.bodyId()}/${clipId}`;
    publicUrl.search = `t=${token}`;
    return Response.json({
      ok: true,
      url: publicUrl.toString(),
      bytes: bytes.byteLength,
    });
  }

  private serveClip(clipId: string, token = ""): Response {
    const id = clipId.replace(/[^a-zA-Z0-9-]/g, "");
    const stored = this.ctx.storage.sql
      .exec<{ token: string }>("SELECT token FROM clip_token WHERE id = ?", id)
      .toArray()[0];
    if (stored?.token && stored.token !== token) {
      return Response.json({ error: "not found" }, { status: 404 });
    }
    const meta = this.ctx.storage.sql
      .exec("SELECT mime, bytes_len FROM clip_meta WHERE id = ?", id)
      .toArray()[0] as { mime: string; bytes_len: number } | undefined;
    if (!meta) {
      return Response.json({ error: "not found" }, { status: 404 });
    }
    const parts = this.ctx.storage.sql
      .exec("SELECT bytes FROM clip_parts WHERE id = ? ORDER BY seq", id)
      .toArray() as Array<{ bytes: ArrayBuffer }>;
    const out = new Uint8Array(Number(meta.bytes_len));
    let offset = 0;
    for (const part of parts) {
      const chunk = new Uint8Array(part.bytes);
      out.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return new Response(out, {
      headers: {
        "content-type": meta.mime || "video/mp4",
        "content-length": String(out.byteLength),
        "cache-control": "private, max-age=3600",
      },
    });
  }

  private storeUtterance(text: string | null): void {
    if (!text) {
      this.latestUtterance = null;
      this.setMeta("utterance", "");
      this.setMeta("utterance_at", "0");
      return;
    }
    const at = Date.now();
    this.latestUtterance = { text, at };
    this.setMeta("utterance", text);
    this.setMeta("utterance_at", String(at));
  }

  private popUtterance(): string | null {
    let item = this.latestUtterance;
    if (!item) {
      const text = this.getMeta("utterance");
      const at = Number(this.getMeta("utterance_at") || 0);
      if (text && at) item = { text, at };
    }
    this.storeUtterance(null);
    if (!item) return null;
    if (Date.now() - item.at > UTTERANCE_TTL_MS) return null;
    return item.text;
  }
}
