// 默认留空 = 同源相对路径。
//
// 为什么默认改成空串而不是 http://localhost:8000：
//   容器化部署时前端由 Nginx 托管，/api 与 /ws 已反代到后端容器。
//   此时必须走同源相对路径，否则浏览器会直连 localhost:8000 —— 那在用户
//   机器上并不存在该端口（后端只在容器网络内），请求必然失败。
//   开发（vite dev server）下由 vite.config.ts 的 proxy 兜住相对路径，
//   同样无需绝对地址。
const DEFAULT_API_BASE_URL = "";

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function deriveWsBaseUrl(apiBaseUrl: string): string {
  if (import.meta.env.VITE_WS_BASE_URL) {
    return stripTrailingSlash(import.meta.env.VITE_WS_BASE_URL);
  }

  // 空串（同源）时按当前页面协议推导 ws/wss，天然兼容 http 与 https
  if (!apiBaseUrl) {
    return `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}`;
  }

  if (apiBaseUrl.startsWith("https://")) {
    return apiBaseUrl.replace(/^https:\/\//, "wss://");
  }

  if (apiBaseUrl.startsWith("http://")) {
    return apiBaseUrl.replace(/^http:\/\//, "ws://");
  }

  return `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}`;
}

export const API_BASE_URL = stripTrailingSlash(
  import.meta.env.VITE_API_BASE_URL ?? DEFAULT_API_BASE_URL
);

export const WS_BASE_URL = deriveWsBaseUrl(API_BASE_URL);
