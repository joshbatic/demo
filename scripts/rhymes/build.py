#!/usr/bin/env python3
"""Builds the free rhyming dictionary on the website: hellodemo.app/rhymes/<word>/ for every common dictionary
word, an A-Z page per letter, the /rhymes/ home with a search box, and docs/sitemap.xml.

The rhymes come from the app's own dictionary (native/Demo/Resources/Rhymes.tsv, CMU pronunciations) with the
app's rules (engines.md §1): perfect rhymes share the stressed vowel and everything after it; near rhymes are
groups scoring 6 or more. Only real dictionary words show (the word library's list, native/Demo/Resources/Words.txt),
no slang and no rare words, sorted by syllables, then how common they are. Each page ends with a short line about
the app. Run it again after the dictionary changes:

    python3 scripts/rhymes/build.py
"""
import collections, html, json, os, shutil

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
res = os.path.join(root, 'native', 'Demo', 'Resources')
out = os.path.join(root, 'docs', 'rhymes')
SITE = 'https://hellodemo.app'
APP_STORE = 'https://apps.apple.com/app/id6825757339'
PAGE_TIER = 5          # words common enough to get a page (tiers 0-9, 0 most common)
SHOW_TIER = 7          # rhymes shown on a page (8-9 are rare)

VOW = set('AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW'.split())
CL = {'M': 'n', 'N': 'n', 'NG': 'n', 'P': 't', 'B': 't', 'T': 't', 'D': 't', 'K': 't', 'G': 't', 'F': 's', 'V': 's',
      'S': 's', 'Z': 's', 'SH': 's', 'ZH': 's', 'TH': 's', 'DH': 's', 'CH': 'c', 'JH': 'c', 'L': 'l', 'R': 'r',
      'HH': 'h', 'W': 'w', 'Y': 'w'}
VF = {'IH': 1, 'IY': 1, 'EH': 2, 'AE': 2, 'EY': 2, 'AA': 3, 'AO': 3, 'AH': 4, 'UH': 4, 'UW': 4, 'OW': 5, 'AW': 5,
      'AY': 6, 'OY': 7, 'ER': 8}


def score(a, b):
    """gscore: how near two rhyme parts are (6+ is a near rhyme)."""
    if sum(x in VOW for x in a) != sum(x in VOW for x in b):
        return 0
    ca = [x for x in a[1:] if x not in VOW]
    cb = [x for x in b[1:] if x not in VOW]
    if a[0] == b[0]:
        s = 4
    elif VF.get(a[0]) and VF.get(a[0]) == VF.get(b[0]):
        s = 2
    else:
        return 0
    if ca == cb:
        s += 4
    elif ''.join(CL.get(x, x) for x in ca) == ''.join(CL.get(x, x) for x in cb):
        s += 3
    elif ca and cb and ca[-1] == cb[-1]:
        s += 2
    if [x for x in a[1:] if x in VOW] == [x for x in b[1:] if x in VOW]:
        s += 1
    return s


def load():
    words, groups, keys = {}, [], []
    for line in open(os.path.join(res, 'Rhymes.tsv'), encoding='utf-8'):
        k, ws = line.rstrip('\n').split('\t', 1)
        gi = len(groups)
        g = []
        for t in ws.split(' '):
            f = ''
            if t and t[-1] in 'cs':
                f, t = t[-1], t[:-1]
            if len(t) < 3:
                continue
            w = t[:-2]
            words[w] = dict(g=gi, t=int(t[-2]), s=int(t[-1]), f=f)
            g.append(w)
        groups.append(g)
        keys.append(k.split('-'))
    dic = set()
    with open(os.path.join(res, 'Words.txt'), encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            w = line.split('\t', 1)[0]
            if ' ' in w:
                break
            dic.add(w)
    return words, groups, keys, dic


def main():
    words, groups, keys, dic = load()

    def ok(w):
        e = words.get(w)
        # a real word, not slang, not rare, not an abbreviation read letter by letter
        return e and w in dic and e['f'] != 's' and e['t'] <= SHOW_TIER and not (e['s'] >= 2 and len(w) <= e['s']) and len(w) > 1

    pages = sorted(w for w, e in words.items() if ok(w) and e['t'] <= PAGE_TIER and w.isalpha())
    have = set(pages)
    by_key = collections.defaultdict(list)
    for gi, k in enumerate(keys):
        by_key[len([x for x in k if x in VOW])].append(gi)

    def rhymes(w):
        e = words[w]
        gi = e['g']
        perfect = [x for x in groups[gi] if x != w and ok(x)]
        near = []
        nv = len([x for x in keys[gi] if x in VOW])
        for g in by_key[nv]:
            if g == gi:
                continue
            sc = score(keys[gi], keys[g])
            if sc >= 6:
                near += [(sc, words[x]['t'], x) for x in groups[g] if ok(x) and x != w]
        near.sort(key=lambda z: (-z[0], z[1], z[2]))
        perfect.sort(key=lambda x: (words[x]['s'], words[x]['t'], x))
        return perfect, [x for _, _, x in near[:60]]

    def link(x):
        return f'<a href="/rhymes/{x}/">{x}</a>' if x in have else f'<span>{x}</span>'

    def by_syl(ws):
        d = collections.OrderedDict()
        for x in sorted(ws, key=lambda x: (words[x]['s'], words[x]['t'], x)):
            n = words[x]['s']
            d.setdefault(min(n, 4), []).append(x)
        return d

    head = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{url}">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="/icon-192.png">
<link rel="stylesheet" href="/styles.css">
<link rel="stylesheet" href="/rhymes/rhymes.css">
</head>
<body>
<div class="nav">
  <a class="brand" href="/"><img src="/icon-192.png" alt=""><b>*[demo]</b></a>
  <div class="navlinks"><a href="/rhymes/">Rhymes</a><a href="{store}">Get the app</a></div>
</div>
<main class="wrap rh">
'''
    cta = f'''<div class="rhcta">
  <b>Rhymes as you write</b>
  <p>*[demo] is a songwriting app that shows rhymes, syllables and ideas for the word you’re on, right above the keyboard, with your voice memos and demos in the same place.</p>
  <div class="rhbtns"><a class="go" href="{APP_STORE}">Download on the App Store</a><a class="alt" href="/app/">Open in your browser</a></div>
</div>
'''
    foot = '''</main>
<footer>
  <span>© 2026 *[demo]</span>
  <nav class="links"><a href="/rhymes/">Rhyming dictionary</a><a href="/privacy.html">Privacy</a><a href="/terms.html">Terms</a></nav>
</footer>
</body>
</html>
'''
    syl_name = {1: '1 syllable', 2: '2 syllables', 3: '3 syllables', 4: '4 or more syllables'}

    if os.path.isdir(out):
        for n in os.listdir(out):
            p = os.path.join(out, n)
            if os.path.isdir(p):
                shutil.rmtree(p)
    os.makedirs(out, exist_ok=True)

    urls = []
    for i, w in enumerate(pages):
        perfect, near = rhymes(w)
        e = words[w]
        top = (perfect + near)[:4]
        desc = (f'Words that rhyme with {w}' + (f': {", ".join(top)} and more' if top else '')
                + ', sorted by syllables, with near rhymes. A free rhyming dictionary for songwriters from *[demo].')
        body = [f'<p class="rhcrumb"><a href="/rhymes/">Rhyming dictionary</a> › <a href="/rhymes/{w[0]}/">{w[0].upper()}</a></p>',
                f'<h1>Words that rhyme with {html.escape(w)}</h1>',
                f'<p class="rhsub">{e["s"]} syllable{"s" if e["s"] != 1 else ""}. '
                f'{len(perfect)} perfect rhyme{"s" if len(perfect) != 1 else ""}, {len(near)} near.</p>']
        if perfect:
            body.append('<h2>Perfect rhymes</h2>')
            for n, ws in by_syl(perfect).items():
                body.append(f'<h3>{syl_name[n]}</h3><p class="rhw">' + ' '.join(link(x) for x in ws) + '</p>')
        else:
            body.append('<h2>Perfect rhymes</h2><p class="rhnone">No common words rhyme perfectly with this one. Try a near rhyme below.</p>')
        if near:
            body.append('<h2>Near rhymes</h2><p class="rhnote">Close in sound: the same vowel, with a similar ending.</p>')
            for n, ws in by_syl(near).items():
                body.append(f'<h3>{syl_name[n]}</h3><p class="rhw">' + ' '.join(link(x) for x in ws) + '</p>')
        nb = pages[max(0, i - 6):i] + pages[i + 1:i + 7]
        body.append(cta)
        body.append('<h2 class="rhmoreh">More rhymes</h2><p class="rhw rhmore">' + ' '.join(link(x) for x in nb) + '</p>')
        url = f'{SITE}/rhymes/{w}/'
        d = os.path.join(out, w)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(head.format(title=f'Words that rhyme with {w} | Rhymes for songwriters', desc=html.escape(desc),
                                url=url, store=APP_STORE) + '\n'.join(body) + '\n' + foot)
        urls.append(url)

    # A-Z
    letters = collections.OrderedDict()
    for w in pages:
        letters.setdefault(w[0], []).append(w)
    for L, ws in letters.items():
        d = os.path.join(out, L)
        os.makedirs(d, exist_ok=True)
        body = [f'<p class="rhcrumb"><a href="/rhymes/">Rhyming dictionary</a></p>',
                f'<h1>Rhymes for words starting with {L.upper()}</h1>',
                '<p class="rhaz">' + ' '.join(f'<a href="/rhymes/{x}/">{x.upper()}</a>' for x in letters) + '</p>',
                '<p class="rhw">' + ' '.join(f'<a href="/rhymes/{x}/">{x}</a>' for x in ws) + '</p>', cta]
        with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(head.format(title=f'Rhymes for words starting with {L.upper()} | Rhyming dictionary',
                                desc=f'Find rhymes for {len(ws)} words starting with {L.upper()}, sorted by syllables. A free rhyming dictionary for songwriters from *[demo].',
                                url=f'{SITE}/rhymes/{L}/', store=APP_STORE) + '\n'.join(body) + '\n' + foot)
        urls.append(f'{SITE}/rhymes/{L}/')

    # home: search, popular words, A-Z
    # the words songs keep coming back to
    SONG = ('love heart night light time life mind soul fire rain home alone gone cry eyes way day free dream sky feel real '
            'away stay go know show hold cold gold old young run sun fall call wall tonight forever never together '
            'again pain change strange tears years fear lie lies tried die high fly blue true you me tell well hell '
            'kiss miss lost cross break heartbreak shake wake fake money honey baby crazy lonely only start apart dark '
            'heaven seven moon soon road alive fight right wrong song strong long burn turn learn back black ride side '
            'face place space down town around ground sound found summer river water ocean shine line mine wine').split()
    popular = [w for w in dict.fromkeys(SONG) if w in have]
    with open(os.path.join(out, 'words.json'), 'w', encoding='utf-8') as f:
        json.dump(pages, f, separators=(',', ':'))
    body = ['<h1>Rhyming dictionary for songwriters</h1>',
            f'<p class="rhsub">Rhymes for {len(pages):,} words, sorted by syllables, with near rhymes. From the dictionary inside *[demo].</p>',
            '<form class="rhfind" id="find" role="search"><label for="q" class="vh">Word to rhyme</label>'
            '<input id="q" name="q" placeholder="Type a word" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="go">'
            '<button type="submit">Find rhymes</button></form><p class="rhnone" id="miss" hidden></p>',
            '<h2>Popular</h2><p class="rhw">' + ' '.join(f'<a href="/rhymes/{x}/">{x}</a>' for x in popular) + '</p>',
            '<h2>A to Z</h2><p class="rhaz">' + ' '.join(f'<a href="/rhymes/{x}/">{x.upper()}</a>' for x in letters) + '</p>',
            cta,
            '''<script>
(function(){var W=null,f=document.getElementById('find'),q=document.getElementById('q'),m=document.getElementById('miss');
fetch('/rhymes/words.json').then(function(r){return r.json()}).then(function(a){W={};a.forEach(function(w){W[w]=1})}).catch(function(){});
f.onsubmit=function(e){e.preventDefault();var w=(q.value||'').toLowerCase().replace(/[^a-z]/g,'');if(!w)return;
if(!W||W[w]){location.href='/rhymes/'+w+'/';return}
m.hidden=false;m.textContent='There’s no page for “'+w+'” yet. *[demo] has rhymes for 68,000 words: try it in the app.'}})();
</script>''']
    with open(os.path.join(out, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(head.format(title='Rhyming dictionary for songwriters | *[demo]',
                            desc=f'Free rhyming dictionary for songwriters: rhymes for {len(pages):,} words, sorted by syllables, with near rhymes.',
                            url=f'{SITE}/rhymes/', store=APP_STORE) + '\n'.join(body) + '\n' + foot)
    urls.insert(0, f'{SITE}/rhymes/')

    # sitemap for the whole site
    site = [f'{SITE}/', f'{SITE}/mac.html', f'{SITE}/privacy.html', f'{SITE}/terms.html'] + urls
    with open(os.path.join(root, 'docs', 'sitemap.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n')
        for u in site:
            f.write(f'<url><loc>{u}</loc></url>\n')
        f.write('</urlset>\n')
    print(f'{len(pages)} word pages, {len(letters)} letter pages')


if __name__ == '__main__':
    main()
