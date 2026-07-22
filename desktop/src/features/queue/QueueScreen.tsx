import { CloudUpload, ExternalLink, KeyRound, LockKeyhole, RefreshCw, ShieldAlert } from "lucide-react";
import { useState } from "react";
import { openTrustedWebsiteUrl, syncNow, unlockWithPassphrase } from "../../api/desktop";
import type { DesktopStatus } from "../../types";

const BATTLE_NET_REAUTH_URL = "https://rainingembers.org/api/auth/battlenet/start?return_to=%2Fmembers%3Fview%3Dsettings";

export function QueueScreen({ status, onRefresh }: { status: DesktopStatus; onRefresh: () => void }) {
  const [passphrase, setPassphrase] = useState("");
  const [unlocking, setUnlocking] = useState(false);
  const [unlockError, setUnlockError] = useState<string | null>(null);
  const [syncError, setSyncError] = useState<string | null>(null);
  const actionRequired = status.queue.actionRequired ?? 0;
  const authorizationRequired = status.queue.authorizationRequired ?? false;
  const sync = async () => {
    setSyncError(null);
    try {
      await syncNow();
    } catch (reason) {
      setSyncError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      onRefresh();
    }
  };
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
      <div className="metrics-row queue-metrics">
        <MetricRow label="Pending" value={status.queue.pending} />
        <MetricRow label="Uploading" value={status.queue.uploading} />
        <MetricRow label="Retry later" value={status.queue.failed} warning={status.queue.failed > 0} />
        <MetricRow label="Needs attention" value={actionRequired} warning={actionRequired > 0} />
      </div>
      {authorizationRequired ? <div className="authorization-required" role="status"><ShieldAlert size={24} /><div><strong>Battle.net verification is required</strong><p>The website paused these encrypted uploads until your Battle.net characters and current guild membership are verified again. Reverify on rainingembers.org, return here, then select Process queue.</p></div><button className="primary-button" type="button" onClick={() => void openTrustedWebsiteUrl(BATTLE_NET_REAUTH_URL)}><ExternalLink size={16} /> Reverify with Battle.net</button></div> : null}
      {syncError && !authorizationRequired ? <p className="queue-sync-error" role="alert">{syncError}</p> : null}
      <div className="secure-explainer"><LockKeyhole size={24} /><div><strong>{status.vault === "ready" ? "Local payload encryption is active" : "Local payload encryption is required"}</strong><p>{status.vault === "ready" ? "Queued payloads are encrypted on this device and decrypted only for a signed upload." : "EmberSync fails closed if neither the operating-system credential vault nor an unlocked passphrase vault is available."}</p></div></div>
      {status.vault !== "ready" ? <form className="vault-form" onSubmit={(event) => { event.preventDefault(); void unlock(); }}><KeyRound size={22} /><div><strong>Unlock a passphrase vault</strong><p>Use at least 12 characters. The passphrase never leaves this device and is never stored.</p><input type="password" autoComplete="current-password" value={passphrase} onChange={(event) => setPassphrase(event.target.value)} placeholder="Local vault passphrase" aria-label="Local vault passphrase" minLength={12} required />{unlockError ? <span className="field-error" role="alert">{unlockError}</span> : null}</div><button className="primary-button" type="submit" disabled={unlocking || passphrase.length < 12}>Unlock</button></form> : null}
      {status.connection !== "paired" ? <div className="empty-state"><CloudUpload size={28} /><strong>Connect this device to upload</strong><span>Pairing uses your current Raining Embers website membership.</span></div> : null}
    </section>
  );
}

function MetricRow({ label, value, warning = false }: { label: string; value: number; warning?: boolean }) {
  return <article className={warning ? "queue-metric warning" : "queue-metric"}><span>{label}</span><strong>{value}</strong></article>;
}
