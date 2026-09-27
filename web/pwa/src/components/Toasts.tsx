import { Icon, type IconName } from "./Icon";
import { dismissToast, toasts } from "../store";

const CONFETTI: IconName[] = ["sparkles", "star", "heart", "sparkles", "star", "heart"];
/** The relay prefixes messages with 👋 / 🎉; our outline icon already says that. */
const stripEmoji = (s: string) => s.replace(/^[\p{Extended_Pictographic}\uFE0F\s]+/u, "");

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
                  <Icon name={c} size={16} filled={c === "heart"} />
                </i>
              ))}
            </span>
          )}
          <span class="ez-toast-icon" aria-hidden="true">
            <Icon name={tt.kind === "match" ? "party" : tt.kind === "error" ? "alert" : "wave"} size={20} />
          </span>
          <span class="ez-toast-msg">{stripEmoji(tt.message) || tt.message}</span>
        </div>
      ))}
    </div>
  );
}
