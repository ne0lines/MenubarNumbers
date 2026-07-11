import { describe, expect, it } from "vitest";

import { renderKey, svgDataUri } from "../src/render";

describe("renderKey", () => {
  it("escapes values before placing them in SVG", () => {
    const svg = renderKey({ value: "<5 & rising>", mode: "value", status: "fresh", history: [] });

    expect(svg).toContain("&lt;5 &amp; rising&gt;");
    expect(svg).not.toContain("<5 & rising>");
  });

  it("centers a flat sparkline", () => {
    const svg = renderKey({
      value: "5",
      mode: "sparkline",
      status: "fresh",
      history: [
        { timestamp: "2026-07-11T10:00:00Z", value: 5 },
        { timestamp: "2026-07-11T10:01:00Z", value: 5 }
      ]
    });

    expect(svg).toContain('points="12,104 132,104"');
  });

  it("scales negative and decimal values over the chart bounds", () => {
    const svg = renderKey({
      value: "1.5",
      mode: "sparkline",
      status: "fresh",
      history: [
        { timestamp: "2026-07-11T10:00:00Z", value: -2.5 },
        { timestamp: "2026-07-11T10:01:00Z", value: 1.5 }
      ]
    });

    expect(svg).toContain('points="12,124 132,84"');
  });

  it("dims stale values and draws a warning indicator", () => {
    const svg = renderKey({ value: "7", mode: "value", status: "stale", history: [] });

    expect(svg).toContain('opacity="0.55"');
    expect(svg).toContain('fill="#f59e0b"');
  });

  it("shows Offline only when no cached value exists", () => {
    expect(renderKey({ mode: "value", status: "offline", history: [] })).toContain(">Offline</text>");
    expect(renderKey({ value: "7", mode: "value", status: "offline", history: [] })).toContain(">7</text>");
  });

  it("encodes SVG as a data URI", () => {
    expect(svgDataUri("<svg></svg>")).toBe("data:image/svg+xml,%3Csvg%3E%3C%2Fsvg%3E");
  });
});
