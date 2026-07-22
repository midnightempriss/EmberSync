import { Download, ExternalLink, FolderPlus, Link2, LogOut, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { addWowRoot, getStartAtLogin, openTrustedWebsiteUrl, pollPairing, revokeDevice, setStartAtLogin, startPairing } from "../../api/desktop";
import { checkForUpdate, type AvailableUpdate } from "../../api/updater";
import type { DesktopStatus, PairingStart } from "../../types";

export function SettingsScreen({ status, onRefresh }: { status: DesktopStatus; onRefresh: () => void }) {
  const [root, setRoot] = useState("");
  const [startup, setStartup] = useState(false);
  const [pairing, setPairing] = useState<PairingStart | null>(null);
  const [busy, setBusy] = useState(false);
  const [update, setUpdate] = useState<AvailableUpdate | null>(null);
  const [updateMessage, setUpdateMessage] = useState("Updates are verified with EmberSync’s release signing key before installation.");
  const [updateProgress, setUpdateProgress] = useState<number | null>(null);
  useEffect(() => { void getStartAtLogin().then(setStartup); }, []);
  const addRoot = async () => { if (!root.trim()) return; setBusy(true); try { await addWowRoot(root.trim()); setRoot(""); onRefresh(); } finally { setBusy(false); } };
  const beginPairing = async () => { setBusy(true); try { const next = await startPairing(); setPairing(next); await openTrustedWebsiteUrl(next.verificationUri); } finally { setBusy(false); } };
  const checkPairing = async () => { setBusy(true); try { await pollPairing(); onRefresh(); } finally { setBusy(false); } };
  const revoke = async () => { setBusy(true); try { await revokeDevice(); setPairing(null); onRefresh(); } finally { setBusy(false); } };
  const checkUpdates = async () => {
    setBusy(true);
    setUpdateMessage("Checking the signed EmberSync release feed…");
    try {
      if (update) await update.close();
      const next = await checkForUpdate();
      setUpdate(next);
      setUpdateMessage(next ? `EmberSync ${next.version} is ready to install.` : "You’re running the latest EmberSync release.");
    } catch (error) {
      setUpdate(null);
      setUpdateMessage(error instanceof Error ? `Update check failed: ${error.message}` : "Update check failed.");
    } finally {
      setBusy(false);
    }
  };
  const installUpdate = async () => {
    if (!update) return;
    setBusy(true);
    setUpdateMessage(`Downloading EmberSync ${update.version}…`);
    try {
      await update.install((downloaded, total) => {
        if (total && total > 0) setUpdateProgress(Math.min(100, Math.round((downloaded / total) * 100)));
      });
    } catch (error) {
      setUpdateMessage(error instanceof Error ? `Update failed: ${error.message}` : "Update failed.");
      setBusy(false);
    }
  };
  return (
    <section className="screen" aria-labelledby="settings-title">
      <div className="screen-heading"><div><h1 id="settings-title">Settings</h1><p>Manage WoW locations, background startup, and this device’s website connection.</p></div></div>
      <div className="settings-section"><h2>World of Warcraft locations</h2><p>EmberSync watches every account beneath an installation without changing any SavedVariables file.</p><div className="inline-form"><input value={root} onChange={(event) => setRoot(event.target.value)} placeholder="Path to World of Warcraft or WTF folder" /><button className="secondary-button" disabled={busy || !root.trim()} type="button" onClick={() => void addRoot()}><FolderPlus size={16} /> Add location</button></div><ul className="root-list">{status.roots.map((path) => <li key={path}>{path}</li>)}</ul></div>
      <div className="settings-section"><h2>Background behavior</h2><label className="toggle-row"><span><strong>Start EmberSync when I sign in</strong><small>Starts in the tray with no terminal window.</small></span><input type="checkbox" checked={startup} onChange={(event) => { const checked = event.target.checked; setStartup(checked); void setStartAtLogin(checked).catch(() => setStartup(!checked)); }} /></label></div>
      <div className="settings-section"><h2>Website connection</h2>{status.connection === "paired" ? <div className="paired-device"><Link2 size={20} /><div><strong>{status.deviceName || "This device"}</strong><small>Paired with a verified Raining Embers member account.</small></div><button className="danger-button" disabled={busy} type="button" onClick={() => void revoke()}><LogOut size={16} /> Revoke</button></div> : <><p>Pairing opens rainingembers.org so the website can verify current guild membership.</p><button className="primary-button" disabled={busy} type="button" onClick={() => void beginPairing()}><ExternalLink size={16} /> Connect website</button></>}{pairing ? <div className="pairing-code"><span>Enter this code on the website</span><strong>{pairing.userCode}</strong><small>Expires {new Date(pairing.expiresAt).toLocaleTimeString()}</small><button className="secondary-button" disabled={busy} type="button" onClick={() => void checkPairing()}><RefreshCw size={16} /> I approved this device</button></div> : null}</div>
      <div className="settings-section"><h2>Application updates</h2><p aria-live="polite">{updateMessage}{updateProgress !== null ? ` ${updateProgress}%` : ""}</p><div className="button-row update-actions">{update ? <button className="primary-button" disabled={busy} type="button" onClick={() => void installUpdate()}><Download size={16} /> Install {update.version}</button> : <button className="secondary-button" disabled={busy} type="button" onClick={() => void checkUpdates()}><RefreshCw size={16} /> Check for updates</button>}</div></div>
    </section>
  );
}
