import { api } from '@/api/http';

export interface GatewayHealth {
  status: string;
  service: string;
  version: string;
  instance: string;
}

export const systemApi = {
  health(): Promise<GatewayHealth> {
    return api.get<GatewayHealth>('/health', { silent: true });
  },
};
