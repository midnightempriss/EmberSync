import { LockKeyhole, MessageSquareOff, ShieldCheck } from "lucide-react";

const RULES = [
  ["Guild and character state", "Collected only from a verified main or alt guild character."],
  ["Sensitive guild data", "Encrypted locally and private on the website by default."],
  ["Chat boundaries", "Guild and permitted officer chat only. Whispers, Battle.net, party, and raid chat are excluded."],
  ["Mail boundaries", "Mail bodies are never collected. Only supported metadata may be captured."],
  ["No game automation", "The addon reads exposed state and never performs protected actions."],
] as const;

export function PrivacyScreen() {
  return (
    <section className="screen" aria-labelledby="privacy-title">
      <div className="screen-heading"><div><h1 id="privacy-title">Privacy boundaries</h1><p>These limits are enforced by the addon, desktop validator, and website independently.</p></div></div>
      <div className="privacy-grid">
        {RULES.map(([title, detail], index) => <article key={title}><span>{index === 2 ? <MessageSquareOff /> : index === 1 ? <LockKeyhole /> : <ShieldCheck />}</span><div><strong>{title}</strong><p>{detail}</p></div></article>)}
      </div>
    </section>
  );
}
