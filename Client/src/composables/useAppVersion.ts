import { onMounted, ref } from 'vue';
import { systemApi } from '@/api/system';

export function useAppVersion() {
  const version = ref('');

  onMounted(async () => {
    try {
      const health = await systemApi.health();
      version.value = health.version;
    } catch {
      version.value = '';
    }
  });

  return { version };
}
