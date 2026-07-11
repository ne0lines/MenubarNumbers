import { describe, expect, it, vi } from "vitest";

import { PluginRuntime, type RuntimeCache, type RuntimeClient, type VisibleAction } from "../src/runtime";
import type { StreamDeckSelection, StreamDeckSnapshot } from "../src/contracts";

const selection: StreamDeckSelection = {
  sourceID: "2d597f73-0e6a-4026-93fe-f7174fcffced",
  jsonPointer: "/count",
  displayMode: "sparkline"
};

const snapshot: StreamDeckSnapshot = {
  selection,
  type: "number",
  value: "7",
  numericValue: 7,
  history: [
    { timestamp: "2026-07-11T10:00:00Z", value: 6 },
    { timestamp: "2026-07-11T10:01:00Z", value: 7 }
  ],
  status: "fresh",
  updatedAt: "2026-07-11T10:01:00Z"
};

describe("PluginRuntime", () => {
  it("deduplicates subscriptions and fans one snapshot batch out to two keys", async () => {
    const client = fakeClient([snapshot]);
    const runtime = new PluginRuntime(client, memoryCache(), { clientID: "test-client" });
    const first = fakeAction("first", selection);
    const second = fakeAction("second", selection);
    runtime.appear(first);
    runtime.appear(second);

    await runtime.heartbeat();
    await runtime.cycle();

    expect(client.replaceSubscriptions).toHaveBeenCalledWith("test-client", [selection]);
    expect(client.snapshots).toHaveBeenCalledTimes(1);
    expect(client.snapshots).toHaveBeenCalledWith([selection]);
    expect(first.setImage).toHaveBeenCalledTimes(1);
    expect(second.setImage).toHaveBeenCalledTimes(1);
  });

  it("replaces settings and removes disappeared actions", async () => {
    const client = fakeClient([]);
    const runtime = new PluginRuntime(client, memoryCache(), { clientID: "test-client" });
    const action = fakeAction("first", selection);
    runtime.appear(action);
    runtime.update("first", { ...selection, jsonPointer: "/other", displayMode: "value" });

    await runtime.heartbeat();
    runtime.disappear("first");
    await runtime.heartbeat();

    expect(client.replaceSubscriptions).toHaveBeenNthCalledWith(1, "test-client", [
      { ...selection, jsonPointer: "/other", displayMode: "value" }
    ]);
    expect(client.replaceSubscriptions).toHaveBeenNthCalledWith(2, "test-client", []);
  });

  it("loads persisted cache and renders it as offline after a bridge failure", async () => {
    const client = fakeClient([]);
    client.snapshots.mockRejectedValue(new Error("offline"));
    const cache = memoryCache({ [cacheKey(selection)]: snapshot });
    const runtime = new PluginRuntime(client, cache, { clientID: "test-client" });
    const action = fakeAction("first", selection);
    runtime.appear(action);
    await runtime.initialize();

    await runtime.cycle();

    expect(action.setImage).toHaveBeenCalledWith(expect.stringContaining("opacity%3D%220.55%22"));
    expect(action.setImage).toHaveBeenCalledWith(expect.stringContaining("%3E7%3C%2Ftext%3E"));
  });

  it("persists successful snapshots", async () => {
    const client = fakeClient([snapshot]);
    const cache = memoryCache();
    const runtime = new PluginRuntime(client, cache, { clientID: "test-client" });
    runtime.appear(fakeAction("first", selection));

    await runtime.cycle();

    expect(cache.save).toHaveBeenCalledWith({ [cacheKey(selection)]: snapshot });
  });

  it("does not overwrite cached data while the app waits for its first response", async () => {
    const warmingSnapshot: StreamDeckSnapshot = {
      selection,
      history: [],
      status: "missing"
    };
    const client = fakeClient([warmingSnapshot]);
    const cache = memoryCache({ [cacheKey(selection)]: snapshot });
    const runtime = new PluginRuntime(client, cache, { clientID: "test-client" });
    const action = fakeAction("first", selection);
    runtime.appear(action);
    await runtime.initialize();

    await runtime.cycle();

    expect(cache.save).toHaveBeenCalledWith({ [cacheKey(selection)]: snapshot });
    expect(action.setImage).toHaveBeenCalledWith(expect.stringContaining("opacity%3D%220.55%22"));
    expect(action.setImage).toHaveBeenCalledWith(expect.stringContaining("%3E7%3C%2Ftext%3E"));
  });
});

function fakeClient(values: StreamDeckSnapshot[]): RuntimeClient & {
  replaceSubscriptions: ReturnType<typeof vi.fn>;
  snapshots: ReturnType<typeof vi.fn>;
} {
  return {
    replaceSubscriptions: vi.fn().mockResolvedValue(undefined),
    snapshots: vi.fn().mockResolvedValue(values)
  };
}

function memoryCache(initial: Record<string, StreamDeckSnapshot> = {}): RuntimeCache & {
  save: ReturnType<typeof vi.fn>;
} {
  return {
    load: vi.fn().mockResolvedValue(initial),
    save: vi.fn().mockResolvedValue(undefined)
  };
}

function fakeAction(context: string, settings: StreamDeckSelection): VisibleAction & {
  setImage: ReturnType<typeof vi.fn>;
} {
  return {
    context,
    settings,
    setImage: vi.fn().mockResolvedValue(undefined)
  };
}

function cacheKey(value: StreamDeckSelection): string {
  return `${value.sourceID}\u0000${value.jsonPointer}\u0000${value.displayMode}`;
}
