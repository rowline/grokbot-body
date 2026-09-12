import { describe, expect, it } from "vitest";
import { asBool } from "../src/crypto";
import { bytesToBase64, normalizeVoice } from "../src/tts";

describe("grok tts helpers", () => {
  it("unknown voice falls back to eve", () => {
    expect(normalizeVoice("")).toBe("eve");
    expect(normalizeVoice("EVE")).toBe("eve");
    expect(normalizeVoice("ara")).toBe("ara");
    expect(normalizeVoice("not-a-voice")).toBe("eve");
  });

  it("base64 round-trips a short buffer", () => {
    const bytes = new Uint8Array([1, 2, 3, 250]);
    expect(bytesToBase64(bytes)).toBe(Buffer.from(bytes).toString("base64"));
  });
});

describe("asBool", () => {
  it("does not treat the string false as on", () => {
    expect(asBool(true)).toBe(true);
    expect(asBool(false)).toBe(false);
    expect(asBool("false")).toBe(false);
    expect(asBool("0")).toBe(false);
    expect(asBool("off")).toBe(false);
    expect(asBool("true")).toBe(true);
  });
});
