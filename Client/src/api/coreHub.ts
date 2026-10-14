import * as signalR from '@microsoft/signalr';
import { useAuthStore } from '@/stores/auth';
import { GATEWAY_URL } from '@/config/runtime';

function hubUrl(): string {
  return `${GATEWAY_URL}/core/hubs/core`;
}

export function buildCoreHubConnection(): signalR.HubConnection {
  const auth = useAuthStore();
  return new signalR.HubConnectionBuilder()
    .withUrl(hubUrl(), {
      accessTokenFactory: () => auth.accessToken ?? '',
    })
    .withAutomaticReconnect()
    .configureLogging(signalR.LogLevel.Warning)
    .build();
}
