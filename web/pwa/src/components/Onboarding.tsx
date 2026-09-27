import { useEffect, useMemo, useState } from "preact/hooks";
import { completeNameGate, editingProfile, nameGate, room, updateProfile, you } from "../store";
import { setUiLang, t } from "../i18n";
import { langFlag, langNative, preferredLang } from "../langs";
import { AVATARS, Avatar, COLORS } from "./Avatar";
import { Mascot } from "./Mascot";

export function Onboarding() {
  const r = room.value!;
  const me = you.value;
  const editing = me !== null;
  const gate = nameGate.value; // lazy name prompt (first question / meet)
  const langs = r.languages.length ? r.languages : [r.presenterLang];

  const initialLang = useMemo(() => me?.lang ?? preferredLang(langs, r.presenterLang), []);
  const [step, setStep] = useState<0 | 1>(gate ? 1 : 0);
  const [lang, setLang] = useState(initialLang);
  const [name, setName] = useState(me?.name ?? "");
  const [avatar, setAvatar] = useState(me?.avatar ?? AVATARS[Math.floor(Math.random() * AVATARS.length)].id);
  const [color, setColor] = useState(me?.color ?? COLORS[Math.floor(Math.random() * COLORS.length)]);
  const [tagline, setTagline] = useState(me?.tagline ?? "");
  const [contact, setContact] = useState(me?.contact ?? "");
  const [spotMe, setSpotMe] = useState(me?.spotMe ?? "");

  // Preview UI in the language being picked.
  useEffect(() => setUiLang(lang), [lang]);

  const cancel = () => {
    if (me) setUiLang(me.lang);
    editingProfile.value = false;
    nameGate.value = null; // closing the prompt cancels the pending action
  };

  // New attendees only pick a language; the name is asked for later, when it matters.
  const start = () => updateProfile({ name: "", avatar, color, lang, tagline: "", contact: "" });

  const submit = (e: Event) => {
    e.preventDefault();
    if (!name.trim()) return;
    updateProfile({ name, avatar, color, lang, tagline, contact, spotMe });
    if (gate) completeNameGate(false);
  };

  return (
    <div class="onb" role="dialog" aria-modal="true" aria-labelledby="onb-title">
      <div class="onb-inner">
        {editing && (
          <button class="icon-btn onb-close" onClick={cancel} aria-label={t("close")}>
            ✕
          </button>
        )}
        {step === 0 ? (
          <section class="onb-step" key="s0">
            <Mascot size={140} lead={t("hello")} />
            <h1 id="onb-title" class="onb-title">
              {t("onbLangTitle")}
            </h1>
            <p class="muted onb-hint">{t("onbLangHint")}</p>
            <div class="lang-grid" role="radiogroup" aria-label={t("language")}>
              {langs.map((l) => (
                <button
                  key={l}
                  role="radio"
                  aria-checked={lang === l}
                  class={`lang-tile ${lang === l ? "on" : ""}`}
                  onClick={() => setLang(l)}
                >
                  <span class="lang-flag" aria-hidden="true">
                    {langFlag(l)}
                  </span>
                  <span class="lang-name">{langNative(l)}</span>
                </button>
              ))}
            </div>
            <div class="onb-actions">
              <button class="btn primary big" onClick={editing ? () => setStep(1) : start}>
                {editing ? `${t("next")} →` : `${t("start")} →`}
              </button>
            </div>
          </section>
        ) : (
          <form class="onb-step" key="s1" onSubmit={submit}>
            <div class="onb-preview">
              <Avatar who={{ avatar, color, name: name || "?" }} size={84} />
              <div class="onb-preview-name">{name || t("namePh")}</div>
              {tagline && <div class="muted small">{tagline}</div>}
            </div>
            <h1 id="onb-title" class="onb-title">
              {gate ? t(gate.reason === "ask" ? "namePromptAsk" : "namePromptMeet") : t("onbAboutTitle")}
            </h1>
            {gate && <p class="muted onb-hint">{t(gate.reason === "ask" ? "namePromptAskHint" : "namePromptMeetHint")}</p>}

            <label class="field">
              <span class="field-label">{t("name")}</span>
              <input
                class="input"
                value={name}
                maxLength={32}
                required
                autoComplete="nickname"
                placeholder={t("namePh")}
                onInput={(e) => setName((e.target as HTMLInputElement).value)}
              />
            </label>

            <fieldset class="field">
              <legend class="field-label">{t("pickAvatar")}</legend>
              <div class="avatar-grid">
                {AVATARS.map((a) => (
                  <button
                    type="button"
                    key={a.id}
                    class={`avatar-pick ${avatar === a.id ? "on" : ""}`}
                    aria-pressed={avatar === a.id}
                    aria-label={a.label}
                    onClick={() => setAvatar(a.id)}
                  >
                    <Avatar who={{ avatar: a.id, color, name: a.label }} size={48} />
                  </button>
                ))}
              </div>
            </fieldset>

            {gate?.reason !== "ask" && (
              <>
            <fieldset class="field">
              <legend class="field-label">{t("pickColor")}</legend>
              <div class="swatches">
                {COLORS.map((c) => (
                  <button
                    type="button"
                    key={c}
                    class={`swatch ${color === c ? "on" : ""}`}
                    style={{ background: c }}
                    aria-pressed={color === c}
                    aria-label={c}
                    onClick={() => setColor(c)}
                  />
                ))}
              </div>
            </fieldset>

            <label class="field">
              <span class="field-label">{t("taglineLabel")}</span>
              <input
                class="input"
                value={tagline}
                maxLength={80}
                placeholder={t("taglinePh")}
                onInput={(e) => setTagline((e.target as HTMLInputElement).value)}
              />
            </label>

            <label class="field">
              <span class="field-label">👀 {t("spotMe")}</span>
              <input
                class="input"
                value={spotMe}
                maxLength={80}
                autoComplete="off"
                placeholder={t("spotMePh")}
                onInput={(e) => setSpotMe((e.target as HTMLInputElement).value)}
              />
              <span class="field-help">🔒 {t("spotMeHint")}</span>
            </label>

            <label class="field">
              <span class="field-label">{t("contact")}</span>
              <input
                class="input"
                value={contact}
                maxLength={120}
                autoComplete="off"
                placeholder={t("contactPh")}
                onInput={(e) => setContact((e.target as HTMLInputElement).value)}
              />
              <span class="field-help">🔒 {t("contactHint")}</span>
            </label>

              </>
            )}

            <div class="onb-actions">
              {gate ? (
                gate.reason === "ask" && (
                  <button type="button" class="btn ghost" onClick={() => completeNameGate(true)}>
                    {t("skipAnon")}
                  </button>
                )
              ) : (
                <button type="button" class="btn ghost" onClick={() => setStep(0)}>
                  ← {t("back")}
                </button>
              )}
              <button type="submit" class="btn primary big" disabled={!name.trim()}>
                {gate ? (gate.reason === "ask" ? t("send") : t("letsGo")) : editing ? t("save") : t("letsGo")}
              </button>
            </div>
          </form>
        )}
        <div class="onb-dots" aria-hidden="true" hidden={!!gate || !editing}>
          <span class={step === 0 ? "on" : ""} />
          <span class={step === 1 ? "on" : ""} />
        </div>
      </div>
    </div>
  );
}
