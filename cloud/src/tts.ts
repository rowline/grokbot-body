export const GROK_VOICES = [
  "eve",
  "ara",
  "leo",
  "rex",
  "sal",
  "carina",
  "luna",
  "iris",
  "atlas",
  "ursa",
] as const;

export type GrokVoice = (typeof GROK_VOICES)[number];

const TTS_URL = "https://api.x.ai/v1/tts";
const TTS_MAX_CHARS = 1200;
const TTS_MAX_BYTES = 700_000;

export function normalizeVoice(name: string | undefined): GrokVoice {
  const id = (name || "eve").trim().toLowerCase();
  return (GROK_VOICES as readonly string[]).includes(id) ? (id as GrokVoice) : "eve";
}

export function bytesToBase64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

export async function synthesizeGrokSpeech(
  apiKey: string,
  text: string,
  voiceId: string,
): Promise<{ mime: string; base64: string; bytes: number } | null> {
  const spoken = text.trim().slice(0, TTS_MAX_CHARS);
  if (!apiKey || !spoken) return null;
  const response = await fetch(TTS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      text: spoken,
      voice_id: normalizeVoice(voiceId),
      language: "zh",
      output_format: { codec: "mp3", sample_rate: 24000, bit_rate: 128000 },
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) return null;
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength < 64 || bytes.byteLength > TTS_MAX_BYTES) return null;
  return { mime: "audio/mpeg", base64: bytesToBase64(bytes), bytes: bytes.byteLength };
}
