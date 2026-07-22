import { CheckCircle2, CloudUpload, Database, RefreshCw, ShieldCheck } from "lucide-react";
import { scanNow, syncNow } from "../../api/desktop";
import { Metric } from "../../components/Metric";
import type { DesktopStatus } from "../../types";

function formatDate(value?: string): string {
  if (!value) return "Not yet";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

export function OverviewScreen({ status, onRefresh }: { status: DesktopStatus; onRefresh: () => void }) {
  const rescan = async () => { await scanNow(); onRefresh(); };
  const sync = async () => { await syncNow(); onRefresh(); };
  return (
    <section className="screen" aria-labelledby="overview-title">
      <div className="screen-heading">
        <div><h1 id="overview-title">Guild data, ready when you are</h1><p>EmberSync watches approved SavedVariables and securely prepares only changed data.</p></div>
        <div className="button-row compact">
          <button className="secondary-button" type="button" onClick={() => void rescan()}><RefreshCw size={16} /> Rescan</button>
          <button className="primary-button" type="button" onClick={() => void sync()} disabled={status.connection !== "paired" || status.vault !== "ready"}><CloudUpload size={16} /> Sync now</button>
        </div>
      </div>
      <div className="metrics-row">
        <Metric label="Approved guilds" value={String(status.guilds.length)} detail="Main and alt guild only" icon={<ShieldCheck size={20} />} />
        <Metric label="SavedVariables" value={String(status.discoveredFiles)} detail={`Last scan ${formatDate(status.lastScanAt)}`} icon={<Database size={20} />} />
        <Metric label="Pending upload" value={String(status.queue.pending)} detail={formatBytes(status.queue.bytesEncrypted)} icon={<CloudUpload size={20} />} />
      </div>
      <div className="guild-list-panel">
        <div className="panel-heading"><div><h2>Verified exports</h2><p>Only these hard-coded guild identities can enter the encrypted queue.</p></div></div>
        {status.guilds.length === 0 ? <p className="empty-copy">No approved exports are available yet.</p> : status.guilds.map((guild) => (
          <div className="guild-row" key={guild.key}>
            <span className="guild-emblem">{guild.key === "main" ? "RE" : "RA"}</span>
            <div><strong>{guild.name}</strong><small>{guild.realm} · US · {guild.sourceCharacters} source character{guild.sourceCharacters === 1 ? "" : "s"}</small></div>
            <span className="verified-label"><CheckCircle2 size={16} /> Verified locally</span>
            <time>{formatDate(guild.lastCapturedAt)}</time>
          </div>
        ))}
      </div>
      <div className="pipeline" aria-label="Synchronization pipeline">
        <div><span>1</span><strong>WoW saved</strong><small>Addon export</small></div>
        <i />
        <div><span>2</span><strong>Validated</strong><small>Guild allowlist</small></div>
        <i />
        <div><span>3</span><strong>Encrypted</strong><small>Local queue</small></div>
        <i />
        <div><span>4</span><strong>Uploaded</strong><small>Member verified</small></div>
      </div>
    </section>
  );
}
