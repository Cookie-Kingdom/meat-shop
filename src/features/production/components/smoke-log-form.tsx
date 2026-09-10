"use client";

import { useState, useTransition, type FormEvent } from "react";
import { LoaderCircle } from "lucide-react";

import { saveSmokeLog } from "@/features/production/actions";
import { formatHundredths, parseKg } from "@/features/production/kg";
import type { SmokeLogKeys, SmokeLogResult } from "@/features/production/types";

import { AlertBanner } from "./alert-banner";
import { BottomActionBar, writeButton } from "./bottom-action-bar";
import {
  LotSourceList,
  type SourceOption,
  type SourceRow,
} from "./lot-source-list";
import { newRowId, PackWeightList, type BagRow } from "./pack-weight-list";
import { WeightField } from "./weight-field";

/* SmokeLogForm — CM 04, Daily Smoke Log (S2, DESIGN-CONTRACTS). In physical order, one
 * column at every width: which lots went in and how much from each (LotSourceList), brine
 * used, the weight after production, then the pack weights of this batch (PackWeightList),
 * with the system-computed remainder (น้ำหนักรอทำ) — never a figure the operator derives, and
 * never output-subtracted (R18, v0.2 line 175).
 *
 * YIELD IS ABSENT FROM THIS COMPONENT (BR15). Not hidden: nothing here divides one weight by
 * another. The packed total and the after-production weight are shown as a kg difference,
 * the SmokeLogForm contract's warn case, and never as a percentage.
 *
 * TWO WRITES, ONLY WHAT CHANGED. The log is sent only when its fields differ from what is
 * saved for this date — the upsert replaces the sources, so re-sending unchanged ones is a
 * rewrite for nothing, and sending an empty list would erase them. The bags are sent only when
 * there are new ones. A value already saved can be corrected but not cleared (the function's
 * coalesce); clearing one is an unlock-and-fix.
 *
 * THE KEYS ARE HELD HERE (REVIEW item 10, ADR-005). Minted when the page rendered, kept across
 * failures so a retry is a replay, replaced from the action's answer after a success. */

const TIME = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  timeStyle: "short",
});

export type ExistingLog = {
  sources: { lotId: string; kg: string }[];
  smokedKg: string;
  brineKg: string;
};

function normalise(h: string): string {
  if (h === "") return "";
  const v = parseKg(h);
  return v === null ? `?${h}` : String(v);
}

/** The log's identity for "did it change": sources as a sorted set, then the two weights. */
function signature(
  sources: { lotId: string; kg: string }[],
  smoked: string,
  brine: string,
) {
  const s = sources
    .filter((r) => r.lotId !== "" || r.kg !== "")
    .map((r) => `${r.lotId}:${normalise(r.kg)}`)
    .sort()
    .join("|");
  return `${s}#${normalise(smoked)}#${normalise(brine)}`;
}

type Outcome =
  | { kind: "saved"; at: string }
  | { kind: "error"; at: string; message: string; logSaved: boolean };

export function SmokeLogForm({
  lotId,
  eventDate,
  keys: initialKeys,
  options,
  existing,
  savedBagCount,
  savedPackedH,
}: {
  lotId: string;
  eventDate: string;
  keys: SmokeLogKeys;
  options: SourceOption[];
  existing: ExistingLog | null;
  savedBagCount: number;
  savedPackedH: number;
}) {
  const [keys, setKeys] = useState(initialKeys);
  const [sources, setSources] = useState<SourceRow[]>(() =>
    existing && existing.sources.length > 0
      ? existing.sources.map((s, i) => ({
          id: `s${i}`,
          lotId: s.lotId,
          kg: s.kg,
        }))
      : [{ id: "s0", lotId, kg: "" }],
  );
  const [smoked, setSmoked] = useState(existing?.smokedKg ?? "");
  const [brine, setBrine] = useState(existing?.brineKg ?? "");
  const [bags, setBags] = useState<BagRow[]>([{ id: "r0", kg: "" }]);
  const [baseline, setBaseline] = useState<string | null>(() =>
    existing
      ? signature(existing.sources, existing.smokedKg, existing.brineKg)
      : null,
  );
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [pending, startTransition] = useTransition();

  const current = signature(sources, smoked, brine);
  // A lot picked with no weight is not an entry: the first row arrives pre-set to this lot, and
  // an untouched form must read "nothing changed", not offer to save an empty log.
  const hasLogInput =
    sources.some((r) => r.kg !== "") || smoked !== "" || brine !== "";
  const logDirty = baseline === null ? hasLogInput : current !== baseline;
  const newBags = bags.map((b) => b.kg.trim()).filter((kg) => kg !== "");

  // The remainder for THIS lot after today's entry: what it had before today, minus what
  // today's rows draw from it. Integer hundredths throughout (kg.ts).
  const own = options.find((o) => o.lotId === lotId);
  let drawnH = 0;
  for (const r of sources) if (r.lotId === lotId) drawnH += parseKg(r.kg) ?? 0;
  const remainderH = own?.availableH != null ? own.availableH - drawnH : null;

  let packedH = savedPackedH;
  for (const kg of newBags) packedH += parseKg(kg) ?? 0;
  const smokedH = smoked === "" ? null : parseKg(smoked);

  function patchSource(id: string, patch: Partial<Omit<SourceRow, "id">>) {
    setSources((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)));
  }

  function validate(): string | null {
    if (logDirty || baseline === null) {
      const filled = sources.filter((r) => r.lotId !== "" || r.kg !== "");
      if (filled.length === 0)
        return "ใส่ Lot ที่นำไปรมควันพร้อมน้ำหนักอย่างน้อยหนึ่งแถว";
      for (const [i, r] of filled.entries()) {
        if (r.lotId === "") return `แถว Lot ที่ ${i + 1}: ยังไม่ได้เลือก Lot`;
        const h = parseKg(r.kg);
        if (h === null || h <= 0)
          return `แถว Lot ที่ ${i + 1}: กรอกน้ำหนักมากกว่า 0`;
      }
      if (new Set(filled.map((r) => r.lotId)).size !== filled.length) {
        return "เลือก Lot เดียวกันซ้ำ — รวมน้ำหนักให้อยู่แถวเดียว";
      }
    }
    for (const [i, kg] of newBags.entries()) {
      const h = parseKg(kg);
      if (h === null || h <= 0)
        return `ถุงที่ ${i + 1}: น้ำหนักแพ็คต้องมากกว่า 0`;
    }
    if (!logDirty && newBags.length === 0) return "ยังไม่มีอะไรเปลี่ยน";
    return null;
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    const at = TIME.format(new Date());
    const problem = validate();
    if (problem) {
      setOutcome({ kind: "error", at, message: problem, logSaved: false });
      return;
    }
    const sentSignature = current;
    const sendLog = logDirty;
    startTransition(async () => {
      let result: SmokeLogResult;
      try {
        result = await saveSmokeLog({
          lotId,
          eventDate,
          keys,
          log: sendLog
            ? {
                sources: sources
                  .filter((r) => r.lotId !== "" || r.kg !== "")
                  .map((r) => ({ lotId: r.lotId, kg: r.kg })),
                smokedKg: smoked,
                brineKg: brine,
              }
            : null,
          bags: newBags,
        });
      } catch {
        result = {
          ok: false,
          code: "NETWORK",
          message: "เชื่อมต่อเซิร์ฟเวอร์ไม่ได้",
        };
      }
      if (result.ok) {
        setKeys(result.keys);
        setBaseline(sentSignature);
        setBags([{ id: newRowId(), kg: "" }]);
        setOutcome({ kind: "saved", at });
        return;
      }
      if (result.keys) setKeys(result.keys);
      if (result.logSaved) setBaseline(sentSignature);
      setOutcome({
        kind: "error",
        at,
        message: result.message,
        logSaved: Boolean(result.logSaved),
      });
    });
  }

  const label = pending
    ? "กำลังบันทึก…"
    : outcome?.kind === "error" && newBags.length > 0
      ? `ส่งอีกครั้ง ${newBags.length} ถุง`
      : logDirty && newBags.length > 0
        ? `บันทึกรมควันและ ${newBags.length} ถุง`
        : newBags.length > 0
          ? `บันทึก ${newBags.length} ถุง`
          : logDirty
            ? "บันทึกรมควัน"
            : "ยังไม่มีอะไรเปลี่ยน";

  return (
    <form onSubmit={submit} className="flex flex-col gap-5" noValidate>
      {outcome?.kind === "saved" ? (
        <AlertBanner tone="success" title={`บันทึกแล้ว เวลา ${outcome.at}`}>
          ยอดที่บันทึกแล้วด้านล่างเป็นตัวเลขจากระบบ
        </AlertBanner>
      ) : outcome?.kind === "error" ? (
        <AlertBanner tone="danger" title={`บันทึกไม่สำเร็จ เวลา ${outcome.at}`}>
          {outcome.message} — ค่าที่กรอกยังอยู่ในเครื่อง
          {newBags.length > 0 ? ` (${newBags.length} ถุงค้างส่ง)` : ""}{" "}
          กดส่งอีกครั้งได้เลย
        </AlertBanner>
      ) : null}

      <LotSourceList
        rows={sources}
        options={options}
        onChange={patchSource}
        onAdd={() =>
          setSources((rs) => [...rs, { id: newRowId("s"), lotId: "", kg: "" }])
        }
        onDelete={(id) => setSources((rs) => rs.filter((r) => r.id !== id))}
      />

      <p className="rounded-lg border border-border bg-surface p-3 text-body-sm text-text-secondary">
        น้ำหนักรอทำของ Lot นี้หลังบันทึก{" "}
        {remainderH === null ? (
          <span className="text-text-muted">
            — ยังไม่ได้บันทึกน้ำหนักก่อนสโมค
          </span>
        ) : (
          <>
            <span className="font-mono text-num-md text-text-primary tabular-nums">
              {formatHundredths(remainderH)}
            </span>{" "}
            กก.
          </>
        )}
      </p>

      <WeightField
        id="brine-used"
        size="secondary"
        label="น้ำดองที่ใช้"
        value={brine}
        onChange={setBrine}
        helper={
          existing?.brineKg
            ? "แก้เป็นค่าใหม่ได้ ลบค่าที่บันทึกแล้วไม่ได้"
            : undefined
        }
      />

      <WeightField
        id="smoked-weight"
        size="secondary"
        label="น้ำหนักหลังผลิต"
        value={smoked}
        onChange={setSmoked}
        helper={
          existing?.smokedKg
            ? "แก้เป็นค่าใหม่ได้ ลบค่าที่บันทึกแล้วไม่ได้"
            : "กรอกตอนเย็นหลังรมเสร็จได้ ไม่ต้องกรอกพร้อมกัน"
        }
      />

      <PackWeightList
        rows={bags}
        setRows={setBags}
        savedCount={savedBagCount}
        savedH={savedPackedH}
      />

      {smokedH !== null && packedH > 0 && packedH !== smokedH ? (
        <AlertBanner tone="warning" title="ยอดแพ็คไม่ตรงกับน้ำหนักหลังผลิต">
          แพ็ครวม{" "}
          <span className="font-mono tabular-nums">
            {formatHundredths(packedH)}
          </span>{" "}
          กก. ต่างจากน้ำหนักหลังผลิต{" "}
          <span className="font-mono tabular-nums">
            {formatHundredths(packedH - smokedH)}
          </span>{" "}
          กก. — บันทึกได้ ตรวจอีกครั้งถ้าไม่ได้ตั้งใจ
        </AlertBanner>
      ) : null}

      <BottomActionBar>
        <button
          type="submit"
          disabled={pending || (!logDirty && newBags.length === 0)}
          className={writeButton}
        >
          {pending ? (
            <LoaderCircle
              aria-hidden
              className="size-5 animate-spin motion-reduce:animate-none"
            />
          ) : null}
          {label}
        </button>
      </BottomActionBar>
    </form>
  );
}
