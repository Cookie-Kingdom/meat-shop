import { Button } from "@/components/ui/button";
import { enterAsPersona } from "@/features/demo/actions";
import { DEMO_PERSONAS } from "@/features/demo/personas";

/* ^ref-65 D6 — the demo's /login: four large cards in place of the form. Each card is a
 * submit button of one form, so picking is one tap and no credential is ever typed. */

export function PersonaPicker({ failed }: { failed: boolean }) {
  return (
    <form action={enterAsPersona} className="flex flex-col gap-3">
      <p className="text-body-sm text-text-secondary">
        โหมดทดลอง — เลือกตำแหน่งที่จะใช้งาน
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
          className="h-16 justify-start px-4 text-body"
        >
          {persona.name}
        </Button>
      ))}
    </form>
  );
}
