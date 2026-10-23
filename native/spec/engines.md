# *[demo] — Client engines spec (rhymes, AI, Clean up, lyric sync, live merge)

Source: `www/index.html`, build `9adeae1` (APP_SEQ 413). Line numbers refer to that file. Code blocks marked
"verbatim" are copied byte-for-byte from the source by line range (generated, not retyped), so prompt text, regexes
and constants are exact. Lines are long minified JS; read them as reference implementations to port.

Contents
1. Rhyme engine (built-in dictionary, lookups, perfect/near, syllables, rhyme map, Datamuse, offline)
2. AI features (routing, consent, every prompt, parsing, caching, learning loops)
3. Text utilities: Clean up, case detection, section tags, chords, import parsing
4. Lyric sync (Whisper words → line timestamps)
5. Live co-writing text merge
6. Small client renderers worth porting exactly (generated covers, waveform peaks, share palette)

---

## 1. Rhyme engine

### 1.1 Where the data lives

- One JS template literal: `var DATA=\`` starts on **line 1643** and the closing `` `; `` is at the end of **line
  15083** (the last entry is `AH-S-IH-N\tbussin52s`). Immediately after it, line 15084 is the comment
  `/* git commit this build came from … */` and 15085 `var APP_COMMIT=…`.
- **13,441 lines** (one per rhyme group), **45,230 words** (each word appears exactly once — one pronunciation per word),
  ~674 KB of text. Largest group: 717 words.
- There are no other embedded dictionaries: no definitions, synonyms or phrase tables ship in the file. Those come from
  Datamuse or the AI. (The other big blobs are the splash PNGs on line 1211 and the lamejs encoder, 1307–1614.)

### 1.2 Format (exact parsing rules)

Each line: `KEY \t TOKEN( TOKEN)*`

- **KEY** = the word's rhyme part in CMU/ARPAbet phones, from its **last stressed vowel to the end**, stress digits
  removed, joined with `-`. Examples: `AY-P` (type, pipe), `EY-SH-AH-N` (information, education…), `IH-N` (in, been,
  within…). Phone set: vowels `AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW`, consonants
  `B CH D DH F G HH JH K L M N NG P R S SH T TH V W Y Z ZH`. Keys are unique.
- **TOKEN** = `word` + `T` + `S` + optional `F`, where
  - `word`: lowercase `[a-z']+` (in practice only `[a-z]`; apostrophes were removed: `yall`, `aint`, `dont`),
  - `T`: one digit 0–9, **frequency tier** (0 = most common; distribution 0:102, 1:179, 2:739, 3:1779, 4:3554,
    5:6163, 6:9478, 7:11306, 8:8262, 9:3668),
  - `S`: one digit 1–8, **syllable count**,
  - `F`: optional flag letter — `s` = slang/explicit (29 words: bruh, bae, shit, bullshit, lit, lowkey, highkey, slay,
    bitch, fam, dope, fuck, fucking, yeet, tryna, swag, fucked, vibe, vibes, asshole, shawty, bitches, fucker,
    motherfucker, homie, ima, imma, finna, bussin), `c` = colloquial/contraction (21: cause, yall, yo, dunno, til,
    bout, em, cuz, nope, yeah, gonna, wanna, yep, ya, nah, gotta, kinda, aint, gimme, lemme, sorta).
- Within a line, tokens are ordered by tier ascending (most common first). Line order is not meaningful except that the
  line index is the group id.
- Parse (verbatim, line 15595): if the token ends in `c` or `s`, strip it as the flag; then `word = token[0..-2]`,
  `t = token[-2]`, `s = token[-1]`.

**Extracting to a separate file for the native app**: take everything between the first backtick after `var DATA=`
and the backtick before `;` that precedes `/* git commit this build came from`. Don't rely on line numbers across
builds; use the markers:

```python
import re
src = open('www/index.html', encoding='utf-8').read()
start = src.index('var DATA=`') + len('var DATA=`')
end = src.index('`;', start)            # first closing backtick after the start
data = src[start:end]                   # 13,441 lines "KEY\tword<t><s>[f] ..."
open('Rhymes.tsv', 'w', encoding='utf-8').write(data + '\n')
```

Suggested native representation: ship `Rhymes.tsv` (≈0.67 MB, compresses to ~200 KB) or pre-build a SQLite/binary
table `words(word TEXT PRIMARY KEY, group INT, tier INT, syl INT, flag CHAR)` + `groups(id INT, key TEXT)`.
Parsing 45 k tokens at launch takes <50 ms in Swift; build the derived structures lazily.

### 1.3 Derived structures (built once at startup)

Verbatim, lines 15591–15622:

<!-- verbatim index.html lines 15591-15622 -->
```js
/* ---------- phonetic rhyme engine (CMU pronunciations, built in) ---------- */
var KEYS=[],GRP=[],W={},NG={},NK=[],SC={},ALLW=[];
var VOW={AA:1,AE:1,AH:1,AO:1,AW:1,AY:1,EH:1,ER:1,EY:1,IH:1,IY:1,OW:1,OY:1,UH:1,UW:1};
var CL={M:'n',N:'n',NG:'n',P:'t',B:'t',T:'t',D:'t',K:'t',G:'t',F:'s',V:'s',S:'s',Z:'s',SH:'s',ZH:'s',TH:'s',DH:'s',CH:'c',JH:'c',L:'l',R:'r',HH:'h',W:'w',Y:'w'};
DATA.split('\n').forEach(function(l,gi){var p=l.split('\t');KEYS.push(p[0]);var ws=[];p[1].split(' ').forEach(function(x){var f='';if(/[cs]$/.test(x)){f=x.slice(-1);x=x.slice(0,-1)}var w=x.slice(0,-2);W[w]={k:gi,t:+x.charAt(x.length-2),s:+x.slice(-1),f:f};ws.push(w);ALLW.push(w)});GRP.push(ws);
  var t=p[0].split('-'),nk=t[0]+'|'+t.slice(1).map(function(q){return VOW[q]?'@':CL[q]||q}).join('');(NG[nk]=NG[nk]||[]).push(gi);NK[gi]=nk});
ALLW.sort(function(a,b){return W[a].t-W[b].t});
function nw(w){return(w||'').toLowerCase().replace(/[^a-z]/g,'')}
function hsyl(w){if(w.length<=3)return 1;w=w.replace(/(?:[^laeiouy]es|[^td]ed|[^laeiouy]e)$/,'').replace(/^y/,'');var m=w.match(/[aeiouy]{1,2}/g);return m?m.length:1}
function syl(w){w=nw(w);if(!w)return 0;if(W[w])return W[w].s;return hsyl(w)}
function lsyl(l){return(l.match(/[A-Za-z']+/g)||[]).reduce(function(a,w){return a+syl(w)},0)}
function guess(w){var best=null,bl=1;for(var i=0;i<ALLW.length;i++){var x=ALLW[i],l=0;while(l<w.length&&l<x.length&&w[w.length-1-l]===x[x.length-1-l])l++;if(l>bl){bl=l;best=x}}return best?W[best].k:null}
var TK=KEYS.map(function(k){return k.split('-')}),VF={IH:1,IY:1,EH:2,AE:2,EY:2,AA:3,AO:3,AH:4,UH:4,UW:4,OW:5,AW:5,AY:6,OY:7,ER:8};
function isV(x){return!!VOW[x]}
function cls(a){return a.map(function(x){return CL[x]||x}).join('')}
function gscore(a,b){
  var s=0,ca=a.slice(1).filter(function(x){return!isV(x)}),cb=b.slice(1).filter(function(x){return!isV(x)});
  if(a.filter(isV).length!==b.filter(isV).length)return 0;
  if(a[0]===b[0])s+=4;else if(VF[a[0]]&&VF[a[0]]===VF[b[0]])s+=2;else return 0;
  if(ca.join('-')===cb.join('-'))s+=4;else if(cls(ca)===cls(cb))s+=3;else if(ca.length&&cb.length&&ca[ca.length-1]===cb[cb.length-1])s+=2;
  if(a.slice(1).filter(isV).join()===b.slice(1).filter(isV).join())s+=1;
  return s;
}
function rsets(w){
  w=nw(w);if(SC[w])return SC[w];var gi=W[w]?W[w].k:guess(w),p=[],n=[];
  if(gi!=null){p=GRP[gi].filter(function(x){return x!==w});
    var sc=[];for(var g=0;g<TK.length;g++){if(g===gi)continue;var s=gscore(TK[gi],TK[g]);if(s>=6)sc.push([g,s])}
    sc.forEach(function(e){GRP[e[0]].forEach(function(x){n.push([x,e[1]])})});
    n.sort(function(a,b){return b[1]-a[1]||W[a[0]].t-W[b[0]].t});
    n=n.slice(0,500).map(function(e){return e[0]}).filter(function(x){return x!==w})}
  return SC[w]={gi:gi,p:p,n:n};
}
```

- `W[word] = {k: groupIndex, t: tier, s: syllables, f: flag}`
- `GRP[gi]` = words of group gi (tier order); `KEYS[gi]` = key; `TK[gi]` = key split into phones.
- `ALLW` = every word sorted by tier (stable), used by `guess()`.
- `NG/NK` ("near key": first phone + rest with vowels → `@` and consonants → class letter via `CL`) are built but
  **unused** by the current code (left from an older near-rhyme method). You can skip them.
- `CL` consonant classes: nasals `n` (M N NG), stops `t` (P B T D K G), fricatives `s` (F V S Z SH ZH TH DH),
  affricates `c` (CH JH), `l`, `r`, `h`, glides `w` (W Y).
- `VF` vowel families: 1 {IH IY}, 2 {EH AE EY}, 3 {AA AO}, 4 {AH UH UW}, 5 {OW AW}, 6 {AY}, 7 {OY}, 8 {ER}.

### 1.4 Word normalisation and lookup

- `nw(w)` = lowercase, remove everything except `a–z` (so "Don't" → "dont", "rock'n'roll" → "rocknroll").
- Lookup: `W[nw(w)]`. Unknown word → `guess(w)`: scan all 45 k words (tier order) for the longest common **suffix**
  with `w`; needs at least 2 matching trailing letters (`bl=1`, strictly greater wins, so earlier/more common words win
  ties); returns that word's group. Unknown with no ≥2-letter suffix match → no rhymes.
  *Native: precompute a reversed-word trie for `guess` instead of the linear scan.*

### 1.5 Perfect vs near rhymes — `rsets(w)` (cached per word in `SC`)

- **Perfect** `p` = all other words in the same group (same rhyme part), in tier order.
- **Near** `n`: compare the word's group key with **every other group** using `gscore(a,b)` (a,b = phone arrays):
  - 0 if the number of vowels differs;
  - first phone (the stressed vowel): identical +4, same vowel family `VF` +2, otherwise 0 (return);
  - consonants after the first phone (`ca`, `cb`): identical sequence +4, else same class sequence (`CL`) +3, else same
    final consonant +2;
  - remaining vowels (after the first) identical sequence +1.
  - Groups with score ≥6 qualify; every word of every qualifying group is listed with that score, sorted by score desc
    then tier asc, capped at **500**, the word itself removed.
- So near = "same stressed vowel and similar consonants" or "same vowel family with identical consonants", etc.

### 1.6 Register filter — `fl(list)` (verbatim, line 15633)

<!-- verbatim index.html lines 15633-15633 -->
```js
function fl(a){return a.filter(function(x){var f=W[x]&&W[x].f;return!f||(f==='c'&&PF.reg!=='Poetic')||(f==='s'&&(PF.reg==='Slang'||PF.reg==='Explicit'))})}
```

Flag `c` words are hidden only when Language = Poetic; flag `s` words are shown only when Language = Slang or Explicit.
Applied to both built-in and Datamuse results (Datamuse words aren't in `W` unless they are in the dictionary, so their
flags come from the dictionary only).

### 1.7 Syllable counting

Verbatim (part of the block above, lines 15598–15601):
- `syl(w)`: dictionary syllables if known, else `hsyl(w)` heuristic: words ≤3 letters = 1; strip a final
  `[^laeiouy]es`, `[^td]ed` or `[^laeiouy]e`, strip a leading `y`; count runs of 1–2 vowels `[aeiouy]{1,2}`; minimum 1.
- `lsyl(line)` = sum of `syl` over `[A-Za-z']+` tokens.
- Datamuse results carry `numSyllables`, remembered in `DMS[word]`; `sy(x)` = `DMS[x]` || (phrase ? `lsyl` : `syl`).
- Line counts used everywhere (rhyme bar "N syl", "N to match", Lines targets, syllable gutter, cover bar widths).

### 1.8 What word the bar targets — `ctx()` and rhyme schemes (verbatim 16526–16547)

<!-- verbatim index.html lines 16526-16547 -->
```js
function wordAt(l,c){var re=/[A-Za-z']+/g,m,b=null;while((m=re.exec(l))){var s=m.index,e=s+m[0].length;if(c>=s&&c<=e)return m[0];if(e<=c)b=m[0]}return b}
function lastW(l){var m=(l||'').match(/[A-Za-z']+/g);return m?m[m.length-1]:''}
/* stanza = the lines above the cursor back to the last blank line or [section] tag */
function stanzaOf(v,ls){var a=v.slice(0,ls).split('\n');a.pop();var o=[];for(var i=a.length-1;i>=0;i--){var s=a[i].trim();if(!s||s[0]==='[')break;o.unshift(a[i])}return o}
function endMatch(a,b){var x=nw(lastW(a)),y=nw(lastW(b));if(!x||!y)return false;if(x===y)return true;var S=rsets(x);return S.p.indexOf(y)>=0||S.n.indexOf(y)>=0}
function relIdx(s,q){return s==='AABB'?(q%2?q-1:-1):s==='ABAB'?(q>=2?q-2:-1):s==='ABBA'?(q===2?1:q===3?0:-1):s==='ABCB'?(q===3?1:-1):s==='AAAA'?(q>=1?q-1:-1):-1}
function autoS(st,q,base){
  var ex={ABAB:[[0,2],[1,3]],AABB:[[0,1],[2,3]],ABBA:[[1,2],[0,3]],ABCB:[[1,3]]},best='ABAB',bs=-1;
  Object.keys(ex).forEach(function(k){var sc=0;ex[k].forEach(function(p){var i=base+p[0],j=base+p[1];if(j<st.length&&endMatch(st[i],st[j]))sc++});if(sc>bs){bs=sc;best=k}});
  return best;
}
function ctx(){
  var ta=$('#lyr'),v=ta.value,a=ta.selectionStart,b=ta.selectionEnd,ls=v.lastIndexOf('\n',a-1)+1,le=v.indexOf('\n',a);if(le<0)le=v.length;
  var c=v.slice(ls,le),cl=c.trim()[0]==='['?'':c,st=stanzaOf(v,ls),p=st.length,q=p%4,base=p-q;
  var sch=scheme==='auto'?autoS(st,q,base):scheme,r=relIdx(sch,q),ti=r>=0?base+r:-1,tl=ti>=0?st[ti]:'';
  var sel=b>a?v.slice(a,b):'',word,via='';
  if(sel)word=lastW(sel);
  else if(cl.trim()){var end=ls+cl.replace(/\s+$/,'').length;if(a>=end&&tl){word=lastW(tl);via='line '+(ti+1)}else word=wordAt(cl,a-ls)}
  /* a fresh, empty line starts clean: no rhymes carried over from the line before until you type or tap a word
     (Lines still knows which line it should rhyme with, from tl/ti) */
  return{cur:cl,raw:c,ls:ls,le:le,sel:sel,word:word||'',st:st,p:p,sch:sch,ti:ti,tl:tl,via:via,ref:tl||st[p-1]||''};
}
```

- `stanzaOf(v, ls)` = lines above the caret line back to the previous blank line or `[tag]` line.
- Position in the stanza `p` (0-based), quatrain position `q = p % 4`, `base = p − q`.
- Scheme `scheme` (per song, `'auto'` default): auto picks the best of ABAB / AABB / ABBA / ABCB by counting existing
  line-end pairs that rhyme (`endMatch`: same last word, or last word in the other's perfect/near set). Ties keep the
  first (ABAB).
- `relIdx(scheme, q)` gives the earlier line in the quatrain that line q should rhyme with: AABB → q odd ? q−1;
  ABAB → q≥2 ? q−2; ABBA → q=2→1, q=3→0; ABCB → q=3→1; AAAA → q−1; else none.
- Target word: selection's last word; else if the caret is at/after the end of the line's text and there is a partner
  line → partner's last word (`via 'line N'`); else the word under the caret (`wordAt`: the `[A-Za-z']+` token
  containing the column, else the last token before it). Empty lines give no word.
- `ref` = partner line or previous stanza line — used for "N to match" (syllables).

### 1.9 Ordering of chips (verbatim 16604–16605)

<!-- verbatim index.html lines 16604-16605 -->
```js
  function order(a){var rare=function(x){var w=nw(x),e=W[w];return!!e&&(e.t>=8||(e.s>=2&&w.length<=e.s))};a=a.filter(function(x){return!rare(x)}).concat(a.filter(rare));
    if(!left)return a;var f=function(x){return sy(x)===left&&!rare(x)};return a.filter(f).concat(a.filter(function(x){return!f(x)}))}
```

"Rare" = tier ≥8, or an abbreviation read letter by letter (syllables ≥2 and word length ≤ syllables, e.g. "atm",
"mph"). Rare words go last; when the line needs exactly `left` more syllables, words with exactly that count (and not
rare) go first. Default caps: Rhymes = 40 perfect + 30 near (near dropped when "Perfect only"), Perfect = 40,
Near = 60; Dictionary 60/40 (Near 80).

### 1.10 Rhyme map colouring — `rmap()` (verbatim 17049–17079, includes STOP list and gutter)

<!-- verbatim index.html lines 17049-17079 -->
```js
var STOP={};'a an the and or but to of in on at by for with as is it its be am are was were i me my we us our you your he him his she her they them their this that these those so do did does not no just oh if then than from can will would could should have has had there what when where who how im ive id dont cant wont aint like'.split(' ').forEach(function(w){STOP[w]=1});
var rvT;function refreshViews(){clearTimeout(rvT);rvT=setTimeout(function(){rmap();gut();rateMarks();if(cur&&!cur.art)$('#cov').innerHTML=cover(cur)},140)}
function rmap(){
  if(!window.CSS||!CSS.highlights||!window.Highlight)return;for(var i=0;i<8;i++)CSS.highlights.delete('rm'+i);if(!VIEW.map||!cur)return;
  var v=getText(),tok=[],stz=0,pos=0;
  v.split('\n').forEach(function(l){var tr=l.trim();if(!tr||tr[0]==='['){stz++;pos+=l.length+1;return}var re=/[A-Za-z']+/g,m;while((m=re.exec(l))){var w=nw(m[0]);if(w.length>1&&!STOP[w])tok.push({w:w,a:pos+m.index,b:pos+m.index+m[0].length,s:stz})}pos+=l.length+1});
  /* Used to group only exact rhyme-family matches (same NK key) within a stanza — "time"/"mine"
     would light up together but "time"/"shine" (a near/slant rhyme, same as the word-tool's "Near"
     results, gscore>=6) never would. Near-rhyme pairs aren't one single family though, so within
     each stanza we union-find the rhyme-group indices actually present there whenever two score as
     a near rhyme, then group and color by the resulting merged set rather than the raw family key. */
  var byStanza={};
  tok.forEach(function(x){var S=rsets(x.w);if(S.gi==null)return;x.gi=S.gi;(byStanza[x.s]=byStanza[x.s]||[]).push(x)});
  var col={},ci=0,sets=[[],[],[],[],[],[],[],[]];
  Object.keys(byStanza).forEach(function(sk){
    var items=byStanza[sk],gis=[];items.forEach(function(x){if(gis.indexOf(x.gi)<0)gis.push(x.gi)});
    var parent={};gis.forEach(function(g){parent[g]=g});
    function find(g){while(parent[g]!==g){parent[g]=parent[parent[g]];g=parent[g]}return g}
    for(var i=0;i<gis.length;i++)for(var j=i+1;j<gis.length;j++)if(gscore(TK[gis[i]],TK[gis[j]])>=6){var ra=find(gis[i]),rb=find(gis[j]);if(ra!==rb)parent[ra]=rb}
    var grp={};items.forEach(function(x){var rk=find(x.gi);(grp[rk]=grp[rk]||[]).push(x)});
    Object.keys(grp).forEach(function(rk){var g=grp[rk],ws={};g.forEach(function(x){ws[x.w]=1});if(Object.keys(ws).length<2)return;var ck=sk+'|'+rk;if(col[ck]==null)col[ck]=(ci++)%8;
      g.forEach(function(x){var r=document.createRange(),p=locate(x.a),q=locate(x.b);r.setStart(p[0],p[1]);r.setEnd(q[0],q[1]);sets[col[ck]].push(r)})})
  });
  sets.forEach(function(rs,i){if(rs.length){var h=new Highlight();rs.forEach(function(r){h.add(r)});CSS.highlights.set('rm'+i,h)}});
}
function gut(){
  var g=$('#gut'),sc=$('#sc');g.innerHTML='';sc.classList.toggle('gu',VIEW.syl);if(!VIEW.syl||!cur)return;
  var v=getText(),pos=0,sr=sc.getBoundingClientRect(),st=sc.scrollTop;
  v.split('\n').forEach(function(l){var tr=l.trim();if(tr&&tr[0]!=='['){var lead=l.length-l.replace(/^\s+/,'').length,wl=(/^\S+/.exec(l.slice(lead))||[''])[0].length||1,p=locate(pos+lead),q=locate(pos+lead+wl),r=document.createRange();r.setStart(p[0],p[1]);r.setEnd(q[0],q[1]);var rc=Array.prototype.filter.call(r.getClientRects(),function(x){return x.width>0&&x.height>0})[0];
    if(rc&&rc.height){var s=document.createElement('span'),mm=melAt(pos),cn=lsyl(l);s.textContent=cn+(mm?'/'+mm.n:'');if(mm){var df=Math.abs(cn-mm.n);s.className=df===0?'ok':df===1?'o1':'o2';s.title=df?'Melody has '+mm.n+' syllables here':'Fits the melody'}s.style.top=(rc.top-sr.top+st)+'px';s.style.height=rc.height+'px';g.appendChild(s)}}pos+=l.length+1});
}
```

Algorithm:
1. Tokenise lyrics into words (`[A-Za-z']+`, normalised, length >1, not in `STOP`), tagging each with a **stanza index**
   that increments at every blank or `[tag]` line.
2. Map each token to its rhyme group `gi` via `rsets` (unknown words use `guess`).
3. Per stanza: union-find over the distinct groups present, merging two groups when `gscore ≥ 6` (near rhyme).
4. Each merged set with **≥2 distinct words** gets a colour index; colour indices are assigned in first-seen order
   across stanzas, cycling through 8 colours (`(ci++) % 8`), keyed by stanza+set (so the same sound in two stanzas can
   get different colours).
5. Colours (CSS 1078): `rgba(255,149,0,.30)`, `rgba(52,199,89,.28)`, `rgba(0,122,255,.24)`, `rgba(175,82,222,.26)`,
   `rgba(255,45,85,.24)`, `rgba(90,200,250,.34)`, `rgba(255,204,0,.38)`, `rgba(162,132,94,.32)` — background highlights
   behind the words (internal rhymes included, not only line ends).
Recomputed 140 ms after any edit. *Native: compute ranges on the plain text and apply as temporary attributes
(`NSLayoutManager`/TextKit 2 rendering attributes) so they never enter the stored rich text.*

### 1.11 Online: Datamuse (verbatim 16375–16394)

<!-- verbatim index.html lines 16375-16394 -->
```js
/* ---------- Datamuse rhymes (online), built-in dictionary as instant fallback ---------- */
var DMKEY='';/* Datamuse requires a key from 1 Jan 2027: paste it here */
var DM={},DMS={},dmFails=0,dmOff=false;
function sy(x){return DMS[x]||(x.indexOf(' ')>=0?lsyl(x):syl(x))}
function dmFetch(q){var c=new AbortController(),tm=setTimeout(function(){c.abort()},4000);
  return fetch('https://api.datamuse.com/words?'+q+(DMKEY?'&key='+encodeURIComponent(DMKEY):''),{signal:c.signal}).then(function(r){clearTimeout(tm);if(!r.ok)throw new Error(r.status);return r.json()})}
function dmRhymes(w){
  w=nw(w);if(!w||dmOff)return Promise.resolve(null);var d=DM[w];if(d)return d.then?d:Promise.resolve(d);
  var pr=Promise.all([dmFetch('rel_rhy='+w+'&md=sf&max=250'),dmFetch('rel_nry='+w+'&md=sf&max=150')]).then(function(r){
    dmFails=0;
    function fq(o){var g=(o.tags||[]).filter(function(x){return x.indexOf('f:')===0})[0];return g?parseFloat(g.slice(2)):0}
    function ok(o){var x=(o.word||'').toLowerCase();if(!/^[a-z' ]+$/.test(x)||x===w)return false;return x.indexOf(' ')>=0||fq(o)>=.08}
    function take(a){var one=[],many=[];a.filter(ok).forEach(function(o){var x=o.word.toLowerCase();DMS[x]=o.numSyllables||sy(x);(x.indexOf(' ')<0?one:many).push(x)});return one.concat(many)}
    var P=take(r[0]),seen={};P.forEach(function(x){seen[x]=1});
    var N=take(r[1]).filter(function(x){return!seen[x]});
    return DM[w]={p:P,n:N};
  }).catch(function(){delete DM[w];if(++dmFails>=2)dmOff=true;return null});
  DM[w]=pr;return pr;
}
function getR(w){var d=DM[nw(w)];if(d&&!d.then)return{src:'dm',p:fl(d.p),n:fl(d.n)};var S=rsets(w);return{src:'local',p:fl(S.p),n:fl(S.n)}}
```

- Endpoint `https://api.datamuse.com/words?<query>[&key=DMKEY]`, 4 s timeout. `DMKEY` is empty; comment: "Datamuse
  requires a key from 1 Jan 2027: paste it here".
- Rhymes: `rel_rhy=<w>&md=sf&max=250` (perfect) and `rel_nry=<w>&md=sf&max=150` (near) in parallel. Keep
  `^[a-z' ]+$`, not the word itself; multi-word items always kept, single words only if frequency tag `f:` ≥ 0.08;
  single words first then phrases; near excludes anything already in perfect. `numSyllables` cached.
- Word modes `DMQ` (16931): `syn → ml=`, `rel → rel_trg=`, `adj → rel_jjb=`, `ant → rel_ant=`, `snd → sl=`; each
  `&md=sf&max=60`, plus `&topics=<top 5 song words>` when "Listen to the whole song" is on (`topics()`: words >3 letters,
  not STOP, by frequency in the current lyrics). `phr` (Phrases) = the multi-word items from the rhyme queries.
- Define: `sp=<w>&md=d&max=1` → `defs` entries `"pos\ttext"`, up to 6.
- **Offline / failure**: any failure deletes that cache entry; **two consecutive failures set `dmOff = true` for the rest
  of the session** (no more network attempts; built-in dictionary only). Rhyme modes always render the built-in result
  immediately and swap to Datamuse when it arrives (only if the user is still on that word). `getR(w)` returns Datamuse
  sets when cached, else built-in, both through `fl()`.
- Without Datamuse and AI, meaning modes show "Meaning-based lists need a word database or a connection, and neither is
  reachable here."

---

## 2. AI features

### 2.1 Routing, model tiers, consent, parsing (verbatim 16431–16525)

<!-- verbatim index.html lines 16431-16525 -->
````js
function bakedOpenAICall(prompt,modelTier){
  if(!prompt)return Promise.reject(new Error('Empty prompt.'));
  if(prompt.length>24000)return Promise.reject(new Error('That request is too large to send ('+prompt.length+' characters, limit 24000).'));
  var g=bakedGuardCall();if(!g.ok)return Promise.reject(new Error(g.error));
  if(typeof CFG!=='undefined'&&CFG.ai_off)return Promise.reject(new Error(CFG_PAUSED.ai));
  var s=sbClient();
  if(s&&s.functions){
    return s.functions.invoke('ai-proxy',{body:{prompt:prompt,modelTier:modelTier}}).then(function(res){
      if(res.error){var msg=(res.error&&res.error.message)||'AI service error';throw new Error(msg)}
      if(res.data&&res.data.error)throw new Error(res.data.error);
      var text=(res.data&&res.data.text)||'';
      if(!text.trim())throw new Error('AI returned an empty response.');
      return text;
    });
  }
  if(BAKED_OPENAI_KEY){
    var model=modelTier==='complex'?'gpt-5':'gpt-5-mini',maxTokens=modelTier==='complex'?5000:2000,reasoningEffort=modelTier==='complex'?'medium':'minimal',timeoutMs=modelTier==='complex'?110000:45000;
    var payload={model:model,messages:[{role:'user',content:prompt}],max_completion_tokens:maxTokens};
    if(reasoningEffort)payload.reasoning_effort=reasoningEffort;
    var c=new AbortController(),tm=setTimeout(function(){c.abort()},timeoutMs);
    return fetch('https://api.openai.com/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+BAKED_OPENAI_KEY},body:JSON.stringify(payload),signal:c.signal}).then(function(r){
      return r.text().then(function(body){
        clearTimeout(tm);
        var j;try{j=JSON.parse(body)}catch(e){}
        if(!r.ok){var msg=(j&&j.error&&j.error.message)||('HTTP '+r.status);throw new Error(msg)}
        var choice=j.choices&&j.choices[0],text=(choice&&choice.message&&choice.message.content)||'';
        if(!text.trim()){if(choice&&choice.finish_reason==='length')throw new Error('OpenAI ran out of tokens before answering (hit the length limit).');throw new Error('OpenAI returned an empty response.')}
        return text
      })
    },function(e){clearTimeout(tm);throw new Error(e&&e.name==='AbortError'?'Timed out reaching OpenAI':String((e&&e.message)||e))})
  }
  return Promise.reject(new Error('AI service not configured.'));
}
function aiAvailable(){return oaiReady||!!sampleFn||(!!window.supabase&&!!window.supabase.createClient)||!!BAKED_OPENAI_KEY}
function parseAIJson(text){
  text=(text||'').trim();
  try{return JSON.parse(text)}catch(e){}
  var m=text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if(m){try{return JSON.parse(m[1].trim())}catch(e){}}
  var s=text.search(/[\[{]/),en=Math.max(text.lastIndexOf('}'),text.lastIndexOf(']'));
  if(s>=0&&en>s){try{return JSON.parse(text.slice(s,en+1))}catch(e){}}
  throw new Error('Could not parse response as JSON');
}
/* ---------- permission before anything goes to an AI provider (App Store guideline 5.1.2(i)) ----------
   The first time someone taps an AI feature, a card names the provider and what's sent, with Allow / Not Now.
   Background requests (the muse learning your style, judging candidates) never ask: they only run once allowed.
   Turn it on or off any time in Account › AI Features. Stored per device. */
/* ---------- native iPhone alerts and action sheets (@capacitor/dialog, @capacitor/action-sheet) ----------
   On iPhone, questions use the system alert and destructive choices the system action sheet (red button,
   Cancel underneath). On the Mac and the web, or before the plugins are installed, each caller keeps its
   in-app version: these return null there. */
function natPlug(n){var C=window.Capacitor;try{return C&&C.isNativePlatform&&C.isNativePlatform()&&(!C.getPlatform||C.getPlatform()==='ios')&&C.Plugins&&C.Plugins[n]||null}catch(e){return null}}
function natBlur(){try{var ae=document.activeElement;if(ae&&ae.blur)ae.blur()}catch(e){}}
function natConfirm(o){var D=natPlug('Dialog');if(!D)return null;natBlur();
  return D.confirm({title:o.title,message:o.message||'',okButtonTitle:o.ok||'OK',cancelButtonTitle:o.cancel||'Cancel'}).then(function(r){return!!(r&&r.value)},function(){return false})}
function natDestroy(o){var A=natPlug('ActionSheet');if(!A)return null;natBlur();haptic('warning');
  var a={title:o.title,options:[{title:o.ok,style:'DESTRUCTIVE'},{title:'Cancel',style:'CANCEL'}]};if(o.message)a.message=o.message;
  return A.showActions(a).then(function(r){return!!r&&r.index===0},function(){return false})}
var AI_ASK=null,AI_TAP=0;
['pointerup','keydown'].forEach(function(ev){document.addEventListener(ev,function(){AI_TAP=Date.now()},true)});
function aiOk(){try{return localStorage.getItem('songpad:aiconsent')||''}catch(e){return''}}
function aiSet(v){try{if(v)localStorage.setItem('songpad:aiconsent',v);else localStorage.removeItem('songpad:aiconsent')}catch(e){}}
function aiWho(){return sampleFn&&!oaiReady?'Anthropic (Claude)':'OpenAI'}
function aiOffErr(){var e=new Error('AI features are off. Turn them on in Account › AI Features.');e.aiOff=true;return e}
function aiConsent(ask){var v=aiOk();if(v==='yes')return Promise.resolve();
  if(v==='no'){if(ask)toast('AI features are off. Turn them on in Account › AI Features.');return Promise.reject(aiOffErr())}
  if(!ask&&Date.now()-AI_TAP>2500)return Promise.reject(aiOffErr());
  if(AI_ASK)return AI_ASK;
  AI_ASK=new Promise(function(res,rej){
    var AI_MSG='Lines, Muse, Rate, Writing voice and lyric sync send what you’re working on (your lyrics, the song brief and, for lyric sync, a low-quality copy of the audio) to '+aiWho()+' to write suggestions. It’s used only to answer each request, not to train models.';
    var nat=natConfirm({title:'Use AI features?',message:AI_MSG+'\n\nNothing is sent unless you allow it. The Privacy Policy is in Account.',ok:'Allow',cancel:'Not Now'});
    if(nat){nat.then(function(ok){AI_ASK=null;if(ok){aiSet('yes');res()}else{aiSet('no');toast('AI features are off. Turn them on any time in Account › AI Features.');rej(aiOffErr())}});return}
    var ov=document.createElement('div');ov.id='aiask';ov.setAttribute('role','alertdialog');ov.setAttribute('aria-modal','true');ov.setAttribute('aria-labelledby','aiask-t');
    ov.innerHTML='<div class="aiask"><b id="aiask-t">Use AI features?</b><p></p><p class="aiask-s">Nothing is sent unless you allow it. <a href="#" data-doc="privacy">Privacy Policy</a></p><button class="go" id="aiask-y">Allow</button><button id="aiask-n">Not Now</button></div>';
    ov.querySelector('p').textContent=AI_MSG;
    var done=function(ok){ov.classList.remove('on');setTimeout(function(){ov.remove()},220);AI_ASK=null;
      if(ok){aiSet('yes');res()}else{aiSet('no');toast('AI features are off. Turn them on any time in Account › AI Features.');rej(aiOffErr())}};
    ov.querySelector('#aiask-y').onclick=function(){done(true)};ov.querySelector('#aiask-n').onclick=function(){done(false)};
    ov.querySelector('[data-doc]').onclick=function(e){e.preventDefault();openDoc('privacy')};
    try{document.activeElement&&document.activeElement.blur&&document.activeElement.blur()}catch(e){}
    document.body.appendChild(ov);requestAnimationFrame(function(){ov.classList.add('on')})});
  return AI_ASK}
function aiJson(prompt,opts){return aiConsent().then(function(){return aiJson0(prompt,opts)},function(e){if(Date.now()-AI_TAP<2500&&aiOk()==='no'&&!aiJson.told){aiJson.told=1;setTimeout(function(){aiJson.told=0},4000);toast(e.message)}throw e})}
function aiJson0(prompt,opts){
  opts=opts||{};
  if(oaiReady&&window.desktop&&window.desktop.aiJson){
    return window.desktop.aiJson(prompt,opts.modelTier).then(function(r){
      if(!r||!r.ok)return Promise.reject(new Error((r&&r.error)||'Request failed'));
      return parseAIJson(r.text);
    });
  }
  if(sampleFn)return sampleFn.json(prompt,opts);
  if((window.supabase&&window.supabase.createClient)||BAKED_OPENAI_KEY)return bakedOpenAICall(prompt,opts.modelTier).then(parseAIJson);
  return Promise.reject(new Error('Not available'));
}
````

- **Providers** (first available wins, `aiJson0`): Mac app with a saved OpenAI key (`window.desktop.aiJson(prompt,
  modelTier)`) → Claude artifact runtime (`claude.use('sample')`, `sampleFn.json`) → **Supabase Edge Function
  `ai-proxy`** with body `{prompt, modelTier}` returning `{text}` or `{error}` (this is the production path on iPhone) →
  direct OpenAI with a baked key (empty in this build).
- **modelTier**: omitted (= fast) for everything except Rate and the voice profile, which pass `'complex'`. The baked-key
  fallback maps complex → `gpt-5`, 5000 max tokens, reasoning `medium`, 110 s timeout; default → `gpt-5-mini`, 2000
  tokens, reasoning `minimal`, 45 s. (The proxy decides its own models; mirror these tiers.) Prompts over 24,000 chars
  are refused. Remote config `ai_off` blocks with "AI features are paused for maintenance. They’ll be back shortly."
- **Responses are always JSON**. `parseAIJson`: try `JSON.parse(text)`, else the contents of a ```json fence, else the
  slice from the first `[`/`{` to the last `]`/`}`; else error.
- **Consent** (`aiConsent(ask)`): stored per device in `songpad:aiconsent`. `yes` → proceed. `no` → reject (toast only if
  the user just tapped). Unset → only prompts if the request was started by a tap within the last 2.5 s (`AI_TAP` is set
  on every pointerup/keydown) — **background requests (voice-profile learning, judging, ranking) never prompt**, they
  just fail until allowed. One prompt at a time (`AI_ASK` promise shared). Copy in features doc §1.7.
- **Caching**: the `{cache:true|false}` option is only honoured by the artifact runtime; the app itself caches results
  in memory maps keyed by strings that include `pfk()` (see each feature). `pfk()` (15705) =
  `'#' + JSON.stringify(PF) + '#' + learnedVoice() + (VIEW.ctx ? '#ctx' : '')`, so changing the writing voice, the
  learned voice or the context toggle invalidates. `savePF()` also clears `MC` and `LSK`. Caches are per session.

### 2.2 Shared prompt parts: voice suffix `pfx()`, learned voice, song context, muse context

**`pfx()`** — the writer's voice, appended to every generation prompt (verbatim 15705–15765, includes `VOICES`,
`GENRE_DESC`):

<!-- verbatim index.html lines 15705-15765 -->
```js
function pfk(){return'#'+JSON.stringify(PF)+'#'+learnedVoice()+(typeof VIEW!=='undefined'&&VIEW.ctx?'#ctx':'')}
var VOICES={Neutral:'',
'Southern US':'Southern US vernacular: easy drawl rhythm, y\'all and fixin\' to, porches, back roads, church and heat',
'Appalachian':'Appalachian mountain speech: old-time phrasing, hollers, creeks, coal and kin',
'Texas':'Texas plain talk: big-sky imagery, dry humour, highways and dust',
'Midwest':'plain-spoken Midwestern voice: understated and polite, grain towns, lakes and long winters',
'New York':'New York voice: fast, blunt and streetwise, subways, stoops and bodegas',
'West Coast':'California and West Coast voice: laid-back, freeways, sun, smog and the ocean',
'Atlanta':'Atlanta voice: Southern hip-hop cadence and slang, trap-era imagery, heat and hustle',
'Chicago':'Chicago voice: grit and wind, the L train, lake winters, blues and drill-era slang',
'London':'London voice: British spelling, MLE and cockney-leaning slang, the tube, estates and corner shops',
'Northern England':'Northern English voice: dry wit, terraced streets, pubs, rain, words like "our kid" and "nowt"',
'Scottish':'Scottish voice: Scots words used naturally (wee, aye, ken, greet), Glasgow streets and Highland weather',
'Irish':'Irish voice: lyrical storytelling cadence, Hiberno-English (grand, so it is, craic), sea, pubs and leaving',
'Australian':'Australian voice: laconic humour, Aussie slang used naturally (arvo, servo, reckon, heaps), suburbs, beach and outback',
'New Zealand':'New Zealand voice: Kiwi slang (chur, sweet as, yeah nah), understated humour, coast and bush',
'Caribbean':'Caribbean voice: island rhythm, light patois phrasing used with respect, sea, heat and sound systems',
'Gen Z':'Gen Z online voice: very online, ironic, group-chat phrasing, lowercase energy',
'Old soul':'old-soul voice: timeless plain words, no modern slang, could have been written any decade'};
var GENRE_DESC={
 'Pop':'pop — hook-first, broad appeal, radio-ready polish',
 'Bedroom pop':'bedroom pop — lo-fi, intimate, diary-like detail',
 'Indie folk':'indie folk — acoustic, literary, unhurried storytelling',
 'Alt-rock':'alternative rock — guitar-driven, moody dynamics',
 'Pop-punk':'pop-punk — fast, confessional, big shouted choruses',
 'Emo':'emo — raw, melodramatic, painfully specific heartbreak',
 'Synth-pop':'synth-pop — glossy, nostalgic 80s-leaning synths',
 'Dance-pop':'dance-pop — hook-first, built for the floor',
 'Hyperpop':'hyperpop — maximalist, glitchy, internet-native hyperbole',
 'R&B':'R&B — smooth, vocal-run phrasing, intimate groove',
 'Neo-soul':'neo-soul — warm, loose in the pocket, lyrical',
 'Hip-hop':'hip-hop — rhythmic flow, wordplay, punchlines that land',
 'Trap':'trap — dark, minimal, repetition and ad-lib energy',
 'Drill':'drill — menacing, street-specific, deadpan delivery',
 'Country':'country — plainspoken storytelling, small-town detail',
 'Americana':'Americana — roots, weathered, open-road imagery',
 'Gospel':'gospel — devotional, call-and-response, building toward uplift',
 'Blues':'blues — plainspoken hardship, repetition, grit',
 'Afrobeats':'Afrobeats — rhythmic, warm, communal and danceable',
 'Alternative':'alternative — genre-agnostic, idiosyncratic, unconcerned with radio convention'
};
function pfx(){var p=PF,a=[];
  if(p.genre!=='Any')a.push('Genre: '+(GENRE_DESC[p.genre]||p.genre)+'.');
  if(p.mood!=='Any')a.push('Mood: '+p.mood.toLowerCase()+'.');
  if(p.dial.trim())a.push('Write specifically in this voice: '+p.dial.trim()+'. Use its real vocabulary, idioms and spelling naturally, never as caricature.');
  if(p.era!=='Any')a.push(p.era==='Timeless'?'Era: timeless, avoid dated references.':'Era: write as if it were the '+p.era+' (or right '+p.era.toLowerCase()+'), with period-true references and slang.');
  if(p.pov!=='Any')a.push('Point of view: '+{I:'first person (I)',You:'second person, addressing "you"',We:'first person plural (we)',Story:'third-person storytelling'}[p.pov]+'.');
  if(p.tense!=='Any')a.push('Tense: '+p.tense.toLowerCase()+'.');
  if(p.img.length)a.push('Draw imagery from: '+p.img.join(', ').toLowerCase()+'.');
  if(p.dev.length)a.push('Techniques to use: '+p.dev.join(', ').toLowerCase()+'.');
  a.push('Language: '+{Poetic:'poetic and imagistic, with metaphor and no slang',Conversational:'natural everyday speech, contractions welcome',Slang:'casual and slangy like real speech, never forced',Explicit:'raw and uncensored, with profanity where it lands naturally'}[p.reg]+'.');
  /* Always on, independent of the Clichés setting below — that toggle is specifically about stock
     rhyme pairs and worn-out phrases a songwriter would recognize as lazy writing. This is about a
     different, narrower thing: the surface tics that make text read as obviously AI-written even
     when the content itself is fine — so it applies whether or not clichés are allowed. */
  a.push('Write like a person drafting by hand, not an AI assistant: skip the tidy "it\'s not X, it\'s Y" contrast, stock openers like "in the silence/stillness" or "let me take you back", em-dash asides, and a neatly uplifting resolution by default. Let a line stay plain, unresolved, or a little rough rather than polishing every single one.');
  if(p.cliche)a.push('Avoid clichés and stock rhyme pairs (fire/desire, heart/apart, eyes/skies, rain/pain, love/above) and stock phrases.');
  if(p.refs.trim())a.push('Influences, for tone only: '+p.refs.trim()+'. Never quote or closely paraphrase existing lyrics.');
  if(p.custom.trim())a.push('Extra direction from the writer: '+p.custom.trim());
  return' '+a.join(' ')+learnedVoice()+learnedLinePref();
}
```

**Learned voice** (only fills dimensions the writer didn't set explicitly; verbatim 15641–15696):

<!-- verbatim index.html lines 15641-15696 -->
```js
function voiceFingerprint(suppressPov,suppressImg){
  var lines=[],words={};
  songs.forEach(function(s){if(s.id===GUIDE_ID)return;(s.lyrics||'').split('\n').forEach(function(l){l=l.trim();if(l&&l[0]!=='[')lines.push(l)})});
  if(lines.length<8)return null;
  var totW=0,totS=0,pov={I:0,You:0,We:0},imgRx={City:/\b(city|street|block|skyline|subway|downtown)\b/i,'small town':/\b(small town|main street|porch|county|back road)\b/i,nature:/\b(tree|forest|mountain|river|flower|sky)\b/i,coast:/\b(ocean|beach|wave|tide|coast|shore)\b/i,'the road':/\b(highway|road|drive|miles|wheel|car)\b/i,night:/\b(night|moon|dark|stars)\b/i,home:/\b(home|house|kitchen|bed|porch)\b/i,weather:/\b(rain|storm|snow|sun|wind)\b/i,faith:/\b(god|prayer|faith|heaven|soul)\b/i,money:/\b(money|cash|dollar|broke|rich)\b/i,party:/\b(party|dance|drink|club)\b/i},imgCount={};
  lines.forEach(function(l){
    var w=l.match(/[A-Za-z']+/g)||[];totW+=w.length;totS+=lsyl(l);
    if(/\b(i|my|me|i'm|i've)\b/i.test(l))pov.I++;if(/\b(you|your|you're)\b/i.test(l))pov.You++;if(/\b(we|our|we're)\b/i.test(l))pov.We++;
    Object.keys(imgRx).forEach(function(k){if(imgRx[k].test(l))imgCount[k]=(imgCount[k]||0)+1});
    w.forEach(function(x){x=x.toLowerCase();if(x.length>3&&!STOP[x])words[x]=(words[x]||0)+1})
  });
  var avgW=(totW/lines.length).toFixed(1),avgS=(totS/lines.length).toFixed(1);
  var topImg=Object.keys(imgCount).filter(function(k){return imgCount[k]>=lines.length*0.04}).sort(function(a,b){return imgCount[b]-imgCount[a]}).slice(0,2);
  var topPov=Object.keys(pov).sort(function(a,b){return pov[b]-pov[a]})[0],bits=[];
  var topWords=Object.keys(words).filter(function(w){return words[w]>=3}).sort(function(a,b){return words[b]-words[a]}).slice(0,6);
  bits.push('lines average around '+avgW+' words / '+avgS+' syllables');
  if(!suppressImg&&topImg.length)bits.push('imagery leans toward '+topImg.join(' and '));
  if(!suppressPov&&pov[topPov]>lines.length*0.15)bits.push('mostly written in '+({I:'first person (I/my)',You:'second person (you)',We:'first person plural (we)'}[topPov]));
  if(topWords.length)bits.push('words they keep coming back to: '+topWords.join(', '));
  return bits
}
function hookLines(){
  var out=[];
  songs.forEach(function(s){
    if(!s.rich||s.id===GUIDE_ID)return;
    try{
      var d=new DOMParser().parseFromString('<body>'+s.rich+'</body>','text/html').body;
      d.querySelectorAll('[style*="background-color"]').forEach(function(el){
        var bg=(el.style&&el.style.backgroundColor)||'';
        if(/255,\s*204,\s*0/.test(bg)){var t=el.textContent.trim();if(t&&t.length<120)out.push({t:t,u:s.updated||0})}
      })
    }catch(e){}
  });
  out.sort(function(a,b){return b.u-a.u});
  var seen={},res=[];out.forEach(function(o){if(res.length>=4||seen[o.t])return;seen[o.t]=1;res.push(o.t)});
  return res
}
function learnedVoice(){
  /* Used to switch off entirely the moment ANY Writing Voice field was touched — but setting a
     Genre doesn't mean the writer wants their own typical line length, word choices and favorite
     lines ignored too. Now it keeps contributing on whatever dimensions they haven't explicitly
     set themselves, and only suppresses the one dimension an explicit choice actually covers
     (POV, imagery) — still never arguing with an explicit choice, just no longer throwing out
     everything else along with it. */
  var suppressPov=PF.pov!=='Any',suppressImg=PF.img.length>0;
  var sig=songsSig()+'|'+suppressPov+'|'+suppressImg;
  if(LVC.sig!==sig){
    LVC.sig=sig;
    var fp=voiceFingerprint(suppressPov,suppressImg),hooks=hookLines(),parts=[];
    if(fp&&fp.length)parts.push('From this writer\'s own past songs: '+fp.join('; ')+'.');
    if(hooks.length)parts.push('Lines they themselves marked as a favorite "Hook", for tone and quality only — never reuse or closely paraphrase them: '+hooks.map(function(h){return'"'+h+'"'}).join(' / ')+'.');
    LVC.txt=parts.length?' '+parts.join(' '):'';
    if(typeof DEV_MODE!=='undefined'&&DEV_MODE)console.log('[learnedVoice] recomputed —',fp?fp.join('; '):'not enough lines yet (need 8+)','| hooks:',hooks.length,'| text:',LVC.txt||'(empty)')
  }
  return LVC.txt
}
```

**Learned rhyme preference** (verbatim 15771–15780): counts in `songpad:linepref` from accepted word chips
(`perfect`/`near`) and accepted lines (`perfect`/`near`/`loose`); ignored when "Perfect only"; needs ≥8 picks.

<!-- verbatim index.html lines 15771-15780 -->
```js
function recordLineAccept(type){if(!type)return;try{var st=JSON.parse(localStorage.getItem('songpad:linepref')||'{}');st[type]=(st[type]||0)+1;localStorage.setItem('songpad:linepref',JSON.stringify(st))}catch(e){}}
function learnedLinePref(){
  if(PF.strict)return'';
  try{
    var st=JSON.parse(localStorage.getItem('songpad:linepref')||'{}'),perfect=st.perfect||0,near=st.near||0,loose=st.loose||0,total=perfect+near+loose;
    if(total<8)return'';
    if(near+loose>perfect*1.3)return' This writer tends to pick near/slant rhymes over perfect ones when both are offered — lean that way when it reads naturally.';
    return'';
  }catch(e){return''}
}
```

**Song context `songCtx(o)`** (verbatim 16695–16711). With "Listen to the whole song" off: the current stanza only.
On: title/artist/notes + the whole lyric with a `⟦NEW LINE GOES HERE⟧` marker (or `⟦…⟧` around the phrase being
rewritten), windowed to 5000 chars (3500 before the marker).

<!-- verbatim index.html lines 16695-16711 -->
```js
function songCtx(o){
  var v=getText(),at=o.at!=null?o.at:v.length,s;
  if(!VIEW.ctx){
    /* used to grab just the last 2 non-blank lines anywhere above the cursor, which could cross a
       section break and pull in a different stanza entirely. o.section (the current stanza's own
       lines, from stanzaOf()/ctx().st) is the actual section being written, so prefer that — and
       send the whole thing, not just 2 lines, since the analysis instruction below needs enough of
       it to actually read tone/style/imagery from rather than guess off a fragment. */
    var sec=o.section&&o.section.length?o.section:v.slice(0,o.kind==='rw'?v.lastIndexOf('\n',o.a-1)+1:at).split('\n').filter(function(x){return x.trim()}).slice(-2);
    var prev=sec.join('\n');
    return prev?'Lines already written in this section:\n'+prev+'\n\nBefore writing, read these lines and note their tone (the emotional register), their writing style (sentence rhythm, vocabulary, formality) and any imagery or metaphors already in play. What you write must match all three, not just continue the plot.':''
  }
  if(o.kind==='rw')s=v.slice(0,o.a)+'⟦'+v.slice(o.a,o.b)+'⟧'+v.slice(o.b);else s=v.slice(0,at)+'⟦NEW LINE GOES HERE⟧'+v.slice(at);
  if(s.length>5000){var m=s.indexOf('⟦'),st=Math.max(0,m-3500);s=(st?'…':'')+s.slice(st,st+5000)+'…'}
  var head='Song: '+(cur&&cur.title||'Untitled')+(cur&&cur.artist?' by '+cur.artist:'')+(cur&&cur.notes?'\nWriter\'s notes: '+cur.notes.slice(0,400):'');
  return head+'\nFull lyrics so far ('+(o.kind==='rw'?'⟦ ⟧ marks the phrase being rewritten':'⟦NEW LINE GOES HERE⟧ marks where the new line goes')+'):\n'+s+'\n\nBefore writing, read what\'s there and note its tone, its writing style (sentence rhythm, vocabulary, formality), and any imagery or metaphors already in play. The new text must belong in this song: match that tone, style and imagery, continue its story, keep its characters, tense and point of view consistent, and do not repeat lines or end words already used nearby.';
}
```

**Muse memory and `museCtx(sec)`** — the personal block appended after `songCtx` in Lines and Read my song
(verbatim 16713–16798). Events `{id, song, src:'lines'|'muse', o:'kept'|'edited'|'deleted'|'reject'|'passed', shown,
final, why, at}`; stored locally (500 max) and in Supabase `muse_events`; the voice profile in `muse_profile`.
Outcome tracking: every applied suggestion is re-checked ≥3 min later (`mzCheck`, every 60 s and on background):
still present verbatim → `kept`; best Dice word-overlap ≥0.45 with some line → `edited` (with that line as `final`);
else `deleted`. Shared songs with >1 member are skipped (can't tell who edited). "Not this" chips → `reject` with reason;
"New ideas" without using any → `passed` (first 6 lines).

<!-- verbatim index.html lines 16713-16798 -->
```js
/* ---------- the muse's memory: what this writer actually does with suggestions ----------
   Every suggestion that gets used is checked again a few minutes later: still there word for word
   (kept), changed (edited, with the writer's own version, the most useful signal there is), or gone
   (deleted). "Not this" on a suggestion records a reason, and asking for new ideas marks the batch as
   passed over. Kept on the device and, when signed in, in the private muse_events table
   (supabase/muse.sql) so it follows the writer between devices. museCtx() turns it into guidance. */
var MZ={ev:[],pend:[],q:[],prof:null,noTable:false,building:false};
/* kept per account (like songs and ideas), so signing out and in as someone else never mixes two writers' memory */
function mzKey(k){var u=typeof AUTH_USER!=='undefined'&&AUTH_USER&&AUTH_USER.id;return'songpad:muse:'+k+(u?':'+u:(typeof DEV_MODE!=='undefined'&&DEV_MODE?':dev':''))}
function mzLoad(){MZ.ev=[];MZ.pend=[];MZ.q=[];MZ.prof=null;MZ.building=false;MZ.uid=typeof AUTH_USER!=='undefined'&&AUTH_USER?AUTH_USER.id:null;
  try{MZ.ev=JSON.parse(localStorage.getItem(mzKey('ev'))||'[]')||[];MZ.pend=JSON.parse(localStorage.getItem(mzKey('pend'))||'[]')||[];MZ.prof=JSON.parse(localStorage.getItem(mzKey('prof'))||'null')}catch(e){}}
mzLoad();
function mzSave(){try{localStorage.setItem(mzKey('ev'),JSON.stringify(MZ.ev.slice(-500)));localStorage.setItem(mzKey('pend'),JSON.stringify(MZ.pend.slice(-40)))}catch(e){}}
function mzId(){return Date.now().toString(36)+Math.random().toString(36).slice(2,9)}
function mzCloud(){var c=AUTH_USER&&!DEV_MODE&&sbClient();return c&&!MZ.noTable?c:null}
function mzMissing(err){return/relation|does not exist|schema cache|42P01|PGRST20/i.test((err&&err.message)||'')}
function mzLog(e){e.id=e.id||mzId();e.at=e.at||Date.now();MZ.ev.push(e);if(MZ.ev.length>500)MZ.ev.splice(0,MZ.ev.length-500);mzSave();MZ.q.push(e);if(MZ.q.length>500)MZ.q.splice(0,MZ.q.length-500);mzFlush()}
function mzFlush(){clearTimeout(MZ.ft);MZ.ft=setTimeout(function(){var c=mzCloud();if(!c||!MZ.q.length)return;var batch=MZ.q.splice(0,50);
  c.from('muse_events').upsert(batch.map(function(e){return{id:e.id,song_id:e.song||null,src:e.src||null,outcome:e.o,shown:(e.shown||'').slice(0,600)||null,final:(e.final||'').slice(0,600)||null,reason:e.why||null,created_at:new Date(e.at).toISOString()}}),{onConflict:'id',ignoreDuplicates:true})
    .then(function(r){if(r.error){if(mzMissing(r.error))MZ.noTable=true;else MZ.q=batch.concat(MZ.q)}else if(MZ.q.length)mzFlush()},function(){MZ.q=batch.concat(MZ.q)})},1500)}
/* on sign-in: merge the account's history with this device's, upload anything only this device has */
function mzPull(){var c=mzCloud();if(!c)return;
  c.from('muse_events').select('id,song_id,src,outcome,shown,final,reason,created_at').order('created_at',{ascending:false}).limit(500).then(function(r){
    if(r.error){if(mzMissing(r.error))MZ.noTable=true;return}
    var srv={},have={};MZ.ev.forEach(function(e){have[e.id]=1});
    (r.data||[]).forEach(function(x){srv[x.id]=1;if(!have[x.id])MZ.ev.push({id:x.id,song:x.song_id,src:x.src,o:x.outcome,shown:x.shown,final:x.final,why:x.reason,at:Date.parse(x.created_at)||0})});
    MZ.ev.sort(function(a,b){return a.at-b.at});if(MZ.ev.length>500)MZ.ev.splice(0,MZ.ev.length-500);mzSave();
    var oldest=(r.data&&r.data.length>=500)?Date.parse(r.data[r.data.length-1].created_at):0;
    MZ.ev.forEach(function(e){if(!srv[e.id]&&e.at>=oldest&&MZ.q.indexOf(e)<0)MZ.q.push(e)});mzFlush();
    c.from('muse_profile').select('profile,edited,basis,updated_at').maybeSingle().then(function(p){if(p.error||!p.data)return mzProfAuto();var t=Date.parse(p.data.updated_at)||0;
      if(!MZ.prof||t>(MZ.prof.at||0)){MZ.prof={text:p.data.profile||'',edited:!!p.data.edited,at:t,n:p.data.basis||0};mzProfStore(false)}else if(MZ.prof&&MZ.prof.at>t)mzProfStore(true);mzProfAuto()})})}
function mzNorm(s){return String(s||'').toLowerCase().replace(/[’‘]/g,"'").replace(/[^a-z0-9' ]+/g,' ').replace(/\s+/g,' ').trim()}
function mzSim(a,b){var A=mzNorm(a).split(' '),B=mzNorm(b).split(' ');if(!A[0]||!B[0])return 0;var m={},n=0;A.forEach(function(w){m[w]=(m[w]||0)+1});B.forEach(function(w){if(m[w]>0){m[w]--;n++}});return 2*n/(A.length+B.length)}
/* a suggestion went into the song: follow it up later */
function mzUsed(line,src){if(!cur||!line)return;MZ.pend.push({id:mzId(),song:cur.id,src:src,shown:line,at:Date.now()});mzSave();mzProfAuto()}
function mzCheck(force){if(!MZ.pend.length)return;var now=Date.now(),left=[];
  MZ.pend.forEach(function(p){var s=songs.filter(function(x){return x.id===p.song})[0];if(!s)return;if(s.shared&&(s.members||[]).length>1)return;
    if(!force&&now-p.at<180000){left.push(p);return}
    var ls=(s.lyrics||'').split('\n').map(function(x){return x.trim()}).filter(function(x){return x&&x[0]!=='['}),t=mzNorm(p.shown),best='',bs=0;
    if(ls.some(function(x){return mzNorm(x)===t}))return mzLog({song:p.song,src:p.src,o:'kept',shown:p.shown,at:p.at});
    ls.forEach(function(x){var v=mzSim(x,p.shown);if(v>bs){bs=v;best=x}});
    mzLog(bs>=.45?{song:p.song,src:p.src,o:'edited',shown:p.shown,final:best,at:p.at}:{song:p.song,src:p.src,o:'deleted',shown:p.shown,at:p.at})});
  MZ.pend=left;mzSave()}
setInterval(function(){mzCheck(false)},60000);
document.addEventListener('visibilitychange',function(){if(document.hidden)mzCheck(false)});
function mzReject(line,why,src){mzLog({song:cur&&cur.id,src:src,o:'reject',shown:line,why:why})}
function mzPassed(list,src){if(!list||!list.length)return;mzLog({song:cur&&cur.id,src:src,o:'passed',shown:list.slice(0,6).join(' / ')})}
var MZ_WHY=[['cliche','Cliché'],['voice','Not my voice'],['nose','Too on the nose'],['sing','Doesn’t sing'],['sense','Makes no sense']];
var MZ_WHYL={};MZ_WHY.forEach(function(x){MZ_WHYL[x[0]]=x[1]});

/* ---------- stock song phrases: never shown, whatever the model says ---------- */
var MZ_CLICHE=[/\bneon (light|lights|glow|sign|signs|dream|dreams)\b/,/\bshatter(ed|s)? (heart|hearts|glass|pieces|dreams)\b/,/\b(heart|hearts) (of gold|of stone|on (my|your) sleeve)\b/,/\becho(es|ing)? (of|in the|through)\b/,/\bwhisper(s|ed|ing)? (in the dark|of the|in my ear|of you)\b/,/\btapestry\b/,/\bsymphony\b/,/\bkaleidoscope\b/,/\blabyrinth\b/,/\bdanc(e|ing) in the rain\b/,/\bset (my|your|our) (soul|heart) on fire\b/,/\bburning desire\b/,/\bfire\b.*\bdesire\b|\bdesire\b.*\bfire\b/,/\blost in (your|those|her|his) eyes\b/,/\bchasing (dreams|the sun|shadows|the light|the stars)\b/,/\bbroken wings\b/,/\brise from the ashes\b/,/\bmidnight hour\b/,/\bvelvet (sky|night)\b/,/\bsilver lining\b/,/\bstorm inside\b/,/\btears? (fall|falling) like rain\b/,/\bheart ?beat(s)? like a drum\b/,/\bweight of the world\b/,/\blight in the dark(ness)?\b/,/\bin the dead of (the )?night\b/,/\bagainst all odds\b/,/\bendless night\b/,/\btime stands still\b/,/\bfaded memor(y|ies)\b/,/\bghosts? of (the past|you|us|yesterday)\b/,/\bshadows (dance|dancing)\b/,/\bstarlit\b/,/\bembers? (of|glow)\b/,/\bsoul(s)? (on fire|ablaze)\b/,/\bunspoken words\b/,/\bwings to fly\b/,/\bspread (my|your) wings\b/,/\btouch the sky\b/,/\breach for the stars\b/,/\bheart of the night\b/,/\bbleeding heart\b/,/\bscars (that|tell|of)\b/,/\bcold as ice\b/,/\bhold on tight\b/];
function mzCliche(line){var l=mzNorm(line);for(var i=0;i<MZ_CLICHE.length;i++)if(MZ_CLICHE[i].test(l))return true;return false}
/* words this writer keeps throwing out (and never keeps) */
function mzAvoid(){var bad={},good={},add=function(t,n){mzNorm(t).split(' ').forEach(function(w){if(w.length>3&&!STOP[w])bad[w]=(bad[w]||0)+n})};
  MZ.ev.forEach(function(e){
    if(e.o==='deleted'||e.o==='reject')add(e.shown,1);
    else if(e.o==='kept')mzNorm(e.shown).split(' ').forEach(function(w){good[w]=1});
    else if(e.o==='edited'){var f={};mzNorm(e.final).split(' ').forEach(function(w){f[w]=1;good[w]=1});mzNorm(e.shown).split(' ').forEach(function(w){if(!f[w]&&w.length>3&&!STOP[w])bad[w]=(bad[w]||0)+1})}});
  return Object.keys(bad).filter(function(w){return bad[w]>=2&&!good[w]}).sort(function(a,b){return bad[b]-bad[a]}).slice(0,25)}
function mzRecent(kind,n){return MZ.ev.filter(function(e){return e.o===kind&&e.shown}).slice(-n)}
/* the writer's own lines closest to what they're writing now (shared words, then favourite hooks) */
function mzMyLines(sec,n){var q={},words=function(t){return(mzNorm(t).match(/[a-z']+/g)||[]).filter(function(w){return w.length>3&&!STOP[w]})};
  (sec||[]).concat([cur&&cur.title||'',cur&&cur.brief?[cur.brief.who,cur.brief.to,cur.brief.where,cur.brief.thing].join(' '):'']).forEach(function(t){words(t).forEach(function(w){q[w]=1})});
  var hk={};hookLines().forEach(function(h){hk[mzNorm(h)]=1});
  var cand=[];songs.forEach(function(s){if(s===cur||!s.lyrics||s.id===GUIDE_ID)return;s.lyrics.split('\n').forEach(function(l){l=l.trim();if(l.length<14||l.length>110||l[0]==='[')return;
    var sc=0,seen={};words(l).forEach(function(w){if(q[w]&&!seen[w]){seen[w]=1;sc+=1}});if(hk[mzNorm(l)])sc+=1.5;cand.push({l:l,s:s.id,sc:sc,u:s.updated||0})})});
  cand.sort(function(a,b){return b.sc-a.sc||b.u-a.u});
  var out=[],per={},seenL={};for(var i=0;i<cand.length&&out.length<n;i++){var c=cand[i],k=mzNorm(c.l);if(seenL[k]||(per[c.s]||0)>=3)continue;seenL[k]=1;per[c.s]=(per[c.s]||0)+1;out.push(c.l)}
  return out}
function mzBrief(s){var b=s&&s.brief;if(!b)return'';var a=[];if(b.who)a.push('Who\'s singing: '+b.who);if(b.to)a.push('Singing to: '+b.to);if(b.where)a.push('Where and when: '+b.where);if(b.thing)a.push('A real detail from it: '+b.thing);if(b.more)a.push('Also true: '+b.more);return a.join('\n')}
function mzQ(x){return'"'+String(x).replace(/"/g,'\'')+'"'}
/* everything personal the muse knows, as one block for a prompt */
function museCtx(sec){var a=[];
  if(MZ.prof&&MZ.prof.text)a.push('HOW THIS WRITER WRITES (their voice profile; let it shape style and word choice, not subject matter):\n'+MZ.prof.text.slice(0,1400));
  var br=mzBrief(cur);if(br)a.push('BACKGROUND ON THIS SONG from the writer. Treat it as what you know, not a checklist: only bring a name, place or detail in when it fits the line and the moment naturally, change or leave it out when it doesn\'t, and never force it into every suggestion. Most good lines will use none of it:\n'+br);
  var mine=mzMyLines(sec,8);if(mine.length)a.push('THE WRITER\'S OWN LINES from other songs, that might be close to what they\'re writing now. Use them only for how this writer sounds (kind of detail, plainness or strangeness, rhythm), not as material to borrow, and ignore any that don\'t fit this song. Never reuse or paraphrase them:\n'+mine.map(mzQ).join('\n'));
  var mc=meantChoices(8);if(mc.length)a.push('LINES THEY DEFENDED as deliberate when a critic questioned them. These are habits of their voice: don\'t smooth them away, write with them:\n'+mc.map(function(x){return'- '+mzQ(x.q)+(x.why?' ('+x.why+')':'')}).join('\n'));
  if(!(MZ.prof&&MZ.prof.text)){var rr=rateReads(2);if(rr.length)a.push('HOW A CLOSE READER DESCRIBED THEIR WRITING (style only):\n'+rr.map(function(x){return'- '+x}).join('\n'))}
  var ed=mzRecent('edited',6);if(ed.length)a.push('SUGGESTIONS THEY REWROTE, and what they changed them to. Learn the direction of each change and write like the "after":\n'+ed.map(function(e){return'- '+mzQ(e.shown)+' -> '+mzQ(e.final)}).join('\n'));
  var kp=mzRecent('kept',5);if(kp.length)a.push('SUGGESTIONS THEY KEPT word for word (this is the bar):\n'+kp.map(function(e){return'- '+mzQ(e.shown)}).join('\n'));
  var rj=MZ.ev.filter(function(e){return(e.o==='reject'||e.o==='deleted')&&e.shown}).slice(-8);if(rj.length)a.push('SUGGESTIONS THEY THREW OUT (don\'t write anything like these):\n'+rj.map(function(e){return'- '+mzQ(e.shown)+(e.why&&MZ_WHYL[e.why]?' ('+MZ_WHYL[e.why].toLowerCase()+')':'')}).join('\n'));
  var av=mzAvoid();
  a.push('NEVER USE stock song language: neon lights, shattered hearts, echoes, whispers in the dark, fire and desire, tapestries, symphonies, chasing dreams, rising from the ashes, broken wings, the weight of the world, a light in the dark, lost in your eyes, or anything else a thousand songs already say. Prefer one specific, slightly unexpected concrete detail over a big abstract feeling. Plain, true and particular beats poetic and vague.'+(av.length?' Also avoid these words this writer keeps rejecting: '+av.join(', ')+'.':''));
  a.push('ORDER OF PRIORITY: first, the lines already written in this song and where they\'re heading (that is what the new line must fit and continue); second, how this writer sounds; only then the background above, and only where it genuinely fits. Vary the suggestions: don\'t let one detail or image from the background show up across many of them.');
  return'\n\n'+a.join('\n\n')}
```

**Filtering and the judge** (verbatim 16799–16830):
- `mzFilter(items, get, min)`: drop candidates already in the song or previously rejected/deleted (normalised match);
  hold back "echoes" of existing lines (shared 4-word run; same end word plus another shared word ≥4 letters; or word
  Jaccard ≥0.5 with ≥3 shared) — used only if nothing else survives; demote clichés (`MZ_CLICHE` regexes, 16764) and
  lines containing words the writer keeps rejecting (`mzAvoid`, top 25) — demoted ones are appended only if fewer than
  `min` good ones remain.
- `mzJudge(cands, {section, what, timeout})`: needs ≥3 candidates; 9 s timeout → `null` (caller keeps its own order);
  returns `{index: score}`.

<!-- verbatim index.html lines 16799-16830 -->
```js
/* keep the candidates that pass: no stock phrases, no rejected words, nothing already in the song or
   already thrown out. If that would leave too few, the rest come back at the end instead of vanishing. */
function mzFilter(items,get,min){var av={},have={},rej={},prior=[];mzAvoid().forEach(function(w){av[w]=1});
  (getText()||'').split('\n').forEach(function(l){var k=mzNorm(l);if(k&&l.trim()[0]!=='['){have[k]=1;prior.push(k)}});
  MZ.ev.forEach(function(e){if(e.o==='reject'||e.o==='deleted')rej[mzNorm(e.shown)]=1});
  var ok=[],weak=[],echo=[];items.forEach(function(x){var t=get(x),k=mzNorm(t);if(!k||have[k]||rej[k])return;
    if(mzEcho(k,prior)){echo.push(x);return}
    var bad=mzCliche(t)||k.split(' ').some(function(w){return av[w]});(bad?weak:ok).push(x)});
  /* near-copies of lines already in the song only come back if there's truly nothing else */
  var out=ok.length>=(min||1)?ok:ok.concat(weak);return out.length?out:echo}
/* does this suggestion just repeat a line that's already written? Two tests against every line in the song:
   it reuses a run of 4 words, or most of its words are that line's words (only the rhyme should match, not the line) */
function mzEcho(k,prior){var w=k.split(' ').filter(Boolean);if(w.length<3)return false;
  var grams={};for(var i=0;i+4<=w.length;i++)grams[w.slice(i,i+4).join(' ')]=1;
  var set={};w.forEach(function(x){set[x]=1});
  return prior.some(function(p){var pw=p.split(' ').filter(Boolean);if(pw.length<3)return false;
    for(var j=0;j+4<=pw.length;j++)if(grams[pw.slice(j,j+4).join(' ')])return true;
    /* same end word as an existing line plus another of its key words: a reworded copy ("came up and met me halfway") */
    if(pw[pw.length-1]===w[w.length-1]&&w.slice(0,-1).some(function(x){return x.length>=4&&pw.slice(0,-1).indexOf(x)>=0}))return true;
    var ps={},inter=0,uni={};pw.forEach(function(x){ps[x]=1;uni[x]=1});w.forEach(function(x){uni[x]=1});
    Object.keys(set).forEach(function(x){if(ps[x])inter++});
    return inter/Object.keys(uni).length>=0.5&&inter>=3})}
/* second pass: a hard-to-please judge scores every candidate. Falls back to null (caller keeps its own
   order) if it takes too long or fails, so suggestions never get stuck behind it. */
function mzJudge(cands,o){if(!cands||cands.length<3)return Promise.resolve(null);
  return new Promise(function(res){var done=false,fin=function(v){if(done)return;done=true;clearTimeout(t);res(v)},t=setTimeout(function(){fin(null)},o.timeout||9000);
    var mine=mzMyLines(o.section,4),br=mzBrief(cur);
    aiJson('You are a hard-to-please co-writer judging lyric lines for a specific writer. Score each candidate from 1 to 10.\n\n'+
      (MZ.prof&&MZ.prof.text?'The writer\'s voice:\n'+MZ.prof.text.slice(0,900)+'\n\n':'')+(mine.length?'Lines the writer wrote themselves:\n'+mine.map(mzQ).join('\n')+'\n\n':'')+(br?'Background on this song (a line that forces these details in where they don\'t fit scores lower):\n'+br+'\n\n':'')+
      (o.section&&o.section.length?'The section they\'re writing:\n'+o.section.join('\n')+'\n\n':'')+'Task: '+o.what+'\n\nCandidates:\n'+cands.map(function(c,i){return i+'. '+c}).join('\n')+
      '\n\nScore on: specific and concrete rather than generic; sounds like this writer, not like a generic songwriter; fresh rather than a stock phrase or cliché; natural to sing out loud; belongs in this song at this moment. Be harsh: a line any songwriter could have written scores 4 or less, a stock phrase scores 2. A line that repeats, rewords or closely echoes a line already in the section scores 1. Return ONLY JSON: [{"i":0,"s":7}, ...] with one entry for every candidate.',{cache:false})
      .then(function(r){var out={},n=0;(Array.isArray(r)?r:[]).forEach(function(x){if(x&&isFinite(x.i)&&isFinite(x.s)){out[+x.i]=+x.s;n++}});fin(n?out:null)},function(){fin(null)})})}
```

### 2.3 Lines (AI line suggestions) — `suggest` / `selGen` / `runGen`

Task strings (verbatim 16682–16693):

<!-- verbatim index.html lines 16682-16693 -->
```js
function suggest(c,again){
  var t=c.tl,part=c.cur.trim(),ml=melAt(c.ls);
  runGen({k:(t||'')+'#'+c.p+'#'+c.sch+pfk(),kind:'line',n:ml?ml.n:t?lsyl(t):(lsyl(c.st[c.p-1]||'')||8),lw:t?nw(lastW(t)):'',again:again,
    at:c.ls,section:c.st,
    task:'You are writing line '+(c.p+1)+' of this stanza (rhyme scheme '+c.sch+').'+(t?' It should rhyme with line '+(c.ti+1)+': "'+t+'".':' It starts a new rhyme, so end on a common word that is easy to rhyme.')+(part?' The line must begin with: "'+part+'".':'')+(ml?' The melody for this line has '+ml.n+' syllables'+(ml.pat?', with this rhythm (CAPS are strong beats, ~ is a held note): '+ml.pat+'. Put naturally stressed syllables on the strong beats and open vowels on held notes.':'.'):'')});
}
function selGen(t,kind,a,b,again,section){
  var v=getText(),ls=v.lastIndexOf('\n',a-1)+1,le=v.indexOf('\n',b);if(le<0)le=v.length;var line=v.slice(ls,le),lw=lastW(t);
  runGen({k:'S#'+kind+'#'+t+pfk(),kind:kind,n:lsyl(t),lw:nw(lw),keep:kind==='rw'||kind==='tighten',again:again,a:a,b:b,src:v.slice(a,b),
    at:le,section:section,
    task:kind==='rw'?'Rewrite only this phrase: "'+t+'". It sits in the line: "'+line+'". Each option replaces just that phrase, so the full line must still read naturally. Keep roughly the same meaning and end on a word that rhymes with "'+lw+'" (keeping "'+lw+'" is allowed).':kind==='tighten'?'Rewrite only this phrase: "'+t+'". It sits in the line: "'+line+'". Each option replaces just that phrase with a noticeably shorter version — fewer syllables, same meaning, still ending on a word that rhymes with "'+lw+'" (keeping "'+lw+'" is allowed) — so the line sings tighter against the melody without losing what it says.':'Write a new line that rhymes with this phrase: "'+t+'". It will go right after the line: "'+line+'".'});
}
```

Generation (verbatim 16884–16928):

<!-- verbatim index.html lines 16884-16928 -->
```js
function runGen(o){
  LSK=o.k;
  /* Cache hit: this exact generation (same rhyme target/section/voice/context state) was already
     fetched — show it immediately rather than re-asking the AI. This is what makes toggling
     Listen-to-whole-song, or flipping between the selection buttons, instant on the way back
     instead of resetting to nothing every time. "New ideas"/again always bypasses this. */
  if(!o.again&&LSC[o.k]&&!LSC[o.k].busy){rhyme();return}
  /* Regenerating ("again"): remember what was already shown and passed over for this exact spot,
     so the next batch doesn't just reshuffle the same handful of ideas. Capped so the prompt
     doesn't grow without bound over a long session of repeated regenerates. */
  if(o.again&&LSC[o.k]&&LSC[o.k].list&&LSC[o.k].list.length){
    if(!LSC[o.k].used)mzPassed(LSC[o.k].list.map(function(x){return x.line}),'lines');
    var h=GENHIST[o.k]=GENHIST[o.k]||[];
    LSC[o.k].list.forEach(function(x){if(h.indexOf(x.line)<0)h.push(x.line)});
    if(h.length>30)h.splice(0,h.length-30);
  }
  LSC[o.k]={k:o.k,busy:true};rhyme();
  rhymeSets(o.lw,function(S){
    var P=S.p.slice(0,70),Nr=PF.strict?[]:S.n.slice(0,24),ps={},ns={};P.forEach(function(x){ps[x]=1});Nr.forEach(function(x){ns[x]=1});if(o.keep&&o.lw)ps[o.lw]=1;
    var rule=o.lw?(P.length||Nr.length?'3. Prefer ending on one of these perfect rhymes for "'+o.lw+'": '+P.join(', ')+(Nr.length?'\n   If none fits naturally, end on one of these near/slant rhymes: '+Nr.join(', '):'')+'\n   If neither list works, rhyme by ear.':'3. Rhyme with "'+o.lw+'" by ear.'):'3. End on a word with plenty of rhymes.';
    var skip=GENHIST[o.k]&&GENHIST[o.k].length?'\n5. These were already suggested here and passed over — do not repeat them or near-identical rewordings of them, and vary the approach (different imagery, structure or end word) from all of them: '+GENHIST[o.k].map(function(x){return'"'+x+'"'}).join(' / ')+'.':'';
    aiJson('You write song lyrics.'+pfx()+'\n\n'+songCtx(o)+museCtx(o.section)+'\n\n'+o.task+'\n\nPriorities:\n1. Match the tone, writing style and imagery you just read in the section above — this comes before rhyme or syllable count.\n2. Aim for exactly '+o.n+' syllables, as close as you can.\n'+rule+'\n4. Twenty different options, and spread them across several different end words rather than reusing the same one or two rhyming words over and over. Mix exact/perfect rhymes with slant or near rhymes (words that share the vowel sound or final consonant sound but aren\'t identical) so the set offers real variety, not twenty ways to land on the same sound. Natural phrasing, no filler. Each string is just the lyric line itself — never follow it with its rhyme or end word repeated in parentheses or any other annotation.\n6. Every line must say something new. Never repeat, reword or reorder a line that is already in the song, especially the line it rhymes with: only the end sound should match that line, not its words, images or structure. Move the song forward.'+skip+'\n\nReturn ONLY a JSON array of 20 strings.',{cache:!o.again}).then(function(r){
      /* Belt-and-braces: even with the prompt now telling it not to, the model occasionally still
         echoes the end/rhyme word back in parentheses, e.g. "i walk in your room (room)". Strip a
         trailing "(word)" whenever it just repeats the line's own last word or the target rhyme
         word, rather than stripping any parenthetical (which could be a deliberate ad-lib). */
      function deparen(x){var m=x.match(/^(.*?)\s*\(([^()]{1,30})\)\s*$/);if(!m)return x;var core=m[1].trim(),paren=nw(m[2].trim());if(!core)return x;var lastWord=nw(lastW(core));if(paren===lastWord||(o.lw&&paren===nw(o.lw)))return core;return x}
      var seen={},l=(Array.isArray(r)?r:[]).filter(function(x){return typeof x==='string'&&x.trim()}).map(function(x){x=deparen(x.trim());var w=nw(lastW(x)),d=lsyl(x)-o.n,ty=!o.lw?'new':ps[w]?'perfect':ns[w]?'near':'loose';return{line:x,n:lsyl(x),d:d,type:ty,sc:Math.abs(d)+(ty==='near'?1.5:ty==='loose'?3.5:0)}}).filter(function(m){if(seen[m.line])return false;seen[m.line]=1;return true});
      l.sort(function(a,b){return a.sc-b.sc});
      /* drop stock phrases, words this writer keeps rejecting and lines already in the song, then let the
         judge score the best 14 and show the top 6: judged quality first, rhyme and syllable fit as tie-breaks */
      l=mzFilter(l,function(x){return x.line},6);
      var fin=function(js){var top=l.slice(0,14);
        if(js)top.forEach(function(x,i){x.js=js[i]!=null?js[i]:0;x.rk=x.js*1.0-x.sc*.55});
        if(js)top.sort(function(a,b){return b.rk-a.rk});
        var out=(js?top:l).slice(0,6);
        LSC[o.k]=out.length?{k:o.k,list:out,best:Math.min.apply(null,out.map(function(x){return x.sc})),kind:o.kind,a:o.a,b:o.b,src:o.src,judged:!!js}:{k:o.k,err:'No lines came back. Try again.'};rhyme();
        if(out.length&&document.body.classList.contains('kb')){var ae=document.activeElement;if(ae&&ae.blur&&(ae.id==='lyr'||ae.id==='title'))ae.blur()}};
      if(l.length<4)return fin(null);
      LSC[o.k]={k:o.k,busy:true,stage:'judge'};rhyme();
      mzJudge(l.slice(0,14).map(function(x){return x.line}),{section:o.section,what:o.task.slice(0,600)}).then(fin);
      return;
    },function(e){LSC[o.k]={k:o.k,err:e&&e.code==='not_granted'?'Allow access to get line suggestions.':'Could not get suggestions.'};rhyme()});
  });
}
```

- Prompt = `'You write song lyrics.' + pfx() + '\n\n' + songCtx(o) + museCtx(o.section) + '\n\n' + o.task +
  '\n\nPriorities:…'` (exact text above) with: target syllables `o.n` (melody phrase count, else partner line's
  syllables, else the previous line's, else 8); rule 3 lists up to 70 perfect rhymes and 24 near rhymes for the end word
  (from Datamuse/built-in, near omitted with "Perfect only"; for Rewrite/Tighten the original end word is allowed);
  rule 5 lists up to 30 lines already suggested and passed over at this spot (`GENHIST`).
- Returns `string[20]`. Post-processing: trim; strip a trailing `(word)` that just repeats the line's own last word or
  the target word (`deparen`); dedupe; classify end word: `perfect` (in perfect set), `near` (in near set), `loose`
  (neither), `new` (no target); fit score `sc = |syllables − n| + (near 1.5 | loose 3.5)`; sort ascending; `mzFilter`
  (min 6); if ≥4 remain → judge the top 14 (`mzJudge` with `what = task[0..600]`), rank `js − 0.55·sc`, show top 6;
  else show the first 6 by fit.
- Cache: `LSC[key]` with key `(partnerLine)#p#scheme+pfk()` for line writing, `S#next|rw|tighten#<selection>+pfk()` for
  selections; `again` (New ideas) bypasses and records the previous batch as passed.
- Errors: `not_granted` → "Allow access to get line suggestions."; otherwise "Could not get suggestions."; empty →
  "No lines came back. Try again."

### 2.4 Muse — Read my song (verbatim 17109–17121)

<!-- verbatim index.html lines 17109-17121 -->
```js
function readSong(){if(!needAI())return;var o=stkOut('<p>'+aidots()+' Reading your song</p>'),at=getSel().s,k=ctx(),tk=o.dataset.seq,live=function(){return o.dataset.seq===tk};
  aiJson('You are a songwriting mentor helping a writer who is stuck.'+pfx()+'\n\n'+songCtx({at:at})+museCtx(k.st)+'\n\nRespond as JSON: {"read": one or two plain sentences on what this song is really about so far and where it seems to stall, "questions": 3 short, specific questions about the song\'s subject that would dig up fresh material from the writer\'s real life, "moves": 8 objects {"idea": a short direction to take next (under 12 words), "line": a next line that starts that direction, in this writer\'s voice and matching the song\'s line length}}. The 8 moves must go in genuinely different directions. Be concrete, no flattery. If the song is empty, read the title, notes and brief and suggest openings.',{cache:false}).then(function(r){
    if(!live())return;if(!r||!r.moves){aiErr(o);return}
    var mv=mzFilter((Array.isArray(r.moves)?r.moves:[]).filter(function(m){return m&&typeof m.line==='string'&&m.line.trim()}),function(m){return m.line},4);
    var show=function(js){if(!live())return;o.innerHTML='';
      if(js){mv.forEach(function(m,i){m.js=js[i]!=null?js[i]:0});mv.sort(function(a,b){return b.js-a.js})}
      var p=document.createElement('p');p.textContent=r.read||'';o.appendChild(p);
      if(r.questions&&r.questions.length){var h=document.createElement('h4');h.textContent='Answer one of these in your head';o.appendChild(h);r.questions.forEach(function(q){var x=document.createElement('p');x.textContent='• '+q;o.appendChild(x)})}
      var h2=document.createElement('h4');h2.textContent='Ways forward (tap to add the line)';o.appendChild(h2);
      mv.slice(0,4).forEach(function(m){var row=mzLineRow(o,{line:m.line,meta:''},function(){insLine(m.line)},'muse'),b=row.querySelector('.ln');b.className='mv';b.innerHTML='<b></b><span></span><em></em>';b.children[0].textContent=m.idea||'';b.children[1].textContent=m.line;b.children[2].textContent=lsyl(m.line)+' syl · tap to add'});
      act(o,'Read again',readSong)};
    o.innerHTML='<p>'+aidots()+' Picking the best ways forward</p>';
    mzJudge(mv.map(function(m){return m.line}),{section:k.st,what:'the next line for this song'}).then(show)},function(){if(live())aiErr(o)})}
```

Prompt: `'You are a songwriting mentor helping a writer who is stuck.' + pfx() + songCtx({at: caret}) + museCtx(stanza)
+ instructions`; JSON `{read, questions[3], moves[8]{idea, line}}`; not cached. Moves → `mzFilter(min 4)` → judge
(`what: 'the next line for this song'`) → sorted by score; shows the read, questions and the top 4 moves.
Other Muse cards (Stare at a thing, Wild card, Pen never stops) are offline (lists `CARDS`, `NOUNS` at 17086–17087).

### 2.5 Rate (verbatim 17583–17595 tones, 17612–17645 run + context)

<!-- verbatim index.html lines 17583-17595 -->
```js
var TONE={
 enc:{label:'Encouraging',head:'Could be even stronger',
  who:'You are warm and encouraging: you believe in the song, you name what is working first and generously, and you frame anything weaker as an opportunity, never a verdict. Music is subjective and you hold that lightly — your read is one take on it, not a judgment.',
  cal:'Calibrate generously. Someone who cares enough to ask has a song worth taking seriously: a working draft that does its job usually sits around 7 to 8.5; a strong, distinctive song 9 and up; below 6.5 only if it genuinely is not working yet.',
  count:'Give 3-4 strengths and 0-2 opportunities, most valuable first — it is completely fine to raise nothing if the song is solid. Word each opportunity kindly and constructively, and only raise it if you are genuinely confident it would help.'},
 bal:{label:'Balanced',head:'Could be stronger',
  who:'You are fair and supportive: honest about weak spots, equally clear about what works. Music is subjective — you give your honest read, not a scorecard of flaws, and you stay generous about taste and genre choices you might not personally make.',
  cal:'A working draft by a capable writer usually sits around 6.5 to 8; strong, finished, distinctive writing goes higher; below 5.5 only if it genuinely is not working yet.',
  count:'Give 3-4 strengths and 1-3 issues, most important first.'},
 blunt:{label:'Blunt',head:'Where it falls apart',
  who:'You are direct and exacting, like a producer who respects the writer enough to be honest — but never cold, never cruel, and never forgetting that taste in music is subjective.',
  cal:'6 is competent but forgettable, 7.5 is good enough for a record, 9 and up is rare.',
  count:'Give 3 strengths and 2-3 issues, worst first — the ones genuinely worth a writer\'s time, not every nitpick.'}};
```

<!-- verbatim index.html lines 17612-17645 -->
```js
function runRate(){if(!aiAvailable()){rtNote('Rating needs a connection, which isn’t set up in this copy.');return}
  var v=getText();if(!v.trim()){toast('Write something to rate first');return}
  var part='',label='the whole song';if(rtScope==='sec'){var s=secAt(getSel().s);if(s){part=v.slice(s.a,s.b);label='the '+s.name+' section'}}if(rtScope==='sel'&&rtSel){part=v.slice(rtSel.a,rtSel.b);label='the selected lines'}
  rtBusy=true;buildRateHead();rtNote(aidots()+' Reading '+esc(label)+' like a listener would',true);
  var song=cur,prev=cur.rating&&cur.rating.scope===rtScope&&(cur.rating.tone||'blunt')===rtTone?cur.rating.overall:null;
  aiJson('You are a seasoned co-writer giving notes on song lyrics, the kind of person writers want in the room. '+TONE[rtTone].who+' Listen first, then judge.\n\nSTEP 1, understand before scoring. Work out what this song is going for: its genre and its conventions, the feeling it is chasing, who is singing to whom, and how finished it is (status: '+(cur.status||'Idea')+'; '+(v.split('\n').filter(function(l){return l.trim()&&l.trim()[0]!=='['}).length)+' lyric lines so far). Judge the song on its own terms. Simple words, repetition, a familiar phrase or a direct hook can be exactly right in pop, country, hip-hop or folk when they are earned; abstraction can be right in dreamy indie. Familiar is not the same as weak — a well-worn phrase, a simple rhyme, or a line that sounds like plenty of others in its genre can still be exactly the right line if it lands. Slang, colloquial speech, regional or genre dialect (AAVE in hip-hop and R&amp;B, Southern or Americana phrasing in country, text-speak or internet voice in pop, bent grammar used for rhythm, emphasis or attitude) is not a legibility or craft problem — judge it by how it sounds spoken or sung in that voice, never against formal grammar. Don\'t reward generic, workshop-polished, \'correct\' writing over something rougher that actually sounds like a person and fits the genre; technically tidy is not automatically better than something out there that works. Don\'t punish a deliberate choice. A sketch is rated on what is there and where it is heading, not on what is missing.\n\nRead every line in context, never in isolation. Before judging a line, ask what job it does in the song: a set-up that a later line pays off, a payoff, a plain line that makes the next image hit harder, a deliberate understatement, a callback to an earlier line, a twist on a repeated phrase, a transition into a new section, the hook, or a rhyme partner that works as a couplet. A line that looks flat or obvious on its own may be doing exactly its job. Section roles matter too: verses set scenes, pre-choruses build, choruses land the idea, bridges turn it. Only flag a line if it still fails once you account for what it sets up or pays off, and when you do, say why in terms of its role (for example: the set-up promises something the payoff never delivers).\n\nTHE SONG’S WORLD. Before judging any line, map the song’s world: its recurring images, motifs and settings, the metaphors it keeps returning to, and how its images connect across sections (for example a door in verse one that becomes a closed road in the bridge). A line that belongs to this world, extends a motif, or echoes an earlier image is working, even if it is abstract, surprising or unexplained on its own. Songs are allowed to leave images unexplained when the whole earns them. Never mark a line down for being unusual if it fits the world.\n\nCOHESION, LINE AGAINST LINE. Separately from the song\'s world, read the lines against each other in sequence, not just each on its own: does it keep a consistent tense and point of view, or drift without reason; do the verses echo or escalate the idea rather than repeat it with nothing new; does the hook or chorus feel earned by what led into it; does the ending answer, pay off or recontextualize the opening rather than just stopping. Score cohesion on how well the lines build on each other as a sequence, not on how good any single line is alone — a song of strong individual lines that never build on each other scores lower on cohesion than a simpler song that clearly goes somewhere.\n\nTHE WRITER’S PERSONALITY. Learn how this writer writes from this song, their other songs below, and what you have learned about them before: plain-spoken or ornate, literal or impressionistic, how they use rhyme, repetition, humour, fragments, slang and line length. This read updates every time you rate them — weigh what you\'re seeing in THIS song and what you\'ve learned across their other songs above any generic idea of \'good writing\'. Their habits are their voice, not mistakes. Judge the song against the best version of THIS writer, not against a generic ideal.\n\nWhen unsure whether a line is a flaw or a choice, treat it as a choice. Fewer, sharper notes beat many weak ones. Remember music is subjective: you are offering one experienced ear\'s honest read, not a final verdict, so stay generous and lead with what is working. Being insightful means explaining WHY something lands or doesn\'t in terms specific to this song, not cataloguing everything that could theoretically be improved — a song can be genuinely good with real weak spots left unmentioned because they are not worth this writer\'s time right now.\n\nSTEP 2, score each dimension 0-10 (one decimal) on how well it achieves what THIS song is going for:\n- cleverness: moments of craft that make you lean in (an image, a turn, a rhyme, a twist), relative to the style\n- legibility: does the listener get what they need to feel it; clear enough for the style\n- cohesion: judged line against line and section against section — does it build as one song rather than a pile of unrelated good lines\n- voice: does it sound like someone, and fit the writer\'s chosen voice settings when they set any\nUse your judgment rather than a formula. '+TONE[rtTone].cal+' Overall is your gut feel as a listener, not an average.\n\nThe writer\'s voice settings:'+pfx()+writerContext()+'\n\nSong: '+(cur.title||'Untitled')+(cur.artist?' by '+cur.artist:'')+(cur.notes?'\nWriter\'s notes: '+cur.notes.slice(0,400):'')+'\n\nFull lyrics:\n'+v.slice(0,7000)+(part?'\n\nRate ONLY this part, using the rest as context:\n'+part:'')+intentText()+
  '\n\nReturn JSON exactly like (fill "world" and "personality" FIRST, then judge with them in mind): {"world":"one or two sentences: the song\'s image world, motifs and how they connect","personality":"one or two sentences: how this writer writes, their habits and strengths","intent":"one sentence: what this song is going for and how you read it","overall":0,"verdict":"one or two sentences, a human reaction, lead with what lands","potential":{"score":0,"how":"one sentence: the single change that would lift it most"},"scores":{"cleverness":{"score":0,"why":"one sentence"},"legibility":{"score":0,"why":""},"cohesion":{"score":0,"why":""},"voice":{"score":0,"why":""}},"strengths":[{"quote":"","role":"1-3 words","note":""}],"issues":[{"quote":"","role":"what this line is doing in the song, 1-3 words (e.g. set-up, payoff, hook, transition, image, callback)","problem":"why it falls short in context","check":"why this is not explained by the song\'s world or the writer\'s style","confidence":0.0,"fix":""}]}\n'+TONE[rtTone].count+' Only raise what a good co-writer actually would. Give each issue a confidence from 0 to 1 that it is a real weakness rather than a deliberate choice. Every quote must be copied EXACTLY from the lyrics (a phrase or a full line). Each fix is a concrete direction, not a rewritten line.',{cache:false,modelTier:'complex'}).then(function(r){
    rtBusy=false;if(!r||typeof r.overall!=='number'||!r.scores){rtNote('That didn’t come back cleanly. Try again.');buildRateHead();return}
    var sq={};(r.strengths||[]).forEach(function(x){sq[(x.quote||'').toLowerCase()]=1});
    r.issues=(r.issues||[]).filter(function(x){var q=(x.quote||'').toLowerCase();if(sq[q])return false;for(var k in sq){if(k&&(k.indexOf(q)>=0||q.indexOf(k)>=0))return false}return typeof x.confidence!=='number'||x.confidence>=0.72});
    if(typeof r.personality==='string')r.personality=r.personality.slice(0,300);
    r.t=Date.now();r.scope=rtScope;r.tone=rtTone;r.prev=prev;r.marks=true;song.rating=r;song.updated=Date.now();save();if(cur===song){buildRateHead();renderRating();refreshViews()}haptic('success');
  },function(e){rtBusy=false;buildRateHead();rtNote(e&&e.code==='not_granted'?'Allow access to get a rating.':'Couldn’t get a rating. Try again in a moment.')})}
function rtNote(t,html){var o=$('#rt-out');o.innerHTML='';var g=document.createElement('div');g.className='gf accg';o.appendChild(g);var c=document.createElement('div');c.className='cell notile';var ct=document.createElement('span');ct.className='ct';if(html)ct.innerHTML=t;else ct.textContent=t;c.appendChild(ct);g.appendChild(c)}
/* the writer: their other songs, what earlier ratings learned, and choices they've kept on purpose */
/* What Rate has learned about the writer lives on their songs (each rating keeps its read of their style,
   each "I meant that" keeps the line and why), so it's per account and syncs with the library. The muse
   (museCtx) and the voice profile (mzProfBuild) read the same notes, and Rate reads the voice profile. */
try{localStorage.removeItem('songpad:writer')}catch(e){}
function rateReads(n,skip){return songs.filter(function(s){return s!==skip&&s.id!==GUIDE_ID&&s.rating&&typeof s.rating.personality==='string'&&s.rating.personality.trim()})
  .sort(function(a,b){return(b.rating.t||0)-(a.rating.t||0)}).slice(0,n).map(function(s){return s.rating.personality.slice(0,300)})}
function meantChoices(n,skip){var out=[];songs.forEach(function(s){if(s===skip||s.id===GUIDE_ID)return;(s.intents||[]).forEach(function(x){if(x&&x.quote)out.push({q:x.quote,why:x.why||'',t:x.t||0})})});
  return out.sort(function(a,b){return a.t-b.t}).slice(-n)}
function writerContext(){var out='',others=songs.filter(function(s){return s!==cur&&(s.lyrics||'').trim()}).sort(function(a,b){return b.updated-a.updated}).slice(0,6);
  if(others.length)out+='\n\nOther songs by this writer (for their style only, do not rate these):\n'+others.map(function(s){return'- '+(s.title||'Untitled')+': '+llines(s).slice(0,6).join(' / ')}).join('\n');
  if(MZ.prof&&MZ.prof.text)out+='\n\nHow this writer writes (their voice profile, learned from all their songs and from which suggestions they kept, rewrote and threw out; judge against this voice, not a generic ideal):\n'+MZ.prof.text.slice(0,1400);
  var w=rateReads(6,cur);if(w.length)out+='\n\nWhat earlier readings learned about this writer:\n'+w.map(function(x){return'- '+x}).join('\n');
  var kept=meantChoices(10,cur);if(kept.length)out+='\n\nLines in other songs this writer told you were deliberate when they were questioned (their habits, not mistakes):\n'+kept.map(function(x){return'- '+mzQ(x.q)+(x.why?' ('+x.why+')':'')}).join('\n');
  var br=mzBrief(cur);if(br)out+='\n\nWhat the writer told you about this song (use it to understand what it\'s going for and who is singing to whom; never mark a line down for not using these details):\n'+br;
  return out}
function intentText(){var a=(cur&&cur.intents)||[];if(!a.length)return'';return'\n\nThe writer has told you these choices are deliberate. Respect them: do not raise them as issues again, and re-judge the scores they affect with the intent in mind. If the intent makes the line work, credit it; only mention one if it truly undermines something else, and then gently:\n'+a.map(function(x){return'- "'+x.quote+'"'+(x.why?' (writer: '+x.why+')':' (no reason given)')}).join('\n')}
function keepIntent(it,why){if(!cur)return;cur.intents=(cur.intents||[]).filter(function(x){return x.quote!==it.quote});cur.intents.push({quote:it.quote,why:why,t:Date.now()});mzProfAuto();
  var R=cur.rating;if(R&&R.issues)R.issues=R.issues.filter(function(x){return x!==it});cur.updated=Date.now();save();refreshViews();renderRating();toast('Got it. Re-rating with that in mind.');runRate()}
function findQuote(q){var v=getText();if(!q)return null;var i=v.indexOf(q);if(i<0){i=v.toLowerCase().indexOf(q.toLowerCase())}if(i<0){var s=q.replace(/[“”"]/g,'').trim();i=v.toLowerCase().indexOf(s.toLowerCase());if(i>=0)return[i,i+s.length];return null}return[i,i+q.length]}
```

- `modelTier: 'complex'`, not cached. Prompt = tone `who` + the long rubric + `pfx()` + `writerContext()` (up to 6 other
  recent songs as "Title: line / line / …" (first 6 lyric lines), the voice profile (1400 chars), up to 6 earlier Rate
  "personality" reads, up to 10 "I meant that" intents from other songs, the song brief) + title/artist/notes + full
  lyrics (first 7000 chars) + optional "Rate ONLY this part…" + `intentText()` (this song's deliberate choices) + the
  JSON shape + tone `count`.
- Response shape: `{world, personality, intent, overall, verdict, potential:{score, how}, scores:{cleverness, legibility,
  cohesion, voice:{score, why}}, strengths:[{quote, role, note}], issues:[{quote, role, problem, check, confidence, fix}]}`.
- Validation: must have numeric `overall` and `scores`. Post-filter issues: drop any whose quote equals/contains/is
  contained in a strength quote; drop issues with `confidence < 0.72` (missing confidence keeps it). `personality`
  truncated to 300 chars. Saved as `song.rating = r + {t, scope, tone, prev, marks:true}` where `prev` = previous overall
  when the previous rating had the same scope and tone (for the delta).
- `rateReads(n)` (latest personalities) and `meantChoices(n)` (intents across songs) also feed the voice profile and
  `museCtx` — Rate, the muse and the profile learn from each other.
- Quotes are located in the lyrics by exact match, then case-insensitive, then with quotes stripped (`findQuote`).

### 2.6 Writing voice profile ("How the muse sees your writing") — `mzProfBuild` (verbatim 16832–16857)

<!-- verbatim index.html lines 16832-16857 -->
```js
/* ---------- voice profile: a short description of how this writer writes ----------
   Written by the stronger model from their catalogue plus what they kept, rewrote and threw out.
   Rebuilt on its own every 25 new outcomes or two weeks, never over a version the writer edited
   themselves (until they tap Relearn). Shown and editable in Writing voice. */
function mzProfStore(push){try{localStorage.setItem(mzKey('prof'),JSON.stringify(MZ.prof))}catch(e){}
  var c=push&&mzCloud();if(c&&MZ.prof)c.from('muse_profile').upsert({user_id:AUTH_USER.id,profile:MZ.prof.text||'',edited:!!MZ.prof.edited,basis:MZ.prof.n||0,updated_at:new Date(MZ.prof.at||Date.now()).toISOString()},{onConflict:'user_id'}).then(function(r){if(r.error&&mzMissing(r.error))MZ.noTable=true})}
function mzCatalog(){var out=[];songs.forEach(function(s){if(s.id===GUIDE_ID)return;(s.lyrics||'').split('\n').forEach(function(l){l=l.trim();if(l&&l[0]!=='[')out.push(l)})});return out}
function mzOutcomes(){var n=0;songs.forEach(function(s){n+=(s.intents||[]).length});return MZ.ev.filter(function(e){return e.o!=='passed'}).length+n}
function mzProfAuto(){if(MZ.building||!isPro()||!aiAvailable())return;if(MZ.prof&&MZ.prof.edited)return;
  var n=mzOutcomes(),lines=mzCatalog().length;if(lines<16)return;
  if(!MZ.prof||!MZ.prof.text||n-(MZ.prof.n||0)>=25||(Date.now()-(MZ.prof.at||0)>14*864e5&&n>(MZ.prof.n||0)))mzProfBuild()}
function mzProfBuild(manual){if(MZ.building)return Promise.resolve(null);MZ.building=true;var forUid=MZ.uid;
  var hk=hookLines(),pool=[];songs.slice().sort(function(a,b){return(b.updated||0)-(a.updated||0)}).forEach(function(s){if(s.id===GUIDE_ID)return;var ls=(s.lyrics||'').split('\n').map(function(x){return x.trim()}).filter(function(x){return x&&x[0]!=='['});if(ls.length)pool.push({t:s.title||'Untitled',ls:ls})});
  var sample=[],budget=9000;pool.forEach(function(p){if(budget<=200)return;var chunk=p.ls.slice(0,16).map(function(l){return l.slice(0,200)}).join('\n').slice(0,budget);budget-=chunk.length;sample.push('['+String(p.t).slice(0,80)+']\n'+chunk)});
  var ed=mzRecent('edited',12),kp=mzRecent('kept',10),rj=MZ.ev.filter(function(e){return(e.o==='reject'||e.o==='deleted')&&e.shown}).slice(-12);
  var pr='You are studying a songwriter so a writing assistant can write lines that sound like them and not like generic AI lyrics.\n\nTheir songs (most recent first):\n'+sample.join('\n\n')+
    (hk.length?'\n\nLines they marked as favourites: '+hk.map(mzQ).join(' / '):'')+
    (ed.length?'\n\nSuggestions they rewrote (suggested -> their version):\n'+ed.map(function(e){return mzQ(e.shown)+' -> '+mzQ(e.final)}).join('\n'):'')+
    (kp.length?'\n\nSuggestions they kept as written:\n'+kp.map(function(e){return mzQ(e.shown)}).join('\n'):'')+
    (rj.length?'\n\nSuggestions they threw out:\n'+rj.map(function(e){return mzQ(e.shown)+(e.why&&MZ_WHYL[e.why]?' ('+MZ_WHYL[e.why].toLowerCase()+')':'')}).join('\n'):'')+
    (function(){var mc=meantChoices(12);return mc.length?'\n\nLines of theirs a critic questioned that they defended as deliberate (strong evidence of their habits):\n'+mc.map(function(x){return mzQ(x.q)+(x.why?' ('+x.why+')':'')}).join('\n'):''})()+
    (function(){var rr=rateReads(4);return rr.length?'\n\nHow a critic who read their songs described their writing (secondary evidence; trust the lyrics over it):\n'+rr.map(function(x){return'- '+x}).join('\n'):''})()+
    '\n\nWrite a voice profile of 120 to 200 words as direct instructions to someone writing lines for them ("Uses...", "Never..."). Cover: what kind of concrete details and nouns they reach for; how literal or oblique they are; vocabulary and register (slang, swearing, plainness); line length and rhythm; how they rhyme (perfect, slant, internal, or loose); point of view and who they talk to; recurring themes; and what they clearly avoid. Be specific to THIS writer and quote short fragments of their own words as evidence. No praise, no generic advice that would fit any songwriter. Return JSON: {"profile":"..."}';
  if(pr.length>20000)pr=pr.slice(0,19000)+'\n\nWrite a voice profile of 120 to 200 words as direct instructions. Return JSON: {"profile":"..."}';
  return aiJson(pr,{modelTier:'complex',cache:false}).then(function(r){if(MZ.uid!==forUid)return null;MZ.building=false;var t=r&&typeof r.profile==='string'?r.profile.trim():'';if(!t)return null;if(!manual&&MZ.prof&&MZ.prof.edited)return null;
    MZ.prof={text:t,edited:false,at:Date.now(),n:mzOutcomes()};mzProfStore(true);if($('#sheet2')&&$('#sheet2').classList.contains('on'))buildSettings();return t},function(){MZ.building=false;return null})}
```

- `modelTier: 'complex'`, JSON `{profile}`, 120–200 words of instructions. Sample: songs by most recent, each up to 16
  lines ×200 chars, total budget 9000 chars; + favourite Hook lines, last 12 rewrites (suggested → theirs), 10 kept,
  12 thrown out (with reasons), 12 defended intents, 4 Rate reads. Prompt >20,000 chars is cut to 19,000 + a short
  instruction.
- Auto rebuild (`mzProfAuto`): Pro + AI available + profile not hand-edited + catalogue ≥16 lyric lines, and (no profile
  yet, or ≥25 new outcomes since the last build, or >14 days old with any new outcome). Outcomes = muse events except
  `passed` + all intents. Manual **Relearn** overwrites even an edited profile. Stored `{text, edited, at, n}` locally
  and in `muse_profile`.

### 2.7 Word-level AI: phrase rhymes, meaning lists, definitions, context ranking

Phrase rhymes (verbatim 16595–16597; Pro; cache key `'PHR#'+nw(sel)+'#'+syllables+pfk()` in `MC`):

<!-- verbatim index.html lines 16595-16597 -->
```js
    var pr=aiJson('Songwriting helper.'+pfx()+'\n\n'+songCtx({at:c.ls})+'\n\nThe writer selected this phrase from the line: "'+selPhrase+'" ('+n+' syllables, ending in a word that rhymes with "'+endw+'"). Suggest 16 short alternative phrases of about the same length ('+n+' syllables, give or take one) that end in a word rhyming with "'+endw+'" — match the ending sound closely, syllable by syllable — and fit the song\'s voice and context above, so swapping the phrase in keeps the line\'s rhythm and meaning going in the same direction. Avoid using the exact same end word on more than two or three of the sixteen — spread them across different words that share that rhyme, mixing perfect rhymes with slant/near rhymes (same vowel sound or final consonant, not identical) so the options feel varied, not repetitive. Return ONLY a JSON array of strings, each a short phrase, no explanations or numbering.',{cache:true}).then(function(r){
      return(Array.isArray(r)?r:[]).filter(function(x){return typeof x==='string'&&x.trim()}).map(function(x){return x.trim()}).filter(function(x){return nw(x)!==nw(selPhrase)})
    },function(){return[]});
```

Meaning lists fallback (verbatim 16932, 16959; Pro; key `mode|word(|c)`), definitions fallback (16948; key
`DEF|word`), context ranking (17038–17045; Pro + ctx on + ≥4 candidates; key `word|line+pfk()` in `RK`):

<!-- verbatim index.html lines 16932-16932 -->
```js
var AIQ={phr:'short phrases (2 to 4 words) whose final word rhymes with it, to end a lyric line',syn:'synonyms and words with a similar meaning that could replace it in the line',rel:'words strongly associated with it (images, objects, places, feelings) to spark the next line',adj:'vivid adjectives that could describe it',ant:'opposites and contrasting words',snd:'words that sound similar through assonance or consonance but are not exact rhymes'};
```

<!-- verbatim index.html lines 16959-16959 -->
```js
  pr=pr.catch(function(){if(!aiAvailable()||!isPro())return[];return aiJson('Songwriting helper.'+pfx()+'\n\nWord: "'+w+'"\nLyric line it appears in: "'+line+'"'+(VIEW.ctx?'\n\n'+songCtx({at:getSel().s})+'\nPick words that suit this song.':'')+'\n\nList 24 '+AIQ[m]+'. Fit the voice above. Lowercase, no duplicates, no explanations. Return ONLY a JSON array of strings.',{cache:true}).then(function(r){return(Array.isArray(r)?r:[]).filter(function(x){return typeof x==='string'&&x.trim()}).map(function(x){return x.trim().toLowerCase()}).filter(function(x){return x!==nw(w)})},function(){return[]})}).then(function(a){MC[k]=a;return a});
```

<!-- verbatim index.html lines 16948-16950 -->
```js
    return aiJson('You are a dictionary.'+pfx()+'\n\nDefine the word "'+w+'" as it is normally used, ordinary dictionary style. Give up to 3 concise senses, each under 18 words, no song-specific invention and no example sentences. Return ONLY a JSON array of objects like {"pos":"noun","text":"..."}; pos may be empty if unsure.',{cache:true}).then(function(r){
      return(Array.isArray(r)?r:[]).filter(function(x){return x&&typeof x.text==='string'&&x.text.trim()}).slice(0,6).map(function(x){return{pos:String(x.pos||'').trim(),text:x.text.trim()}})
    },function(){return[]})
```

<!-- verbatim index.html lines 17038-17045 -->
```js
function rankGet(w,line,list,at){if(!isPro())return null;
  if(list.length<4)return null;var k=nw(w)+'|'+nw(line)+pfk(),v=RK[k];if(v)return v;
  RK[k]={busy:true};var want=nw(w);
  aiJson('Songwriting helper.'+pfx()+'\n\n'+songCtx({at:at})+'\n\nThe writer wants a word that rhymes with "'+w+'" for the line: "'+line+'". From the candidates below, choose the 30 that best fit this song\'s meaning, imagery and voice, best first. Use only words from the list, exactly as written.\nCandidates: '+list.join(', ')+'\n\nReturn ONLY a JSON array of strings.',{cache:true}).then(function(r){
    var ok={};list.forEach(function(x){ok[x]=1});RK[k]={list:(Array.isArray(r)?r:[]).map(function(x){return String(x).toLowerCase().trim()}).filter(function(x){return ok[x]})};
    if(!lines&&nw(ctx().word||'')===want)rhyme()},function(){RK[k]={list:[]}});
  return RK[k];
}
```

### 2.8 Lyric sync (AI audio)

Not an LLM prompt: audio goes to the Supabase Edge Function **`lyric-sync`** (Whisper). Multipart form: `audio` (a 48 kbps
mono MP3 piece, or 16 kHz WAV fallback) and `prompt` (the lyric lines joined with `\n`, used as Whisper's hint). See §4.
It is covered by the same AI consent.

### 2.9 Clean up is **not** AI (deterministic, §3).

### 2.10 Summary table

| Feature | Function | Tier | Cache key | Output |
|---|---|---|---|---|
| Lines – write line N | `suggest`→`runGen` | default | `tl#p#scheme`+pfk | string[20] → filter → judge → 6 |
| Lines – selection | `selGen`→`runGen` | default | `S#kind#sel`+pfk | same |
| Judge | `mzJudge` | default | none | `[{i,s}]` |
| Phrase rhymes | in `rhyme()` | default | `PHR#…`+pfk | string[16] |
| Meaning lists (fallback) | `mlist` | default | `mode\|word(\|c)` | string[24] |
| Define (fallback) | `defLookup` | default | `DEF\|word` | `[{pos,text}]`≤3 |
| Context ranking | `rankGet` | default | `word\|line`+pfk | string[30] subset |
| Read my song | `readSong` | default | none | `{read,questions,moves}` |
| Rate | `runRate` | complex | none (saved on song) | rating object |
| Voice profile | `mzProfBuild` | complex | none (saved) | `{profile}` |
| Lyric sync | `runSync` | Whisper | saved on song | words with times |

---

## 3. Text utilities

### 3.1 Clean up — `cleanLyrics(text, o)` and helpers (verbatim 18057–18079)

<!-- verbatim index.html lines 18057-18079 -->
```js
var CU={caseMode:null,stream:false,tags:true};
var TAGRX=/^\s*[\[(]?\s*(intro|verse|pre[\s-]?chorus|chorus|post[\s-]?chorus|refrain|hook|bridge|break|interlude|instrumental|solo|tag|outro|coda|ad[\s-]?libs?)\s*(\d+)?\s*[\])]?\s*:?\s*$/i;
function tagName(m){var n=m[1].toLowerCase().replace(/[\s-]+/g,'-');var map={'pre-chorus':'Pre-Chorus','post-chorus':'Post-Chorus','ad-lib':'Ad-Libs','ad-libs':'Ad-Libs'};return'['+(map[n]||n.charAt(0).toUpperCase()+n.slice(1))+(m[2]?' '+m[2]:'')+']'}
function lineCase(l){var letters=l.replace(/[^A-Za-z]/g,'');if(letters.length<2)return null;if(letters===letters.toUpperCase())return'caps';if(letters===letters.toLowerCase())return'lower';return/^[^A-Za-z]*[A-Z]/.test(l)?'sentence':'mixed'}
function detectCase(text){var n={caps:0,lower:0,sentence:0,mixed:0};text.split('\n').forEach(function(l){if(!l.trim()||TAGRX.test(l)||/^\s*\[/.test(l))return;var c=lineCase(l);if(c)n[c]++});
  var tot=n.caps+n.lower+n.sentence+n.mixed;if(!tot)return'sentence';if(n.caps/tot>=.5)return'caps';if(n.lower/tot>=.5)return'lower';return'sentence'}
function cleanLyrics(text,o){var out=[],L=text.replace(/\r/g,'').replace(/\t/g,' ').split('\n');
  L.forEach(function(raw){var l=raw.replace(/[  -​]/g,' ').replace(/ {2,}/g,' ').trim();
    var m=TAGRX.exec(l)||(/^\[([^\]]+)\]$/.exec(l)&&[l,l.slice(1,-1)]);
    if(m){if(!o.tags)return;out.push({tag:true,s:TAGRX.test(l)?tagName(TAGRX.exec(l)):'['+m[1].trim().replace(/\b\w/g,function(c){return c.toUpperCase()})+']'});return}
    if(!l){out.push({blank:true});return}
    l=l.replace(/[‘’ʼ]/g,"'").replace(/[“”]/g,'"').replace(/\s+([,.!?;:])/g,'$1').replace(/([,!?;:])(?=[A-Za-z])/g,'$1 ');
    var rep=1,rm=/\s*[\(\[]?\s*[x×]\s?(\d)\s*[\)\]]?\s*$/i.exec(l);if(rm&&+rm[1]>1&&+rm[1]<9){rep=+rm[1];l=l.slice(0,rm.index).trim()}
    if(o.caseMode==='caps')l=l.toUpperCase();
    else if(o.caseMode==='lower')l=l.toLowerCase();
    else{if(lineCase(l)==='caps')l=l.toLowerCase();l=l.replace(/\bi(?=\b|'(m|ll|ve|d|s)\b)/g,'I');l=l.replace(/^([^A-Za-z]*)([a-z])/,function(_,a,b){return a+b.toUpperCase()})}
    if(o.stream){l=l.replace(/[,.;:\-–—]+$/,'').replace(/\.{2,}$/,'').trim()}
    if(o.stream&&rep>1){for(var i=0;i<rep;i++)out.push({s:l})}else out.push({s:l+(rep>1?' (x'+rep+')':'')});
  });
  var res=[];out.forEach(function(x,i){if(x.blank){if(res.length&&res[res.length-1]!==''&&!(res.length&&/^\[/.test(res[res.length-1])))res.push('');return}
    if(x.tag){if(res.length&&res[res.length-1]!=='')res.push('');res.push(x.s);return}res.push(x.s)});
  while(res.length&&res[res.length-1]==='')res.pop();return res.join('\n')}
function cuDiff(a,b){var A=a.split('\n'),B=b.split('\n'),n=0,m=Math.max(A.length,B.length);for(var i=0;i<m;i++)if((A[i]||'')!==(B[i]||''))n++;return n}
```

Rules, per line (after `\r` removed, tabs → space):
1. Replace no-break and typographic spaces (character class U+00A0 and U+2000–U+200B: NBSP, en/em/thin/hair spaces,
   zero-width space; written as literal characters in the source regex) with a normal space; collapse runs; trim.
2. **Section tags**: a line matching `TAGRX` — optional `[` or `(`, one of intro, verse, pre-chorus (pre chorus /
   prechorus), chorus, post-chorus, refrain, hook, bridge, break, interlude, instrumental, solo, tag, outro, coda,
   ad-lib(s), optional number, optional `]`/`)`, optional `:` — becomes a canonical tag via `tagName`: `[Verse 2]`,
   `[Pre-Chorus]`, `[Post-Chorus]`, `[Ad-Libs]`, others capitalised (`[Chorus]`, `[Bridge]`…). Any other `[…]` line is
   kept as a tag with each word capitalised. With "Section tags: Remove", tag lines are dropped.
3. Blank lines collapse to one, never directly after a tag; a blank line is inserted before each tag (except at the top);
   trailing blanks removed.
4. Typographic quotes → straight (`‘ ’ ʼ` → `'`, `“ ”` → `"`); no space before `, . ! ? ; :`; a space after `, ! ? ; :`
   when followed by a letter.
5. Repeat markers at the end of a line: `x2`, `×3`, `(x2)`, `[x4]` (2–8) are parsed. Tidy: kept, normalised as
   ` (x2)`. Streaming-ready: the line is written out that many times.
6. Case: ALL CAPS / lowercase modes convert the whole line. Sentence mode: lines that were all caps are lowercased first;
   standalone `i` and `i'm/i'll/i've/i'd/i's` → `I`; first letter of the line capitalised.
7. Streaming-ready also strips trailing `, . ; : - – —` and trailing `..`/`...`.
- `detectCase(text)`: classify each non-tag line with ≥2 letters as caps / lower / sentence (first letter upper) / mixed;
  ≥50% caps → `caps`, ≥50% lower → `lower`, else `sentence` (also when no lines).
- "N lines will change" = `cuDiff` = count of line indices whose text differs (not a real diff).
- Applying: `snap('Before clean-up')`, `lyrics = cleaned`, `rich = ''`, re-bold tags.

### 3.2 Section labels and stanzas
- A tag line is `/^\s*\[([^\]]+)\]\s*$/` (editor/Rate/melody) — `llines`, sync and cover use "trimmed line starts with
  `[`" / `/^\[[^\]]*\]$/`.
- Stanza boundaries for rhyme schemes / rhyme map = blank lines **and** tag lines.
- `sections()` (17598) = list of `{name, a, b}` character ranges from each tag to the next; `secAt(pos)` = the last
  section starting at or before `pos`. Section name normalisation for melody: strip a trailing number or `x2`, lowercase
  (`secName`).
- `chorusText()` (17046): lines after the first `[Chorus]` until a blank line or tag.

### 3.3 Lyric line helpers
- `llines(s)` (15866) = non-empty lines whose trimmed text doesn't start with `[` — used for list subtitles, credits,
  Rate's other songs.
- `getText()` = plain text from the editor (BR → `\n`, final `\n` dropped).
- `wordAt`, `lastW` (last `[A-Za-z']+` token), `shortSel` (tags stripped, collapsed, ≤22 chars cut at a word + "…").
- `lyricSig(song)` = synced-line signature (non-empty, non-tag lines joined) — decides "Lyrics changed since".

### 3.4 Chords
There is no chord engine beyond the key-based chip palette (features doc §2.1, `chordChips` 15930) and plain-text chord
sheets in `song.chords`. Chords are not parsed, transposed or aligned to lyrics. `fromText` reads them from a
`--- Chords ---` section.

### 3.5 Text tokens used by AI-adjacent features
- `STOP` words (17049) — excluded from rhyme map, topics, muse word stats.
- `topics()` (17037) — top 5 song words for Datamuse `topics=`.
- `mzNorm` (lowercase, curly → straight apostrophe, non `[a-z0-9' ]` → space, collapse) and `mzSim` (Dice coefficient
  over word multisets) — used for outcome tracking.

### 3.6 Import from text — `fromText` and backup (verbatim 17694–17699, 17714)

<!-- verbatim index.html lines 17694-17699 -->
```js
function fromText(txt,name){txt=txt.replace(/\r/g,'');var L=txt.split('\n'),title=(L[0]||'').trim(),i=1,meta={};
  if(L[1]&&/ · |^(by |Key: |Status: |Capo: |Tuning: )|BPM/.test(L[1])){L[1].split(' · ').forEach(function(p){var m;if(/^by /.test(p))meta.artist=p.slice(3);else if((m=/^Key: (.*)/.exec(p)))meta.key=m[1];else if((m=/^(\d+) BPM/.exec(p)))meta.bpm=m[1];else if((m=/^Capo: (.*)/.exec(p)))meta.capo=m[1];else if((m=/^Tuning: (.*)/.exec(p)))meta.tuning=m[1];else if((m=/^Status: (.*)/.exec(p)))meta.status=m[1]});i=2}
  var body=L.slice(i).join('\n').replace(/^\n+/,''),ch='',nt='',ci=body.indexOf('\n--- Chords ---\n'),ni=body.indexOf('\n--- Notes ---\n');
  if(ni>=0){nt=body.slice(ni+15).trim();body=body.slice(0,ni)}if(ci>=0){ch=body.slice(ci+16).trim();body=body.slice(0,ci)}
  if(!title||title.length>80){body=txt;title=(name||'Imported').replace(/\.[^.]+$/,'')}
  return Object.assign({id:'s'+Date.now()+Math.floor(Math.random()*1e4),title:title,lyrics:body.replace(/\s+$/,''),chords:ch,notes:nt,status:'Idea',folder:'',updated:Date.now()},meta)}
```

<!-- verbatim index.html lines 17714-17714 -->
```js
function backupJSON(){return JSON.stringify({app:'*[demo]',saved:new Date().toISOString(),songs:songs.filter(function(s){return!s.shared}).map(function(s){var o={};Object.keys(s).forEach(function(k){if(k[0]!=='_')o[k]=s[k]});return o})},null,1)}
```

Text format: line 1 = title; optional line 2 meta joined with ` · ` (`by Artist`, `Key: X`, `N BPM`, `Capo: X`,
`Tuning: X`, `Status: X`); then lyrics; optional `\n--- Chords ---\n` and `\n--- Notes ---\n` sections (notes after
chords). If line 1 is empty or >80 chars the whole file is the lyrics and the title is the filename without extension.
Note the generated id is `'s'+timestamp+random` (not a UUID; it's converted to a UUID when the song is first shared).

---

## 4. Lyric sync engine (verbatim 20041–20142)

<!-- verbatim index.html lines 20041-20142 -->
```js
function syncLinesOf(text){var out=[];(text||'').split('\n').forEach(function(l){var t=l.trim();if(t&&!/^\[[^\]]*\]$/.test(t))out.push(t)});return out}
function lyricSig(song){return syncLinesOf(song&&song.lyrics).join('\n')}
function normWords(s){return(s||'').toLowerCase().replace(/[’‘`']/g,'').replace(/&/g,' and ').replace(/[^a-z0-9\s]+/g,' ').split(/\s+/).filter(Boolean)}
function levD(a,b){var m=a.length,n=b.length,p=[],c,i,j;for(j=0;j<=n;j++)p[j]=j;for(i=1;i<=m;i++){c=[i];for(j=1;j<=n;j++)c[j]=Math.min(p[j]+1,c[j-1]+1,p[j-1]+(a[i-1]===b[j-1]?0:1));p=c}return p[n]}
var SYNC_STOP={a:1,an:1,the:1,i:1,im:1,you:1,me:1,my:1,we:1,it:1,its:1,is:1,was:1,be:1,to:1,of:1,in:1,on:1,at:1,and:1,or:1,but:1,so:1,for:1,your:1,oh:1,ooh:1,yeah:1,la:1,na:1,da:1};
function wordScore(a,b){if(a===b)return SYNC_STOP[a]?2:4;if(a.length<3||b.length<3)return-2;return levD(a,b)/Math.max(a.length,b.length)<=.34?2:-2}
/* Line up the lyric's words with the words Whisper heard (a sequence alignment: lyric words in order
   against heard words in order), then give each line the time its first matched word was sung.
   Heard words that aren't in the lyric (ad-libs, a chorus sung more times than it's written, talking
   in the intro) are cheap to skip, and leading/trailing ones are free. Lines nothing matched get a
   time spread evenly between their timed neighbours. */
function alignLyrics(lines,words){
  var L=[],li=[];lines.forEach(function(l,i){normWords(l).forEach(function(w){L.push(w);li.push(i)})});
  var W=[],wt=[];(words||[]).forEach(function(x){normWords(x.w).forEach(function(w){W.push(w);wt.push(+x.s||0)})});
  var n=L.length,m=W.length,times=lines.map(function(){return null}),timed=0;
  if(n&&m){
    var GL=-2,GW=-1,cols=m+1,S=new Int32Array((n+1)*cols),D=new Uint8Array((n+1)*cols),i,j;
    for(i=1;i<=n;i++){S[i*cols]=i*GL;D[i*cols]=2}
    for(j=1;j<=m;j++){S[j]=0;D[j]=3}
    for(i=1;i<=n;i++){for(j=1;j<=m;j++){
      var diag=S[(i-1)*cols+j-1]+wordScore(L[i-1],W[j-1]),up=S[(i-1)*cols+j]+GL,left=S[i*cols+j-1]+(i===n?0:GW),k=i*cols+j;
      /* on a tie, skip the later heard words: a chorus written once but sung twice lines up with the first time it's sung */
      if(left>=diag&&left>=up){S[k]=left;D[k]=3}else if(diag>=up){S[k]=diag;D[k]=1}else{S[k]=up;D[k]=2}}}
    var tokT=new Array(n);i=n;j=m;
    while(i>0||j>0){var d=i>0&&j>0?D[i*cols+j]:(i>0?2:3);
      if(d===1){if(wordScore(L[i-1],W[j-1])>0)tokT[i-1]=wt[j-1];i--;j--}else if(d===2)i--;else j--}
    /* a line only counts as heard if a fair share of its words matched - a lone "the" from somewhere
       else in the song isn't evidence the line was sung there */
    var first=lines.map(function(){return null}),hit=lines.map(function(){return 0}),real=lines.map(function(){return 0}),cnt=lines.map(function(){return 0});
    for(var k2=0;k2<n;k2++){var ln=li[k2];cnt[ln]++;if(tokT[k2]!=null){hit[ln]++;if(!SYNC_STOP[L[k2]])real[ln]++;if(first[ln]==null)first[ln]=tokT[k2]}}
    for(var q=0;q<lines.length;q++){if(first[q]!=null&&real[q]>0&&hit[q]>=Math.max(1,Math.ceil(cnt[q]*.3))&&(hit[q]>=2||cnt[q]<=2))times[q]=first[q]}
  }
  times.forEach(function(t){if(t!=null)timed++});
  /* keep times in order, then fill the gaps */
  var last=-1;for(var a=0;a<times.length;a++){if(times[a]!=null){if(times[a]<last)times[a]=null;else last=times[a]}}
  for(var b=0;b<times.length;b++){if(times[b]!=null)continue;var pv=b-1;while(pv>=0&&times[pv]==null)pv--;var nx=b+1;while(nx<times.length&&times[nx]==null)nx++;
    var tp=pv>=0?times[pv]:null,tn=nx<times.length?times[nx]:null;
    if(tp!=null&&tn!=null)times[b]=tp+(tn-tp)*(b-pv)/(nx-pv);else if(tn!=null)times[b]=Math.max(0,tn-3*(nx-b));else if(tp!=null)times[b]=tp+3*(b-pv);else times[b]=3*b}
  return{lines:lines.map(function(t,x){return{text:t,t:Math.round(times[x]*100)/100}}),timed:timed,total:lines.length}}
/* A small speech-quality copy for listening: the track decoded once and resampled to 16 kHz mono on the device. */
function toSyncPcm(blob){return decodeBlob(blob).then(function(buf){
  var sr=16000,len=Math.max(1,Math.ceil(buf.duration*sr)),OAC=window.OfflineAudioContext||window.webkitOfflineAudioContext;
  var manual=function(){var chs=buf.numberOfChannels,src=buf.sampleRate,out=new Float32Array(len),data=[];for(var c=0;c<chs;c++)data.push(buf.getChannelData(c));
    var ratio=src/sr;for(var i=0;i<len;i++){var x=i*ratio,x0=Math.floor(x),f=x-x0,v=0;for(var c2=0;c2<chs;c2++){var d=data[c2];v+=(d[x0]||0)*(1-f)+(d[x0+1]||0)*f}out[i]=v/chs}return out};
  var viaOAC=function(){return new Promise(function(res,rej){try{var oc=new OAC(1,len,sr),s=oc.createBufferSource();s.buffer=buf;s.connect(oc.destination);s.start(0);
    oc.oncomplete=function(e){res(e.renderedBuffer.getChannelData(0))};var p=oc.startRendering();if(p&&p.then)p.then(function(r){res(r.getChannelData(0))},rej)}catch(e){rej(e)}})};
  return(OAC?viaOAC().catch(manual):Promise.resolve(manual())).then(function(pcm){return{pcm:pcm,sr:sr,dur:buf.duration}})})}
/* The song goes up in one-minute pieces (each overlapping the next by a couple of seconds so a word on
   the join isn't lost), a few at a time, as small 48 kbps MP3s. Whisper's time grows with the length of
   what it hears, so one long request could run past the server's time limit; short pieces in parallel
   finish in seconds. Each piece keeps only the words that start inside its own minute. */
var SYNC_CHUNK=60,SYNC_OVER=2,SYNC_PAR=4,SYNC_WAIT=90000,SYNC_PROG=null;
function syncProgText(name){var g=SYNC_PROG;if(!g||!g.total)return'Getting “'+name+'” ready to listen to…';
  return g.done>=g.total?'Lining the words up with your lyrics…':'Timing every line to “'+name+'”: '+g.done+' of '+g.total+' minutes heard.'}
function syncProgPaint(name){var el=document.getElementById('syncprog');if(el)el.textContent=syncProgText(name)}
function syncPiece(pcm,sr,k,prompt){var a=Math.max(0,k*SYNC_CHUNK-SYNC_OVER),b=Math.min(pcm.length/sr,(k+1)*SYNC_CHUNK+SYNC_OVER),
    part=pcm.subarray(Math.floor(a*sr),Math.ceil(b*sr)),fake={numberOfChannels:1,sampleRate:sr,length:part.length,getChannelData:function(){return part}};
  var send=function(file){var fd=new FormData();fd.append('audio',file);fd.append('prompt',prompt);
    var t,timer=new Promise(function(_,rej){t=setTimeout(function(){rej(new Error('the sync server took too long to answer. Try again in a moment.'))},SYNC_WAIT)});
    return Promise.race([sbClient().functions.invoke('lyric-sync',{body:fd}),timer]).then(function(res){clearTimeout(t);
      if(res&&res.error)return fnErr(res.error).then(function(m){throw new Error(m)});return(res&&res.data)||{}},function(e){clearTimeout(t);throw e})};
  var fileP=mp3FromBuf(fake,null,48).then(function(bl){return new File([bl],'part'+k+'.mp3',{type:'audio/mpeg'})},
    function(){return new File([wav16(part,sr)],'part'+k+'.wav',{type:'audio/wav'})});
  return fileP.then(function(file){return send(file).catch(function(e){if(/sign in|deployed|too long to sync|isn.t set up|limit|a minute|paused/i.test(e.message))throw e;return send(file)})})
    .then(function(d){var lo=k*SYNC_CHUNK,hi=(k+1)*SYNC_CHUNK,len=b-a;
      /* (once the updated function is deployed) leave out stretches Whisper itself thinks were not singing:
         over music it can otherwise "hear" the lyrics it was given as a hint */
      var bad=(d.segments||[]).filter(function(g){return g.ns>.6&&g.lp<-.8});
      return(d.words||[]).filter(function(w){return w.s<=len+.5&&!bad.some(function(g){return w.s>=g.s-.05&&w.s<=g.e+.05})})
        .map(function(w){return{w:w.w,s:w.s+a,e:w.e+a}}).filter(function(w){return w.s>=lo&&(w.s<hi||k===Math.ceil(pcm.length/sr/SYNC_CHUNK)-1)})})}
function syncListen(pcm,sr,prompt,onStep){var n=Math.max(1,Math.ceil(pcm.length/sr/SYNC_CHUNK)),out=new Array(n),next=0,done=0;
  onStep(0,n);
  return new Promise(function(res,rej){var failed=false,running=0;
    function pump(){if(failed)return;if(done===n)return res([].concat.apply([],out));
      while(running<SYNC_PAR&&next<n){(function(k){running++;
        syncPiece(pcm,sr,k,prompt).then(function(ws){out[k]=ws;running--;done++;onStep(done,n);pump()},function(e){failed=true;rej(e)})})(next++)}}
    pump()})}
function wav16(f,sr){var n=f.length,b=new ArrayBuffer(44+n*2),v=new DataView(b),w=function(o,s){for(var i=0;i<s.length;i++)v.setUint8(o+i,s.charCodeAt(i))};
  w(0,'RIFF');v.setUint32(4,36+n*2,true);w(8,'WAVE');w(12,'fmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,sr,true);v.setUint32(28,sr*2,true);v.setUint16(32,2,true);v.setUint16(34,16,true);w(36,'data');v.setUint32(40,n*2,true);
  for(var i=0,o=44;i<n;i++,o+=2){var s=Math.max(-1,Math.min(1,f[i]));v.setInt16(o,s<0?s*0x8000:s*0x7FFF,true)}return new Blob([b],{type:'audio/wav'})}
function fnErr(err){var ctx=err&&err.context;
  if(ctx&&ctx.status===404)return Promise.resolve('the lyric-sync function isn’t deployed on Supabase yet (or is named differently).');
  if(ctx&&ctx.status===401)return Promise.resolve('Supabase didn’t accept your sign-in. Sign out and back in, then try again.');
  if(ctx&&(ctx.status===504||ctx.status===546||ctx.status===408))return Promise.resolve('the sync server took too long to answer. Try again in a moment.');
  if(ctx&&ctx.json)return ctx.json().then(function(b){return(b&&b.error)||err.message},function(){return err.message});
  var m=(err&&err.message)||'';return Promise.resolve(/failed to send|fetch/i.test(m)?'check your connection and try again.':m)}
function runSync(){var song=cur,a=audCur(song);if(!song||!a)return;
  if(!isPro())return upsell('sync');
  if(aiOk()!=='yes')return aiConsent(true).then(runSync,function(){});
  if(!sfCloud())return toast(DEV_MODE?'Lyric sync needs a signed-in account.':'Sign in to sync lyrics.');
  if(CFG.sync_off)return toast(CFG_PAUSED.sync);
  var lines=syncLinesOf(song.lyrics);if(lines.length<2)return toast('Write the lyrics first, then sync them to the audio.');
  if(a.dur>720)return toast('That track is too long to sync (over 12 minutes).');
  SYNC_BUSY=song.id;SYNC_PROG=null;renderAud();
  sfBlob(a).then(toSyncPcm).then(function(r){if(r.dur>720)throw new Error('That track is too long to sync (over 12 minutes).');
    return syncListen(r.pcm,r.sr,lines.join('\n'),function(d,n){SYNC_PROG={done:d,total:n};syncProgPaint(a.name)})})
  .then(function(words){if(!words.length)throw new Error('no words could be heard in that track.');
    var al=alignLyrics(lines,words);
    song.sync={audioId:a.id,at:Date.now(),sig:lines.join('\n'),lines:al.lines,timed:al.timed,total:al.total};sfTouch(song);
    toast(al.timed<al.total*.4?'Synced, but the vocals were hard to make out, so some lines are estimates':'Lyrics synced to “'+a.name+'”')})
  .catch(function(e){toast('Couldn’t sync: '+sfErr(e))})
  .then(function(){SYNC_BUSY=null;SYNC_PROG=null;if(cur===song)renderAud()})}
```

Pipeline (`runSync`):
1. Preconditions: Pro, AI consent, signed in, `sync_off` not set, ≥2 lyric lines, current version ≤12 minutes.
2. Download the current version (cache first) → decode → **16 kHz mono PCM** (`toSyncPcm`; OfflineAudioContext, linear
   interpolation fallback).
3. Split into **60 s pieces with 2 s overlap**, encode each as **48 kbps MP3** (lamejs; WAV fallback), POST to
   `lyric-sync` with the lyrics as prompt, **4 in parallel**, 90 s timeout per piece, one retry unless the error is
   terminal (sign-in / not deployed / too long / limit / paused).
4. Response `{words:[{w, s, e}], segments:[{s, e, ns, lp}]}` (times relative to the piece). Drop words inside segments
   Whisper marks as non-speech (`no_speech_prob > 0.6` and `avg_logprob < −0.8`); offset to absolute time; keep only
   words starting inside the piece's own minute (the last piece keeps the tail).
5. **Alignment** (`alignLyrics`): normalise words (lowercase, drop apostrophes, `&`→and, non-alphanumerics → space).
   Global alignment (Needleman–Wunsch style) of lyric words vs heard words: match score `wordScore` = 4 for identical
   words (2 if a stop word), 2 for Levenshtein distance ≤34% of the longer word (both ≥3 letters), else −2; gap in lyric
   (skip a lyric word) −2; gap in heard words −1, **free after the last lyric word** and free before the first (row 0 =
   0); ties prefer skipping heard words (so a chorus written once matches its first sung occurrence). Traceback assigns
   each matched lyric word (positive score) the heard word's start time.
6. A line is timed at its first matched word only if: at least one non-stop word matched, matched words ≥
   max(1, ceil(30% of the line's words)), and (≥2 matched or the line has ≤2 words). Times are forced monotonic (an
   earlier-than-previous time is discarded), gaps are interpolated linearly between timed neighbours; leading lines get
   `next − 3 s·distance`, trailing `prev + 3 s·distance`, all-untimed `3 s·index`. Rounded to 0.01 s.
7. Save `song.sync = {audioId, at, sig, lines:[{text, t}], timed, total}`. Toast "Synced, but the vocals were hard to make
   out, so some lines are estimates" when fewer than 40% of lines were heard.

**LRC export** (20277): `[ti:Title]`, `[ar:Artist]`, `[length:m:ss]`, `[re:*[demo]]`, then `[mm:ss.xx]line` for each timed
line; filename = title with `\/:*?"<>|` removed + `.lrc`.

*Native: Swift port of `alignLyrics` is straightforward (Int32 DP matrix). Audio prep via AVAudioConverter to 16 kHz
mono, encode pieces as AAC/M4A if the server accepts it (Whisper does) — otherwise keep MP3 via a small encoder.*

---

## 5. Live co-writing text merge (verbatim 17310–17329)

<!-- verbatim index.html lines 17310-17329 -->
```js
var LIVE={ch:null,id:null,snap:null,t:0,last:0,pend:[],comp:false,who:{},full:0};
var LIVE_F=['lyrics','title','artist','chords','notes','key','bpm','tuning','status'];
/* formatting (bold, italics…) isn't patched character by character: iPhone and Mac write the same formatting
   differently. It's sent whole, only when it changes without the words changing. */
function liveVal(s,k){var v=s[k];return v==null?'':String(v)}
function liveDiff(a,b){if(a===b)return null;var n=Math.min(a.length,b.length),p=0;while(p<n&&a.charCodeAt(p)===b.charCodeAt(p))p++;
  var q=0;while(q<n-p&&a.charCodeAt(a.length-1-q)===b.charCodeAt(b.length-1-q))q++;
  return{f:p,d:a.slice(p,a.length-q),i:b.slice(p,b.length-q),c:a.slice(Math.max(0,p-16),p),a:a.slice(a.length-q,a.length-q+16)}}
/* find where a change from the other device belongs in my copy, even if I've typed nearby since: the exact
   spot if the text around it still matches, otherwise the nearest place where the text just before it (or
   just after it) still matches, trying shorter and shorter overlaps */
function livePatch(t,P){var A=P.a||'',C=P.c||'',D=P.d||'';
  var fits=function(q){return q>=0&&q<=t.length&&t.substr(q,D.length)===D};
  if(fits(P.f)&&t.slice(Math.max(0,P.f-C.length),P.f)===C&&t.substr(P.f+D.length,A.length)===A)return{t:t.slice(0,P.f)+P.i+t.slice(P.f+D.length),at:P.f};
  var best=-1,bd=1e9,cand=function(q){if(fits(q)){var dd=Math.abs(q-P.f);if(dd<bd){bd=dd;best=q}}};
  var scan=function(key,toPos){if(!key)return;var k=t.indexOf(key);while(k>=0){cand(toPos(k));k=t.indexOf(key,k+1)}};
  for(var n=C.length;n>=3&&best<0;n=n>8?8:n-2)scan(C.slice(C.length-n)+D,function(k){return k+n});
  for(var m=A.length;m>=3&&best<0;m=m>8?8:m-2)scan(D+A.slice(0,m),function(k){return k});
  if(best<0&&!C&&!A)best=Math.min(P.f,t.length);
  if(best<0)return null;return{t:t.slice(0,best)+P.i+t.slice(best+D.length),at:best}}
```

- Fields patched live: `lyrics, title, artist, chords, notes, key, bpm, tuning, status`; rich formatting is sent whole
  (`fmt` event) only when formatting changed without the words changing, and only applied if the receiver's plain
  lyrics equal the sender's.
- `liveDiff(a, b)`: common prefix length `f`, common suffix; patch `{f, d: deleted text, i: inserted text, c: 16 chars
  before, a: 16 chars after}`.
- `livePatch(text, P)`: apply at `f` if the deleted text and both contexts still match; else search for the nearest
  position (to `f`) where `context-tail + d` matches (trying context lengths 16→8→6→4…≥3), then `d + after-head`;
  if both contexts are empty, apply at min(f, len); else fail → request the full text (`need` → `full` event).
- Messages at most every 150 ms per editor; the full song row is saved to the database at most every 4 s while live.
  Caret position is shifted by the patch (`at`, `d.length`, `i.length`). Patches arriving during IME composition are
  queued until `compositionend`.
- Channel `song:<id>` (Supabase Realtime broadcast, private with fallback to public) events: `p`, `need`, `full`, `fmt`,
  `files`, `gone`. `data-and-backend.md` covers channels and RLS.
- *Native: keep this patch format for interoperability with the web/Mac clients during transition; a CRDT can come later.*

---

## 6. Small client renderers to port exactly

### 6.1 Generated cover art (verbatim 17220–17244; `duo()` is unused)

<!-- verbatim index.html lines 17220-17244 -->
```js
/* ---------- default cover: one bar per line, length = syllables, gaps between sections ---------- */
/* a stable two-colour pairing per song, from the app's ink palette: bold background, light tint of a different colour for the lines */
function duo(id){var P=['#E5566F','#D4881C','#4E9A5B','#2C8DBF','#5D6BE0','#A35FCB','#8E8E96'],h=0;for(var i=0;i<id.length;i++)h=(h*33+id.charCodeAt(i))>>>0;
  var a=h%P.length,b=(a+1+((h>>>4)%(P.length-1)))%P.length;function tint(x,k){var n=parseInt(x.slice(1),16),r=n>>16,g=n>>8&255,bl=n&255;r=Math.round(r+(255-r)*k);g=Math.round(g+(255-g)*k);bl=Math.round(bl+(255-bl)*k);return'rgb('+r+','+g+','+bl+')'}
  return[P[a],tint(P[b],.62)]}
function cover(s){var rows=[],gap=false;(s&&s.lyrics||'').split('\n').forEach(function(l){var tr=l.trim();if(!tr||tr[0]==='['){if(rows.length&&!gap){rows.push(0);gap=true}return}gap=false;rows.push(Math.max(.18,Math.min(1,lsyl(l)/12)))});
  while(rows.length&&rows[rows.length-1]===0)rows.pop();var empty=!rows.length;if(empty)rows=[.72,.5,.62];rows=rows.slice(0,9);
  var h='<svg class="cvs" viewBox="0 0 40 40" aria-hidden="true">'+covGrad(s&&s.id||''),y=9,sp=rows.length>6?2.9:3.6;
  rows.forEach(function(r){if(r===0){y+=sp*.55;return}h+='<rect x="8" y="'+y.toFixed(1)+'" width="'+(24*r).toFixed(1)+'" height="1.8" rx=".9" fill="#fff" opacity="'+(empty?.6:.82)+'"/>';y+=sp});
  return h+'</svg>'}
/* every song without artwork gets its own soft gradient, picked from its id so it never changes:
   a pastel pair washed diagonally, plus a glow of a third colour somewhere in the square */
var COV_PAL=[['#FFC9B0','#FF8FA3'],['#D7C4FF','#9CC8FF'],['#BFF0D4','#7FCCDB'],['#FFE9A8','#FFAA7F'],['#FFC2DA','#B9A6FF'],['#B6E8D8','#9AAEF2'],['#F5D7BA','#EE8F82'],['#B8DEFF','#B5EDC6'],['#F7AFC2','#F9CD86'],['#AFBBFF','#EFAED6'],['#C9E6A6','#86CFB4'],['#FFD6A5','#E7A6E0']];
var COV_N=0; /* each drawing gets its own gradient ids: a duplicate id inside a hidden list would blank the visible one */
function covPick(id){var h=2166136261;for(var i=0;i<id.length;i++){h^=id.charCodeAt(i);h=Math.imul(h,16777619)>>>0}
  var r=function(){h^=h<<13;h>>>=0;h^=h>>>17;h^=h<<5;h>>>=0;return h/4294967296};r();
  var p=COV_PAL[Math.floor(r()*COV_PAL.length)],q=COV_PAL[Math.floor(r()*COV_PAL.length)],a=r()*360,cx=(15+r()*70).toFixed(0),cy=(15+r()*70).toFixed(0),c=q[r()<.5?0:1];
  return{p:p,a:a,cx:cx,cy:cy,c:c}}
/* the song's cover colours, strongest first (the share card's fallback background) */
function covHex(id){var k=covPick(id);return[k.p[1],k.c,k.p[0]]}
function covGrad(id){var k=covPick(id),p=k.p,a=k.a,cx=k.cx,cy=k.cy,c=k.c,g='cg'+(++COV_N),
    x1=(50+50*Math.cos(a*Math.PI/180)).toFixed(0),y1=(50+50*Math.sin(a*Math.PI/180)).toFixed(0);
  return '<defs><linearGradient id="'+g+'l" x1="'+x1+'%" y1="'+y1+'%" x2="'+(100-x1)+'%" y2="'+(100-y1)+'%"><stop offset="0" stop-color="'+p[0]+'"/><stop offset="1" stop-color="'+p[1]+'"/></linearGradient>'+
    '<radialGradient id="'+g+'r" cx="'+cx+'%" cy="'+cy+'%" r="60%"><stop offset="0" stop-color="'+c+'" stop-opacity=".85"/><stop offset="1" stop-color="'+c+'" stop-opacity="0"/></radialGradient></defs>'+
    '<rect width="40" height="40" fill="url(#'+g+'l)"/><rect width="40" height="40" fill="url(#'+g+'r)"/><rect class="cvdim" width="40" height="40"/>'}
```

### 6.2 Waveform peaks (verbatim 20202–20206)

<!-- verbatim index.html lines 20202-20206 -->
```js
function peaksOf(blob){return decodeBlob(blob).then(peaksFromBuf)}
function peaksFromBuf(buf){return(function(){var P=180,len=buf.length,chs=[],out=[],step=Math.max(1,Math.floor(len/P)),stride=Math.max(1,Math.floor(step/500));
  for(var c=0;c<buf.numberOfChannels;c++)chs.push(buf.getChannelData(c));
  for(var i=0;i<P;i++){var s=i*step,e=Math.min(len,s+step),m=0;for(var j=s;j<e;j+=stride)for(var c2=0;c2<chs.length;c2++){var v=chs[c2][j];if(v<0)v=-v;if(v>m)m=v}out.push(m)}
  var mx=0;out.forEach(function(v){if(v>mx)mx=v});mx=mx||1;return{peaks:out.map(function(v){return Math.round(Math.pow(v/mx,.7)*100)}),dur:buf.duration}})()}
```

180 buckets, max |sample| over all channels sampled with a stride (≤500 reads per bucket), normalised to the max, then
`round(pow(v, 0.7)·100)`. Ideas memos keep 60 values (every 3rd of the 180). Drawing: `shWaveDraw` (20380) — bars 2.4 pt,
gap 2.1 pt, height `max(2.5, v·0.6·h)`, played part opaque, rest 30–42% alpha, Gaussian magnification (σ 20 pt).

### 6.3 Share palette (verbatim 20293–20312)

<!-- verbatim index.html lines 20293-20312 -->
```js
function rgbHsl(r,g,b){r/=255;g/=255;b/=255;var mx=Math.max(r,g,b),mn=Math.min(r,g,b),l=(mx+mn)/2,h=0,s=0,d=mx-mn;
  if(d){s=l>.5?d/(2-mx-mn):d/(mx+mn);h=mx===r?(g-b)/d+(g<b?6:0):mx===g?(b-r)/d+2:(r-g)/d+4;h*=60}return[h,s,l]}
function hexHsl(x){var n=parseInt(x.slice(1),16);return rgbHsl(n>>16&255,n>>8&255,n&255)}
function hsl(c,l,a,ds){var s=Math.max(0,Math.min(.62,c[1]*(ds||1)));return'hsla('+Math.round(c[0])+','+Math.round(s*100)+'%,'+Math.round(l*100)+'%,'+(a==null?1:a)+')'}
/* the cover's main colours: pixels grouped by hue, ranked by how much of the image they cover and how vivid they are */
function artPalette(src){return new Promise(function(res){var im=new Image();im.onload=function(){try{var n=40,c=document.createElement('canvas');c.width=c.height=n;var x=c.getContext('2d');x.drawImage(im,0,0,n,n);
    var d=x.getImageData(0,0,n,n).data,bins={};
    for(var i=0;i<d.length;i+=4){if(d[i+3]<128)continue;var h=rgbHsl(d[i],d[i+1],d[i+2]),k=h[1]<.14||h[2]<.07||h[2]>.96?'g'+Math.round(h[2]*4):'h'+Math.round(h[0]/15)%24;
      var b=bins[k]||(bins[k]={n:0,r:0,g:0,b:0,w:0});b.n++;b.r+=d[i];b.g+=d[i+1];b.b+=d[i+2];b.w+=(k[0]==='g'?.35:.6+h[1])*(h[2]<.12||h[2]>.92?.5:1)}
    var out=[];Object.keys(bins).map(function(k){var b=bins[k];return{w:b.w,c:rgbHsl(b.r/b.n,b.g/b.n,b.b/b.n)}}).sort(function(a,b){return b.w-a.w}).forEach(function(o){
      if(out.length<5&&!out.some(function(p){return(p[1]<.14&&o.c[1]<.14)||(p[1]>=.14&&o.c[1]>=.14&&Math.min(Math.abs(p[0]-o.c[0]),360-Math.abs(p[0]-o.c[0]))<28)}))out.push(o.c)});
    res(out)}catch(e){res([])}};im.onerror=function(){res([])};im.src=src})}
function songPalette(s){var fall=covHex(s.id||'').map(hexHsl);return artOk(s.art)?artPalette(s.art).then(function(p){return p.length?p:fall}):Promise.resolve(fall)}
/* the background: the colour, deep at the top and near-black at the foot, with a glow of the next colour */
/* the background: pastel like the default covers. The chosen colour washes diagonally into the next one,
   with a soft glow of a third in the corner; text is a deep shade of the main colour rather than plain black */
function shSoft(c,l){var s=c[1]<.14?Math.min(c[1],.12):Math.max(.42,Math.min(.78,c[1]*1.1));return'hsl('+Math.round(c[0])+','+Math.round(s*100)+'%,'+Math.round(l*100)+'%)'}
function shBg(pal,i){var n=pal.length,a=pal[i]||[220,.1,.5],b=pal[(i+1)%n]||a,g=pal[(i+2)%n]||b,top=shSoft(a,.86),bot=shSoft(b,.8),glow=shSoft(g,.88);
  var k=Math.round(a[0])+','+Math.round((a[1]<.14?.08:.4)*100)+'%,15%';
  return{top:top,bot:bot,glow:glow,glow0:glow.replace('hsl(','hsla(').replace(')',',0)'),k:k,css:'radial-gradient(90% 60% at 88% 4%,'+glow+','+glow.replace('hsl(','hsla(').replace(')',',0)')+' 72%),linear-gradient(155deg,'+top+','+bot+')'}}
```

Cover image sampled at 40×40; pixels binned by hue (15° bins) or as greys (saturation <0.14, or very dark/light) by
lightness; weight = (greys .35, colours .6+saturation) × (.5 if very dark/light); up to 5 colours whose hues differ by
≥28°. Background = pastel diagonal gradient (155°) from colour i (lightness .86) to colour i+1 (.80) + radial glow of
colour i+2 (.88) at 88% / 4%; text ink = `hsl(hue, 8% (grey) | 40%, 15%)`.

### 6.4 Share image layout (`shImage`, 20349)

1080 px wide PNG, height max(1350, content) ≤16000: 84 px padding; player
card scaled ×2.55 (rounded 24, white 52% fill); lyrics lines 700-weight 50 px with 64 px line height (wrapped to width);
section names 600 30 px at 50% alpha (+14 px before, 50 px after); gaps 34 px; footer "Written in *[demo]" 600 28 px at
42% alpha. Link preview (og) image 1200×630 JPEG q.86 with only the player card (×2.85 with audio, ×3.3 without).
Share-link page HTML (`shRender`, 20426) is shared with the public viewer at listen.hellodemo.app (between the
`SHARE-RENDER:BEGIN/END` markers) — the native app only needs to upload the same snapshot shape:
`{v:1, title, artist, key, bpm, blocks:[{sec}|{gap:true}|{line, t}], bg:{top, bot, glow, k}, art, audio:{src, name, dur,
peaks}|null, og}`.
