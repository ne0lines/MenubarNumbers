import { describe, expect, it, vi } from "vitest";

import { loadCatalog } from "../src/catalog";

describe("loadCatalog", () => {
  it("loads sources and refreshes the selected source fields", async () => {
    const client = {
      listSources: vi.fn().mockResolvedValue([{ id: "source", name: "API", isEnabled: true, hasResponse: true }]),
      fields: vi.fn().mockResolvedValue([{ sourceID: "source", jsonPointer: "/count", label: "count", type: "number", value: "7" }])
    };

    const catalog = await loadCatalog(client, { sourceID: "source", refresh: true });

    expect(client.fields).toHaveBeenCalledWith("source", true);
    expect(catalog.sources).toHaveLength(1);
    expect(catalog.fields).toHaveLength(1);
  });

  it("loads only sources before one is selected", async () => {
    const client = {
      listSources: vi.fn().mockResolvedValue([]),
      fields: vi.fn()
    };

    expect(await loadCatalog(client, { refresh: false })).toEqual({ sources: [], fields: [] });
    expect(client.fields).not.toHaveBeenCalled();
  });
});
