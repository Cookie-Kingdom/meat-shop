import { SetupBanner } from "@/features/setup/components/setup-banner";

/* (owner) template — ADR-023's persistent banner (card ^ref-61).
 *
 * A TEMPLATE, NOT THE LAYOUT. A template renders between this group's layout and every page
 * in it (node_modules/next/dist/docs/…/template.md), so the banner reaches every OW screen
 * without editing `layout.tsx`, which the parallel build reserves for nav lines. It remounts
 * on navigation, so the banner clears the moment the last BLOCK item is set. */

export default function OwnerTemplate({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <SetupBanner />
      {children}
    </>
  );
}
