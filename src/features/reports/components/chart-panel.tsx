import type { ReactNode } from "react";

import { dp2 } from "@/lib/format/number";

/* ChartPanel — server-rendered SVG, no charting library (PLAN-reporting Finding 11; the OW 08
 * contracts in DESIGN-CONTRACTS ChartPanel and LAYOUT-SKELETONS S7). OW 08 plots two series: daily
 * revenue as bars and daily Loss % as a line. No client JavaScript ships.
 *
 * The caller downsamples to at most 62 points (S7), so 365 days never render 365 labels. A single
 * point is a labelled dot, not a broken line. The panel owns its horizontal scroll; the page body
 * never scrolls sideways. Plot coordinates are the only arithmetic here, and they are geometry,
 * not money: every value arrives as the database or the range sum computed it.
 */

export type ChartPoint = {
  /** Axis label for the bucket (a date or a date range). */
  label: string;
  /** The plotted value; null = no data for the bucket (drawn as a gap). */
  value: number | null;
};

const PLOT_H = 200;
const STEP = 16;
const PAD = 28;

export function ChartPanel({
  title,
  type,
  points,
  unit,
  scopeNote,
  empty,
}: {
  title: string;
  type: "bar" | "line";
  points: ChartPoint[];
  unit: string;
  scopeNote?: ReactNode;
  empty: string;
}) {
  const known = points.flatMap((p, i) =>
    p.value === null ? [] : [{ i, v: p.value, label: p.label }],
  );
  const max = Math.max(1, ...known.map((k) => k.v));
  const width = Math.max(320, points.length * STEP + PAD * 2);
  const height = PLOT_H + PAD * 2;
  const x = (i: number) => PAD + i * STEP + STEP / 2;
  const y = (v: number) => PAD + PLOT_H - (Math.max(v, 0) / max) * PLOT_H;
  const base = PAD + PLOT_H;

  return (
    <section className="flex min-h-60 flex-col gap-2 rounded-lg border border-border bg-surface p-4">
      <h3 className="text-h3 text-text-primary">{title}</h3>
      {scopeNote}
      {known.length === 0 ? (
        <p className="text-body-sm text-text-secondary">{empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <svg
            role="img"
            aria-label={title}
            viewBox={`0 0 ${width} ${height}`}
            width={width}
            height={height}
            className="text-caption"
          >
            <line
              x1={PAD}
              x2={width - PAD}
              y1={base}
              y2={base}
              className="stroke-border"
            />
            <text x={PAD} y={PAD - 10} className="fill-text-secondary">
              สูงสุด {dp2(max)} {unit}
            </text>

            {type === "bar"
              ? known.map((k) => (
                  <rect
                    key={k.i}
                    x={x(k.i) - STEP * 0.35}
                    y={y(k.v)}
                    width={STEP * 0.7}
                    height={base - y(k.v)}
                    className="fill-accent"
                  >
                    <title>{`${k.label}: ${dp2(k.v)} ${unit}`}</title>
                  </rect>
                ))
              : null}

            {type === "line" && known.length > 1 ? (
              <polyline
                fill="none"
                strokeWidth={2}
                className="stroke-warning"
                points={known.map((k) => `${x(k.i)},${y(k.v)}`).join(" ")}
              />
            ) : null}

            {type === "line"
              ? known.map((k) => (
                  <circle
                    key={k.i}
                    cx={x(k.i)}
                    cy={y(k.v)}
                    r={known.length === 1 ? 5 : 3}
                    className="fill-warning"
                  >
                    <title>{`${k.label}: ${dp2(k.v)} ${unit}`}</title>
                  </circle>
                ))
              : null}

            {known.length === 1 ? (
              <text
                x={x(known[0].i)}
                y={y(known[0].v) - 10}
                textAnchor="middle"
                className="fill-text-primary"
              >
                {dp2(known[0].v)} {unit}
              </text>
            ) : null}

            <text x={PAD} y={base + 18} className="fill-text-secondary">
              {points[0].label}
            </text>
            {points.length > 1 ? (
              <text
                x={width - PAD}
                y={base + 18}
                textAnchor="end"
                className="fill-text-secondary"
              >
                {points[points.length - 1].label}
              </text>
            ) : null}
          </svg>
        </div>
      )}
    </section>
  );
}
