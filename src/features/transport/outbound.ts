import { divRound, toHundredths } from "@/lib/format/number";
import type { AllocMethod } from "./types";

/* The outbound booking's pure half: the fare table, the split preview, and the URL the
 * preview lives in (card ^ref-24, `TransportForm` direction `outbound`). No I/O here, so the
 * page and the action read the same answer from the same inputs.
 *
 * THE FARE TABLE'S SHAPE (PLAN-transport.md ^ref-24 build notes, Finding 3).
 * API_DATA_MODEL.md says only "keyed by vehicle type and one-way/round-trip". This screen
 * reads
 *
 *     { "<vehicle type>": { "ONE_WAY": 1200.00, "ROUND_TRIP": 2000.00 } }
 *
 * A missing vehicle, a missing trip kind, a value that is not a non-negative 2-decimal
 * number, or a 0 (fn_allocate_freight's RUN_FARE_NOT_SET: 0 is the branch leg's fare, never
 * this one) all read as NOT CONFIGURED. Nothing is defaulted (ADR-023): the screen names the
 * key and the booking cannot be confirmed.
 *
 * THE SPLIT PREVIEW IS fn_allocate_freight's ARITHMETIC IN BIGINT SATANG. BY_LOT_WEIGHT is
 * round(fare × w / Σw, 2), EQUAL_SPLIT is round(fare / n, 2), and the remainder goes to the
 * heaviest line, as in the function. The one difference: the function breaks a weight tie
 * by line id, and a line id does not exist before submit, so on two equally heavy lots the
 * satang may land on the other one. The stored split is what the run sheet shows afterwards.
 */

export type TripKind = "ONE_WAY" | "ROUND_TRIP";

export const TRIP_KINDS: { value: TripKind; label: string }[] = [
  { value: "ONE_WAY", label: "เที่ยวเดียว" },
  { value: "ROUND_TRIP", label: "ไป-กลับ (รถคันเดียวกัน คิดค่าเที่ยวครั้งเดียว)" },
];

export function tripKind(raw: string): TripKind | null {
  return raw === "ONE_WAY" || raw === "ROUND_TRIP" ? raw : null;
}

export function allocMethod(raw: string | null | undefined): AllocMethod | null {
  return raw === "BY_LOT_WEIGHT" || raw === "EQUAL_SPLIT" || raw === "MANUAL"
    ? raw
    : null;
}

export type FareTable = Map<string, Partial<Record<TripKind, bigint>>>;

function money(v: unknown): bigint | null {
  if (typeof v === "number") return Number.isFinite(v) ? toHundredths(String(v)) : null;
  if (typeof v === "string") return toHundredths(v);
  return null;
}

/** freight_thb_by_vehicle_type's value_json → vehicle → trip → fare in hundredths. Null when
 * the key is unset or is not an object at all. */
export function parseFareTable(json: unknown): FareTable | null {
  if (!json || typeof json !== "object" || Array.isArray(json)) return null;
  const table: FareTable = new Map();
  for (const [vehicle, trips] of Object.entries(json as Record<string, unknown>)) {
    if (!trips || typeof trips !== "object" || Array.isArray(trips)) continue;
    const row: Partial<Record<TripKind, bigint>> = {};
    for (const { value } of TRIP_KINDS) {
      const fare = money((trips as Record<string, unknown>)[value]);
      if (fare !== null) row[value] = fare;
    }
    table.set(vehicle, row);
  }
  return table;
}

/** The fare for one vehicle and trip kind, in hundredths — or null, which is "not
 * configured" and blocks the booking. 0 is null here too (RUN_FARE_NOT_SET). */
export function fareFor(
  table: FareTable | null,
  vehicle: string,
  trip: TripKind,
): bigint | null {
  const fare = table?.get(vehicle)?.[trip];
  return fare !== undefined && fare > BigInt(0) ? fare : null;
}

/** Per-lot share in hundredths, keyed by lot id. Null under MANUAL, which
 * fn_allocate_freight refuses to compute. */
export function previewSplit(
  fare: bigint,
  lines: { id: string; weight: bigint }[],
  method: AllocMethod,
): Map<string, bigint> | null {
  if (method === "MANUAL" || lines.length === 0) return null;
  const zero = BigInt(0);
  const total = lines.reduce((sum, l) => sum + l.weight, zero);
  if (total === zero) return null;

  const shares = lines.map((l) => ({
    ...l,
    share:
      method === "BY_LOT_WEIGHT"
        ? divRound(fare * l.weight, total)
        : divRound(fare, BigInt(lines.length)),
  }));
  const allocated = shares.reduce((sum, s) => sum + s.share, zero);

  // The remainder's home: heaviest line, ties by the smallest id (the function uses line id).
  const heaviest = [...shares].sort((a, b) =>
    a.weight === b.weight ? (a.id < b.id ? -1 : 1) : a.weight > b.weight ? -1 : 1,
  )[0];
  heaviest.share += fare - allocated;

  return new Map(shares.map((s) => [s.id, s.share]));
}

export type OutboundChoice = {
  date: string;
  vehicle: string;
  trip: TripKind | "";
  lots: string[];
};

/** What was previewed, as one string. The confirm button posts it, and the action refuses to
 * book a selection that differs from the one whose fare and split the Owner looked at. */
export function outboundSig(c: OutboundChoice): string {
  return [c.date, c.vehicle, c.trip, [...c.lots].sort().join(",")].join("|");
}

/** The preview's URL — the GET form's own shape, so a redirect lands on the same screen. */
export function outboundHref(
  c: OutboundChoice,
  extra: Record<string, string> = {},
): string {
  const q = new URLSearchParams({ new: "1" });
  if (c.date) q.set("date", c.date);
  if (c.vehicle) q.set("vehicle", c.vehicle);
  if (c.trip) q.set("trip", c.trip);
  for (const lot of c.lots) q.append("lot", lot);
  for (const [k, v] of Object.entries(extra)) if (v) q.set(k, v);
  return `/owner/transport?${q.toString()}`;
}
