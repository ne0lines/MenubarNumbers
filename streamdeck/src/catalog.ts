import type { StreamDeckScalarField, StreamDeckSourceSummary } from "./contracts";

export type CatalogRequest = {
  sourceID?: string;
  refresh: boolean;
};

export type CatalogClient = {
  listSources(): Promise<StreamDeckSourceSummary[]>;
  fields(sourceID: string, refresh: boolean): Promise<StreamDeckScalarField[]>;
};

export async function loadCatalog(
  client: CatalogClient,
  request: CatalogRequest
): Promise<{ sources: StreamDeckSourceSummary[]; fields: StreamDeckScalarField[] }> {
  const sources = await client.listSources();
  const fields = request.sourceID
    ? await client.fields(request.sourceID, request.refresh)
    : [];
  return { sources, fields };
}
