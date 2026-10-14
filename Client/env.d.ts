/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_GATEWAY_URL: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface RelativaRuntimeConfig {
  readonly gatewayUrl?: string;
}

interface Window {
  readonly __RELATIVA_CONFIG__?: RelativaRuntimeConfig;
}
