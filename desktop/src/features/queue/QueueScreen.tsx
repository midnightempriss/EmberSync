import { CloudUpload, KeyRound, LockKeyhole, RefreshCw } from "lucide-react";
import { useState } from "react";
import { syncNow, unlockWithPassphrase } from "../../api/desktop";
import type { DesktopStatus } from "../../types";

export function QueueScreen({ status, onRefresh }: { status: DesktopStatus; onRefresh: () => void }) {
  const [passphrase, setPassphrase] = useState("");
  const [unlocking, setUnlocking] = useState(false);
  const [unlockError, setUnlockError] = useState<string | null>(null);
  const sync = async () => { await syncNow(); onRefresh(); };
  const unlock = async () => {
    setUnlocking(true);
    setUnlockError(null);
    try {
      await unlockWithPassphrase(passphrase);
      setPassphrase("");
      onRefresh();
    } catch (reason) {
      setUnlockError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setUnlocking(false);
    }
  };
  return (
    <section className="screen" aria-labelledby="queue-title">
      <div className="screen-heading"><div><h1 id="queue-title">Encrypted sync queue</h1><p>Payload content stays outside the webview and is decrypted only for a signed upload.</p></div><button className="primary-button" type="button" onClick={() => void sync()} disabled={status.connection !== "paired" || status.vault !== "ready"}><RefreshCw size={16} /> Process queue</button></div>
      <div className="metrics-row">
        <MetricRow label="Pending" value={status.queue.pending} />
        <MetricRow label="Uploading" value={status.queue.uploading} />
        <MetricRow label="Needs retry" value={status.queue.failed} warning={status.queue.failed > 0} />
      </div>
      <div className="secure-explainer"><LockKeyhole size={24} /><div><strong>Local payload encryption is required</strong><p>EmberSync fails closed if neither the operating-system credential vault nor an unlocked passphrase vault is available.</p></div></div>
      {status.vault !== "ready" ? <form className="vault-form" onSubmit={(event) => { event.preventDefault(); void unlock(); }}><KeyRound size={22} /><div><strong>Unlock a passphrase vault</strong><p>Use at least 12 characters. The passphrase never leaves this device and is never stored.</p><input type="password" autoComplete="current-password" value={passphrase} onChange={(event) => setPassphrase(event.target.value)} placeholder="Local vault passphrase" aria-label="Local vault passphrase" minLength={12} required />{unlockError ? <span className="field-error" role="alert">{unlockError}</span> : null}</div><button className="primary-button" type="submit" disabled={unlocking || passphrase.length < 12}>Unlock</button></form> : null}
      {status.connection !== "paired" ? <div className="empty-state"><CloudUpload size={28} /><strong>Connect this device to upload</strong><span>Pairing uses your current Raining Embers website membership.</span></div> : null}
    </section>
  );
}

function MetricRow({ label, value, warning = false }: { label: string; value: number; warning?: boolean }) {
  return <article className={warning ? "queue-metric warning" : "queue-metric"}><span>{label}</span><strong>{value}</strong></article>;
}
