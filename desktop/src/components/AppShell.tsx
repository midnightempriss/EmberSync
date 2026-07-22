import {
  Activity,
  Database,
  Gauge,
  ListChecks,
  LockKeyhole,
  Settings,
  ShieldCheck,
} from "lucide-react";
import type { PropsWithChildren } from "react";
import type { DesktopStatus, ScreenId } from "../types";

const NAVIGATION: ReadonlyArray<{ id: ScreenId; label: string; Icon: typeof Gauge }> = [
  { id: "overview", label: "Overview", Icon: Gauge },
  { id: "coverage", label: "Data coverage", Icon: ListChecks },
  { id: "queue", label: "Sync queue", Icon: Database },
  { id: "privacy", label: "Privacy", Icon: ShieldCheck },
  { id: "diagnostics", label: "Diagnostics", Icon: Activity },
  { id: "settings", label: "Settings", Icon: Settings },
];

interface AppShellProps extends PropsWithChildren {
  activeScreen: ScreenId;
  status: DesktopStatus;
  onNavigate: (screen: ScreenId) => void;
}

export function AppShell({ activeScreen, status, onNavigate, children }: AppShellProps) {
  const paired = status.connection === "paired";
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">E</span>
          <span><strong>EmberSync</strong><small>Raining Embers</small></span>
        </div>
        <nav aria-label="Primary navigation">
          {NAVIGATION.map(({ id, label, Icon }) => (
            <button
              className={activeScreen === id ? "nav-item active" : "nav-item"}
              key={id}
              onClick={() => onNavigate(id)}
              type="button"
            >
              <Icon size={18} strokeWidth={1.8} aria-hidden="true" />
              <span>{label}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-security">
          <LockKeyhole size={18} aria-hidden="true" />
          <span><strong>Private by default</strong><small>Encrypted on this device</small></span>
        </div>
      </aside>
      <main className="main-region">
        <header className="topbar">
          <div>
            <span className={`status-dot ${status.watcherRunning ? "healthy" : "muted"}`} />
            {status.watcherRunning ? "Watching WoW data" : "Watcher paused"}
          </div>
          <div className="connection-status">
            <span className={`status-dot ${paired ? "healthy" : "warning"}`} />
            {paired ? status.deviceName || "Website connected" : "Website not connected"}
          </div>
        </header>
        <div className="content-region">{children}</div>
      </main>
    </div>
  );
}
