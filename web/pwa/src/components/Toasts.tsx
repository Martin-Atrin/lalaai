import { dismissToast, toasts } from "../store";

const CONFETTI = ["🎉", "✨", "🤝", "💛", "🎊", "⭐"];

export function Toasts() {
  const list = toasts.value;
  return (
    <div class="ez-toasts" aria-live="assertive">
      {list.map((tt) => (
        <div key={tt.id} class={`ez-toast ${tt.kind}`} role="status" onClick={() => dismissToast(tt.id)}>
          {tt.kind === "match" && (
            <span class="confetti" aria-hidden="true">
              {CONFETTI.map((c, i) => (
                <i key={i} style={{ "--i": i } as Record<string, number>}>
                  {c}
                </i>
              ))}
            </span>
          )}
          <span class="ez-toast-icon" aria-hidden="true">
            {tt.kind === "match" ? "🤝" : tt.kind === "error" ? "⚠️" : "💬"}
          </span>
          <span class="ez-toast-msg">{tt.message}</span>
        </div>
      ))}
    </div>
  );
}
