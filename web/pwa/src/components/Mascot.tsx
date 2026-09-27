import { useEffect, useState } from "preact/hooks";

const GREETINGS = ["Hi!", "สวัสดี!", "Hallo!", "Ahoj!", "¡Hola!", "こんにちは", "Salut !", "你好！", "Привіт!", "Ciao!", "Olá!", "Cześć!", "안녕!"];

interface Props {
  size?: number;
  greet?: boolean;
  /** first line to show before cycling (e.g. the localized hello) */
  lead?: string;
  mood?: "happy" | "sleepy" | "party";
}

/**
 * "Laai" — the La Laai droplet (the melting ice from the logo) with the two logo
 * speech bubbles as hands: navy one resting, warm one waving.
 */
export function Mascot({ size = 150, greet = true, lead, mood = "happy" }: Props) {
  const list = lead ? [lead, ...GREETINGS.filter((g) => g !== lead)] : GREETINGS;
  const [i, setI] = useState(0);
  useEffect(() => {
    if (!greet) return;
    const h = setInterval(() => setI((x) => (x + 1) % list.length), 1600);
    return () => clearInterval(h);
  }, [greet, list.length]);

  return (
    <div class={`mascot mascot-${mood}`} style={{ width: size }}>
      {greet && (
        <div class="mascot-bubble" aria-live="off">
          <span key={i} class="mascot-bubble-text">
            {list[i % list.length]}
          </span>
        </div>
      )}
      <svg viewBox="0 0 200 190" width={size} height={size * 0.95} aria-hidden="true">
        <defs>
          <linearGradient id="laai-body" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="var(--mascot-body-top)" />
            <stop offset="1" stop-color="var(--mascot-body)" />
          </linearGradient>
          <linearGradient id="laai-warm" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#ff8a66" />
            <stop offset="1" stop-color="var(--mascot-warm)" />
          </linearGradient>
        </defs>
        <ellipse class="mascot-shadow" cx="100" cy="180" rx="46" ry="7" />
        <g class="mascot-bounce">
          {/* left hand: navy speech bubble, resting */}
          <g class="mascot-arm-l">
            <circle cx="30" cy="124" r="23" fill="var(--mascot-navy)" stroke="var(--mascot-hand-stroke)" stroke-width="2.5" />
            <path d="M42 140 L60 152 L50 132 Z" fill="var(--mascot-navy)" />
            <circle cx="20" cy="124" r="3.4" fill="#fff" />
            <circle cx="30" cy="124" r="3.4" fill="#fff" />
            <circle cx="40" cy="124" r="3.4" fill="#fff" />
          </g>
          {/* body: the droplet */}
          <path
            d="M100 16 C114 42 152 76 152 118 A52 52 0 0 1 48 118 C48 76 86 42 100 16 Z"
            fill="url(#laai-body)"
            stroke="var(--mascot-outline)"
            stroke-width="3"
            stroke-linejoin="round"
          />
          <ellipse cx="100" cy="138" rx="32" ry="24" fill="var(--mascot-belly)" opacity="0.55" />
          {/* shine */}
          <g class="mascot-sprout">
            <path d="M74 84 C74 70 82 58 90 50" stroke="#fff" stroke-width="7" fill="none" stroke-linecap="round" opacity="0.85" />
            <circle cx="72" cy="98" r="4" fill="#fff" opacity="0.85" />
          </g>
          {/* face */}
          <g class="mascot-eyes">
            <ellipse cx="84" cy="112" rx="7.5" ry="10" fill="var(--mascot-navy)" />
            <ellipse cx="116" cy="112" rx="7.5" ry="10" fill="var(--mascot-navy)" />
            <circle cx="87" cy="108" r="2.8" fill="#fff" />
            <circle cx="119" cy="108" r="2.8" fill="#fff" />
          </g>
          <ellipse cx="70" cy="128" rx="8" ry="5" fill="var(--mascot-warm)" opacity="0.8" />
          <ellipse cx="130" cy="128" rx="8" ry="5" fill="var(--mascot-warm)" opacity="0.8" />
          <path class="mascot-mouth" d="M90 128 Q100 142 110 128 Q100 133 90 128 Z" fill="var(--mascot-navy)" />
          <path d="M95 133 Q100 139 105 133 Q100 135 95 133 Z" fill="var(--mascot-warm)" />
          {/* right hand: warm speech bubble, waving */}
          <g class="mascot-arm-r">
            <circle cx="172" cy="88" r="23" fill="url(#laai-warm)" />
            <path d="M158 104 L142 118 L150 96 Z" fill="var(--mascot-warm)" />
            <path d="M163 86 a5.5 5.5 0 0 1 9 -5 a5.5 5.5 0 0 1 9 5 q0 7 -9 12 q-9 -5 -9 -12 Z" fill="#fff" />
          </g>
        </g>
      </svg>
    </div>
  );
}
