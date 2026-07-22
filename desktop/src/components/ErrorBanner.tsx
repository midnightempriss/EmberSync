import { AlertTriangle, RotateCcw } from "lucide-react";

export function ErrorBanner({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="error-banner" role="alert">
      <AlertTriangle size={18} aria-hidden="true" />
      <span>{message}</span>
      <button type="button" onClick={onRetry}><RotateCcw size={15} /> Retry</button>
    </div>
  );
}
