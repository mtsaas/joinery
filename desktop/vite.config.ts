import preact from "@preact/preset-vite";
import { defineConfig } from "vite";

// Tauri serves the built app from dist/, and in development from this server.
export default defineConfig({
  plugins: [preact()],
  clearScreen: false,
  // The examples are the Mac app's, in Joinery/Examples.
  server: { port: 1420, strictPort: true, fs: { allow: [".."] } },
  build: { target: "es2022", outDir: "dist" },
});
