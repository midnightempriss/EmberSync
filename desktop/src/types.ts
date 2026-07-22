export type ScreenId = "overview" | "coverage" | "queue" | "privacy" | "diagnostics" | "settings";

export type VaultState = "ready" | "locked" | "unavailable";
export type MembershipState = "checking" | "authorized" | "denied" | "no_exports";
export type ConnectionState = "unpaired" | "paired" | "connecting" | "error";

export interface GuildStatus {
  key: "main" | "alt";
  name: string;
  realm: string;
  sourceCharacters: number;
  lastCapturedAt?: string;
}

export interface QueueSummary {
  pending: number;
  uploading: number;
  failed: number;
  actionRequired?: number;
  authorizationRequired?: boolean;
  bytesEncrypted: number;
}

export interface DesktopStatus {
  membership: MembershipState;
  vault: VaultState;
  connection: ConnectionState;
  deviceName?: string;
  deviceId?: string;
  watcherRunning: boolean;
  discoveredFiles: number;
  lastScanAt?: string;
  lastUploadAt?: string;
  message?: string;
  guilds: GuildStatus[];
  queue: QueueSummary;
  roots: string[];
}

export type CoverageStatus =
  | "complete"
  | "partial"
  | "forbidden"
  | "interaction_required"
  | "unavailable"
  | "unsupported";

export interface CoverageRow {
  guildKey: "main" | "alt";
  dataset: string;
  subjectId: string;
  status: CoverageStatus;
  observedAt?: string;
  reason?: string;
}

export interface DiagnosticEvent {
  id: string;
  at: string;
  level: "info" | "warning" | "error";
  message: string;
}

export interface PairingStart {
  verificationUri: string;
  userCode: string;
  expiresAt: string;
}
