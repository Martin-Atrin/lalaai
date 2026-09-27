// In-browser fake relay for demos: open any /m/<slug>?mock=1.
// Mirrors the wire protocol so the UI runs exactly the same code paths as with the real relay.
import type {
  AttendeeToRelay,
  Icebreaker,
  Lang,
  MatchView,
  MeetState,
  Profile,
  QuestionView,
  RelayToAttendee,
  RoomInfo,
  SegmentView,
} from "@shared/protocol";
import type { Identity } from "./identity";
import { storageGet, storageSet } from "./identity";
import type { Link, LinkHandlers } from "./net";

const LANGS: Lang[] = ["en", "cs", "de", "es", "fr", "ja", "zh", "uk", "th"];

export function mockRoom(slug: string): RoomInfo {
  return {
    slug,
    title: "On-device AI for humans",
    presenterName: "Jana Nováková",
    presenterLang: "en",
    languages: LANGS,
    llmEnabled: true,
    live: true,
    attendeeCount: 42,
  };
}

// ─────────────────────────── fake content ───────────────────────────
type Texts = Partial<Record<Lang, string>>;

const SCRIPT: Texts[] = [
  {
    en: "Hi everyone, thanks for coming tonight.",
    cs: "Ahoj všichni, díky, že jste dnes večer přišli.",
    de: "Hallo zusammen, danke, dass ihr heute Abend gekommen seid.",
    es: "Hola a todos, gracias por venir esta noche.",
    fr: "Bonjour à tous, merci d'être venus ce soir.",
    ja: "皆さん、今夜はお越しいただきありがとうございます。",
    uk: "Привіт усім, дякую, що прийшли сьогодні ввечері.",
    zh: "大家好，感谢今晚到场。",
  },
  {
    en: "Everything you are reading right now is transcribed on my laptop.",
    cs: "Všechno, co teď čtete, se přepisuje přímo na mém notebooku.",
    de: "Alles, was ihr gerade lest, wird auf meinem Laptop transkribiert.",
    es: "Todo lo que estáis leyendo ahora se transcribe en mi portátil.",
    fr: "Tout ce que vous lisez en ce moment est transcrit sur mon ordinateur.",
    ja: "今読んでいる文章はすべて私のノートPCで書き起こされています。",
    uk: "Усе, що ви зараз читаєте, транскрибується на моєму ноутбуці.",
    zh: "你们现在看到的一切都是在我的笔记本上转写的。",
  },
  {
    en: "No cloud, no waiting, and it works in eight languages at once.",
    cs: "Žádný cloud, žádné čekání a funguje to v osmi jazycích najednou.",
    de: "Keine Cloud, kein Warten, und es läuft in acht Sprachen gleichzeitig.",
    es: "Sin nube, sin esperas, y funciona en ocho idiomas a la vez.",
    fr: "Pas de cloud, pas d'attente, et ça marche en huit langues à la fois.",
    ja: "クラウドなし、待ち時間なし、8か国語で同時に動きます。",
    uk: "Жодної хмари, жодного очікування, і все працює вісьмома мовами одночасно.",
    zh: "没有云端，无需等待，而且同时支持八种语言。",
  },
  {
    en: "If you have a question, open the Q&A tab and ask in your own language.",
    cs: "Pokud máte otázku, otevřete záložku Otázky a zeptejte se svým jazykem.",
    de: "Wenn ihr eine Frage habt, öffnet den Fragen-Tab und fragt in eurer Sprache.",
    es: "Si tenéis una pregunta, abrid la pestaña de preguntas y preguntad en vuestro idioma.",
    fr: "Si vous avez une question, ouvrez l'onglet Questions et posez-la dans votre langue.",
    ja: "質問があれば、Q&Aタブを開いて自分の言語で聞いてください。",
    uk: "Якщо маєте питання, відкрийте вкладку Питання й запитайте своєю мовою.",
    zh: "如果有问题，请打开问答页，用你自己的语言提问。",
  },
  {
    en: "And when someone likes your question, you can meet them after the talk.",
    cs: "A když se někomu vaše otázka líbí, můžete se s ním po přednášce potkat.",
    de: "Und wenn jemand eure Frage mag, könnt ihr euch nach dem Vortrag treffen.",
    es: "Y si a alguien le gusta tu pregunta, podéis conoceros después de la charla.",
    fr: "Et si quelqu'un aime votre question, vous pourrez vous rencontrer après.",
    ja: "誰かがあなたの質問にいいねしたら、トークの後で会えます。",
    uk: "А якщо комусь сподобається ваше питання, ви зможете зустрітися після доповіді.",
    zh: "当有人喜欢你的问题时，你们可以在演讲后见面。",
  },
  {
    en: "Let's talk about why small models are suddenly good enough.",
    cs: "Pojďme si říct, proč jsou malé modely najednou dost dobré.",
    de: "Reden wir darüber, warum kleine Modelle plötzlich gut genug sind.",
    es: "Hablemos de por qué los modelos pequeños de repente son suficientes.",
    fr: "Parlons de pourquoi les petits modèles sont soudain assez bons.",
    ja: "なぜ小さなモデルが急に十分な性能になったのか話しましょう。",
    uk: "Поговорімо, чому малі моделі раптом стали достатньо хорошими.",
    zh: "我们来聊聊为什么小模型突然变得足够好了。",
  },
];

/** Fallback "fake language" for anything not in the script. */
function blorb(s: string): string {
  return s.replace(/[aeiou]/g, (v) => ({ a: "ä", e: "ë", i: "ï", o: "ö", u: "ü" })[v] ?? v);
}
function pick(texts: Texts, lang: Lang): string {
  return texts[lang] ?? blorb(texts.en ?? "");
}

const PEOPLE: Record<string, Profile> = {
  mia: { uid: "mockMia000000001", name: "Mia", avatar: "owl", color: "#4f8cff", lang: "de", tagline: "ML engineer, Berlin", contact: "linkedin.com/in/mia-example" },
  kenji: { uid: "mockKenji0000002", name: "Kenji", avatar: "robot", color: "#2bb3a3", lang: "ja", tagline: "iOS dev, loves Swift & ramen", contact: "@kenji_dev" },
  lucia: { uid: "mockLucia0000003", name: "Lucía", avatar: "frog", color: "#6aa84f", lang: "es", tagline: "Product designer" },
  tomas: { uid: "mockTomas0000004", name: "Tomáš", avatar: "bear", color: "#c2723b", lang: "cs", tagline: "Backend @ startup, climber" },
  olena: { uid: "mockOlena0000005", name: "Olena", avatar: "cat", color: "#e94f64", lang: "uk", tagline: "Data scientist" },
};
const pub = (p: Profile) => ({ uid: p.uid, name: p.name, avatar: p.avatar, color: p.color });
const peer = (p: Profile, withContact: boolean): Profile => {
  const { contact, ...rest } = p;
  return withContact && contact ? { ...rest, contact } : rest;
};

interface MockQuestion {
  id: string;
  author: Profile;
  original: string;
  originalLang: Lang;
  texts: Texts;
  likers: Set<string>;
  answered: boolean;
  pinned: boolean;
  createdAt: number;
}

interface MockMatch {
  id: string;
  peer: Profile;
  outgoing: boolean;
  status: MatchView["status"];
  questionId: string;
  icebreakers: Partial<Record<Lang, Icebreaker[]>>;
  icebreakerSource: MatchView["icebreakerSource"];
  createdAt: number;
}

const ICE_LLM: Partial<Record<Lang, Icebreaker[]>> = {
  en: [
    { topic: "Offline speech models", prompt: "Have you tried running Whisper-style models fully offline? What broke first?" },
    { topic: "Swift on-device ML", prompt: "What's your favourite trick for keeping Core ML models small?" },
    { topic: "Conference life", prompt: "Which talk tonight would you have given instead?" },
  ],
  cs: [
    { topic: "Offline modely řeči", prompt: "Zkoušel(a) jsi pouštět modely typu Whisper úplně offline? Co se rozbilo první?" },
    { topic: "ML ve Swiftu", prompt: "Jaký je tvůj oblíbený trik, jak udržet Core ML modely malé?" },
    { topic: "Život na konferencích", prompt: "Kterou přednášku bys dnes večer měl(a) místo toho ty?" },
  ],
};
const ICE_FALLBACK: Partial<Record<Lang, Icebreaker[]>> = {
  en: [
    { topic: "Why this talk", prompt: "What made you come to this talk tonight?" },
    { topic: "Side projects", prompt: "What are you building for fun right now?" },
  ],
  cs: [
    { topic: "Proč tahle přednáška", prompt: "Co tě dnes přivedlo právě sem?" },
    { topic: "Side projekty", prompt: "Na čem teď děláš jen tak pro radost?" },
  ],
};

// ─────────────────────────── fake relay ───────────────────────────
export function openMock(slug: string, id: Identity, h: LinkHandlers): Link {
  const room = mockRoom(slug);
  const timers: ReturnType<typeof setTimeout>[] = [];
  const later = (ms: number, fn: () => void) => timers.push(setTimeout(fn, ms));
  let closed = false;

  let me: Profile | null = null;
  try {
    const raw = storageGet(`lalaai.mock.profile.${slug}`);
    if (raw) me = JSON.parse(raw) as Profile;
  } catch {
    /* ignore */
  }
  const lang = () => me?.lang ?? room.presenterLang;
  const emit = (m: RelayToAttendee) => !closed && h.onMessage(m);

  // Seed state.
  const now = Date.now();
  let qSeq = 10;
  const questions: MockQuestion[] = [
    {
      id: "q1",
      author: PEOPLE.mia,
      original: "Wie funktioniert die Übersetzung, wenn das WLAN hier ausfällt?",
      originalLang: "de",
      texts: {
        en: "How does translation work when the Wi-Fi here goes down?",
        cs: "Jak funguje překlad, když tady vypadne Wi-Fi?",
        es: "¿Cómo funciona la traducción si se cae el Wi-Fi aquí?",
        fr: "Comment marche la traduction si le Wi-Fi tombe ici ?",
        ja: "ここのWi-Fiが落ちたら翻訳はどうなりますか？",
        uk: "Як працює переклад, якщо тут зникне Wi-Fi?",
        zh: "如果这里的 Wi-Fi 断了，翻译还能用吗？",
      },
      likers: new Set([PEOPLE.kenji.uid, PEOPLE.tomas.uid, PEOPLE.olena.uid, id.uid]),
      answered: false,
      pinned: true,
      createdAt: now - 9 * 60_000,
    },
    {
      id: "q2",
      author: PEOPLE.kenji,
      original: "モデルのサイズはどれくらいですか？",
      originalLang: "ja",
      texts: {
        en: "How big is the model?",
        cs: "Jak velký je ten model?",
        de: "Wie groß ist das Modell?",
        es: "¿Qué tamaño tiene el modelo?",
        fr: "Quelle est la taille du modèle ?",
        uk: "Наскільки великою є модель?",
        zh: "模型有多大？",
      },
      likers: new Set([PEOPLE.mia.uid, PEOPLE.lucia.uid]),
      answered: true,
      pinned: false,
      createdAt: now - 7 * 60_000,
    },
    {
      id: "q3",
      author: PEOPLE.lucia,
      original: "¿Se puede usar también para reuniones por videollamada?",
      originalLang: "es",
      texts: {
        en: "Can it be used for video-call meetings too?",
        cs: "Dá se to použít i na videohovory?",
        de: "Kann man das auch für Videocalls nutzen?",
        fr: "Peut-on l'utiliser aussi en visio ?",
        ja: "ビデオ会議でも使えますか？",
        uk: "Чи можна це використати й для відеодзвінків?",
        zh: "视频会议也能用吗？",
      },
      likers: new Set([PEOPLE.olena.uid]),
      answered: false,
      pinned: false,
      createdAt: now - 3 * 60_000,
    },
    {
      id: "q4",
      author: { uid: id.uid, name: "", avatar: "fox", color: "#45c2f9", lang: "en" },
      original: "Does the on-device model drain the laptop battery a lot?",
      originalLang: "en",
      texts: {
        cs: "Vybíjí model běžící na zařízení hodně baterii notebooku?",
        de: "Zieht das On-Device-Modell viel Akku vom Laptop?",
        es: "¿El modelo local gasta mucha batería del portátil?",
        fr: "Le modèle local vide-t-il beaucoup la batterie ?",
        ja: "オンデバイスのモデルはノートPCのバッテリーをかなり消費しますか？",
        uk: "Чи сильно модель на пристрої розряджає батарею ноутбука?",
        zh: "本地模型会很耗笔记本电量吗？",
      },
      likers: new Set([PEOPLE.kenji.uid, PEOPLE.lucia.uid, PEOPLE.olena.uid]),
      answered: false,
      pinned: false,
      createdAt: now - 5 * 60_000,
    },
  ];
  const matches: MockMatch[] = [
    {
      id: "m1",
      peer: PEOPLE.kenji,
      outgoing: false,
      status: "accepted",
      questionId: "q4",
      icebreakers: ICE_LLM,
      icebreakerSource: "llm",
      createdAt: now - 2 * 60_000,
    },
    {
      id: "m2",
      peer: PEOPLE.lucia,
      outgoing: false,
      status: "pending",
      questionId: "q4",
      icebreakers: {},
      icebreakerSource: "none",
      createdAt: now - 60_000,
    },
  ];

  const qText = (q: MockQuestion, l: Lang) => (l === q.originalLang ? q.original : q.texts[l] ?? q.original);
  const viewQ = (q: MockQuestion): QuestionView => {
    const l = lang();
    const mine = q.author.uid === id.uid;
    const author = mine && me ? pub(me) : pub(q.author.name ? q.author : { ...q.author, name: "You" });
    return {
      id: q.id,
      author,
      text: qText(q, l),
      original: q.original,
      originalLang: q.originalLang,
      translated: l !== q.originalLang && !!q.texts[l],
      likes: q.likers.size,
      likedByMe: q.likers.has(id.uid),
      mine,
      answered: q.answered,
      pinned: q.pinned,
      createdAt: q.createdAt,
    };
  };
  const viewMeet = (): MeetState => {
    const l = lang();
    const all = Object.values(PEOPLE);
    return {
      likers: questions
        .filter((q) => q.author.uid === id.uid && q.likers.size)
        .map((q) => ({
          questionId: q.id,
          questionText: qText(q, l),
          people: [...q.likers].map((u) => all.find((p) => p.uid === u)).filter((p): p is Profile => !!p).map((p) => peer(p, false)),
        })),
      matches: matches.map((m) => {
        const q = questions.find((x) => x.id === m.questionId);
        return {
          id: m.id,
          status: m.status,
          outgoing: m.outgoing,
          peer: peer(m.peer, m.status === "accepted"),
          questionId: m.questionId,
          questionText: q ? qText(q, l) : "",
          icebreakers: m.icebreakers[l] ?? m.icebreakers.en ?? [],
          icebreakerSource: m.icebreakerSource,
          createdAt: m.createdAt,
        };
      }),
    };
  };

  // Transcript.
  const history: { id: number; texts: Texts }[] = [];
  let segId = 100;
  const segView = (sid: number, texts: Texts, final: boolean, frac = 1): SegmentView => {
    const cut = (s: string) => {
      if (frac >= 1) return s;
      const words = s.split(" ");
      return words.slice(0, Math.max(1, Math.ceil(words.length * frac))).join(" ");
    };
    return { id: sid, final, text: cut(pick(texts, lang())), source: cut(texts.en ?? ""), t: Date.now() };
  };
  // Pre-seed two finals so the transcript isn't empty on join.
  for (const texts of SCRIPT.slice(0, 2)) history.push({ id: segId++, texts });
  let scriptIdx = 2;

  const streamNext = () => {
    if (closed) return;
    const texts = SCRIPT[scriptIdx % SCRIPT.length];
    scriptIdx++;
    const sid = segId++;
    const steps = Math.max(3, (texts.en ?? "").split(" ").length);
    for (let i = 1; i <= steps; i++) {
      later(i * 260, () => emit({ type: "segment", segment: segView(sid, texts, false, i / steps) }));
    }
    later(steps * 260 + 350, () => {
      history.push({ id: sid, texts });
      emit({ type: "segment", segment: segView(sid, texts, true) });
      later(1400, streamNext);
    });
  };

  const welcome = () =>
    emit({
      type: "welcome",
      room: { ...room },
      you: me,
      segments: history.slice(-50).map((s) => segView(s.id, s.texts, true)),
      questions: questions.map(viewQ),
      meet: viewMeet(),
    });

  const pushMeet = () => emit({ type: "meet.update", meet: viewMeet() });
  const pushQ = (q: MockQuestion) => emit({ type: "question.upsert", question: viewQ(q) });

  const handle = (msg: AttendeeToRelay) => {
    switch (msg.type) {
      case "ping":
        later(30, () => emit({ type: "pong" }));
        break;
      case "profile.update": {
        const langChanged = me?.lang !== msg.profile.lang;
        me = { uid: id.uid, ...msg.profile };
        storageSet(`lalaai.mock.profile.${slug}`, JSON.stringify(me));
        // Relay behaviour: re-send a localized welcome on language change / first profile.
        if (langChanged) later(150, welcome);
        break;
      }
      case "question.ask": {
        const q: MockQuestion = {
          id: `q${qSeq++}`,
          author: me ?? PEOPLE.mia,
          original: msg.text,
          originalLang: lang(),
          texts: {},
          likers: new Set(),
          answered: false,
          pinned: false,
          createdAt: Date.now(),
        };
        questions.push(q);
        later(120, () => pushQ(q));
        later(2500, () => {
          q.likers.add(PEOPLE.tomas.uid);
          pushQ(q);
          pushMeet();
          emit({ type: "toast", kind: "info", message: `${PEOPLE.tomas.name} ❤️ “${msg.text.slice(0, 40)}”` });
        });
        later(5000, () => {
          q.likers.add(PEOPLE.mia.uid);
          pushQ(q);
          pushMeet();
        });
        break;
      }
      case "question.like": {
        const q = questions.find((x) => x.id === msg.id);
        if (!q) break;
        if (msg.like) q.likers.add(id.uid);
        else q.likers.delete(id.uid);
        later(200, () => pushQ(q));
        break;
      }
      case "question.delete": {
        const i = questions.findIndex((x) => x.id === msg.id && x.author.uid === id.uid);
        if (i >= 0) {
          questions.splice(i, 1);
          later(100, () => {
            emit({ type: "question.remove", id: msg.id });
            pushMeet();
          });
        }
        break;
      }
      case "meet.request": {
        const p = Object.values(PEOPLE).find((x) => x.uid === msg.toUid);
        if (!p || matches.some((m) => m.peer.uid === p.uid)) break;
        const m: MockMatch = {
          id: `m${Date.now()}`,
          peer: p,
          outgoing: true,
          status: "pending",
          questionId: msg.questionId,
          icebreakers: {},
          icebreakerSource: "none",
          createdAt: Date.now(),
        };
        matches.push(m);
        later(200, pushMeet);
        later(2500, () => {
          m.status = "accepted";
          m.icebreakerSource = "pending";
          pushMeet();
          emit({ type: "toast", kind: "match", message: `It's a match! ${p.name} wants to meet you too 🎉` });
        });
        later(6000, () => {
          m.icebreakers = ICE_LLM;
          m.icebreakerSource = "llm";
          pushMeet();
        });
        break;
      }
      case "meet.respond": {
        const m = matches.find((x) => x.id === msg.matchId);
        if (!m) break;
        m.status = msg.accept ? "accepted" : "declined";
        if (msg.accept) {
          m.icebreakerSource = "pending";
          later(150, () => {
            pushMeet();
            emit({ type: "toast", kind: "match", message: `You and ${m.peer.name} matched! 🎉` });
          });
          later(4000, () => {
            m.icebreakers = ICE_FALLBACK;
            m.icebreakerSource = "fallback";
            pushMeet();
          });
        } else later(150, pushMeet);
        break;
      }
    }
  };

  // Boot sequence.
  h.onStatus("connecting");
  later(350, () => {
    h.onStatus("open");
    welcome();
    later(1200, streamNext);
  });

  // Ambient life in the room.
  const ambient = setInterval(() => {
    if (closed) return;
    room.attendeeCount += Math.random() < 0.6 ? 1 : -1;
    emit({ type: "room.update", room: { ...room } });
    const q = questions[Math.floor(Math.random() * questions.length)];
    if (q && q.author.uid !== id.uid) {
      q.likers.add(`anon${Math.random().toString(36).slice(2, 8)}`);
      pushQ(q);
    }
  }, 7000);

  later(18_000, () => {
    const q: MockQuestion = {
      id: `q${qSeq++}`,
      author: PEOPLE.olena,
      original: "Чи можна додати власні мови?",
      originalLang: "uk",
      texts: {
        en: "Can we add our own languages?",
        cs: "Můžeme přidat vlastní jazyky?",
        de: "Kann man eigene Sprachen hinzufügen?",
        es: "¿Podemos añadir nuestros propios idiomas?",
        fr: "Peut-on ajouter nos propres langues ?",
        ja: "独自の言語を追加できますか？",
        zh: "可以添加自己的语言吗？",
      },
      likers: new Set(),
      answered: false,
      pinned: false,
      createdAt: Date.now(),
    };
    questions.push(q);
    pushQ(q);
  });

  return {
    send(msg) {
      if (!closed) handle(msg);
    },
    close() {
      closed = true;
      clearInterval(ambient);
      timers.forEach(clearTimeout);
      h.onStatus("closed");
    },
  };
}
