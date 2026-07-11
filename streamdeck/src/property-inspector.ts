import type { StreamDeckScalarField, StreamDeckSourceSummary } from "./contracts";
import type { ApiDataSettings } from "./runtime";

type LooseSettings = ApiDataSettings & Record<string, unknown>;

type CatalogPayload = {
  type: "catalog";
  sources: StreamDeckSourceSummary[];
  fields: StreamDeckScalarField[];
};

type CatalogErrorPayload = {
  type: "catalogError";
  message: string;
};

type ActionInfo = {
  action: string;
  context: string;
  payload?: { settings?: ApiDataSettings };
  settings?: ApiDataSettings;
};

declare global {
  interface Window {
    connectElgatoStreamDeckSocket?: (
      port: string,
      uuid: string,
      registerEvent: string,
      info: string,
      actionInfo: string
    ) => void;
  }
}

export function filterFields(fields: StreamDeckScalarField[], query: string): StreamDeckScalarField[] {
  const normalized = query.trim().toLocaleLowerCase();
  if (!normalized) return fields;
  return fields.filter((field) =>
    field.label.toLocaleLowerCase().includes(normalized)
    || field.jsonPointer.toLocaleLowerCase().includes(normalized)
  );
}

export function settingsAfterSourceChange(_settings: LooseSettings, sourceID: string): ApiDataSettings {
  return { sourceID, displayMode: "value" };
}

export function settingsAfterFieldChange(
  settings: LooseSettings,
  field: StreamDeckScalarField
): ApiDataSettings {
  return {
    sourceID: field.sourceID,
    jsonPointer: field.jsonPointer,
    displayMode: field.type === "number" && settings.displayMode === "sparkline"
      ? "sparkline"
      : "value"
  };
}

if (typeof window !== "undefined") {
  let socket: WebSocket | undefined;
  let actionUUID = "";
  let context = "";
  let settings: ApiDataSettings = {};
  let fields: StreamDeckScalarField[] = [];

  const source = () => document.querySelector<HTMLSelectElement>("#source")!;
  const search = () => document.querySelector<HTMLInputElement>("#search")!;
  const field = () => document.querySelector<HTMLSelectElement>("#field")!;
  const mode = () => document.querySelector<HTMLSelectElement>("#mode")!;
  const status = () => document.querySelector<HTMLElement>("#status")!;
  const pointer = () => document.querySelector<HTMLElement>("#pointer")!;
  const preview = () => document.querySelector<HTMLElement>("#preview")!;
  const updated = () => document.querySelector<HTMLElement>("#updated")!;

  window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, _info, rawActionInfo) => {
    const actionInfo = JSON.parse(rawActionInfo) as ActionInfo;
    actionUUID = actionInfo.action;
    context = actionInfo.context;
    settings = actionInfo.payload?.settings ?? actionInfo.settings ?? {};
    socket = new WebSocket(`ws://127.0.0.1:${port}`);
    socket.addEventListener("open", () => {
      socket?.send(JSON.stringify({ event: registerEvent, uuid }));
      requestCatalog(settings.sourceID, false);
    });
    socket.addEventListener("message", (event) => receiveMessage(String(event.data)));
  };

  document.addEventListener("DOMContentLoaded", () => {
    source().addEventListener("change", () => {
      settings = settingsAfterSourceChange(settings, source().value);
      writeSettings();
      requestCatalog(source().value, false);
    });
    search().addEventListener("input", renderFields);
    field().addEventListener("change", () => {
      const selected = fields.find((value) => value.jsonPointer === field().value);
      if (!selected) return;
      settings = settingsAfterFieldChange(settings, selected);
      writeSettings();
      renderSelectedField();
    });
    mode().addEventListener("change", () => {
      settings = { ...settings, displayMode: mode().value === "sparkline" ? "sparkline" : "value" };
      writeSettings();
    });
    document.querySelector<HTMLButtonElement>("#refresh")!.addEventListener("click", () => {
      requestCatalog(source().value, true);
    });
  });

  function receiveMessage(raw: string): void {
    const message = JSON.parse(raw) as { event?: string; payload?: CatalogPayload | CatalogErrorPayload };
    if (message.event !== "sendToPropertyInspector" || !message.payload) return;
    if (message.payload.type === "catalogError") {
      status().textContent = message.payload.message;
      status().dataset.state = "error";
      return;
    }
    status().textContent = "Connected to MenubarNumbers";
    status().dataset.state = "connected";
    fields = message.payload.fields;
    renderSources(message.payload.sources);
    renderFields();
    renderSelectedField();
  }

  function renderSources(sources: StreamDeckSourceSummary[]): void {
    source().replaceChildren(...sources.map((value) => {
      const option = document.createElement("option");
      option.value = value.id;
      option.textContent = value.isEnabled ? value.name : `${value.name} (disabled)`;
      option.disabled = !value.isEnabled;
      option.selected = value.id === settings.sourceID;
      return option;
    }));
    if (!settings.sourceID && sources[0]) {
      settings = settingsAfterSourceChange(settings, sources[0].id);
      source().value = sources[0].id;
      writeSettings();
      requestCatalog(sources[0].id, false);
    }
  }

  function renderFields(): void {
    const visible = filterFields(fields, search().value);
    field().replaceChildren(...visible.map((value) => {
      const option = document.createElement("option");
      option.value = value.jsonPointer;
      option.textContent = `${value.label} — ${value.jsonPointer || "/"}`;
      option.selected = value.jsonPointer === settings.jsonPointer;
      return option;
    }));
  }

  function renderSelectedField(): void {
    const selected = fields.find((value) => value.jsonPointer === settings.jsonPointer);
    pointer().textContent = selected ? (selected.jsonPointer || "/") : "No value selected";
    preview().textContent = selected?.value ?? "—";
    updated().textContent = selected ? `Type: ${selected.type}` : "";
    const sparkline = mode().querySelector<HTMLOptionElement>('option[value="sparkline"]')!;
    sparkline.disabled = selected?.type !== "number";
    if (selected?.type !== "number" && settings.displayMode === "sparkline") {
      settings = { ...settings, displayMode: "value" };
      writeSettings();
    }
    mode().value = settings.displayMode ?? "value";
  }

  function requestCatalog(sourceID: string | undefined, refresh: boolean): void {
    status().textContent = "Loading MenubarNumbers data…";
    status().dataset.state = "loading";
    socket?.send(JSON.stringify({
      event: "sendToPlugin",
      action: actionUUID,
      context,
      payload: { type: "getCatalog", sourceID, refresh }
    }));
  }

  function writeSettings(): void {
    socket?.send(JSON.stringify({ event: "setSettings", context, payload: settings }));
  }
}
