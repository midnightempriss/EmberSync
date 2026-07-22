import { useCallback, useEffect, useState } from "react";
import { getCoverage, getDiagnostics, getStatus, subscribeToStatus } from "../api/desktop";
import type { CoverageRow, DesktopStatus, DiagnosticEvent } from "../types";

interface DesktopState {
  status: DesktopStatus | null;
  coverage: CoverageRow[];
  diagnostics: DiagnosticEvent[];
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
}

export function useDesktopState(): DesktopState {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [coverage, setCoverage] = useState<CoverageRow[]>([]);
  const [diagnostics, setDiagnostics] = useState<DiagnosticEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [nextStatus, nextCoverage, nextDiagnostics] = await Promise.all([
        getStatus(),
        getCoverage(),
        getDiagnostics(),
      ]);
      setStatus(nextStatus);
      setCoverage(nextCoverage);
      setDiagnostics(nextDiagnostics);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    let unsubscribe: (() => void) | undefined;
    void subscribeToStatus((nextStatus) => {
      setStatus(nextStatus);
      void Promise.all([getCoverage(), getDiagnostics()]).then(([nextCoverage, nextDiagnostics]) => {
        setCoverage(nextCoverage);
        setDiagnostics(nextDiagnostics);
      });
    }).then((stop) => {
      unsubscribe = stop;
    });
    return () => unsubscribe?.();
  }, [refresh]);

  return { status, coverage, diagnostics, loading, error, refresh };
}
