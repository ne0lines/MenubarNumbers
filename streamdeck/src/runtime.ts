import { randomUUID } from "node:crypto";

import type { StreamDeckSelection, StreamDeckSnapshot } from "./contracts";
import { renderKey, svgDataUri } from "./render";

export type ApiDataSettings = {
  sourceID?: string;
  jsonPointer?: string;
  displayMode?: "value" | "sparkline";
};

export type VisibleAction = {
  context: string;
  settings: ApiDataSettings;
  setImage(dataUri: string): Promise<void>;
};

export type RuntimeClient = {
  replaceSubscriptions(clientID: string, selections: StreamDeckSelection[]): Promise<void>;
  snapshots(selections: StreamDeckSelection[]): Promise<StreamDeckSnapshot[]>;
};

export type RuntimeCache = {
  load(): Promise<Record<string, StreamDeckSnapshot>>;
  save(values: Record<string, StreamDeckSnapshot>): Promise<void>;
};

type RuntimeOptions = {
  clientID?: string;
  logError?: (message: string) => void;
};

export class PluginRuntime {
  private readonly clientID: string;
  private readonly actions = new Map<string, VisibleAction>();
  private readonly timers: Array<ReturnType<typeof setInterval>> = [];
  private snapshotCache: Record<string, StreamDeckSnapshot> = {};
  private initialized = false;

  constructor(
    private readonly client: RuntimeClient,
    private readonly cache: RuntimeCache,
    private readonly options: RuntimeOptions = {}
  ) {
    this.clientID = options.clientID ?? randomUUID();
  }

  appear(action: VisibleAction): void {
    this.actions.set(action.context, action);
  }

  update(context: string, settings: ApiDataSettings): void {
    const action = this.actions.get(context);
    if (action) action.settings = settings;
  }

  disappear(context: string): void {
    this.actions.delete(context);
  }

  async initialize(): Promise<void> {
    if (this.initialized) return;
    this.snapshotCache = await this.cache.load();
    this.initialized = true;
  }

  async start(): Promise<void> {
    await this.initialize();
    await this.heartbeat();
    await this.cycle();
    this.timers.push(setInterval(() => { void this.cycle(); }, 1_000));
    this.timers.push(setInterval(() => { void this.heartbeat(); }, 10_000));
  }

  stop(): void {
    for (const timer of this.timers) clearInterval(timer);
    this.timers.length = 0;
  }

  async heartbeat(): Promise<void> {
    try {
      await this.client.replaceSubscriptions(this.clientID, this.selections());
    } catch {
      this.options.logError?.("MenubarNumbers subscription heartbeat failed");
    }
  }

  async cycle(): Promise<void> {
    const selections = this.selections();
    if (selections.length === 0) return;
    try {
      const snapshots = await this.client.snapshots(selections);
      const received = new Map(snapshots.map((value) => [selectionKey(value.selection), value]));
      for (const snapshot of snapshots) {
        this.snapshotCache[selectionKey(snapshot.selection)] = snapshot;
      }
      await this.cache.save(this.snapshotCache);
      await Promise.all([...this.actions.values()].map(async (action) => {
        const selection = selectionFromSettings(action.settings);
        if (!selection) return;
        const snapshot = received.get(selectionKey(selection)) ?? missingSnapshot(selection);
        await action.setImage(renderSnapshot(action.settings, snapshot, false));
      }));
    } catch {
      this.options.logError?.("MenubarNumbers snapshot refresh failed");
      await Promise.all([...this.actions.values()].map(async (action) => {
        const selection = selectionFromSettings(action.settings);
        if (!selection) return;
        const cached = this.snapshotCache[selectionKey(selection)];
        await action.setImage(cached
          ? renderSnapshot(action.settings, cached, true)
          : svgDataUri(renderKey({ mode: "value", status: "offline", history: [] })));
      }));
    }
  }

  private selections(): StreamDeckSelection[] {
    const values = new Map<string, StreamDeckSelection>();
    for (const action of this.actions.values()) {
      const selection = selectionFromSettings(action.settings);
      if (selection) values.set(selectionKey(selection), selection);
    }
    return [...values.values()].sort((a, b) => selectionKey(a).localeCompare(selectionKey(b)));
  }
}

function selectionFromSettings(settings: ApiDataSettings): StreamDeckSelection | undefined {
  if (!settings.sourceID || settings.jsonPointer === undefined) return undefined;
  return {
    sourceID: settings.sourceID,
    jsonPointer: settings.jsonPointer,
    displayMode: settings.displayMode ?? "value"
  };
}

function selectionKey(selection: StreamDeckSelection): string {
  return `${selection.sourceID}\u0000${selection.jsonPointer}\u0000${selection.displayMode}`;
}

function missingSnapshot(selection: StreamDeckSelection): StreamDeckSnapshot {
  return { selection, history: [], status: "missing" };
}

function renderSnapshot(
  settings: ApiDataSettings,
  snapshot: StreamDeckSnapshot,
  offline: boolean
): string {
  const mode = settings.displayMode === "sparkline" && snapshot.type === "number"
    ? "sparkline"
    : "value";
  return svgDataUri(renderKey({
    value: snapshot.value,
    mode,
    status: offline ? "offline" : snapshot.status,
    history: snapshot.history
  }));
}
