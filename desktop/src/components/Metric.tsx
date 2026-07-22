import type { ReactNode } from "react";

export function Metric({ label, value, detail, icon }: { label: string; value: string; detail: string; icon: ReactNode }) {
  return (
    <article className="metric">
      <span className="metric-icon">{icon}</span>
      <div><span>{label}</span><strong>{value}</strong><small>{detail}</small></div>
    </article>
  );
}
