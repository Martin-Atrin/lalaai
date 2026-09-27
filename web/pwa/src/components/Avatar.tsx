import { displayName, t } from "../i18n";
import type { Profile } from "@shared/protocol";

export const AVATARS: { id: string; emoji: string; label: string }[] = [
  { id: "fox", emoji: "🦊", label: "Fox" },
  { id: "owl", emoji: "🦉", label: "Owl" },
  { id: "cat", emoji: "🐱", label: "Cat" },
  { id: "frog", emoji: "🐸", label: "Frog" },
  { id: "bear", emoji: "🐻", label: "Bear" },
  { id: "panda", emoji: "🐼", label: "Panda" },
  { id: "octopus", emoji: "🐙", label: "Octopus" },
  { id: "robot", emoji: "🤖", label: "Robot" },
];

export const COLORS = ["#45c2f9", "#f9606c", "#002060", "#1d9fd9", "#ff8a66", "#3a5ba8", "#7fd8fb", "#c73a57"];

export function avatarEmoji(id: string): string {
  if (id === "anon") return "🎭";
  return AVATARS.find((a) => a.id === id)?.emoji ?? "🙂";
}

interface Props {
  who: Pick<Profile, "avatar" | "color" | "name">;
  size?: number;
}

export function Avatar({ who, size = 40 }: Props) {
  const color = /^#[0-9a-f]{3,8}$/i.test(who.color) ? who.color : "#45c2f9";
  return (
    <span
      class="avatar"
      role="img"
      aria-label={who.avatar === "anon" ? t("anonymous") : displayName(who.name)}
      style={{ width: size, height: size, fontSize: size * 0.56, background: `${color}33`, boxShadow: `inset 0 0 0 2px ${color}` }}
    >
      <span aria-hidden="true">{avatarEmoji(who.avatar)}</span>
    </span>
  );
}
