import { Button } from "@/components/ui/button";
import { enterAsPersona } from "@/features/demo/actions";
import { DEMO_PERSONAS } from "@/features/demo/personas";

/* ^ref-65 D6 — the demo's /login: four large cards in place of the form. Each card is a
 * submit button of one form, so picking is one tap and no credential is ever typed. A card
 * says what the persona can see and what to try first (^ref-67): the tester may not have
 * DEMO-GUIDE.md open. */

export function PersonaPicker({ failed }: { failed: boolean }) {
  return (
    <form action={enterAsPersona} className="flex flex-col gap-3">
      <p className="text-body-sm text-text-secondary">
        โหมดทดลอง — เลือกตำแหน่งที่จะใช้งาน สลับได้ทุกเมื่อจากแถบด้านบน
      </p>

      {failed ? (
        <p
          role="alert"
          className="rounded-sm bg-danger-subtle p-2 text-body-sm text-danger"
        >
          เข้าใช้งานไม่สำเร็จ ลองอีกครั้ง
        </p>
      ) : null}

      {Object.entries(DEMO_PERSONAS).map(([key, persona]) => (
        <Button
          key={key}
          type="submit"
          name="persona"
          value={key}
          variant="outline"
          className="h-auto min-h-18 flex-col items-start gap-0.5 px-4 py-3 text-left whitespace-normal"
        >
          <span className="text-body text-text-primary">{persona.name}</span>
          <span className="text-caption font-normal text-text-secondary">
            {persona.sees}
          </span>
          <span className="text-caption font-normal text-accent">
            ลองก่อน: {persona.first}
          </span>
        </Button>
      ))}
    </form>
  );
}
