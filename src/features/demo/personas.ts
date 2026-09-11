/* Card ^ref-65 — the demo's four personas and its one guard. The table holds no password:
 * every persona signs in with DEMO_USER_PASSWORD, which only the server reads (D2). */

/* `sees` and `first` are the picker's two hint lines (^ref-67), lifted from DEMO-GUIDE.md.
 * The chef's first task is lot C, not lot B: the seed leaves lot B nothing to smoke. */
export const DEMO_PERSONAS = {
  owner: {
    email: "demo-owner@demo.local",
    name: "เจ้าของร้าน",
    sees: "เห็นทุกอย่าง รวมราคาและต้นทุน",
    first: "จัดสรรล็อต A จากคลังกลางไปสาขา",
  },
  chef: {
    email: "demo-chef@demo.local",
    name: "เชฟเฮาส์ เชียงใหม่",
    sees: "เห็นเฉพาะล็อตที่เชียงใหม่ ไม่เห็นราคาหรือ % yield",
    first: "บันทึกรับล็อต C ที่เพิ่งมาถึง",
  },
  salaeng: {
    email: "demo-salaeng@demo.local",
    name: "แอดมินสาขาศาลาแดง",
    sees: "เห็นเฉพาะสาขาศาลาแดง",
    first: "เปิดวัน แล้วรับของที่เจ้าของร้านจัดสรรมา",
  },
  minburi: {
    email: "demo-minburi@demo.local",
    name: "แอดมินสาขามีนบุรี",
    sees: "เห็นเฉพาะสาขามีนบุรี",
    first: "เปิดวัน แล้วรับของที่เจ้าของร้านจัดสรรมา",
  },
} as const;

export type PersonaKey = keyof typeof DEMO_PERSONAS;

/** `Meat Shop`, the real project. Demo mode never turns on against it. */
const PROD_REF = "enjbvehfsyhekutjtvce";

/** On only when the flag says so AND the app is not pointed at the real project (D4).
 * Server-side by construction: DEMO_MODE has no NEXT_PUBLIC_ prefix, so a client bundle
 * reads undefined and gets false. */
export function isDemoMode(): boolean {
  return (
    process.env.DEMO_MODE === "true" &&
    !(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").includes(PROD_REF)
  );
}

/** Own keys only — `"toString" in DEMO_PERSONAS` is true. */
export function isPersonaKey(value: string): value is PersonaKey {
  return Object.hasOwn(DEMO_PERSONAS, value);
}

export function personaNameByEmail(email: string | null): string | null {
  return (
    Object.values(DEMO_PERSONAS).find((p) => p.email === email)?.name ?? null
  );
}
