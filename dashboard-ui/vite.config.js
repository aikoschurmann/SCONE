import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// `npm run dev` serves the UI with hot reload and forwards /api to the running dashboard server.
export default defineConfig({
  plugins: [svelte()],
  server: { proxy: { "/api": "http://127.0.0.1:8080" } },
  build: { outDir: "dist", emptyOutDir: true },
});
