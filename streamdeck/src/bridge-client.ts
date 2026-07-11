import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type {
  StreamDeckScalarField,
  StreamDeckSelection,
  StreamDeckSnapshot,
  StreamDeckSourceSummary
} from "./contracts";

type Discovery = {
  version: 1;
  port: number;
  token: string;
};

type ReadTextFile = (filePath: string, encoding: BufferEncoding) => Promise<string>;

type BridgeClientDependencies = {
  readFile: ReadTextFile;
  fetch: typeof globalThis.fetch;
  discoveryPath: string;
};

export class BridgeUnavailableError extends Error {
  constructor() {
    super("MenubarNumbers is unavailable");
    this.name = "BridgeUnavailableError";
  }
}

export class BridgeRequestError extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`MenubarNumbers bridge request failed with status ${status}`);
    this.name = "BridgeRequestError";
    this.status = status;
  }
}

export class BridgeClient {
  private readonly dependencies: BridgeClientDependencies;

  constructor(dependencies: Partial<BridgeClientDependencies> = {}) {
    this.dependencies = {
      readFile,
      fetch: globalThis.fetch,
      discoveryPath: path.join(
        os.homedir(),
        "Library",
        "Application Support",
        "MenubarNumbers",
        "streamdeck-bridge.json"
      ),
      ...dependencies
    };
  }

  listSources(): Promise<StreamDeckSourceSummary[]> {
    return this.request("GET", "/v1/sources");
  }

  fields(sourceID: string, refresh = false): Promise<StreamDeckScalarField[]> {
    return this.request("POST", "/v1/fields", { sourceID, refresh });
  }

  async replaceSubscriptions(clientID: string, selections: StreamDeckSelection[]): Promise<void> {
    await this.request("PUT", "/v1/subscriptions", { clientID, selections });
  }

  snapshots(selections: StreamDeckSelection[]): Promise<StreamDeckSnapshot[]> {
    return this.request("POST", "/v1/snapshots", { selections });
  }

  private async request<T>(method: string, route: string, body?: unknown): Promise<T> {
    const discovery = await this.readDiscovery();
    let response: Response;
    try {
      response = await this.dependencies.fetch(`http://127.0.0.1:${discovery.port}${route}`, {
        method,
        headers: {
          Authorization: `Bearer ${discovery.token}`,
          "Content-Type": "application/json"
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(5_000)
      });
    } catch {
      throw new BridgeUnavailableError();
    }
    if (!response.ok) {
      throw new BridgeRequestError(response.status);
    }
    if (response.status === 204) {
      return undefined as T;
    }
    try {
      return await response.json() as T;
    } catch {
      throw new BridgeRequestError(response.status);
    }
  }

  private async readDiscovery(): Promise<Discovery> {
    try {
      const value = JSON.parse(
        await this.dependencies.readFile(this.dependencies.discoveryPath, "utf8")
      ) as Partial<Discovery>;
      if (
        value.version !== 1
        || !Number.isInteger(value.port)
        || (value.port ?? 0) < 1
        || (value.port ?? 0) > 65_535
        || typeof value.token !== "string"
        || value.token.length === 0
      ) {
        throw new Error("Invalid discovery file");
      }
      return value as Discovery;
    } catch {
      throw new BridgeUnavailableError();
    }
  }
}
