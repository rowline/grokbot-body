import { describe, expect, it } from "vitest";
import { BINDING_TOOLS, MANIFEST, toolNames } from "../src/manifest";

describe("capability manifest", () => {
  it("tool list is binding tools plus manifest tools, nothing else", () => {
    const names = toolNames();
    expect(names).toEqual([
      ...BINDING_TOOLS.map((t) => t.name),
      ...MANIFEST.tools.map((t) => t.name),
    ]);
  });

  it("speech tools exist so the phone can talk to the bound bot", () => {
    const names = toolNames();
    expect(names).toContain("wait_for_speech");
    expect(names).toContain("speak");
    expect(names).toContain("set_wake_hook");
  });

  it("every expression and dock action is declared once", () => {
    expect(new Set(MANIFEST.expressions).size).toBe(MANIFEST.expressions.length);
    expect(new Set(MANIFEST.dock_actions).size).toBe(MANIFEST.dock_actions.length);
  });
});
