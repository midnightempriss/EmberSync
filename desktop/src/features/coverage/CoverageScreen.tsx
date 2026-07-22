import { Search } from "lucide-react";
import { useDeferredValue, useState } from "react";
import type { CoverageRow, CoverageStatus } from "../../types";

const LABELS: Record<CoverageStatus, string> = {
  complete: "Complete",
  partial: "Partial",
  forbidden: "Not permitted",
  interaction_required: "Action needed",
  unavailable: "Unavailable",
  unsupported: "Unsupported",
};

export function CoverageScreen({ rows }: { rows: CoverageRow[] }) {
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query.trim().toLocaleLowerCase());
  const filtered = deferredQuery
    ? rows.filter((row) => `${row.dataset} ${row.subjectId} ${row.reason || ""}`.toLocaleLowerCase().includes(deferredQuery))
    : rows;
  return (
    <section className="screen" aria-labelledby="coverage-title">
      <div className="screen-heading"><div><h1 id="coverage-title">Data coverage</h1><p>What WoW exposed, when it was observed, and what requires an in-game interaction.</p></div></div>
      <label className="search-field"><Search size={17} /><span className="sr-only">Search datasets</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search datasets or characters" /></label>
      <div className="table-wrap">
        <table><thead><tr><th>Dataset</th><th>Guild</th><th>Subject</th><th>Coverage</th><th>Observed</th><th>Reason</th></tr></thead>
          <tbody>{filtered.map((row) => <tr key={`${row.guildKey}:${row.dataset}:${row.subjectId}`}><td><strong>{row.dataset}</strong></td><td>{row.guildKey === "main" ? "Main" : "Alt"}</td><td>{row.subjectId}</td><td><span className={`coverage ${row.status}`}>{LABELS[row.status]}</span></td><td>{row.observedAt ? new Date(row.observedAt).toLocaleString() : "—"}</td><td>{row.reason || "—"}</td></tr>)}</tbody>
        </table>
        {filtered.length === 0 ? <p className="empty-copy">No matching coverage records.</p> : null}
      </div>
    </section>
  );
}
