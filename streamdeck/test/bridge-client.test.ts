import { describe, expect, it, vi } from "vitest";

import { BridgeClient, BridgeUnavailableError } from "../src/bridge-client";
import type { StreamDeckSelection } from "../src/contracts";

describe("BridgeClient", () => {
  it("discovers the port and authenticates requests", async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response("[]", { status: 200 }));
    const client = new BridgeClient({
      readFile: async () => JSON.stringify({ version: 1, port: 43123, token: "secret" }),
      fetch: fetcher
    });

    await client.listSources();

    expect(fetcher).toHaveBeenCalledWith(
      "http://127.0.0.1:43123/v1/sources",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer secret" })
      })
    );
  });

  it("maps invalid discovery data to an unavailable error", async () => {
    const client = new BridgeClient({
      readFile: async () => "not json",
      fetch: vi.fn()
    });

    await expect(client.listSources()).rejects.toBeInstanceOf(BridgeUnavailableError);
  });

  it("serializes subscription and snapshot contracts exactly", async () => {
    const requests: Array<{ url: string; init: RequestInit }> = [];
    const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      requests.push({ url: String(url), init: init ?? {} });
      return new Response(String(url).endsWith("/v1/subscriptions") ? null : "[]", {
        status: String(url).endsWith("/v1/subscriptions") ? 204 : 200
      });
    });
    const client = new BridgeClient({
      readFile: async () => JSON.stringify({ version: 1, port: 43123, token: "secret" }),
      fetch: fetcher
    });
    const selection: StreamDeckSelection = {
      sourceID: "2d597f73-0e6a-4026-93fe-f7174fcffced",
      jsonPointer: "/count",
      displayMode: "sparkline"
    };

    await client.replaceSubscriptions("client", [selection]);
    await client.snapshots([selection]);

    expect(JSON.parse(String(requests[0]?.init.body))).toEqual({ clientID: "client", selections: [selection] });
    expect(JSON.parse(String(requests[1]?.init.body))).toEqual({ selections: [selection] });
  });

  it("does not expose bridge response bodies in request errors", async () => {
    const client = new BridgeClient({
      readFile: async () => JSON.stringify({ version: 1, port: 43123, token: "secret" }),
      fetch: async () => new Response("sensitive upstream detail", { status: 500 })
    });

    await expect(client.listSources()).rejects.not.toThrow("sensitive upstream detail");
  });
});
