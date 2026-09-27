"""La Laai extended translator: NLLB-200 (distilled 600M, int8) via CTranslate2, fully on-device.

Only used for languages Apple's Translation framework lacks (Czech, Slovak, Burmese, Lao, Khmer, ...).
The model (~600 MB) downloads once from Hugging Face, then everything runs offline on the CPU.
HTTP on 127.0.0.1 only:
  GET  /health -> {"ok": true, "ready": bool, "stage": "...", "error": str|null, "languages": [...]}
  POST /translate {"texts": [...], "source": "cs", "target": "en"} -> {"texts": [...], "ms": int}
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_REPO = os.environ.get("LALAAI_NLLB_REPO", "JustFrederik/nllb-200-distilled-600M-ct2-int8")
PORT = int(os.environ.get("LALAAI_TRANSLATOR_PORT", "8798"))

# La Laai language code -> NLLB (FLORES-200) code. Keep in sync with Lang.nllbOnly in the Mac app.
NLLB = {
    "af": "afr_Latn", "am": "amh_Ethi", "ar": "arb_Arab", "az": "azj_Latn", "be": "bel_Cyrl", "bg": "bul_Cyrl",
    "bn": "ben_Beng", "bs": "bos_Latn", "ca": "cat_Latn", "cs": "ces_Latn", "cy": "cym_Latn", "da": "dan_Latn",
    "de": "deu_Latn", "el": "ell_Grek", "en": "eng_Latn", "es": "spa_Latn", "et": "est_Latn", "eu": "eus_Latn",
    "fa": "pes_Arab", "fi": "fin_Latn", "fil": "tgl_Latn", "fr": "fra_Latn", "ga": "gle_Latn", "gl": "glg_Latn",
    "gu": "guj_Gujr", "he": "heb_Hebr", "hi": "hin_Deva", "hr": "hrv_Latn", "hu": "hun_Latn", "hy": "hye_Armn",
    "id": "ind_Latn", "is": "isl_Latn", "it": "ita_Latn", "ja": "jpn_Jpan", "ka": "kat_Geor", "kk": "kaz_Cyrl",
    "km": "khm_Khmr", "kn": "kan_Knda", "ko": "kor_Hang", "lo": "lao_Laoo", "lt": "lit_Latn", "lv": "lvs_Latn",
    "mk": "mkd_Cyrl", "ml": "mal_Mlym", "mn": "khk_Cyrl", "mr": "mar_Deva", "ms": "zsm_Latn", "my": "mya_Mymr",
    "nb": "nob_Latn", "ne": "npi_Deva", "nl": "nld_Latn", "pa": "pan_Guru", "pl": "pol_Latn", "pt": "por_Latn",
    "pt-PT": "por_Latn", "ro": "ron_Latn", "ru": "rus_Cyrl", "shn": "shn_Mymr", "si": "sin_Sinh", "sk": "slk_Latn",
    "sl": "slv_Latn", "sq": "als_Latn", "sr": "srp_Cyrl", "sv": "swe_Latn", "sw": "swh_Latn", "ta": "tam_Taml",
    "te": "tel_Telu", "th": "tha_Thai", "tr": "tur_Latn", "uk": "ukr_Cyrl", "ur": "urd_Arab", "uz": "uzn_Latn",
    "vi": "vie_Latn", "zh": "zho_Hans", "zh-TW": "zho_Hant", "zh-HK": "zho_Hant", "yue": "yue_Hant",
}

state = {"ready": False, "stage": "starting", "error": None, "translator": None, "sp": None}
lock = threading.Lock()


def nllb_code(lang: str):
    return NLLB.get(lang) or NLLB.get(lang.split("-")[0])


def load():
    try:
        import ctranslate2
        import sentencepiece as spm
        from huggingface_hub import snapshot_download

        state["stage"] = "downloading model (~600 MB, first time only)"
        path = snapshot_download(MODEL_REPO)
        state["stage"] = "loading model"
        sp = spm.SentencePieceProcessor(model_file=os.path.join(path, "sentencepiece.bpe.model"))
        tr = ctranslate2.Translator(path, device="cpu", compute_type="int8", inter_threads=1,
                                    intra_threads=max(2, (os.cpu_count() or 4) // 2))
        state.update(translator=tr, sp=sp, ready=True, stage="ready")
        print(f"[translator] ready ({MODEL_REPO})", flush=True)
    except Exception as e:  # surfaced via /health
        state.update(error=str(e), stage="failed")
        print(f"[translator] failed: {e}", file=sys.stderr, flush=True)


def translate(texts, source, target):
    src, tgt = nllb_code(source), nllb_code(target)
    if not src or not tgt:
        raise ValueError(f"unsupported pair {source}->{target}")
    sp, tr = state["sp"], state["translator"]
    batch = [[src] + sp.encode(t, out_type=str) + ["</s>"] for t in texts]
    with lock:
        res = tr.translate_batch(batch, target_prefix=[[tgt]] * len(batch), beam_size=2,
                                 max_decoding_length=256, repetition_penalty=1.1)
    out = []
    for r in res:
        toks = r.hypotheses[0]
        if toks and toks[0] == tgt:
            toks = toks[1:]
        out.append(sp.decode(toks))
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            return self._json(200, {"ok": True, "ready": state["ready"], "stage": state["stage"],
                                    "error": state["error"], "languages": sorted(NLLB.keys())})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/translate"):
            return self._json(404, {"error": "not found"})
        if not state["ready"]:
            return self._json(503, {"error": state["error"] or state["stage"]})
        try:
            n = int(self.headers.get("content-length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            texts = [t for t in req.get("texts", []) if isinstance(t, str)][:32]
            t0 = time.time()
            out = translate(texts, req["source"], req["target"])
            self._json(200, {"texts": out, "ms": int((time.time() - t0) * 1000)})
        except Exception as e:
            self._json(400, {"error": str(e)})


def watch_parent():
    """Exit when the La Laai app that started us goes away (no orphaned translators)."""
    parent = int(os.environ.get("LALAAI_PARENT_PID", os.getppid()))
    while True:
        time.sleep(2)
        try:
            os.kill(parent, 0)
        except OSError:
            os._exit(0)


if __name__ == "__main__":
    threading.Thread(target=load, daemon=True).start()
    threading.Thread(target=watch_parent, daemon=True).start()
    print(f"[translator] listening on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
