export type StreamDeckScalarType = "string" | "number" | "boolean" | "null";
export type StreamDeckDisplayMode = "value" | "sparkline";
export type StreamDeckValueStatus = "fresh" | "stale" | "missing";

export type StreamDeckSelection = {
  sourceID: string;
  jsonPointer: string;
  displayMode: StreamDeckDisplayMode;
};

export type StreamDeckSourceSummary = {
  id: string;
  name: string;
  isEnabled: boolean;
  hasResponse: boolean;
  lastSuccess?: string;
  error?: string;
};

export type StreamDeckScalarField = {
  sourceID: string;
  jsonPointer: string;
  label: string;
  type: StreamDeckScalarType;
  value: string;
  numericValue?: number;
};

export type StreamDeckHistorySample = {
  timestamp: string;
  value: number;
};

export type StreamDeckSnapshot = {
  selection: StreamDeckSelection;
  type?: StreamDeckScalarType;
  value?: string;
  numericValue?: number;
  history: StreamDeckHistorySample[];
  status: StreamDeckValueStatus;
  updatedAt?: string;
};
