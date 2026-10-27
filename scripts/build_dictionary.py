#!/usr/bin/env python3
"""Builds the offline dictionaries in Sources/GlosaCore/Resources from open data.

Sources (downloaded once into ~/Library/Caches/Glosa/wiktionary-raw, see --help):
  ru-raw.jsonl.gz           Russian Wiktionary via kaikki.org (meanings in Russian), CC-BY-SA
  en-wikt-spanish.jsonl.gz  English Wiktionary, Spanish entries via kaikki.org (forms, conjugation), CC-BY-SA
  cmudict.dict              CMU Pronouncing Dictionary (English pronunciation), BSD-style licence

Output: dict-es.json.deflate and dict-en.json.deflate (raw DEFLATE JSON), read by OfflineDictionary.swift:
  {"entries": {word: [{"p": pos, "g": [glosses], "x": [[text, ru]], "i": ipa, "h": [syllables],
                       "a": article/"f"-ending}]},
   "forms":   {form: [[lemma, "code|code"]]},
   "conj":    {verb: {"irr": bool, "ger": str, "part": str, "t": {tense: [6 forms]}}},   # Spanish
   "irr":     {verb: [past, participle]},                                                   # English
   "cmu":     {word: "W EH1 N T"}}                                                          # English
"""
import argparse, gzip, json, os, re, zlib

POS = {"noun": "noun", "verb": "verb", "adj": "adjective", "adv": "adverb", "pron": "pronoun",
       "prep": "preposition", "conj": "conjunction", "num": "numeral", "intj": "interjection",
       "article": "determiner", "det": "determiner", "phrase": "expression", "abbrev": "expression",
       "particle": "expression"}

TENSES = {  # code: (required tags, excluded tags)
    "pres": ({"present", "indicative"}, {"subjunctive"}),
    "pret": ({"preterite"}, {"subjunctive"}),
    "impf": ({"imperfect", "indicative"}, {"subjunctive"}),
    "fut": ({"future", "indicative"}, {"subjunctive"}),
    "cond": ({"conditional"}, set()),
    "subj": ({"present", "subjunctive"}, set()),
    "isubj": ({"imperfect", "subjunctive"}, {"se"}),
    "imp": ({"imperative"}, {"negative"}),
}
PERSONS = [("first-person", "singular"), ("second-person", "singular"), ("third-person", "singular"),
           ("first-person", "plural"), ("second-person", "plural"), ("third-person", "plural")]
SKIP_TAGS = {"vos-form", "combined-form", "archaic", "obsolete", "table-tags", "inflection-template", "class", "error-unknown-tag"}


def clean_gloss(g):
    g = re.sub(r"\s+", " ", g).strip(" ;,")
    return g


def senses(entry, limit=6):
    out = []
    for s in entry.get("senses", []):
        if "no-gloss" in s.get("tags", []):
            continue
        for g in s.get("glosses", []):
            g = clean_gloss(g)
            if g and g not in out:
                out.append(g)
    return out[:limit]


def examples(entry, limit=2):
    out = []
    for s in entry.get("senses", []):
        for x in s.get("examples", []):
            t, ru = x.get("text", "").strip(), x.get("translation", "").strip()
            if t and ru and len(t) <= 90 and len(ru) <= 120:
                out.append([t, ru])
                if len(out) == limit:
                    return out
    return out


def ipa(entry):
    for s in entry.get("sounds", []):
        if s.get("ipa") and "plural" not in s.get("tags", []):
            return s["ipa"].strip("[]/ ")
    return None


def syllables(entry):
    for h in entry.get("hyphenations", []):
        parts = [p for part in h.get("parts", []) for p in re.split(r"[.\-·]", part) if p]
        if parts:
            return parts
    return None


def load_jsonl(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        for line in f:
            yield json.loads(line)


def ru_entries(raw_dir, code):
    """Meanings from Russian Wiktionary for one language, keyed by lowercase word."""
    cache = os.path.join(raw_dir, f"{code}.jsonl")
    if not os.path.exists(cache):
        with open(cache, "w", encoding="utf-8") as out:
            for d in load_jsonl(os.path.join(raw_dir, "ru-raw.jsonl.gz")):
                if d.get("lang_code") == code:
                    out.write(json.dumps(d, ensure_ascii=False) + "\n")
    entries, extra = {}, {}
    for d in load_jsonl(cache):
        word = d["word"].strip()
        key = word.lower()
        e = {}
        sy = syllables(d)
        if sy: e["h"] = sy
        i = ipa(d)
        if i: e["i"] = i
        g = senses(d)
        if not g or d.get("pos") == "name":
            # Form pages ("went") have no meaning but still have syllables and pronunciation.
            if e: extra.setdefault(key, e)
            continue
        e.update({"p": POS.get(d.get("pos"), "expression"), "g": g})
        x = examples(d)
        if x: e["x"] = x
        e["_forms"] = [(f.get("form", ""), set(f.get("tags", []))) for f in d.get("forms", [])]
        entries.setdefault(key, []).append(e)
    return entries, extra


def spanish(raw_dir):
    entries, _ = ru_entries(raw_dir, "es")
    needed = set(entries)
    needed |= {w[:-2] for w, es in entries.items() if w.endswith("se") and any(e["p"] == "verb" for e in es)}
    forms, conj, gender, fem = {}, {}, {}, {}
    for d in load_jsonl(os.path.join(raw_dir, "en-wikt-spanish.jsonl.gz")):
        word = d.get("word", "")
        if word not in needed or any(s.get("form_of") for s in d.get("senses", [])):
            continue
        pos = d.get("pos")
        fl = [(f.get("form", ""), set(f.get("tags", []))) for f in d.get("forms", [])]
        if pos == "noun":
            tags = set(d.get("tags", [])) | {t for s in d.get("senses", []) for t in s.get("tags", [])}
            if "masculine" in tags and "feminine" not in tags: gender.setdefault(word, "el")
            if "feminine" in tags and "masculine" not in tags: gender.setdefault(word, "la")
            for f, t in fl:
                if "plural" in t: add_form(forms, f, word, "pl")
        elif pos == "adj":
            for f, t in fl:
                code = ("f" if "feminine" in t else "") + ("pl" if "plural" in t else "")
                if code: add_form(forms, f, word, code)
                if t == {"feminine"} or t == {"feminine", "singular"}: fem.setdefault(word, f)
        elif pos == "verb" and word not in conj:
            table = verb_table(fl)
            if table:
                conj[word] = table
                for f, t in fl:
                    code = verb_code(t)
                    if code: add_form(forms, f, word, code)
    for word, es in entries.items():
        for e in es:
            e.pop("_forms")
            if e["p"] == "noun" and word in gender: e["a"] = gender[word]
            if e["p"] == "adjective" and word in fem:
                f = fem[word]
                if f == word[:-1] + "a" and word.endswith("o"): e["a"] = "a"
                elif f == word + "a": e["a"] = "a+"
    return {"entries": entries, "forms": finish_forms(forms, entries), "conj": conj}


def verb_table(fl):
    t = {}
    for code, (need, exclude) in TENSES.items():
        row = [""] * 6
        for f, tags in fl:
            if " " in f or tags & SKIP_TAGS or tags & exclude or not need <= tags:
                continue
            for i, (person, number) in enumerate(PERSONS):
                if person in tags and number in tags and not row[i]:
                    row[i] = f
        if any(row): t[code] = row
    if "pres" not in t:
        return None
    first = lambda pred: next((f for f, tags in fl if pred(tags) and not tags & SKIP_TAGS), "")
    irregular = any(f == "irregular" and "table-tags" in tags for f, tags in fl)
    return {"irr": irregular, "ger": first(lambda x: "gerund" in x),
            "part": first(lambda x: {"participle", "past", "masculine", "singular"} <= x) or
                    first(lambda x: {"participle", "past"} <= x), "t": t}


def verb_code(tags):
    if tags & SKIP_TAGS: return None
    if "gerund" in tags: return "ger"
    if {"participle", "past"} <= tags: return "part"
    for code, (need, exclude) in TENSES.items():
        if need <= tags and not tags & exclude:
            for i, (person, number) in enumerate(PERSONS):
                if person in tags and number in tags:
                    return f"{i}.{code}"
    return None


def add_form(forms, form, lemma, code):
    if not form or form == "-" or " " in form or form == lemma:
        return
    codes = forms.setdefault(form.lower(), {}).setdefault(lemma, [])
    if code not in codes: codes.append(code)


def finish_forms(forms, entries):
    out = {}
    for form, lemmas in forms.items():
        out[form] = [[lemma, "|".join(codes)] for lemma, codes in lemmas.items()]
    return out


# Irregular English verbs: base past participle (past/participle may hold "a/b" variants).
EN_IRREGULAR = """
arise arose arisen|awake awoke awoken|be was/were been|bear bore born|beat beat beaten|become became become
begin began begun|bend bent bent|bet bet bet|bind bound bound|bite bit bitten|bleed bled bled|blow blew blown
break broke broken|breed bred bred|bring brought brought|broadcast broadcast broadcast|build built built
burn burnt/burned burnt/burned|burst burst burst|buy bought bought|catch caught caught|choose chose chosen
cling clung clung|come came come|cost cost cost|creep crept crept|cut cut cut|deal dealt dealt|dig dug dug
do did done|draw drew drawn|dream dreamt/dreamed dreamt/dreamed|drink drank drunk|drive drove driven
eat ate eaten|fall fell fallen|feed fed fed|feel felt felt|fight fought fought|find found found|flee fled fled
fly flew flown|forbid forbade forbidden|forget forgot forgotten|forgive forgave forgiven|freeze froze frozen
get got got/gotten|give gave given|go went gone|grind ground ground|grow grew grown|hang hung hung|have had had
hear heard heard|hide hid hidden|hit hit hit|hold held held|hurt hurt hurt|keep kept kept|kneel knelt knelt
know knew known|lay laid laid|lead led led|lean leant/leaned leant/leaned|leap leapt/leaped leapt/leaped
learn learnt/learned learnt/learned|leave left left|lend lent lent|let let let|lie lay lain|light lit lit
lose lost lost|make made made|mean meant meant|meet met met|mistake mistook mistaken|pay paid paid
prove proved proven/proved|put put put|quit quit quit|read read read|ride rode ridden|ring rang rung
rise rose risen|run ran run|say said said|see saw seen|seek sought sought|sell sold sold|send sent sent
set set set|sew sewed sewn|shake shook shaken|shine shone shone|shoot shot shot|show showed shown
shrink shrank shrunk|shut shut shut|sing sang sung|sink sank sunk|sit sat sat|sleep slept slept|slide slid slid
smell smelt/smelled smelt/smelled|speak spoke spoken|speed sped sped|spell spelt/spelled spelt/spelled
spend spent spent|spill spilt/spilled spilt/spilled|spin spun spun|spit spat spat|split split split
spoil spoilt/spoiled spoilt/spoiled|spread spread spread|spring sprang sprung|stand stood stood|steal stole stolen
stick stuck stuck|sting stung stung|stink stank stunk|strike struck struck|swear swore sworn|sweep swept swept
swim swam swum|swing swung swung|take took taken|teach taught taught|tear tore torn|tell told told
think thought thought|throw threw thrown|understand understood understood|undertake undertook undertaken
upset upset upset|wake woke woken|wear wore worn|weave wove woven|weep wept wept|win won won|wind wound wound
withdraw withdrew withdrawn|write wrote written|overcome overcame overcome|undergo underwent undergone
"""


def regular_candidates(w):
    """Possible -s/-ed/-ing forms of an English word, with their codes; CMUdict decides which exist."""
    out = [(w + "s", "3sg|pl"), (w + "es", "3sg|pl"), (w + "ed", "past|pp"), (w + "d", "past|pp"), (w + "ing", "ing")]
    if w.endswith("e"): out.append((w[:-1] + "ing", "ing"))
    if w.endswith("y") and len(w) > 2 and w[-2] not in "aeiou":
        out += [(w[:-1] + "ies", "3sg|pl"), (w[:-1] + "ied", "past|pp")]
    if len(w) >= 3 and w[-1] not in "aeiouwxy" and w[-2] in "aeiou" and w[-3] not in "aeiou":
        out += [(w + w[-1] + "ed", "past|pp"), (w + w[-1] + "ing", "ing")]
    return out


def english(raw_dir):
    entries, extra = ru_entries(raw_dir, "en")
    cmu = {}
    with open(os.path.join(raw_dir, "cmudict.dict"), encoding="utf-8") as f:
        for line in f:
            word, _, phones = line.partition(" ")
            phones = phones.split("#")[0].strip()
            if "(" not in word: cmu.setdefault(word, phones)
    forms, irr = {}, {}
    for row in filter(None, (r.strip() for r in re.split(r"[|\n]", EN_IRREGULAR))):
        base, past, pp = row.split()
        irr[base] = [past, pp]
        for p in past.split("/"): add_form(forms, p, base, "past")
        for p in pp.split("/"): add_form(forms, p, base, "pp")
    for word, es in entries.items():
        for e in es:
            for f, tags in e.pop("_forms"):
                if " " in word: continue
                code = "3sg" if "third-person" in tags else "past" if "past" in tags and "participle" not in tags \
                    else "pp" if "participle" in tags else "ing" if "gerund" in tags or "present" in tags \
                    else "pl" if "plural" in tags else None
                if code: add_form(forms, f, word, code)
        if " " in word or word not in cmu: continue  # obscure headwords ("walke") would claim real forms
        poses = {e["p"] for e in es}
        for cand, codes in regular_candidates(word):
            if cand in cmu:
                for code in codes.split("|"):
                    if (code == "pl" and "noun" in poses) or (code != "pl" and "verb" in poses):
                        add_form(forms, cand, word, code)
    for lemmas in forms.values():  # "walked" is walk + ed, not walke + d
        for lemma in [l for l in lemmas if any(l == m + l[-1] for m in lemmas)]:
            del lemmas[lemma]
    finished = finish_forms(forms, entries)
    # Pronunciation and syllables for every word we can show: headwords, their forms, form pages.
    words = set(entries) | set(finished)
    for w, e in extra.items():
        if w in words and w not in entries:
            entries[w] = [dict(e, p="form")]
    return {"entries": entries, "forms": finished, "irr": irr, "cmu": {w: cmu[w] for w in words if w in cmu}}


def write(data, path):
    raw = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE: what NSData.decompressed(using: .zlib) reads
    packed = c.compress(raw) + c.flush()
    with open(path, "wb") as f:
        f.write(packed)
    print(f"{path}: {len(data['entries'])} entries, {len(data['forms'])} forms, "
          f"{len(raw) / 1e6:.1f} MB json, {len(packed) / 1e6:.1f} MB packed")


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", default=os.path.expanduser("~/Library/Caches/Glosa/wiktionary-raw"),
                    help="folder with the three downloads: "
                         "https://kaikki.org/ruwiktionary/raw-wiktextract-data.jsonl.gz (as ru-raw.jsonl.gz), "
                         "https://kaikki.org/dictionary/Spanish/kaikki.org-dictionary-Spanish.jsonl.gz "
                         "(as en-wikt-spanish.jsonl.gz), "
                         "https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict")
    ap.add_argument("--out", default=os.path.join(here, "..", "Sources", "GlosaCore", "Resources"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    write(spanish(args.raw), os.path.join(args.out, "dict-es.json.deflate"))
    write(english(args.raw), os.path.join(args.out, "dict-en.json.deflate"))
