import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import { fileURLToPath, URL } from "node:url";

const RELAY = process.env.LALAAI_RELAY ?? "http://localhost:8787";

export default defineConfig({
  base: "/",
  plugins: [preact()],
  resolve: {
    alias: {
      "@shared": fileURLToPath(new URL("../shared", import.meta.url)),
    },
  },
  server: {
    port: 5173,
    fs: { allow: [".."] },
    proxy: {
      "/api": { target: RELAY, changeOrigin: true },
      "/ws": { target: RELAY, ws: true, changeOrigin: true },
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2020",
  },
});
