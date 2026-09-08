import type { Metadata } from "next";
import { Noto_Sans_Thai } from "next/font/google";
import "./globals.css";

const notoSansThai = Noto_Sans_Thai({
  variable: "--font-noto-sans-thai",
  subsets: ["thai", "latin"],
  weight: ["400", "500", "600"],
  display: "swap",
});

export const metadata: Metadata = {
  title: "NerdNuea Stock — ระบบสต๊อกและต้นทุนเนื้อรมควัน",
  description:
    "ระบบบันทึกสต๊อกและต้นทุน ตั้งแต่รับเนื้อจาก Foodiva ผ่านโรงรมเชียงใหม่ เข้าสต๊อกกลาง กระจายสู่สาขา จนถึงการขาย",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="th" className={`${notoSansThai.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col">{children}</body>
    </html>
  );
}
