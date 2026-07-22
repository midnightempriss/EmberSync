import type { DownloadEvent, Update } from "@tauri-apps/plugin-updater";
import { isDesktopRuntime } from "./desktop";

export interface AvailableUpdate {
  currentVersion: string;
  version: string;
  notes?: string;
  install: (onProgress: (downloadedBytes: number, totalBytes?: number) => void) => Promise<void>;
  close: () => Promise<void>;
}

export async function checkForUpdate(): Promise<AvailableUpdate | null> {
  if (!isDesktopRuntime()) return null;

  const { check } = await import("@tauri-apps/plugin-updater");
  const update = await check({ timeout: 30_000 });
  return update ? wrapUpdate(update) : null;
}

function wrapUpdate(update: Update): AvailableUpdate {
  return {
    currentVersion: update.currentVersion,
    version: update.version,
    notes: update.body,
    close: () => update.close(),
    install: async (onProgress) => {
      let downloadedBytes = 0;
      let totalBytes: number | undefined;

      await update.downloadAndInstall((event: DownloadEvent) => {
        if (event.event === "Started") {
          totalBytes = event.data.contentLength;
          onProgress(downloadedBytes, totalBytes);
        } else if (event.event === "Progress") {
          downloadedBytes += event.data.chunkLength;
          onProgress(downloadedBytes, totalBytes);
        } else {
          onProgress(totalBytes ?? downloadedBytes, totalBytes);
        }
      });

      // Windows exits as part of installer handoff. Other platforms relaunch here.
      const { relaunch } = await import("@tauri-apps/plugin-process");
      await relaunch();
    },
  };
}
