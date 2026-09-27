import type { Lang } from "@shared/protocol";

interface LangMeta {
  native: string;
  flag: string;
}

const META: Record<string, LangMeta> = {
  en: { native: "English", flag: "🇬🇧" },
  cs: { native: "Čeština", flag: "🇨🇿" },
  de: { native: "Deutsch", flag: "🇩🇪" },
  es: { native: "Español", flag: "🇪🇸" },
  fr: { native: "Français", flag: "🇫🇷" },
  ja: { native: "日本語", flag: "🇯🇵" },
  zh: { native: "中文", flag: "🇨🇳" },
  uk: { native: "Українська", flag: "🇺🇦" },
  it: { native: "Italiano", flag: "🇮🇹" },
  pt: { native: "Português", flag: "🇧🇷" }, // Apple's "pt" is Brazilian; pt-PT is its own entry
  pl: { native: "Polski", flag: "🇵🇱" },
  sk: { native: "Slovenčina", flag: "🇸🇰" },
  nl: { native: "Nederlands", flag: "🇳🇱" },
  ko: { native: "한국어", flag: "🇰🇷" },
  ru: { native: "Русский", flag: "🌐" },
  ar: { native: "العربية", flag: "🇸🇦" },
  he: { native: "עברית", flag: "🇮🇱" },
  hi: { native: "हिन्दी", flag: "🇮🇳" },
  tr: { native: "Türkçe", flag: "🇹🇷" },
  vi: { native: "Tiếng Việt", flag: "🇻🇳" },
  th: { native: "ไทย", flag: "🇹🇭" },
  id: { native: "Bahasa Indonesia", flag: "🇮🇩" },
  sv: { native: "Svenska", flag: "🇸🇪" },
  da: { native: "Dansk", flag: "🇩🇰" },
  fi: { native: "Suomi", flag: "🇫🇮" },
  no: { native: "Norsk", flag: "🇳🇴" },
  nb: { native: "Norsk bokmål", flag: "🇳🇴" },
  hu: { native: "Magyar", flag: "🇭🇺" },
  ro: { native: "Română", flag: "🇷🇴" },
  el: { native: "Ελληνικά", flag: "🇬🇷" },
  bg: { native: "Български", flag: "🇧🇬" },
  hr: { native: "Hrvatski", flag: "🇭🇷" },
  sl: { native: "Slovenščina", flag: "🇸🇮" },
  lt: { native: "Lietuvių", flag: "🇱🇹" },
  lv: { native: "Latviešu", flag: "🇱🇻" },
  et: { native: "Eesti", flag: "🇪🇪" },
  my: { native: "မြန်မာ", flag: "🇲🇲" },
  lo: { native: "ລາວ", flag: "🇱🇦" },
  km: { native: "ខ្មែរ", flag: "🇰🇭" },
  shn: { native: "တႆး", flag: "🇲🇲" },
  bn: { native: "বাংলা", flag: "🇧🇩" },
  ur: { native: "اردو", flag: "🇵🇰" },
  fa: { native: "فارسی", flag: "🇮🇷" },
  ms: { native: "Bahasa Melayu", flag: "🇲🇾" },
  fil: { native: "Filipino", flag: "🇵🇭" },
  ne: { native: "नेपाली", flag: "🇳🇵" },
  si: { native: "සිංහල", flag: "🇱🇰" },
  sr: { native: "Српски", flag: "🇷🇸" },
  ca: { native: "Català", flag: "🌐" },
  sw: { native: "Kiswahili", flag: "🇰🇪" },
  yue: { native: "粵語", flag: "🇭🇰" },
};

export function baseLang(code: string | undefined | null): Lang {
  return (code ?? "").toLowerCase().split(/[-_]/)[0] || "en";
}

/** Region part of a code ("zh-TW" → "TW"), if any. */
function regionOf(code: string): string | undefined {
  return code.split(/[-_]/).slice(1).find((p) => /^[A-Za-z]{2}$/.test(p))?.toUpperCase();
}

export function langNative(code: Lang): string {
  const m = META[baseLang(code)];
  // Regional variants (zh-TW, pt-PT, en-GB) get their own native name: "中文（台灣）".
  if (m && !regionOf(code)) return m.native;
  try {
    const dn = new Intl.DisplayNames([code], { type: "language" });
    const name = dn.of(code);
    if (name) return name.charAt(0).toUpperCase() + name.slice(1);
  } catch {
    /* ignore */
  }
  return code.toUpperCase();
}

export function langFlag(code: Lang): string {
  const r = regionOf(code);
  if (r) return String.fromCodePoint(...[...r].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65));
  return META[baseLang(code)]?.flag ?? "🌐";
}

/** Name of `code` written in the viewer's UI language (for "translated from X"). */
export function langNameIn(code: Lang, uiLang: Lang): string {
  try {
    const dn = new Intl.DisplayNames([uiLang], { type: "language" });
    const name = dn.of(code);
    if (name && name !== code) return name;
  } catch {
    /* ignore */
  }
  return langNative(code);
}

/** Best room language matching the browser preferences. */
export function preferredLang(available: Lang[], fallback: Lang): Lang {
  const prefs = typeof navigator !== "undefined" ? navigator.languages ?? [navigator.language] : [];
  const lower = available.map((a) => a.toLowerCase());
  for (const p of prefs) {
    const pl = p.toLowerCase();
    // exact variant first (zh-TW), then Traditional-script browsers → zh-TW/zh-HK, then the base language
    const exact = lower.indexOf(pl);
    if (exact >= 0) return available[exact]!;
    if (/^zh-(hant|tw|hk|mo)/.test(pl)) {
      const trad = available.find((a) => /^zh-(TW|HK)$/.test(a));
      if (trad) return trad;
    }
    const b = baseLang(p);
    if (available.includes(b)) return b;
  }
  return available.includes(fallback) ? fallback : available[0] ?? "en";
}
