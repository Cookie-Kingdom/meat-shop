/* A read that failed, in words the person at the screen can act on.
 *
 * PostgREST's own text ("Could not find the table 'public.v_pnl' in the schema cache") means
 * nothing to the Owner, so the screen leads with one Thai sentence. The raw text is still shown,
 * under a fold for whoever fixes it — never swallowed (the rule in `rpc/result.ts`).
 *
 * ponytail: two cases, the one seen on a live screen and a fallback. Add a case when a real
 * screen shows another raw message, not before. */
export function readErrorHint(raw: string[]): string {
  if (raw.some((e) => /schema cache|does not exist/i.test(e)))
    return "ฐานข้อมูลยังไม่มีส่วนที่หน้านี้ต้องใช้ แจ้งผู้ดูแลระบบให้อัปเดตฐานข้อมูล ข้อมูลที่บันทึกไว้ยังอยู่ครบ";
  return "โหลดข้อมูลบางส่วนไม่ได้ กดดูอีกครั้ง ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ";
}

/** The raw messages once each — eight reads failing the same way are one line, not eight. */
export function readErrorDetail(raw: string[]): string {
  return [...new Set(raw)].join(" · ");
}
