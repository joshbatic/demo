// [demo.] for macOS: a thin native shell around the lyric app in ./app
const { app, BrowserWindow, Menu, shell, session, ipcMain, nativeTheme, dialog, safeStorage, systemPreferences } = require('electron');
const { pathToFileURL } = require('url');
const path = require('path');
const fs = require('fs');
const https = require('https');

let win;
let pendingAuthUrl = null;

// ---- dev build ----
// A copy of the app with a "dev-build" file next to main.js runs as "[developer]": its own settings and
// sign-in (so it can stay signed in as the admin), its own songs folder, its own sign-in link
// (demo-dev://, so callbacks never land in the regular app), and the admin tools on the home screen.
const DEV_BUILD = fs.existsSync(path.join(__dirname, 'dev-build'));
const SCHEME = DEV_BUILD ? 'demo-dev' : 'demo';
if (DEV_BUILD) {
  app.setName('[developer]');
  // the settings folder keeps its first name, so the sign-in and settings carry over
  app.setPath('userData', path.join(app.getPath('appData'), '[demo] Dev'));
}
ipcMain.on('app:info', (e) => { e.returnValue = { devBuild: DEV_BUILD, scheme: SCHEME }; });
const songsDir = () => path.join(app.getPath('documents'), DEV_BUILD ? '[developer] Songs' : '[demo] Songs');

// ---- Google sign-in callback (demo://auth-callback, or demo-dev:// in the dev build) ----
// macOS hands the app this custom-scheme URL after the system browser finishes the Google
// OAuth flow started from the renderer. We just forward the raw URL to the page, which holds
// the Supabase client (and the PKCE code verifier it needs to finish signing in).
app.on('open-url', (event, url) => {
  event.preventDefault();
  if (url.toLowerCase().indexOf(SCHEME + '://') !== 0) return;
  if (win && !win.isDestroyed()) win.webContents.send('auth-callback', url);
  else pendingAuthUrl = url;
});
ipcMain.handle('shell:openExternal', (e, url) => {
  if (typeof url === 'string' && (/^https:\/\//i.test(url) || /^mailto:[^\s]+$/i.test(url))) { shell.openExternal(url); return true; }
  return false;
});

function createWindow() {
  win = new BrowserWindow({
    width: 1180, height: 820, minWidth: 420, minHeight: 560,
    title: '[demo.]',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 18, y: 20 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#000000' : '#ffffff',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true, spellcheck: false }
  });
  const appFile = path.join(__dirname, 'app', 'index.html'), appUrl = pathToFileURL(appFile).href;
  win.loadFile(appFile);
  // links to websites open in the default browser, never inside the app
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  // only the app's own page may load in this window (it holds the desktop bridge); everything else is refused or sent to the browser
  win.webContents.on('will-navigate', (e, url) => { if (url.split('#')[0].split('?')[0] === appUrl) return; e.preventDefault(); if (/^https:/i.test(url)) shell.openExternal(url); });
  win.webContents.on('did-finish-load', () => {
    if (pendingAuthUrl) { win.webContents.send('auth-callback', pendingAuthUrl); pendingAuthUrl = null; }
  });
}

function send(action) { if (win && !win.isDestroyed()) win.webContents.send('menu', action); }

function buildMenu() {
  const template = [
    { role: 'appMenu' },
    { label: 'File', submenu: [
      { label: 'New Song', accelerator: 'CmdOrCtrl+N', click: () => send('new') },
      { type: 'separator' },
      { label: 'Import Songs…', accelerator: 'CmdOrCtrl+Shift+I', click: () => send('import') },
      { label: 'Show Songs Folder', accelerator: 'CmdOrCtrl+Shift+O', click: () => openSongsFolder() },
      { type: 'separator' },
      { role: 'close' }
    ] },
    { role: 'editMenu' },
    { label: 'View', submenu: [
      { label: 'Find Song', accelerator: 'CmdOrCtrl+F', click: () => send('find') },
      { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+Alt+S', click: () => send('sidebar') },
      { type: 'separator' },
      { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
      { type: 'separator' },
      { role: 'togglefullscreen' }
    ] },
    { role: 'windowMenu' }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function openSongsFolder() {
  fs.mkdirSync(songsDir(), { recursive: true });
  shell.openPath(songsDir());
}

// ---- songs mirrored as plain-text files + a full backup ----
const safe = (s) => { const v = (s || 'Untitled').replace(/[\/\\:*?"<>|\u0000-\u001f]/g, '-').replace(/\s+/g, ' ').trim().slice(0, 80).replace(/^\.+/, '').trim(); return v || 'Untitled'; };
// true only for a path strictly inside the Songs folder (no '..', no sibling folder with the same prefix)
const inside = (dir, p) => { const r = path.relative(dir, p); return !!r && !r.startsWith('..') && !path.isAbsolute(r); };
function songText(s) {
  const meta = [s.artist && 'by ' + s.artist, s.key && 'Key: ' + s.key, s.bpm && s.bpm + ' BPM', s.capo && 'Capo: ' + s.capo,
    s.tuning && 'Tuning: ' + s.tuning, s.status && 'Status: ' + s.status].filter(Boolean).join(' · ');
  let out = (s.title || 'Untitled') + '\n' + (meta ? meta + '\n' : '') + '\n' + (s.lyrics || '').replace(/\s+$/, '') + '\n';
  if ((s.chords || '').trim()) out += '\n--- Chords ---\n' + s.chords.replace(/\s+$/, '') + '\n';
  if ((s.notes || '').trim()) out += '\n--- Notes ---\n' + s.notes.replace(/\s+$/, '') + '\n';
  return out;
}
ipcMain.handle('songs:mirror', (e, songs) => {
  if (!Array.isArray(songs)) return false;
  const dir = songsDir();
  fs.mkdirSync(dir, { recursive: true });
  const manPath = path.join(dir, '.demo-manifest.json');
  let man = {};
  try { man = JSON.parse(fs.readFileSync(manPath, 'utf8')); } catch (_) {}
  const next = {}, used = new Set();
  for (const s of songs) {
    if (!s || typeof s.id !== 'string') continue;
    const sub = s.folder ? safe(s.folder) : '';
    let base = safe(s.title || (s.lyrics || '').split('\n').find((l) => l.trim() && l.trim()[0] !== '[') || 'Untitled');
    let rel = path.join(sub, base + '.txt'), n = 2;
    while (used.has(rel.toLowerCase())) rel = path.join(sub, base + ' (' + n++ + ').txt');
    used.add(rel.toLowerCase());
    if (!inside(dir, path.join(dir, rel))) continue;
    fs.mkdirSync(path.join(dir, sub), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), songText(s));
    next[s.id] = rel;
  }
  // remove files this app wrote for songs that were renamed, moved or deleted
  for (const id of Object.keys(man)) {
    const old = man[id];
    if (Object.values(next).includes(old)) continue;
    const p = path.join(dir, old);
    if (typeof old === 'string' && /\.txt$/i.test(old) && inside(dir, p)) { try { fs.unlinkSync(p); } catch (_) {} }
  }
  fs.writeFileSync(manPath, JSON.stringify(next, null, 1));
  fs.writeFileSync(path.join(dir, '[demo.] backup.json'), JSON.stringify({ app: '[demo.]', saved: new Date().toISOString(), songs }, null, 1));
  return true;
});
ipcMain.handle('songs:open', () => openSongsFolder());
// microphone: macOS asks once per app; after that the answer lives in System Settings › Privacy & Security › Microphone
ipcMain.handle('mic:access', async () => {
  if (process.platform !== 'darwin') return 'granted';
  try {
    const st = systemPreferences.getMediaAccessStatus('microphone');
    if (st === 'not-determined') return (await systemPreferences.askForMediaAccess('microphone')) ? 'granted' : 'denied';
    return st;
  } catch (_) { return 'granted'; }
});
ipcMain.handle('mic:settings', () => shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'));

// ---- OpenAI (experimental, desktop-only). The key is written to this app's own
// local config folder and never leaves this machine; it is read only by this
// main process, never by the page itself. ----
const oaiKeyPath = () => path.join(app.getPath('userData'), 'openai-key.txt');
// stored encrypted with the macOS Keychain (safeStorage); older plain-text files still read
function readKey() { try { const b = fs.readFileSync(oaiKeyPath()); if (b.slice(0, 5).toString() === 'enc1:') return safeStorage.decryptString(b.slice(5)).trim(); return b.toString('utf8').trim(); } catch (_) { return ''; } }
ipcMain.handle('openai:setKey', (e, key) => {
  const k = (key || '').trim();
  if (!k) { try { fs.unlinkSync(oaiKeyPath()); } catch (_) {} return { ok: true }; }
  // Sanity-check the shape before it ever touches disk or a network request. This is not a
  // real secret check, just a guard against saving garbage (a pasted URL, a stray newline, etc.)
  // that would otherwise fail confusingly on first use.
  if (!/^sk-[A-Za-z0-9_-]{10,}$/.test(k)) return { ok: false, error: 'That doesn’t look like an OpenAI API key (they start with "sk-").' };
  // the page asks; the person confirms in a native dialog the page can't click, so injected script can't swap the key
  const ok = dialog.showMessageBoxSync(win, { type: 'question', buttons: ['Save Key', 'Cancel'], defaultId: 0, cancelId: 1, message: 'Save this OpenAI key?', detail: 'AI requests from [demo.] on this Mac will be billed to it.' });
  if (ok !== 0) return { ok: false, error: 'Cancelled' };
  fs.mkdirSync(app.getPath('userData'), { recursive: true });
  fs.writeFileSync(oaiKeyPath(), safeStorage.isEncryptionAvailable() ? Buffer.concat([Buffer.from('enc1:'), safeStorage.encryptString(k)]) : k, { mode: 0o600 });
  return { ok: true };
});
ipcMain.handle('openai:hasKey', () => { try { return fs.statSync(oaiKeyPath()).size > 0; } catch (_) { return false; } });

// ---- abuse / runaway-cost protection ----
// The renderer is the one surface here that could misbehave (a bug, a pasted-in prompt-injection
// attempt via song text, a future XSS) and start firing requests in a loop against the user's own
// paid API key. None of this is renderer-enforced — it lives entirely in the main process, which
// the renderer cannot reach around, since it only ever talks to OpenAI through this IPC call.
const RATE_WINDOW_MS = 60 * 1000;
const RATE_MAX_PER_WINDOW = 20;   // interactive calls per rolling minute
const DAILY_MAX_CALLS = 400;      // default hard stop per calendar day, resets at local midnight
const DEV_LIMIT_CAP = 100000;     // sanity ceiling even for a self-chosen dev override
const MAX_PROMPT_CHARS = 24000;   // sanity cap so a runaway context can't balloon a single request
let callTimes = [];
const usagePath = () => path.join(app.getPath('userData'), 'openai-usage.json');
// Dev Mode lets the person raise their own daily AI limit on their own machine, against their own
// key. This is a personal usage guardrail they're adjusting for themselves, not a security boundary.
const devLimitPath = () => path.join(app.getPath('userData'), 'openai-devlimit.json');
function loadDevLimit() {
  try {
    const d = JSON.parse(fs.readFileSync(devLimitPath(), 'utf8'));
    if (d && typeof d.dailyMax === 'number' && d.dailyMax > 0) return Math.min(DEV_LIMIT_CAP, Math.round(d.dailyMax));
  } catch (_) {}
  return null;
}
function effectiveDailyMax() { return loadDevLimit() || DAILY_MAX_CALLS; }
ipcMain.handle('dev:getLimit', async () => ({ ok: true, value: effectiveDailyMax(), default: DAILY_MAX_CALLS, isCustom: loadDevLimit() !== null }));
ipcMain.handle('dev:setLimit', async (e, n) => {
  try {
    if (n === null || n === undefined) { try { fs.unlinkSync(devLimitPath()); } catch (_) {} return { ok: true, value: DAILY_MAX_CALLS, isCustom: false }; }
    const v = Math.max(1, Math.min(DEV_LIMIT_CAP, Math.round(Number(n) || 0)));
    // raising the cap is confirmed natively, so a script in the page can't quietly lift it
    if (v > DAILY_MAX_CALLS && dialog.showMessageBoxSync(win, { type: 'warning', buttons: ['Raise Limit', 'Cancel'], defaultId: 1, cancelId: 1, message: 'Raise the daily AI limit to ' + v + '?', detail: 'Requests are billed to your OpenAI key.' }) !== 0) return { ok: false, error: 'Cancelled' };
    fs.writeFileSync(devLimitPath(), JSON.stringify({ dailyMax: v }));
    return { ok: true, value: v, isCustom: true };
  } catch (err) { return { ok: false, error: String((err && err.message) || err) }; }
});
function loadUsage() {
  const today = new Date().toISOString().slice(0, 10);
  try {
    const u = JSON.parse(fs.readFileSync(usagePath(), 'utf8'));
    if (u && u.date === today && typeof u.count === 'number') return u;
  } catch (_) {}
  return { date: today, count: 0 };
}
function bumpUsage(u) { try { fs.writeFileSync(usagePath(), JSON.stringify(u)); } catch (_) {} }
function guardCall() {
  const now = Date.now();
  callTimes = callTimes.filter((t) => now - t < RATE_WINDOW_MS);
  if (callTimes.length >= RATE_MAX_PER_WINDOW) {
    return { ok: false, error: 'Too many AI requests in a short time (limit ' + RATE_MAX_PER_WINDOW + ' per minute). Wait a moment and try again.' };
  }
  const dailyMax = effectiveDailyMax();
  const usage = loadUsage();
  if (usage.count >= dailyMax) {
    return { ok: false, error: 'Daily AI request limit reached (' + dailyMax + '). Resets at midnight, or raise it in Dev Mode.' };
  }
  callTimes.push(now);
  usage.count += 1;
  bumpUsage(usage);
  return { ok: true };
}
function openaiCall(key, prompt, model, maxTokens, reasoningEffort, timeoutMs) {
  return new Promise((resolve) => {
    const payload = { model: model || 'gpt-5-mini', messages: [{ role: 'user', content: prompt }], max_completion_tokens: maxTokens || 200 };
    if (reasoningEffort) payload.reasoning_effort = reasoningEffort;
    const body = JSON.stringify(payload);
    const req = https.request({
      hostname: 'api.openai.com', path: '/v1/chat/completions', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key, 'Content-Length': Buffer.byteLength(body) },
      timeout: timeoutMs || 45000
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, body: data }));
    });
    req.on('error', (e) => resolve({ ok: false, error: String((e && e.message) || e) }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, error: 'Timed out reaching OpenAI' }); });
    req.write(body); req.end();
  });
}
ipcMain.handle('openai:test', async () => {
  let key = '';
  key = readKey();
  if (!key) return { ok: false, error: 'No OpenAI key saved yet.' };
  const guard = guardCall();
  if (!guard.ok) return guard;
  const r = await openaiCall(key, 'Reply with exactly one word: OK');
  if (!r.ok) {
    let msg = r.error || ('HTTP ' + r.status);
    try { const j = JSON.parse(r.body); if (j.error && j.error.message) msg = j.error.message; } catch (_) {}
    return { ok: false, error: msg };
  }
  try {
    const j = JSON.parse(r.body);
    const text = (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || '';
    return { ok: true, text: text.trim(), model: j.model || '' };
  } catch (_) { return { ok: false, error: 'Unexpected response from OpenAI' }; }
});
// Generic prompt->text call used by every AI feature in the app (Lines, Rhyme, Muse, Rate, etc).
// modelTier 'complex' maps to the stronger model; everything else uses the fast/cheap one.
ipcMain.handle('openai:json', async (e, args) => {
  const prompt = (args && args.prompt) || '';
  const tier = args && args.modelTier;
  const model = tier === 'complex' ? 'gpt-5' : 'gpt-5-mini';
  const maxTokens = tier === 'complex' ? 5000 : 2000;
  // gpt-5-family models spend hidden "thinking" tokens before answering even at low effort.
  // Everything on the mini tier here is list-picking or short-form writing, not real reasoning,
  // so 'minimal' skips that step almost entirely and answers much faster. Rate is the one call
  // that benefits from actual judgment, so it keeps a real reasoning budget.
  const reasoningEffort = tier === 'complex' ? 'medium' : 'minimal';
  // Rate (the 'complex' tier) sends a long prompt and a real reasoning pass over it, which
  // routinely runs past 45s on gpt-5 — that's what was causing the frequent "Timed out
  // reaching OpenAI" failures. Give it a much longer budget; quick list-picking calls on the
  // mini tier stay fast so they keep the short timeout.
  const timeoutMs = tier === 'complex' ? 110000 : 45000;
  let key = '';
  key = readKey();
  if (!key) return { ok: false, error: 'No OpenAI key saved yet.' };
  if (!prompt) return { ok: false, error: 'Empty prompt.' };
  if (prompt.length > MAX_PROMPT_CHARS) return { ok: false, error: 'That request is too large to send (' + prompt.length + ' characters, limit ' + MAX_PROMPT_CHARS + ').' };
  const guard = guardCall();
  if (!guard.ok) return guard;
  const r = await openaiCall(key, prompt, model, maxTokens, reasoningEffort, timeoutMs);
  if (!r.ok) {
    let msg = r.error || ('HTTP ' + r.status);
    try { const j = JSON.parse(r.body); if (j.error && j.error.message) msg = j.error.message; } catch (_) {}
    return { ok: false, error: msg };
  }
  try {
    const j = JSON.parse(r.body);
    const choice = j.choices && j.choices[0];
    const text = (choice && choice.message && choice.message.content) || '';
    if (!text.trim()) {
      if (choice && choice.finish_reason === 'length') return { ok: false, error: 'OpenAI ran out of tokens before answering (hit the length limit).' };
      return { ok: false, error: 'OpenAI returned an empty response.' };
    }
    return { ok: true, text: text, model: j.model || model };
  } catch (_) { return { ok: false, error: 'Unexpected response from OpenAI' }; }
});

app.whenReady().then(() => {
  // registers this app to handle demo:// links, for the Google sign-in callback
  app.setAsDefaultProtocolClient(SCHEME);
  // microphone for melody recording; nothing else
  // microphone (audio only) and clipboard writes, and only for the app's own page in its main frame
  const ours = (wc, url) => { try { const u = wc && wc.getURL(); return !!u && u.startsWith('file:') && (!url || url === 'null' || url.startsWith('file:')); } catch (_) { return false; } };
  session.defaultSession.setPermissionRequestHandler((wc, perm, cb, details) => {
    const mainFrame = !details || details.isMainFrame !== false;
    const audioOnly = !details || !details.mediaTypes || details.mediaTypes.every((t) => t === 'audio');
    cb(ours(wc, details && details.requestingUrl) && mainFrame && ((perm === 'media' && audioOnly) || perm === 'clipboard-sanitized-write' || perm === 'notifications'));
  });
  session.defaultSession.setPermissionCheckHandler((wc, perm, origin) => (perm === 'media' || perm === 'notifications') && ours(wc, origin));
  buildMenu();
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
