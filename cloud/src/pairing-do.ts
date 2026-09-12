import { DurableObject } from "cloudflare:workers";
import { randomToken, secretsEqual } from "./crypto";

type LookupResult = { bodyId: string } | null;

export class PairingIndex extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS codes (
          code TEXT PRIMARY KEY,
          body_id TEXT NOT NULL,
          expires INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS desk (
          code TEXT PRIMARY KEY,
          body_id TEXT NOT NULL,
          expires INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        )
      `);
    });
  }

  async register(code: string, bodyId: string, expires: number): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE body_id = ?", bodyId);
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO codes (code, body_id, expires) VALUES (?, ?, ?)",
      code,
      bodyId,
      expires,
    );
  }

  async lookup(code: string): Promise<LookupResult> {
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE expires < ?", now);
    const row = this.ctx.storage.sql
      .exec<{ body_id: string }>("SELECT body_id FROM codes WHERE code = ?", code)
      .toArray()[0];
    return row ? { bodyId: row.body_id } : null;
  }

  async registerDesk(code: string, bodyId: string, expires: number): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM desk WHERE body_id = ?", bodyId);
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO desk (code, body_id, expires) VALUES (?, ?, ?)",
      code,
      bodyId,
      expires,
    );
  }

  async lookupDesk(code: string): Promise<LookupResult> {
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM desk WHERE expires < ?", now);
    const row = this.ctx.storage.sql
      .exec<{ body_id: string }>("SELECT body_id FROM desk WHERE code = ?", code)
      .toArray()[0];
    return row ? { bodyId: row.body_id } : null;
  }

  async lookupBody(code: string): Promise<LookupResult> {
    return (await this.lookup(code)) || (await this.lookupDesk(code));
  }

  async remove(code: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE code = ?", code);
    this.ctx.storage.sql.exec("DELETE FROM desk WHERE code = ?", code);
  }

  async removeBody(bodyId: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE body_id = ?", bodyId);
    this.ctx.storage.sql.exec("DELETE FROM desk WHERE body_id = ?", bodyId);
  }

  async getConnectorKey(): Promise<string> {
    const existing = this.getMeta("connector_key");
    if (existing) return existing;
    const created = randomToken(18);
    this.setMeta("connector_key", created);
    return created;
  }

  async connectorMatches(candidate: string): Promise<boolean> {
    if (!candidate) return false;
    const expected = await this.getConnectorKey();
    return secretsEqual(candidate, expected);
  }

  async setActiveBody(bodyId: string): Promise<void> {
    this.setMeta("active_body_id", bodyId);
  }

  async getActiveBody(): Promise<string> {
    return this.getMeta("active_body_id");
  }

  async clearActiveBodyIf(bodyId: string): Promise<void> {
    if (this.getMeta("active_body_id") === bodyId) {
      this.setMeta("active_body_id", "");
    }
  }

  async consumeAttempt(): Promise<{ ok: true } | { ok: false; error: string }> {
    const now = Date.now();
    const windowStart = Number(this.getMeta("attempt_window") || 0);
    let count = Number(this.getMeta("attempt_count") || 0);
    if (now - windowStart > 10 * 60 * 1000) {
      count = 0;
      this.setMeta("attempt_window", String(now));
    }
    if (count >= 20) {
      return { ok: false, error: "试得太勤，过几分钟再试" };
    }
    this.setMeta("attempt_count", String(count + 1));
    return { ok: true };
  }

  async noteSuccess(): Promise<void> {
    this.setMeta("attempt_count", "0");
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
}
