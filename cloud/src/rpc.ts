export type ToolResult = Record<string, unknown> & {
  ok?: boolean;
  error?: string;
  session_token?: string;
};

export type BodyRpc = {
  describe(): Promise<Record<string, unknown>>;
  getStatus(): Promise<Record<string, unknown>>;
  claim(botLabel: string): Promise<ToolResult>;
  unbind(): Promise<ToolResult>;
  authorize(sessionToken: string): Promise<boolean>;
  isClaimed(): Promise<boolean>;
  setExpression(name: string, intensity: number, holdMs: number): Promise<ToolResult>;
  controlDock(action: string): Promise<ToolResult>;
  setTracking(enabled: boolean): Promise<ToolResult>;
  getFrame(): Promise<ToolResult>;
  recordVideo(durationS: number): Promise<ToolResult>;
  waitForSpeech(timeoutMs: number): Promise<ToolResult>;
  speak(text: string): Promise<ToolResult>;
  setWakeHook(url: string, secret: string): Promise<ToolResult>;
};

export type PairingRpc = {
  register(code: string, bodyId: string, expires: number): Promise<void>;
  lookup(code: string): Promise<{ bodyId: string } | null>;
  registerDesk(code: string, bodyId: string, expires: number): Promise<void>;
  lookupDesk(code: string): Promise<{ bodyId: string } | null>;
  lookupBody(code: string): Promise<{ bodyId: string } | null>;
  remove(code: string): Promise<void>;
  removeBody(bodyId: string): Promise<void>;
  getConnectorKey(): Promise<string>;
  connectorMatches(candidate: string): Promise<boolean>;
  setActiveBody(bodyId: string): Promise<void>;
  getActiveBody(): Promise<string>;
  clearActiveBodyIf(bodyId: string): Promise<void>;
  consumeAttempt(): Promise<{ ok: true } | { ok: false; error: string }>;
  noteSuccess(): Promise<void>;
};

export function asBody(stub: DurableObjectStub): BodyRpc {
  return stub as unknown as BodyRpc;
}

export function asPairing(stub: DurableObjectStub): PairingRpc {
  return stub as unknown as PairingRpc;
}
