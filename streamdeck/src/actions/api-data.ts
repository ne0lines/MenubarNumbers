import streamDeck, {
  action,
  type DidReceiveSettingsEvent,
  type SendToPluginEvent,
  SingletonAction,
  type WillAppearEvent,
  type WillDisappearEvent
} from "@elgato/streamdeck";

import { type ApiDataSettings, PluginRuntime } from "../runtime";
import { type CatalogClient, loadCatalog } from "../catalog";

@action({ UUID: "com.davidhermansson.menubarnumbers.api-data" })
export class ApiDataAction extends SingletonAction<ApiDataSettings> {
  constructor(
    private readonly runtime: PluginRuntime,
    private readonly catalogClient: CatalogClient
  ) {
    super();
  }

  override onWillAppear(ev: WillAppearEvent<ApiDataSettings>): void {
    if (!ev.action.isKey()) return;
    this.runtime.appear({
      context: ev.action.id,
      settings: ev.payload.settings,
      setImage: (image) => ev.action.setImage(image)
    });
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<ApiDataSettings>): void {
    this.runtime.update(ev.action.id, ev.payload.settings);
  }

  override onWillDisappear(ev: WillDisappearEvent<ApiDataSettings>): void {
    this.runtime.disappear(ev.action.id);
  }

  override async onSendToPlugin(ev: SendToPluginEvent<any, ApiDataSettings>): Promise<void> {
    const payload = ev.payload;
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return;
    const request = payload as Record<string, unknown>;
    if (request.type !== "getCatalog") return;
    const sourceID = typeof request.sourceID === "string" ? request.sourceID : undefined;
    try {
      const catalog = await loadCatalog(this.catalogClient, {
        sourceID,
        refresh: request.refresh === true
      });
      await streamDeck.ui.sendToPropertyInspector({ type: "catalog", ...catalog } as never);
    } catch {
      await streamDeck.ui.sendToPropertyInspector({
        type: "catalogError",
        message: "MenubarNumbers is offline"
      });
    }
  }
}
