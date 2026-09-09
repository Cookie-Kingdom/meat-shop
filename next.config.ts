import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    // Required by `forbidden()`, which the role-group layouts call to refuse a session
    // whose role does not match the group (card ^ref-07).
    authInterrupts: true,
  },
};

export default nextConfig;
