import { useEffect, useRef, useState } from "preact/hooks";
import { changeLang, editingProfile, prefs, room, setPref, settingsOpen, you } from "../store";
import type { FontSize, Theme } from "../store";
import { t, displayName } from "../i18n";
import { langFlag, langNative } from "../langs";
import { Avatar } from "./Avatar";

export function Settings() {
  const p = prefs.value;
  const r = room.value;
  const me = you.value;
  const [about, setAbout] = useState(false);
  const sheetRef = useRef<HTMLDivElement>(null);
  const close = () => (settingsOpen.value = false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    addEventListener("keydown", onKey);
    sheetRef.current?.focus();
    return () => removeEventListener("keydown", onKey);
  }, []);

  const langs = r?.languages ?? [];
  const sizes: FontSize[] = ["s", "m", "l", "xl"];
  const themes: [Theme, string][] = [
    ["auto", t("themeAuto")],
    ["light", t("themeLight")],
    ["dark", t("themeDark")],
    ["contrast", t("themeContrast")],
  ];

  return (
    <div class="sheet-backdrop" onClick={(e) => e.target === e.currentTarget && close()}>
      <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="set-title" tabIndex={-1} ref={sheetRef}>
        <div class="sheet-grip" aria-hidden="true" />
        <header class="sheet-head">
          <h2 id="set-title" class="h2">
            {t("settings")}
          </h2>
          <button class="icon-btn" onClick={close} aria-label={t("close")}>
            ✕
          </button>
        </header>

        {me && (
          <button
            class="card me-card"
            onClick={() => {
              close();
              editingProfile.value = true;
            }}
          >
            <Avatar who={me} size={48} />
            <div class="grow left">
              <div class="person-name">{displayName(me.name)}</div>
              <div class="muted small">{me.tagline || t("editProfile")}</div>
              {me.spotMe && <div class="muted small">👀 {me.spotMe}</div>}
            </div>
            <span class="muted">✎</span>
          </button>
        )}

        <div class="set-group">
          <div class="set-label">{t("language")}</div>
          <div class="lang-row">
            {langs.map((l) => (
              <button
                key={l}
                class={`chip ${me?.lang === l ? "on" : ""}`}
                aria-pressed={me?.lang === l}
                onClick={() => changeLang(l)}
              >
                <span aria-hidden="true">{langFlag(l)}</span> {langNative(l)}
              </button>
            ))}
          </div>
        </div>

        <div class="set-group">
          <div class="set-label">{t("displayMode")}</div>
          <div class="seg-ctl wide">
            <button class={p.mode === "flow" ? "on" : ""} aria-pressed={p.mode === "flow"} onClick={() => setPref("mode", "flow")}>
              <b>📜 {t("flow")}</b>
              <small>{t("flowHint")}</small>
            </button>
            <button
              class={p.mode === "captions" ? "on" : ""}
              aria-pressed={p.mode === "captions"}
              onClick={() => setPref("mode", "captions")}
            >
              <b>🎬 {t("captions")}</b>
              <small>{t("captionsHint")}</small>
            </button>
          </div>
        </div>

        <div class="set-group">
          <div class="set-label">{t("fontSize")}</div>
          <div class="seg-ctl">
            {sizes.map((s) => (
              <button
                key={s}
                class={`fs-${s} ${p.fontSize === s ? "on" : ""}`}
                aria-pressed={p.fontSize === s}
                aria-label={`${t("fontSize")} ${s.toUpperCase()}`}
                onClick={() => setPref("fontSize", s)}
              >
                A<span class="sr-only">{s.toUpperCase()}</span>
              </button>
            ))}
          </div>
        </div>

        <label class="set-group switch-row">
          <span class="set-label">{t("showOriginalSetting")}</span>
          <input
            type="checkbox"
            class="switch"
            checked={p.showOriginal}
            onChange={(e) => setPref("showOriginal", (e.target as HTMLInputElement).checked)}
          />
        </label>

        <div class="set-group">
          <div class="set-label">{t("theme")}</div>
          <div class="seg-ctl tight">
            {themes.map(([k, label]) => (
              <button key={k} class={p.theme === k ? "on" : ""} aria-pressed={p.theme === k} onClick={() => setPref("theme", k)}>
                {label}
              </button>
            ))}
          </div>
        </div>

        <button class="btn ghost full" onClick={() => setAbout((a) => !a)} aria-expanded={about}>
          ℹ️ {t("about")}
        </button>
        {about && (
          <div class="about card soft">
            <img class="brand-mark" src="/logo.svg" alt="La Laai" width="110" />
            <p class="small">{t("aboutBody")}</p>
          </div>
        )}
      </div>
    </div>
  );
}
