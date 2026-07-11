import { describe, expect, it } from "vitest";

import {
  filterFields,
  settingsAfterFieldChange,
  settingsAfterSourceChange
} from "../src/property-inspector";
import type { StreamDeckScalarField } from "../src/contracts";

const numberField: StreamDeckScalarField = {
  sourceID: "source",
  jsonPointer: "/weather/temperature",
  label: "Temperature",
  type: "number",
  value: "21.5",
  numericValue: 21.5
};

const stringField: StreamDeckScalarField = {
  sourceID: "source",
  jsonPointer: "/weather/summary",
  label: "Summary",
  type: "string",
  value: "Sunny"
};

describe("Property Inspector helpers", () => {
  it("filters fields by label or JSON Pointer case-insensitively", () => {
    expect(filterFields([numberField, stringField], "TEMP")).toEqual([numberField]);
    expect(filterFields([numberField, stringField], "/WEATHER/SUMMARY")).toEqual([stringField]);
  });

  it("clears pointer and resets mode when the source changes", () => {
    expect(settingsAfterSourceChange({
      sourceID: "old",
      jsonPointer: "/count",
      displayMode: "sparkline"
    }, "new")).toEqual({ sourceID: "new", displayMode: "value" });
  });

  it("keeps sparkline for numeric fields", () => {
    expect(settingsAfterFieldChange({ sourceID: "source", displayMode: "sparkline" }, numberField)).toEqual({
      sourceID: "source",
      jsonPointer: "/weather/temperature",
      displayMode: "sparkline"
    });
  });

  it("forces value mode for non-numeric fields and emits only action settings", () => {
    expect(settingsAfterFieldChange({
      sourceID: "source",
      jsonPointer: "/old",
      displayMode: "sparkline",
      ignored: "secret"
    }, stringField)).toEqual({
      sourceID: "source",
      jsonPointer: "/weather/summary",
      displayMode: "value"
    });
  });
});
