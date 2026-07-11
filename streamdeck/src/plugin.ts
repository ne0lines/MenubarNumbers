import streamDeck from "@elgato/streamdeck";

import { ApiDataAction } from "./actions/api-data";
import { BridgeClient } from "./bridge-client";
import type { StreamDeckSnapshot } from "./contracts";
import { PluginRuntime, type RuntimeCache } from "./runtime";

type CacheSettings = {
  snapshotCache?: string;
};

class GlobalSettingsCache implements RuntimeCache {
  async load(): Promise<Record<string, StreamDeckSnapshot>> {
    const settings = await streamDeck.settings.getGlobalSettings<CacheSettings>();
    if (!settings.snapshotCache) return {};
    try {
      const parsed = JSON.parse(settings.snapshotCache) as unknown;
      return parsed !== null && typeof parsed === "object"
        ? parsed as Record<string, StreamDeckSnapshot>
        : {};
    } catch {
      return {};
    }
  }

  async save(values: Record<string, StreamDeckSnapshot>): Promise<void> {
    await streamDeck.settings.setGlobalSettings<CacheSettings>({
      snapshotCache: JSON.stringify(values)
    });
  }
}

streamDeck.logger.setLevel("info");
const runtime = new PluginRuntime(new BridgeClient(), new GlobalSettingsCache(), {
  logError: (message) => streamDeck.logger.error(message)
});
streamDeck.actions.registerAction(new ApiDataAction(runtime));

await streamDeck.connect();
await runtime.start();
