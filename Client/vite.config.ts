import { fileURLToPath, URL } from "node:url";

import { defineConfig, loadEnv } from "vite";
import vue from "@vitejs/plugin-vue";

const parseHostList = (value: string | undefined): string[] | undefined =>
  value
    ?.split(",")
    .map((host) => host.trim())
    .filter(Boolean);

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");

  return {
    plugins: [vue()],
    resolve: {
      alias: {
        "@": fileURLToPath(new URL("./src", import.meta.url)),
      },
    },
    server: {
      port: 3000,
      strictPort: true,
      allowedHosts: parseHostList(env.VITE_ALLOWED_HOSTS),
    },
    build: {
      rollupOptions: {
        input: {
          main: fileURLToPath(new URL("./index.html", import.meta.url)),
          redirect: fileURLToPath(new URL("./redirect.html", import.meta.url)),
        },
      },
    },
  };
});
