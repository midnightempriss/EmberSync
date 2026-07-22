import { useCallback, useState } from "react";
import { AppShell } from "../components/AppShell";
import { ErrorBanner } from "../components/ErrorBanner";
import { LockedState } from "../components/LockedState";
import { CoverageScreen } from "../features/coverage/CoverageScreen";
import { DiagnosticsScreen } from "../features/diagnostics/DiagnosticsScreen";
import { OverviewScreen } from "../features/overview/OverviewScreen";
import { PrivacyScreen } from "../features/privacy/PrivacyScreen";
import { QueueScreen } from "../features/queue/QueueScreen";
import { SettingsScreen } from "../features/settings/SettingsScreen";
import { useDesktopState } from "../hooks/useDesktopState";
import type { ScreenId } from "../types";

export function App() {
  const [screen, setScreen] = useState<ScreenId>("overview");
  const desktop = useDesktopState();
  const refresh = useCallback(() => void desktop.refresh(), [desktop]);

  if (desktop.loading || !desktop.status) {
    return <div className="app-loading" role="status">Starting EmberSync securely…</div>;
  }

  const locked = desktop.status.membership === "denied" || desktop.status.membership === "no_exports";

  return (
    <AppShell activeScreen={screen} status={desktop.status} onNavigate={setScreen}>
      {desktop.error ? <ErrorBanner message={desktop.error} onRetry={refresh} /> : null}
      {locked ? (
        <LockedState status={desktop.status} onRefresh={refresh} />
      ) : (
        <>
          {screen === "overview" ? <OverviewScreen status={desktop.status} onRefresh={refresh} /> : null}
          {screen === "coverage" ? <CoverageScreen rows={desktop.coverage} /> : null}
          {screen === "queue" ? <QueueScreen status={desktop.status} onRefresh={refresh} /> : null}
          {screen === "privacy" ? <PrivacyScreen /> : null}
          {screen === "diagnostics" ? <DiagnosticsScreen events={desktop.diagnostics} status={desktop.status} /> : null}
          {screen === "settings" ? <SettingsScreen status={desktop.status} onRefresh={refresh} /> : null}
        </>
      )}
    </AppShell>
  );
}
