import {
  action,
  type DidReceiveSettingsEvent,
  SingletonAction,
  type WillAppearEvent,
  type WillDisappearEvent
} from "@elgato/streamdeck";

import { type ApiDataSettings, PluginRuntime } from "../runtime";

@action({ UUID: "com.davidhermansson.menubarnumbers.api-data" })
export class ApiDataAction extends SingletonAction<ApiDataSettings> {
  constructor(private readonly runtime: PluginRuntime) {
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
}
