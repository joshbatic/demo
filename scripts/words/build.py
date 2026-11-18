#!/usr/bin/env python3
"""Builds *[demo]'s built-in word library from free, open data. Run from the repo root:

    pip install cmudict nltk wordfreq
    NLTK_ALLOW_PROXIED_URLOPEN=1 python3 scripts/words/build.py      # (the env var only matters behind a proxy)

It writes, in place:
  - the rhyme dictionary: `var DATA=` in www/index.html and native/Demo/Resources/Rhymes.tsv (same text)
  - the word file: docs/data/words-v1.txt (the web and Mac app fetch it once and keep it) and
    native/Demo/Resources/Words.txt (bundled with the iPhone app)

Sources (see scripts/words/LICENSES.md):
  - CMU Pronouncing Dictionary: pronunciations, so rhymes and syllables
  - Princeton WordNet 3.0 (via NLTK): synonyms, related words, opposites, definitions, phrases
  - wordfreq: how common each word is (only used to order words, 0 = most common ... 9 = rarest)

Rhyme dictionary format (unchanged, native/spec/engines.md §1.2): one line per rhyme group,
`KEY \\t word<tier><syllables>[flag] ...`, KEY = the phones from the last stressed vowel to the end.
Every word already in the dictionary keeps its group, tier, syllables and flag; groups keep their line
numbers, and new groups go on the end, so nothing that worked before changes.

Word file format (docs/data/words-v1.txt), plain text:
  line 1:      #words-v1 <W> <G>
  next W lines: word \t synonyms \t related \t opposites \t definitions   (empty fields allowed)
  last G lines: the definitions themselves, one per line
Words are sorted (single words a-z, then phrases a-z, plain character order, so lookups binary-search) and numbered from 0; the three lists are
those numbers in base 36, comma-separated, most useful first. Definitions are a part-of-speech letter
(n noun, v verb, a adjective, r adverb) and the definition's number in base 36, e.g. "n1c,v2f".
Phrases (more than one word) are words of their own, so they can be looked up and used as rhymes.
"""
import re, sys, os, collections

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
HTML = os.path.join(ROOT, 'www', 'index.html')
TSV = os.path.join(ROOT, 'native', 'Demo', 'Resources', 'Rhymes.tsv')
WEB_WORDS = os.path.join(ROOT, 'docs', 'data', 'words-v1.txt')
APP_WORDS = os.path.join(ROOT, 'native', 'Demo', 'Resources', 'Words.txt')

import cmudict
import nltk
try:
    from nltk.corpus import wordnet as wn
    wn.synsets('test')
except LookupError:
    nltk.download('wordnet', quiet=True)
    from nltk.corpus import wordnet as wn
from wordfreq import zipf_frequency

# ---------- the rhyme dictionary ----------

def zipf(w):
    return zipf_frequency(w, 'en')

def tier(z):
    """The tiers the dictionary already uses: 0 for zipf >= 6, then a step every half point, 9 below 2."""
    if z >= 6: return 0
    for t, lo in enumerate([5.5, 5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0], start=1):
        if z >= lo: return t
    return 9

strip = lambda p: re.sub(r'\d', '', p)

def rhyme_key(ph):
    """From the last vowel with primary or secondary stress to the end (any vowel if none is stressed)."""
    for i in range(len(ph) - 1, -1, -1):
        if ph[i][-1] in '12': return '-'.join(strip(p) for p in ph[i:])
    for i in range(len(ph) - 1, -1, -1):
        if ph[i][-1].isdigit(): return '-'.join(strip(p) for p in ph[i:])
    return None

def syllables(ph):
    return sum(1 for p in ph if p[-1].isdigit())

def is_wordnet(w):
    return bool(wn.synsets(w)) or bool(wn.morphy(w))

def build_rhymes():
    src = open(HTML, encoding='utf-8').read()
    start = src.index('var DATA=`') + len('var DATA=`')
    end = src.index('`;', start)
    old = src[start:end].strip('\n').split('\n')

    keys, groups, known = [], [], set()
    for line in old:
        k, toks = line.split('\t')
        keys.append(k)
        groups.append(toks.split(' '))
        for t in toks.split(' '):
            if t[-1] in 'cs': t = t[:-1]
            known.add(t[:-2])
    index = {k: i for i, k in enumerate(keys)}

    cmu = cmudict.dict()
    added = collections.defaultdict(list)
    n_new = 0
    for w, prons in cmu.items():
        if w in known or not re.fullmatch(r'[a-z]+', w) or len(w) < 2 and w not in ('a', 'i', 'o'):
            continue
        z = zipf(w)
        # every real word WordNet knows (including plurals and verb forms); anything else only when it's
        # common enough to be a word people write rather than a rare surname or an abbreviation
        if not (is_wordnet(w) or z >= 2.0):
            continue
        ph = prons[0]
        k = rhyme_key(ph)
        if not k: continue
        s = min(9, max(1, syllables(ph)))
        added[k].append((tier(z), -z, w, s))
        n_new += 1

    for k, items in added.items():
        items.sort()
        toks = [f'{w}{t}{s}' for t, _, w, s in items]
        if k in index:
            g = groups[index[k]]
            # merge by tier, keeping the existing order within a tier
            def t_of(tok): return int((tok[:-1] if tok[-1] in 'cs' else tok)[-2])
            merged, a, b = [], 0, 0
            while a < len(g) or b < len(toks):
                if b >= len(toks) or (a < len(g) and t_of(g[a]) <= t_of(toks[b])):
                    merged.append(g[a]); a += 1
                else:
                    merged.append(toks[b]); b += 1
            groups[index[k]] = merged
        else:
            index[k] = len(keys)
            keys.append(k)
            groups.append(toks)

    text = '\n'.join(f'{k}\t{" ".join(g)}' for k, g in zip(keys, groups))
    src = src[:start] + text + src[end:]
    open(HTML, 'w', encoding='utf-8').write(src)
    open(TSV, 'w', encoding='utf-8').write(text + '\n')
    total = sum(len(g) for g in groups)
    print(f'rhymes: {total} words ({n_new} new) in {len(keys)} groups, {len(text) // 1024} KB')
    return cmu

# ---------- synonyms, related words, opposites, definitions ----------

# a sense that lists any of these is the crude one ("love" = have sex): it keeps its definition, but its words
# stay out of the synonym and related lists (explicit words in rhymes are flagged and filtered separately)
CRUDE = set('fuck fucking shag bonk eff frig cunt prick dick cock pussy twat bollocks arse shit crap bullshit piss '
            'asshole bitch bastard motherfucker tit tits boob boobs knockers jism jizz wank'.split())

POS = {'n': 'n', 'v': 'v', 'a': 'adj', 's': 'adj', 'r': 'adv'}
CAP = {'syn': 40, 'rel': 30, 'ant': 20, 'def': 6}

def name(l):
    return l.name().replace('_', ' ').lower()

def clean(x):
    return bool(re.fullmatch(r"[a-z][a-z' -]*", x)) and '|' not in x

def senses(w):
    """The word's own senses (exact spelling, not its base form), most used first across every part of speech."""
    key = w.replace(' ', '_')
    out = []
    for ss in wn.synsets(key):
        for l in ss.lemmas():
            if l.name().lower() == key:
                out.append((ss, l))
                break
    order = {id(x): i for i, x in enumerate(out)}
    return sorted(out, key=lambda sl: (-sl[1].count(), order[id(sl)]))

def tidy(g):
    """WordNet glosses lose their quoted examples, leaving "; ; - Author" behind: tidy that away."""
    g = re.sub(r'\s*;\s*-\s*[A-Z][^;]*$', '', g.strip())
    g = re.sub(r'(\s*;\s*)+(?=;|$)', '', g)
    g = re.sub(r'\s*;\s*;', ';', g).strip(' ;')
    return g.replace('|', ',').replace('\t', ' ').replace('\n', ' ')

def everyday_first(lst):
    """Keep WordNet's sense order, but let common single words come before rare words and phrases."""
    def band(x):
        if ' ' in x or '-' in x: return 2
        z = zipf(x)
        return 0 if z >= 3.0 else 1 if z >= 2.0 else 2
    return sorted(lst, key=band)

def build_words():
    syn, rel, ant, dfs = (collections.defaultdict(list) for _ in range(4))

    def add(table, w, x, cap):
        lst = table[w]
        if x != w and clean(x) and x not in lst and len(lst) < cap * 2:
            lst.append(x)

    order = sorted({name(l) for ss in wn.all_synsets() for l in ss.lemmas()})
    order = [w for w in order if clean(w)]
    for w in order:
        for ss, l in senses(w):
            pos = POS[ss.pos()]
            gloss = tidy(ss.definition())
            # crude senses ("love" = have sex) are kept as definitions but don't fill the word lists
            crude = (any(d.name().split('.')[0] in ('obscenity', 'vulgarism') for d in ss.usage_domains())
                     or any(name(x) in CRUDE for x in ss.lemmas()))
            if crude:
                if len(dfs[w]) < CAP['def'] and gloss and (pos, gloss) not in dfs[w]: dfs[w].append((pos, gloss))
                continue
            for x in ss.lemmas(): add(syn, w, name(x), CAP['syn'])
            for s2 in ss.similar_tos():
                for x in s2.lemmas(): add(syn, w, name(x), CAP['syn'])
            for d in l.derivationally_related_forms(): add(rel, w, name(d), CAP['rel'])
            for r in (ss.hypernyms() + ss.instance_hypernyms() + ss.hyponyms()[:8] + ss.part_holonyms() + ss.member_holonyms()
                      + ss.substance_holonyms() + ss.part_meronyms() + ss.member_meronyms() + ss.substance_meronyms()
                      + ss.also_sees() + ss.attributes() + ss.entailments() + ss.causes() + ss.topic_domains()):
                for x in r.lemmas(): add(rel, w, name(x), CAP['rel'])
            for a in l.antonyms(): add(ant, w, name(a), CAP['ant'])
            # opposites through near-synonyms
            for s2 in ss.similar_tos():
                for l2 in s2.lemmas():
                    for a in l2.antonyms(): add(ant, w, name(a), CAP['ant'])
            if len(dfs[w]) < CAP['def'] and gloss and (pos, gloss) not in dfs[w]:
                dfs[w].append((pos, gloss))
        for t, k in ((syn, 'syn'), (rel, 'rel'), (ant, 'ant')):
            if w in t: t[w] = everyday_first(t[w])[:CAP[k]]

    # each gloss is stored once (a sense is shared by all its words) and referred to by number,
    # and so is every word in the lists, which keeps the file a third of the size
    # single words a-z, then phrases a-z: both sorted plainly, so the app can binary-search the file as it is
    words = sorted(order, key=lambda w: (' ' in w, w))
    words = [w for w in words if w in dfs]
    idx = {w: i for i, w in enumerate(words)}
    b36 = lambda n: _b36(n)
    gl, gid = [], {}
    def g_of(t):
        if t not in gid: gid[t] = len(gl); gl.append(t)
        return gid[t]
    def refs(lst, skip=()):
        return ','.join(b36(idx[x]) for x in lst if x in idx and x not in skip)
    lines = []
    for w in words:
        s = syn.get(w, [])
        r = refs(rel.get(w, []), set(s))
        d = ','.join(f'{PL[p]}{b36(g_of(t))}' for p, t in dfs.get(w, []))
        lines.append(f'{w}\t{refs(s)}\t{r}\t{refs(ant.get(w, []))}\t{d}')
    text = f'#words-v1 {len(lines)} {len(gl)}\n' + '\n'.join(lines) + '\n' + '\n'.join(gl) + '\n'
    os.makedirs(os.path.dirname(WEB_WORDS), exist_ok=True)
    for p in (WEB_WORDS, APP_WORDS):
        open(p, 'w', encoding='utf-8').write(text)
    print(f'words: {len(lines)} entries ({sum(1 for w in words if " " in w)} phrases), {len(gl)} definitions, {len(text) // 1024} KB')

PL = {'n': 'n', 'v': 'v', 'adj': 'a', 'adv': 'r'}

def _b36(n):
    d = '0123456789abcdefghijklmnopqrstuvwxyz'
    s = ''
    while True:
        s = d[n % 36] + s
        n //= 36
        if not n: return s

if __name__ == '__main__':
    build_rhymes()
    build_words()
