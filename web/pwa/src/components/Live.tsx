import { useLayoutEffect, useRef, useState } from "preact/hooks";
import type { SegmentView } from "@shared/protocol";
import { prefs, room, segments } from "../store";
import { t } from "../i18n";
import { Mascot } from "./Mascot";

function Line({ s, last, showOriginal }: { s: SegmentView; last: boolean; showOriginal: boolean }) {
  const partial = !s.final && last;
  return (
    <p class={`seg ${partial ? "partial" : ""}`}>
      <span dir="auto">{s.text || (partial ? "" : s.source)}</span>
      {partial && <span class="caret" aria-hidden="true" />}
      {showOriginal && s.source && s.source !== s.text && (
        <span class="seg-src" dir="auto">
          {s.source}
        </span>
      )}
    </p>
  );
}

function Flow({ segs, showOriginal }: { segs: SegmentView[]; showOriginal: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const [stick, setStick] = useState(true);
  const stickRef = useRef(true);

  const onScroll = () => {
    const el = ref.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
    if (atBottom !== stickRef.current) {
      stickRef.current = atBottom;
      setStick(atBottom);
    }
  };

  useLayoutEffect(() => {
    const el = ref.current;
    if (el && stickRef.current) el.scrollTop = el.scrollHeight;
  }, [segs, showOriginal]);

  const jump = () => {
    const el = ref.current;
    if (!el) return;
    stickRef.current = true;
    setStick(true);
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    el.scrollTo({ top: el.scrollHeight, behavior: reduce ? "auto" : "smooth" });
  };

  return (
    <div class="live-wrap">
      <div class="scroll live-flow" ref={ref} onScroll={onScroll} aria-live="polite" aria-relevant="additions">
        <div class="flow-inner">
          {segs.map((s, i) => (
            <Line key={s.id} s={s} last={i === segs.length - 1} showOriginal={showOriginal} />
          ))}
        </div>
      </div>
      {!stick && (
        <button class="jump-pill" onClick={jump}>
          <span class="live-dot on" aria-hidden="true" /> {t("jumpLive")} ↓
        </button>
      )}
    </div>
  );
}

function Captions({ segs, showOriginal }: { segs: SegmentView[]; showOriginal: boolean }) {
  const tail = segs.slice(-2);
  return (
    <div class="live-wrap">
      <div class="live-captions" aria-live="polite">
        {tail.map((s, i) => (
          <div key={s.id} class={`cap ${i === tail.length - 1 ? "cur" : "prev"}`}>
            <Line s={s} last={i === tail.length - 1} showOriginal={showOriginal} />
          </div>
        ))}
      </div>
    </div>
  );
}

export function Live() {
  const segs = segments.value;
  const p = prefs.value;
  if (!segs.length) {
    return (
      <div class="scroll empty">
        <Mascot size={120} greet={false} mood="sleepy" />
        <p class="muted">{t("waitingSpeaker")}</p>
        {room.value && !room.value.live && <p class="muted small">{t("offline")}</p>}
      </div>
    );
  }
  return p.mode === "captions" ? (
    <Captions segs={segs} showOriginal={p.showOriginal} />
  ) : (
    <Flow segs={segs} showOriginal={p.showOriginal} />
  );
}
