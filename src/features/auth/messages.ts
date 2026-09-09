/* Kept out of `actions.ts` because a "use server" module may export nothing but async
 * functions — an exported object there is a build error, not a lint warning. */

/** The Thai string the user sees is chosen from this set, never taken from Supabase.
 * "อีเมลหรือรหัสผ่านไม่ถูกต้อง" for every sign-in failure is deliberate: a message that
 * distinguished "no such account" from "wrong password" would confirm who has an account. */
export const AUTH_ERRORS = {
  invalid_credentials: "อีเมลหรือรหัสผ่านไม่ถูกต้อง",
  missing_fields: "กรุณากรอกให้ครบทุกช่อง",
  password_mismatch: "รหัสผ่านทั้งสองช่องไม่ตรงกัน",
  password_too_short: "รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร",
  reset_failed: "ตั้งรหัสผ่านใหม่ไม่สำเร็จ กรุณาขอลิงก์ใหม่อีกครั้ง",
  link_invalid: "ลิงก์หมดอายุหรือถูกใช้ไปแล้ว กรุณาขอลิงก์ใหม่",
} as const;

export type AuthErrorCode = keyof typeof AUTH_ERRORS;
