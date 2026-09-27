import type { Icebreaker, Lang } from "../../shared/protocol";

// Used when the presenter has no LLM connected (or it times out). Deliberately generic but warm.
const T: Record<string, (q: string, talk: string) => Icebreaker[]> = {
  en: (q, talk) => [
    { topic: "Your question", prompt: `What made you curious about “${q}”?` },
    { topic: "The talk", prompt: `What's one idea from “${talk}” you'd actually try this month?` },
    { topic: "Real world", prompt: "Where have you run into this problem in your own work or life?" },
  ],
  cs: (q, talk) => [
    { topic: "Vaše otázka", prompt: `Proč vás zajímá „${q}“?` },
    { topic: "Přednáška", prompt: `Kterou myšlenku z „${talk}“ byste tento měsíc opravdu vyzkoušeli?` },
    { topic: "Praxe", prompt: "Kde jste na tenhle problém narazili vy sami?" },
  ],
  de: (q, talk) => [
    { topic: "Deine Frage", prompt: `Was hat dich an „${q}“ neugierig gemacht?` },
    { topic: "Der Vortrag", prompt: `Welche Idee aus „${talk}“ würdest du diesen Monat ausprobieren?` },
    { topic: "Praxis", prompt: "Wo bist du selbst schon auf dieses Problem gestoßen?" },
  ],
  es: (q, talk) => [
    { topic: "Tu pregunta", prompt: `¿Qué te llevó a preguntar “${q}”?` },
    { topic: "La charla", prompt: `¿Qué idea de “${talk}” probarías este mes?` },
    { topic: "En la práctica", prompt: "¿Dónde te has encontrado con este problema?" },
  ],
  fr: (q, talk) => [
    { topic: "Ta question", prompt: `Qu'est-ce qui t'a donné envie de demander « ${q} » ?` },
    { topic: "La conférence", prompt: `Quelle idée de « ${talk} » essaierais-tu ce mois-ci ?` },
    { topic: "En pratique", prompt: "Où as-tu déjà rencontré ce problème ?" },
  ],
  th: (q, talk) => [
    { topic: "คำถามของคุณ", prompt: `อะไรทำให้คุณสนใจเรื่อง “${q}”?` },
    { topic: "ทอล์กนี้", prompt: `ไอเดียไหนจาก “${talk}” ที่คุณอยากลองทำจริง ๆ ในเดือนนี้?` },
    { topic: "ชีวิตจริง", prompt: "คุณเคยเจอปัญหานี้ในงานหรือชีวิตของคุณตอนไหนบ้าง?" },
  ],
  ja: (q, talk) => [
    { topic: "あなたの質問", prompt: `「${q}」に興味を持ったきっかけは？` },
    { topic: "今日のトーク", prompt: `「${talk}」の中で、今月さっそく試したいアイデアは？` },
    { topic: "実体験", prompt: "この問題に実際に出会ったのはどんな場面でしたか？" },
  ],
  zh: (q, talk) => [
    { topic: "你的问题", prompt: `是什么让你对“${q}”感兴趣？` },
    { topic: "这场分享", prompt: `“${talk}”里有哪个想法你这个月就想试试？` },
    { topic: "真实经历", prompt: "你在工作或生活中哪里遇到过这个问题？" },
  ],
  uk: (q, talk) => [
    { topic: "Твоє питання", prompt: `Що зацікавило тебе в «${q}»?` },
    { topic: "Доповідь", prompt: `Яку ідею з «${talk}» ти спробуєш цього місяця?` },
    { topic: "Практика", prompt: "Де ти сам стикався з цією проблемою?" },
  ],
};

export function fallbackIcebreakers(lang: Lang, question: string, talk: string): Icebreaker[] {
  const q = question.length > 90 ? question.slice(0, 87) + "…" : question;
  // regional variants (zh-TW, pt-PT) fall back to their base language's templates
  return (T[lang] ?? T[lang.split("-")[0]!] ?? T.en!)(q, talk);
}
