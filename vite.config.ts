import { defineConfig } from "vite"

export default defineConfig({
  build: {
    outDir: "public/assets",
    emptyOutDir: true,
    rollupOptions: {
      input: "frontend/main.tsx",
      output: {
        entryFileNames: "batchcart.js",
        assetFileNames: "batchcart[extname]",
      },
    },
  },
})
