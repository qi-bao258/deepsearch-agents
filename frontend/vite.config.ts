import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) {
            return undefined;
          }
          if (id.includes("/react/") || id.includes("/react-dom/") || id.includes("/scheduler/")) {
            return "react-vendor";
          }
          if (
            id.includes("/antd/") ||
            id.includes("/@ant-design/") ||
            id.includes("/rc-") ||
            id.includes("/@rc-component/")
          ) {
            return "antd-vendor";
          }
          return "vendor";
        }
      }
    }
  },
  server: {
    port: 5173,
    // 后端开发态端口是 8001（见 scripts/start-backend.ps1 默认值）。
    // 原配置写的是 8000，与前端的 .env.local、后端实际端口都不一致。
    proxy: {
      "/api": {
        target: "http://localhost:8001",
        changeOrigin: true
      },
      "/ws": {
        target: "ws://localhost:8001",
        ws: true
      }
    }
  }
});
