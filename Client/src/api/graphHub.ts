import * as signalR from '@microsoft/signalr';
import { useAuthStore } from '@/stores/auth';
import { GATEWAY_URL } from '@/config/runtime';

function hubUrl(): string {
  return `${GATEWAY_URL}/graph/hubs/graph`;
}

export function buildGraphHubConnection(): signalR.HubConnection {
  const auth = useAuthStore();
  return new signalR.HubConnectionBuilder()
    .withUrl(hubUrl(), {
      accessTokenFactory: () => auth.accessToken ?? '',
    })
    .withAutomaticReconnect()
    .configureLogging(signalR.LogLevel.Warning)
    .build();
}
