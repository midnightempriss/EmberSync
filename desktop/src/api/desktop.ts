import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { open } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { CoverageRow, DesktopStatus, DiagnosticEvent, PairingStart } from "../types";

export const WEBSITE_URL = "https://rainingembers.org";

const browserFallbackStatus: DesktopStatus = {
  membership: "no_exports",
  vault: "locked",
  connection: "unpaired",
  watcherRunning: false,
  discoveredFiles: 0,
  autoSyncIntervalMinutes: 15,
  guilds: [],
  queue: { pending: 0, uploading: 0, failed: 0, actionRequired: 0, authorizationRequired: false, bytesEncrypted: 0 },
  roots: [],
  message: "Launch EmberSync as a desktop app to scan SavedVariables.",
};

function inTauri(): boolean {
  return "__TAURI_INTERNALS__" in window;
}

export function isDesktopRuntime(): boolean {
  return inTauri();
}

export async function getStatus(): Promise<DesktopStatus> {
  return inTauri() ? invoke<DesktopStatus>("get_status") : browserFallbackStatus;
}

export async function getCoverage(): Promise<CoverageRow[]> {
  return inTauri() ? invoke<CoverageRow[]>("get_coverage") : [];
}

export async function getDiagnostics(): Promise<DiagnosticEvent[]> {
  return inTauri() ? invoke<DiagnosticEvent[]>("get_diagnostics") : [];
}

export async function addWowRoot(path: string): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("add_wow_root", { path });
}

export async function browseForWowRoot(defaultPath?: string): Promise<string | null> {
  if (!inTauri()) return null;
  const selected = await open({
    directory: true,
    multiple: false,
    defaultPath,
    title: "Choose your World of Warcraft or EmberSync folder",
  });
  return Array.isArray(selected) ? selected[0] ?? null : selected;
}

export async function scanNow(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("scan_now");
}

export async function syncNow(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("sync_now");
}

export async function startPairing(): Promise<PairingStart> {
  return invoke<PairingStart>("start_pairing");
}

export async function pollPairing(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("poll_pairing");
}

export async function revokeDevice(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("revoke_device");
}

export async function unlockWithPassphrase(passphrase: string): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("unlock_with_passphrase", { passphrase });
}

export async function deleteLocalData(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("delete_local_data");
}

export async function setStartAtLogin(value: boolean): Promise<void> {
  if (value) await enable();
  else await disable();
}

export async function getStartAtLogin(): Promise<boolean> {
  return inTauri() ? isEnabled() : false;
}

export async function openWebsite(): Promise<void> {
  await openTrustedWebsiteUrl(WEBSITE_URL);
}

export async function openTrustedWebsiteUrl(value: string): Promise<void> {
  const parsed = new URL(value);
  if (parsed.origin !== WEBSITE_URL || parsed.username || parsed.password) {
    throw new Error("EmberSync only opens trusted rainingembers.org links.");
  }
  if (inTauri()) await openUrl(parsed.toString());
  else window.open(parsed.toString(), "_blank", "noopener,noreferrer");
}

export async function subscribeToStatus(callback: (status: DesktopStatus) => void): Promise<UnlistenFn> {
  if (!inTauri()) return () => undefined;
  return listen<DesktopStatus>("embersync://status", ({ payload }) => callback(payload));
}
