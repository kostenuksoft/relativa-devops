const DEFAULT_GATEWAY_URL = 'http://localhost:8080';

const runtimeConfig = window.__RELATIVA_CONFIG__ ?? {};

export const GATEWAY_URL = (
  runtimeConfig.gatewayUrl || import.meta.env.VITE_GATEWAY_URL || DEFAULT_GATEWAY_URL
).replace(/\/$/, '');
