import { ExternalLink, FolderSearch, ShieldX } from "lucide-react";
import { openWebsite, scanNow, WEBSITE_URL } from "../api/desktop";
import type { DesktopStatus } from "../types";

const NONMEMBER_MESSAGE =
  "EmberSync is exclusively for members of Raining Embers and Raining Embers Alts. This character is not a member of an approved Raining Embers guild, so EmberSync serves no purpose for this character.";

export function LockedState({ status, onRefresh }: { status: DesktopStatus; onRefresh: () => void }) {
  const denied = status.membership === "denied";
  const runScan = async () => {
    await scanNow();
    onRefresh();
  };
  return (
    <section className="locked-state" aria-labelledby="locked-title">
      <div className="locked-icon"><ShieldX size={34} strokeWidth={1.5} /></div>
      <h1 id="locked-title">{denied ? "Not an approved guild member" : "No eligible EmberSync data found"}</h1>
      <p>{denied ? NONMEMBER_MESSAGE : "EmberSync has not found a SavedVariables export from an approved Raining Embers character."}</p>
      {status.message ? <p className="muted-copy">{status.message}</p> : null}
      <div className="button-row">
        <button className="primary-button" type="button" onClick={() => void runScan()}>
          <FolderSearch size={17} /> Scan again
        </button>
        <button className="secondary-button" type="button" onClick={() => void openWebsite()}>
          <ExternalLink size={17} /> {WEBSITE_URL}
        </button>
      </div>
      <p className="privacy-note">No game or guild data from an ineligible export is saved, queued, or sent.</p>
    </section>
  );
}
