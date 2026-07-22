import { Copy, FileSearch } from "lucide-react";
import type { DesktopStatus, DiagnosticEvent } from "../../types";

export function DiagnosticsScreen({ events, status }: { events: DiagnosticEvent[]; status: DesktopStatus }) {
  const copy = async () => {
    const safe = { status: { ...status, deviceId: status.deviceId ? "redacted" : undefined }, events };
    await navigator.clipboard.writeText(JSON.stringify(safe, null, 2));
  };
  return (
    <section className="screen" aria-labelledby="diagnostics-title">
      <div className="screen-heading"><div><h1 id="diagnostics-title">Diagnostics</h1><p>Safe operational events only—never payloads, character notes, messages, or credentials.</p></div><button className="secondary-button" type="button" onClick={() => void copy()}><Copy size={16} /> Copy safe report</button></div>
      <div className="diagnostics-list">{events.length === 0 ? <div className="empty-state"><FileSearch size={28} /><strong>No diagnostic events</strong><span>Watcher and upload activity will appear here.</span></div> : events.map((event) => <div className="diagnostic-row" key={event.id}><time>{new Date(event.at).toLocaleString()}</time><span className={`event-level ${event.level}`}>{event.level}</span><p>{event.message}</p></div>)}</div>
    </section>
  );
}
