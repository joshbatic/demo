#!/usr/bin/env python3
"""Writes native/DemoWidget/RhymeOfTheDay.swift: a year of words for the Rhyme of the Day widget, each with up to
eight perfect rhymes from the app's dictionary (same rules as the rhyme bar and the website's rhyme pages). The
widget can't reach the app's dictionary, so the words travel with it. Run after the dictionary changes:

    python3 scripts/rhymes/widget_words.py
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import load, root  # noqa: E402

words, groups, keys, dic = load()
pos = {}
with open(os.path.join(root, 'native', 'Demo', 'Resources', 'Words.txt'), encoding='utf-8') as fh:
    fh.readline()
    for line in fh:
        p = line.rstrip('\n').split('\t')
        if ' ' in p[0]:
            break
        pos[p[0]] = {d[0] for d in (p[4].split(',') if len(p) > 4 and p[4] else []) if d}

STOP = set('the and but for with this that from have has had were was are been being they them their there what when where who how why which would could should into onto upon than then also very just only some such each every other these those your yours mine ours hers his him her its our out off over under about above below after before again ever never more most much many less least'.split())
SONG = ('love heart night light time life mind soul fire rain home alone gone cry eyes way day free dream sky feel real '
        'away stay go know show hold cold gold old young run sun fall call wall tonight forever together '
        'again pain change strange tears years fear lie tried die high fly blue true tell well kiss miss lost cross '
        'break shake wake fake money honey baby crazy lonely start apart dark heaven moon soon road alive fight '
        'right wrong song strong long burn turn learn back black ride side face place space down town around ground '
        'sound found summer river water ocean shine line wine fade made shade stone bone wild child slow glow snow '
        'flame shame name game blame storm warm smoke broke hope rope drown crown heat street beat sweet').split()


def ok(w):
    e = words.get(w)
    return e and w in dic and e['f'] != 's' and e['t'] <= 5 and w.isalpha() and not (e['s'] >= 2 and len(w) <= e['s'])


SKIP = set('thereof whereof hereby prior site bart hart cite sight'.split())


def rhymes(w):
    e = words[w]
    # everyday words only (tier 4 or commoner), not the word inside a longer one
    r = [x for x in groups[e['g']] if x != w and ok(x) and words[x]['t'] <= 4 and x not in SKIP
         and not x.endswith(w) and not w.endswith(x)]
    # same syllables first, then more common, then a couple of longer ones for variety
    r.sort(key=lambda x: (words[x]['s'] != e['s'], words[x]['t'], x))
    return r[:8]


pool = [w for w in dict.fromkeys(SONG) if ok(w) and len(rhymes(w)) >= 4]
extra = sorted(w for w, e in words.items()
               if ok(w) and e['t'] <= 3 and 3 <= len(w) <= 9 and w not in STOP and w not in pool
               and (pos.get(w, set()) & {'n', 'v', 'a', 's'}) and len(rhymes(w)) >= 6)
random.Random(7).shuffle(extra)
days = pool + extra[:max(0, 366 - len(pool))]
random.Random(2026).shuffle(days)
data = '|'.join(w + ':' + ','.join(rhymes(w)) for w in days[:366])
out = os.path.join(root, 'native', 'DemoWidget', 'RhymeOfTheDay.swift')
with open(out, 'w', encoding='utf-8') as f:
    f.write('''import Foundation

/// The Rhyme of the Day widget's words: one for each day of the year, with up to eight perfect rhymes from the app's
/// dictionary, same syllables first. Made by scripts/rhymes/widget_words.py; don't edit by hand.
enum RhymeOfTheDay {
    struct Day { let word: String; let rhymes: [String] }

    /// Today's word (the same one all day, everywhere), or any day's.
    static func day(_ date: Date = .now) -> Day {
        let n = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = Calendar.current.component(.year, from: date)
        let i = (n - 1 + year * 7) % all.count
        return all[i]
    }

    static let all: [Day] = data.split(separator: "|").map { e in
        let p = e.split(separator: ":", maxSplits: 1)
        return Day(word: String(p[0]), rhymes: p.count > 1 ? p[1].split(separator: ",").map(String.init) : [])
    }

    private static let data = "''' + data + '''"
}
''')
print(len(days[:366]), 'days;', days[:8])
