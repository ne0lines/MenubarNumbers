import type { StreamDeckDisplayMode, StreamDeckHistorySample, StreamDeckValueStatus } from "./contracts";

export type RenderStatus = StreamDeckValueStatus | "offline";

export type RenderKeyInput = {
  value?: string;
  mode: StreamDeckDisplayMode;
  status: RenderStatus;
  history: StreamDeckHistorySample[];
};

export function renderKey(input: RenderKeyInput): string {
  const value = displayValue(input);
  const isDimmed = input.status === "stale" || input.status === "offline";
  const opacity = isDimmed ? "0.55" : "1";
  const sparkline = input.mode === "sparkline" ? renderSparkline(input.history) : "";
  const valueY = sparkline.length > 0 ? 49 : 79;
  const fontSize = fittedFontSize(value);
  const indicator = input.status === "fresh"
    ? ""
    : '<circle cx="130" cy="14" r="6" fill="#f59e0b"/>';

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">',
    '<rect width="144" height="144" rx="20" fill="#111827"/>',
    `<g opacity="${opacity}">`,
    `<text x="72" y="${valueY}" text-anchor="middle" dominant-baseline="middle" fill="#fff" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-weight="600" font-size="${fontSize}">${escapeXML(value)}</text>`,
    sparkline,
    "</g>",
    indicator,
    "</svg>"
  ].join("");
}

export function svgDataUri(svg: string): string {
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

function displayValue(input: RenderKeyInput): string {
  if (input.status === "missing") return "—";
  if (input.status === "offline" && input.value === undefined) return "Offline";
  return input.value ?? "—";
}

function renderSparkline(history: StreamDeckHistorySample[]): string {
  if (history.length < 2) return "";
  const values = history.map((sample) => sample.value);
  const minimum = Math.min(...values);
  const maximum = Math.max(...values);
  const points = values.map((value, index) => {
    const x = 12 + (120 * index) / (values.length - 1);
    const y = minimum === maximum
      ? 104
      : 124 - ((value - minimum) / (maximum - minimum)) * 40;
    return `${formatCoordinate(x)},${formatCoordinate(y)}`;
  }).join(" ");
  return `<polyline points="${points}" fill="none" stroke="#69d2ff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function fittedFontSize(value: string): number {
  if (value.length <= 6) return 36;
  if (value.length <= 10) return 28;
  if (value.length <= 16) return 21;
  return 16;
}

function formatCoordinate(value: number): string {
  return Number(value.toFixed(2)).toString();
}

function escapeXML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}
