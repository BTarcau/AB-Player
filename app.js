import * as db from './db.js';

// ---------- Constants ----------
const AUDIO_TYPES = {
  mp3: 'audio/mpeg', m4a: 'audio/mp4', m4b: 'audio/mp4', mp4: 'audio/mp4', aac: 'audio/aac',
  wav: 'audio/wav', flac: 'audio/flac', ogg: 'audio/ogg', oga: 'audio/ogg', opus: 'audio/ogg',
  aif: 'audio/aiff', aiff: 'audio/aiff', caf: 'audio/x-caf', webm: 'audio/webm',
};
const IMAGE_TYPES = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', gif: 'image/gif' };
const SPEEDS = [0.75, 0.9, 1, 1.1, 1.2, 1.3, 1.5, 1.75, 2, 2.5, 3];
const SKIP_BACK = 15;
const SKIP_FWD = 30;
const SAVE_EVERY_MS = 5000;
const LS_LAST = 'ab-player:last';
const LS_HINT = 'ab-player:hint-dismissed';

// ---------- Helpers ----------
const $ = (sel) => document.querySelector(sel);
const extOf = (name) => (name.includes('.') ? name.split('.').pop().toLowerCase() : '');
const isAudio = (f) => extOf(f.name) in AUDIO_TYPES || (f.type || '').startsWith('audio/');
const isImage = (f) => extOf(f.name) in IMAGE_TYPES;
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
const uid = () => (crypto.randomUUID ? crypto.randomUUID()
  : Date.now().toString(36) + Math.random().toString(36).slice(2));
const sum = (arr) => arr.reduce((a, b) => a + (b || 0), 0);
const stripExt = (name) => name.replace(/\.[^.]+$/, '');

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fmt(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0;
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const ss = String(s).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

function fmtLong(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0;
  if (sec > 0 && sec < 60) return '<1m';
  const h = Math.floor(sec / 3600);
  const m = Math.round((sec % 3600) / 60);
  if (h && m === 60) return `${h + 1}h`;
  return h ? `${h}h ${m}m` : `${m}m`;
}

function fmtSpeed(r) { return `${Number(r.toFixed(2))}×`; }

function hueFor(str) {
  let h = 0;
  for (const ch of str) h = (h * 31 + ch.codePointAt(0)) % 360;
  return h;
}

function initials(title) {
  const words = title.replace(/[^\p{L}\p{N} ]/gu, ' ').split(/\s+/).filter(Boolean);
  return ((words[0]?.[0] || '') + (words[1]?.[0] || '')).toUpperCase() || '♪';
}

// ---------- State ----------
const audio = $('#audio');
let books = [];
let cur = null;              // { book, index }
let objectUrl = null;
let ready = false;           // metadata loaded for current track
let pendingSeek = null;      // seconds to seek to once metadata arrives
let verifySeek = null;       // re-check seek once playable (iOS sometimes ignores the first one)
let lastSaveAt = 0;
let scrubbing = false;
let sleep = { mode: 'off', until: 0 };
const coverUrls = new Map(); // bookId -> object URL

// ---------- Persistence ----------
function sortBooks() {
  books.sort((a, b) => (b.lastPlayed || 0) - (a.lastPlayed || 0) || (b.createdAt || 0) - (a.createdAt || 0));
}

function writeLast(book) {
  try {
    localStorage.setItem(LS_LAST, JSON.stringify({
      bookId: book.id, track: book.position.track, time: book.position.time, at: book.lastPlayed || Date.now(),
    }));
  } catch { /* storage unavailable */ }
}

function persistBook(book) {
  return db.put('books', book).catch((err) => console.warn('Save failed', err));
}

// Save the current listening position. Called on pause, periodically while
// playing, and whenever the app is hidden or closed.
function savePosition() {
  if (!cur || !ready || verifySeek !== null || pendingSeek !== null) return;
  const t = audio.currentTime;
  if (!isFinite(t)) return;
  const { book, index } = cur;
  book.position = { track: index, time: t };
  book.lastPlayed = Date.now();
  writeLast(book);
  persistBook(book);
  lastSaveAt = Date.now();
}

// ---------- Progress math ----------
function durationsKnown(book) {
  return book.durations.length === book.tracks.length && book.durations.every((d) => d > 0);
}

function bookProgress(book) {
  const pos = book.position || { track: 0, time: 0 };
  const n = book.tracks.length;
  if (book.finished) return { fraction: 1, known: durationsKnown(book), total: sum(book.durations), left: 0 };
  if (!durationsKnown(book)) return { fraction: n ? pos.track / n : 0, known: false };
  const total = sum(book.durations);
  const elapsed = sum(book.durations.slice(0, pos.track)) + pos.time;
  return { fraction: total ? Math.min(1, elapsed / total) : 0, known: true, total, left: Math.max(0, total - elapsed) };
}

// ---------- Covers ----------
function coverStyle(book) {
  const url = coverUrls.get(book.id);
  if (url) return `background-image:url('${url}')`;
  const h = hueFor(book.title);
  return `background-image:linear-gradient(135deg,hsl(${h} 55% 42%),hsl(${(h + 40) % 360} 60% 28%))`;
}

function paintCover(el, book) {
  el.setAttribute('style', coverStyle(book));
  el.textContent = coverUrls.has(book.id) ? '' : initials(book.title);
}

async function loadCover(book) {
  if (!book.coverId || coverUrls.has(book.id)) return;
  const rec = await db.get('files', book.coverId).catch(() => null);
  if (rec?.blob) coverUrls.set(book.id, URL.createObjectURL(rec.blob));
}

// ---------- Library rendering ----------
function renderLibrary() {
  sortBooks();
  const list = $('#bookList');
  $('#empty').hidden = books.length > 0;
  list.innerHTML = books.map((b) => {
    const p = bookProgress(b);
    const n = b.tracks.length;
    const pos = b.position || { track: 0, time: 0 };
    let sub;
    if (b.finished) sub = 'Finished';
    else if (!b.lastPlayed && pos.track === 0 && pos.time < 1) sub = `${n} track${n === 1 ? '' : 's'}${p.known ? ' · ' + fmtLong(p.total) : ''} · Not started`;
    else sub = `Track ${pos.track + 1} of ${n}${p.known ? ` · ${fmtLong(p.left)} left` : ''}`;
    const isCur = cur && cur.book.id === b.id;
    return `<li class="book${isCur ? ' current' : ''}" data-id="${b.id}">
      <button class="book-open" data-act="open">
        <div class="cover thumb" style="${coverStyle(b)}">${coverUrls.has(b.id) ? '' : esc(initials(b.title))}</div>
        <div class="book-info">
          <p class="book-title">${esc(b.title)}</p>
          <p class="book-sub">${esc(sub)}</p>
          <div class="bar"><div style="width:${(p.fraction * 100).toFixed(1)}%"></div></div>
        </div>
      </button>
      <button class="icon-btn book-menu" data-act="menu" aria-label="Options for ${esc(b.title)}">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path class="fill" d="M5 10.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm7 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm7 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/></svg>
      </button>
    </li>`;
  }).join('');
  renderMini();
  renderStorage();
}

async function renderStorage() {
  if (!navigator.storage?.estimate) return;
  try {
    const { usage, quota } = await navigator.storage.estimate();
    const size = (x) => (x >= 1e9 ? `${(x / 1e9).toFixed(1)} GB` : `${Math.round(x / 1e6)} MB`);
    $('#storageInfo').textContent = books.length
      ? `${books.length} book${books.length === 1 ? '' : 's'} · ${size(usage)} used of ~${size(quota)} available`
      : '';
  } catch { /* ignore */ }
}

function renderMini() {
  const mini = $('#mini');
  if (!cur) { mini.hidden = true; return; }
  mini.hidden = false;
  const { book, index } = cur;
  $('#miniTrack').textContent = book.tracks[index].name;
  $('#miniBook').textContent = book.title;
  paintCover($('#miniCover'), book);
  updateTimeUI();
}

// ---------- Player rendering ----------
function renderPlayer() {
  if (!cur) return;
  const { book, index } = cur;
  paintCover($('#pCover'), book);
  $('#pTrack').textContent = book.tracks[index].name;
  $('#pBook').textContent = book.title;
  $('#tTrack').textContent = book.tracks.length > 1 ? `${index + 1} / ${book.tracks.length}` : '';
  $('#speedBtn').textContent = fmtSpeed(book.speed || 1);
  $('#prevBtn').disabled = false;
  $('#nextBtn').disabled = index >= book.tracks.length - 1;
  updateTimeUI();
  updateSleepUI();
}

function currentTimeForUI() {
  if (pendingSeek !== null) return pendingSeek;
  if (verifySeek !== null) return verifySeek;
  return audio.currentTime || (cur?.book.position?.time ?? 0);
}

function updateTimeUI() {
  if (!cur) return;
  const { book, index } = cur;
  const d = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : book.durations[index] || 0;
  const t = currentTimeForUI();
  const frac = d ? Math.min(1, t / d) : 0;
  if (!scrubbing) {
    const seek = $('#seek');
    seek.value = Math.round(frac * 1000);
    seek.style.setProperty('--p', `${frac * 100}%`);
    $('#tCur').textContent = fmt(t);
    $('#tLeft').textContent = d ? `-${fmt(d - t)}` : '';
  }
  $('#miniFill').style.width = `${frac * 100}%`;

  if (durationsKnown(book)) {
    const total = sum(book.durations);
    const elapsed = sum(book.durations.slice(0, index)) + t;
    const rate = book.speed || 1;
    const left = Math.max(0, total - elapsed) / rate;
    $('#bookProg').textContent = `${Math.floor((elapsed / total) * 100)}% · ${fmtLong(left)} left`;
  } else {
    $('#bookProg').textContent = `Track ${index + 1} of ${book.tracks.length}`;
  }
}

function setPlayingClass() {
  const playing = !audio.paused && !audio.ended;
  document.body.classList.toggle('playing', playing);
  const label = playing ? 'Pause' : 'Play';
  $('#playBtn').setAttribute('aria-label', label);
  $('#miniPlay').setAttribute('aria-label', label);
}

function showPlayer() {
  if (!cur) return;
  renderPlayer();
  document.body.classList.add('player-open');
  $('#player').setAttribute('aria-hidden', 'false');
}

function hidePlayer() {
  document.body.classList.remove('player-open');
  $('#player').setAttribute('aria-hidden', 'true');
  renderLibrary();
}

// ---------- Playback ----------
async function loadTrack(book, index, time = 0) {
  index = Math.max(0, Math.min(index, book.tracks.length - 1));
  const rec = await db.get('files', book.tracks[index].id).catch(() => null);
  if (!rec?.blob) { toast('That audio file is missing. Try re-adding the book.'); return false; }

  if (objectUrl) URL.revokeObjectURL(objectUrl);
  objectUrl = URL.createObjectURL(rec.blob);
  cur = { book, index };
  ready = false;
  verifySeek = null;
  pendingSeek = time > 0.5 ? time : null;
  audio.src = objectUrl;
  audio.defaultPlaybackRate = book.speed || 1;
  audio.playbackRate = book.speed || 1;
  audio.load();

  book.position = { track: index, time };
  writeLast(book);
  persistBook(book);

  updateMediaSession();
  renderPlayer();
  renderMini();
  return true;
}

function play() {
  if (!cur) return;
  const { book, index } = cur;
  // Finished book: start over from the beginning.
  if (book.finished || (audio.ended && index === book.tracks.length - 1)) {
    book.finished = false;
    loadTrack(book, 0, 0).then((ok) => ok && play());
    return;
  }
  audio.playbackRate = book.speed || 1;
  const p = audio.play();
  if (p) p.catch((err) => { if (err.name !== 'AbortError') toast('Tap play again to start audio.'); });
}

function togglePlay() {
  if (!cur) return;
  if (audio.paused) play();
  else audio.pause();
}

async function openBook(book, { autoplay = false } = {}) {
  if (!cur || cur.book.id !== book.id) {
    savePosition();
    audio.pause();
    const pos = book.position || { track: 0, time: 0 };
    const ok = await loadTrack(book, pos.track, pos.time);
    if (!ok) return;
  }
  showPlayer();
  if (autoplay) play();
}

async function goToTrack(index, time = 0, keepPlaying = !audio.paused) {
  if (!cur) return;
  savePosition();
  const ok = await loadTrack(cur.book, index, time);
  if (ok && keepPlaying) play();
}

async function skip(seconds) {
  if (!cur) return;
  const { book, index } = cur;
  const wasPlaying = !audio.paused;
  const d = audio.duration;
  let t = currentTimeForUI() + seconds;

  if (t < 0 && index > 0 && book.durations[index - 1] > 0) {
    return goToTrack(index - 1, Math.max(0, book.durations[index - 1] + t), wasPlaying);
  }
  if (isFinite(d) && t >= d) {
    if (index + 1 < book.tracks.length) return goToTrack(index + 1, Math.max(0, t - d), wasPlaying);
    t = Math.max(0, d - 0.25);
  }
  seekTo(Math.max(0, t));
}

function seekTo(t) {
  if (!ready) { pendingSeek = t; updateTimeUI(); return; }
  try { audio.currentTime = t; } catch { /* not seekable yet */ }
  updateTimeUI();
}

function prevTrack() {
  if (!cur) return;
  if (currentTimeForUI() > 3 || cur.index === 0) seekTo(0);
  else goToTrack(cur.index - 1, 0);
}

function nextTrack() {
  if (!cur || cur.index >= cur.book.tracks.length - 1) return;
  goToTrack(cur.index + 1, 0);
}

function setSpeed(rate) {
  if (!cur) return;
  cur.book.speed = rate;
  audio.defaultPlaybackRate = rate;
  audio.playbackRate = rate;
  persistBook(cur.book);
  renderPlayer();
}

// ---------- Sleep timer ----------
function setSleep(mode) {
  if (mode === 'off') sleep = { mode: 'off', until: 0 };
  else if (mode === 'track') sleep = { mode: 'track', until: 0 };
  else sleep = { mode: 'time', until: Date.now() + mode * 60000 };
  updateSleepUI();
}

function updateSleepUI() {
  const btn = $('#sleepBtn');
  const label = $('#sleepLabel');
  btn.classList.toggle('on', sleep.mode !== 'off');
  if (sleep.mode === 'time') label.textContent = fmt(Math.max(0, (sleep.until - Date.now()) / 1000));
  else if (sleep.mode === 'track') label.textContent = 'End of track';
  else label.textContent = 'Sleep';
}

function checkSleep() {
  if (sleep.mode === 'time' && Date.now() >= sleep.until) {
    setSleep('off');
    audio.pause();
  }
}

setInterval(() => {
  if (sleep.mode === 'time') { checkSleep(); updateSleepUI(); }
}, 1000);

// ---------- Audio events ----------
audio.addEventListener('loadedmetadata', () => {
  if (!cur) return;
  const d = audio.duration;
  const { book, index } = cur;
  if (isFinite(d) && d > 0 && Math.abs((book.durations[index] || 0) - d) > 0.5) {
    while (book.durations.length < book.tracks.length) book.durations.push(0);
    book.durations[index] = d;
    persistBook(book);
  }
  if (pendingSeek !== null) {
    const target = isFinite(d) ? Math.min(pendingSeek, Math.max(0, d - 0.5)) : pendingSeek;
    pendingSeek = null;
    verifySeek = target;
    try { audio.currentTime = target; } catch { /* retry on canplay */ }
  }
  ready = true;
  updatePositionState();
  updateTimeUI();
});

audio.addEventListener('canplay', () => {
  if (verifySeek !== null) {
    if (Math.abs(audio.currentTime - verifySeek) > 1.5) {
      try { audio.currentTime = verifySeek; } catch { /* ignore */ }
    }
    verifySeek = null;
  }
});

audio.addEventListener('seeked', () => {
  if (verifySeek !== null && Math.abs(audio.currentTime - verifySeek) <= 1.5) verifySeek = null;
  updatePositionState();
  if (audio.paused) savePosition();
});

audio.addEventListener('timeupdate', () => {
  if (!scrubbing) updateTimeUI();
  checkSleep();
  if (!audio.paused && Date.now() - lastSaveAt > SAVE_EVERY_MS) savePosition();
});

audio.addEventListener('play', () => {
  if (cur) { cur.book.finished = false; cur.book.lastPlayed = Date.now(); }
  setPlayingClass();
  updatePositionState();
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
});

audio.addEventListener('pause', () => {
  savePosition();
  setPlayingClass();
  updatePositionState();
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
});

audio.addEventListener('ratechange', updatePositionState);

audio.addEventListener('ended', async () => {
  if (!cur) return;
  const { book, index } = cur;
  if (index + 1 < book.tracks.length) {
    const stop = sleep.mode === 'track';
    if (stop) setSleep('off');
    const ok = await loadTrack(book, index + 1, 0);
    if (ok && !stop) play();
  } else {
    book.finished = true;
    book.position = { track: index, time: audio.duration || 0 };
    book.lastPlayed = Date.now();
    writeLast(book);
    persistBook(book);
    if (sleep.mode === 'track') setSleep('off');
    setPlayingClass();
    toast(`Finished “${book.title}”`);
  }
});

audio.addEventListener('error', () => {
  if (!cur || !audio.src) return;
  toast('This file could not be played. iPhone supports MP3, M4A/M4B, AAC, WAV and FLAC.');
});

// Save whenever the app is backgrounded, switched away from, or closed.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') savePosition();
  else { updateTimeUI(); setPlayingClass(); updateSleepUI(); }
});
window.addEventListener('pagehide', savePosition);
window.addEventListener('beforeunload', savePosition);

// ---------- Lock screen / Control Center ----------
function updateMediaSession() {
  if (!('mediaSession' in navigator) || !cur) return;
  const { book, index } = cur;
  const art = coverUrls.get(book.id);
  const base = new URL('./icons/', location.href).href;
  try {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: book.tracks[index].name,
      artist: book.title,
      album: book.title,
      artwork: art
        ? [{ src: art, sizes: '512x512' }]
        : [{ src: base + 'icon-512.png', sizes: '512x512', type: 'image/png' }],
    });
  } catch { /* ignore */ }
}

function updatePositionState() {
  if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState) return;
  const d = audio.duration;
  if (!isFinite(d) || d <= 0) return;
  try {
    navigator.mediaSession.setPositionState({
      duration: d, playbackRate: audio.playbackRate || 1, position: Math.min(audio.currentTime || 0, d),
    });
  } catch { /* ignore */ }
}

if ('mediaSession' in navigator) {
  const ms = navigator.mediaSession;
  const handlers = {
    play: () => play(),
    pause: () => audio.pause(),
    stop: () => audio.pause(),
    seekbackward: (e) => skip(-(e.seekOffset || SKIP_BACK)),
    seekforward: (e) => skip(e.seekOffset || SKIP_FWD),
    seekto: (e) => { if (e.seekTime != null) seekTo(e.seekTime); },
  };
  for (const [action, fn] of Object.entries(handlers)) {
    try { ms.setActionHandler(action, fn); } catch { /* unsupported action */ }
  }
}

// ---------- Importing ----------
function cleanTrackName(name) {
  return stripExt(name).replace(/_/g, ' ').trim() || name;
}

const DISC_RE = /^(cd|disc|disk|part|pt|volume|vol)[\s._-]*\d+/i;

function makeGroup(title, entries) {
  const audioEntries = entries.filter((e) => isAudio(e.f))
    .sort((a, b) => collator.compare(a.path, b.path));
  const images = entries.filter((e) => isImage(e.f)).map((e) => e.f);
  return { title, audio: audioEntries.map((e) => e.f), images };
}

// Turn the picked files into one or more books.
//  - A folder with audio in it (or only disc/CD subfolders) => one book.
//  - A folder whose subfolders each contain audio => one book per subfolder.
//  - Loose files => one book.
function groupIntoBooks(files) {
  const entries = files.map((f) => {
    const path = f.webkitRelativePath || f.name;
    return { f, path, parts: path.split('/') };
  });
  if (!entries.some((e) => e.parts.length > 1)) {
    return entries.some((e) => isAudio(e.f)) ? [makeGroup(null, entries)] : [];
  }

  const root = entries[0].parts[0];
  const rootHasAudio = entries.some((e) => e.parts.length === 2 && isAudio(e.f));
  const subs = new Map();
  for (const e of entries) {
    if (e.parts.length > 2) {
      const key = e.parts[1];
      if (!subs.has(key)) subs.set(key, []);
      subs.get(key).push(e);
    }
  }
  const audioSubs = [...subs].filter(([, es]) => es.some((e) => isAudio(e.f)));
  const allDiscs = audioSubs.length > 0 && audioSubs.every(([k]) => DISC_RE.test(k));

  if (rootHasAudio || audioSubs.length <= 1 || allDiscs) {
    if (!rootHasAudio && audioSubs.length === 0) return [];
    const title = rootHasAudio || allDiscs || !audioSubs.length ? root : audioSubs[0][0];
    return [makeGroup(title, entries)];
  }
  const rootImages = entries.filter((e) => e.parts.length === 2 && isImage(e.f));
  return audioSubs.map(([k, es]) => makeGroup(k, es.concat(rootImages)));
}

function pickCover(images) {
  if (!images.length) return null;
  const pref = images.find((f) => /^(cover|folder|front)\b/i.test(f.name));
  return pref || images[0];
}

function guessTitle(files) {
  const names = files.map((f) => stripExt(f.name));
  if (names.length === 1) return cleanTrackName(names[0]);
  let prefix = names[0];
  for (const n of names) {
    let i = 0;
    while (i < prefix.length && i < n.length && prefix[i].toLowerCase() === n[i].toLowerCase()) i++;
    prefix = prefix.slice(0, i);
  }
  prefix = prefix.replace(/[\s\d._\-–—()[\]#]+$/u, '').replace(/[_]/g, ' ').trim();
  return prefix.length >= 3 ? prefix : 'New Book';
}

async function importGroup(group, onProgress) {
  const bookId = uid();
  const tracks = [];
  try {
    for (let i = 0; i < group.audio.length; i++) {
      const f = group.audio[i];
      const type = AUDIO_TYPES[extOf(f.name)] || f.type || 'audio/mpeg';
      const blob = f.type === type ? f : f.slice(0, f.size, type);
      const id = uid();
      await db.put('files', { id, bookId, blob });
      tracks.push({ id, name: cleanTrackName(f.name) });
      onProgress(i + 1, group.audio.length);
    }
    let coverId = null;
    const cover = pickCover(group.images);
    if (cover) {
      coverId = uid();
      const type = IMAGE_TYPES[extOf(cover.name)] || cover.type || 'image/jpeg';
      await db.put('files', { id: coverId, bookId, blob: cover.slice(0, cover.size, type) });
    }
    const book = {
      id: bookId,
      title: group.title,
      tracks,
      durations: tracks.map(() => 0),
      coverId,
      position: { track: 0, time: 0 },
      speed: 1,
      createdAt: Date.now(),
      lastPlayed: 0,
      finished: false,
    };
    await db.put('books', book);
    return book;
  } catch (err) {
    await db.deleteFilesForBook(bookId).catch(() => {});
    throw err;
  }
}

async function handlePicked(fileList) {
  const files = [...fileList].filter((f) => !f.name.startsWith('.'));
  const groups = groupIntoBooks(files);
  if (!groups.length) { toast('No audio files found in that selection.'); return; }

  for (const g of groups) {
    if (!g.title) {
      const t = window.prompt('Name this book', guessTitle(g.audio));
      if (t === null) return;
      g.title = t.trim() || guessTitle(g.audio);
    }
  }

  if (navigator.storage?.persist) navigator.storage.persist().catch(() => {});

  const added = [];
  showBusy('Preparing…');
  try {
    for (let gi = 0; gi < groups.length; gi++) {
      const g = groups[gi];
      const label = groups.length > 1 ? `Book ${gi + 1} of ${groups.length}: ` : '';
      const book = await importGroup(g, (i, n) => showBusy(`${label}${g.title}\nCopying file ${i} of ${n}…`));
      await loadCover(book);
      books.push(book);
      added.push(book);
    }
  } catch (err) {
    console.error(err);
    const quota = err && (err.name === 'QuotaExceededError' || /quota/i.test(err.message || ''));
    toast(quota ? 'Not enough storage space on this device for that book.' : `Import failed: ${err?.message || err}`);
  } finally {
    hideBusy();
    renderLibrary();
  }
  if (added.length) {
    toast(added.length === 1 ? `Added “${added[0].title}”` : `Added ${added.length} books`);
    probeQueue.push(...added);
    runProbes();
  }
}

// Work out each track's length in the background so the app can show
// overall book progress and time remaining.
const probeQueue = [];
let probing = false;
async function runProbes() {
  if (probing) return;
  probing = true;
  const probe = new Audio();
  probe.preload = 'metadata';
  probe.muted = true;
  while (probeQueue.length) {
    const book = probeQueue.shift();
    if (!books.includes(book)) continue;
    let changed = false;
    for (let i = 0; i < book.tracks.length; i++) {
      if (book.durations[i] > 0) continue;
      const rec = await db.get('files', book.tracks[i].id).catch(() => null);
      if (!rec?.blob) continue;
      const url = URL.createObjectURL(rec.blob);
      const d = await new Promise((resolve) => {
        const done = (v) => { clearTimeout(timer); probe.onloadedmetadata = probe.onerror = null; resolve(v); };
        const timer = setTimeout(() => done(0), 15000);
        probe.onloadedmetadata = () => done(probe.duration);
        probe.onerror = () => done(0);
        probe.src = url;
      });
      URL.revokeObjectURL(url);
      if (isFinite(d) && d > 0) {
        while (book.durations.length < book.tracks.length) book.durations.push(0);
        book.durations[i] = d;
        changed = true;
      }
    }
    if (changed) {
      await persistBook(book);
      if (!document.body.classList.contains('player-open')) renderLibrary();
      else updateTimeUI();
    }
  }
  probe.removeAttribute('src');
  probing = false;
}

// ---------- Book actions ----------
async function deleteBook(book) {
  if (!window.confirm(`Delete “${book.title}” from this device? Your original files are not affected.`)) return;
  if (cur && cur.book.id === book.id) {
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = null;
    cur = null;
    ready = false;
    try { localStorage.removeItem(LS_LAST); } catch { /* ignore */ }
    hidePlayer();
  }
  books = books.filter((b) => b !== book);
  const url = coverUrls.get(book.id);
  if (url) { URL.revokeObjectURL(url); coverUrls.delete(book.id); }
  await db.deleteFilesForBook(book.id).catch(() => {});
  await db.del('books', book.id).catch(() => {});
  renderLibrary();
}

async function restartBook(book) {
  book.finished = false;
  book.position = { track: 0, time: 0 };
  if (cur && cur.book.id === book.id) {
    await loadTrack(book, 0, 0);
  } else {
    persistBook(book);
  }
  renderLibrary();
}

async function markFinished(book) {
  if (cur && cur.book.id === book.id) audio.pause();
  book.finished = true;
  const last = book.tracks.length - 1;
  book.position = { track: last, time: book.durations[last] || 0 };
  await persistBook(book);
  renderLibrary();
}

function renameBook(book) {
  const t = window.prompt('Rename book', book.title);
  if (t === null || !t.trim()) return;
  book.title = t.trim();
  persistBook(book);
  if (cur && cur.book.id === book.id) { renderPlayer(); updateMediaSession(); }
  renderLibrary();
}

async function bookMenu(book) {
  const choice = await sheet(book.title, [
    { label: 'Play', value: 'play' },
    { label: 'Rename', value: 'rename' },
    { label: 'Start over', value: 'restart' },
    { label: 'Mark as finished', value: 'finish' },
    { label: 'Delete from device', value: 'delete', danger: true },
  ]);
  if (choice === 'play') openBook(book, { autoplay: true });
  else if (choice === 'rename') renameBook(book);
  else if (choice === 'restart') restartBook(book);
  else if (choice === 'finish') markFinished(book);
  else if (choice === 'delete') deleteBook(book);
}

// ---------- Sheets / overlays ----------
let sheetResolve = null;

function sheet(title, options, { note = '', scrollTo = null } = {}) {
  closeSheet(null);
  $('#sheetTitle').textContent = title;
  const body = $('#sheetBody');
  body.innerHTML = (note ? `<p class="sheet-note">${esc(note)}</p>` : '') + options.map((o, i) => `
    <button class="sheet-opt${o.selected ? ' selected' : ''}${o.danger ? ' danger' : ''}" data-i="${i}">
      <span class="opt-main">${esc(o.label)}${o.desc ? `<span class="opt-desc">${esc(o.desc)}</span>` : ''}</span>
      ${o.meta ? `<small>${esc(o.meta)}</small>` : ''}
    </button>`).join('');
  $('#sheet').hidden = false;
  document.body.classList.add('sheet-open');
  if (scrollTo !== null) {
    const el = body.querySelector(`[data-i="${scrollTo}"]`);
    if (el) el.scrollIntoView({ block: 'center' });
  }
  return new Promise((resolve) => {
    sheetResolve = (i) => resolve(i === null ? null : options[i].value);
  });
}

function closeSheet(i) {
  $('#sheet').hidden = true;
  document.body.classList.remove('sheet-open');
  if (sheetResolve) { const r = sheetResolve; sheetResolve = null; r(i); }
}

$('#sheetBody').addEventListener('click', (e) => {
  const btn = e.target.closest('.sheet-opt');
  if (btn) closeSheet(Number(btn.dataset.i));
});
$('#sheetCancel').addEventListener('click', () => closeSheet(null));
$('#sheet').addEventListener('click', (e) => { if (e.target.id === 'sheet') closeSheet(null); });

let toastTimer;
function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

function showBusy(text) {
  $('#busyText').textContent = text;
  $('#busyText').style.whiteSpace = 'pre-line';
  $('#busy').hidden = false;
}
function hideBusy() { $('#busy').hidden = true; }

// ---------- UI wiring ----------
async function addBook() {
  const choice = await sheet('Add a book', [
    { label: 'Choose a folder', value: 'folder', desc: 'Each folder becomes a book. Pick a folder of folders to add several books at once.' },
    { label: 'Choose audio files', value: 'files', desc: 'Select all the files for one book.' },
  ], { note: 'Files are copied into the app so they play offline.' });
  if (choice === 'folder') $('#pickFolder').click();
  else if (choice === 'files') $('#pickFiles').click();
}

$('#addBtn').addEventListener('click', addBook);
$('#emptyAdd').addEventListener('click', addBook);

for (const id of ['#pickFolder', '#pickFiles']) {
  const input = $(id);
  input.addEventListener('change', async () => {
    const files = input.files;
    if (files && files.length) await handlePicked(files);
    input.value = '';
  });
}

$('#bookList').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const id = btn.closest('.book').dataset.id;
  const book = books.find((b) => b.id === id);
  if (!book) return;
  if (btn.dataset.act === 'open') openBook(book);
  else bookMenu(book);
});

$('#miniOpen').addEventListener('click', showPlayer);
$('#miniPlay').addEventListener('click', togglePlay);
$('#closePlayer').addEventListener('click', hidePlayer);
$('#playBtn').addEventListener('click', togglePlay);
$('#backBtn').addEventListener('click', () => skip(-SKIP_BACK));
$('#fwdBtn').addEventListener('click', () => skip(SKIP_FWD));
$('#prevBtn').addEventListener('click', prevTrack);
$('#nextBtn').addEventListener('click', nextTrack);

const seekEl = $('#seek');
function scrubTarget() {
  const d = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : cur?.book.durations[cur.index] || 0;
  return (seekEl.value / 1000) * d;
}
seekEl.addEventListener('input', () => {
  scrubbing = true;
  const d = isFinite(audio.duration) ? audio.duration : 0;
  const t = scrubTarget();
  seekEl.style.setProperty('--p', `${seekEl.value / 10}%`);
  $('#tCur').textContent = fmt(t);
  $('#tLeft').textContent = d ? `-${fmt(d - t)}` : '';
});
seekEl.addEventListener('change', () => {
  scrubbing = false;
  seekTo(scrubTarget());
});

$('#speedBtn').addEventListener('click', async () => {
  if (!cur) return;
  const curSpeed = cur.book.speed || 1;
  const i = SPEEDS.indexOf(curSpeed);
  const choice = await sheet('Playback speed', SPEEDS.map((s) => ({
    label: fmtSpeed(s), value: s, selected: s === curSpeed,
  })), { scrollTo: i >= 0 ? i : null });
  if (choice !== null) setSpeed(choice);
});

$('#sleepBtn').addEventListener('click', async () => {
  const opts = [5, 10, 15, 30, 45, 60, 90].map((m) => ({ label: `${m} minutes`, value: m }));
  opts.push({ label: 'End of this track', value: 'track', selected: sleep.mode === 'track' });
  if (sleep.mode !== 'off') opts.unshift({ label: 'Turn off timer', value: 'off', danger: true });
  const choice = await sheet('Sleep timer', opts);
  if (choice !== null) setSleep(choice);
});

$('#tracksBtn').addEventListener('click', async () => {
  if (!cur) return;
  const { book, index } = cur;
  const choice = await sheet(book.title, book.tracks.map((t, i) => ({
    label: t.name,
    value: i,
    selected: i === index,
    meta: book.durations[i] > 0 ? fmt(book.durations[i]) : '',
  })), { scrollTo: index });
  if (choice !== null && choice !== index) goToTrack(choice, 0, true);
});

// Install hint for iPhone Safari (not yet added to the Home Screen)
(function installHint() {
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches;
  let dismissed = false;
  try { dismissed = localStorage.getItem(LS_HINT) === '1'; } catch { /* ignore */ }
  if (isIOS && !standalone && !dismissed) $('#installHint').hidden = false;
  $('#hideHint').addEventListener('click', () => {
    $('#installHint').hidden = true;
    try { localStorage.setItem(LS_HINT, '1'); } catch { /* ignore */ }
  });
})();

// ---------- Startup ----------
async function init() {
  try {
    books = await db.getAll('books');
  } catch (err) {
    console.error(err);
    toast('Could not open storage on this device.');
    books = [];
  }
  for (const b of books) {
    b.durations = b.durations || [];
    b.position = b.position || { track: 0, time: 0 };
  }

  // The synchronous localStorage copy may be newer than the IndexedDB record
  // if the app was closed in the middle of a save.
  let last = null;
  try { last = JSON.parse(localStorage.getItem(LS_LAST) || 'null'); } catch { /* ignore */ }
  if (last) {
    const b = books.find((x) => x.id === last.bookId);
    if (b && (last.at || 0) >= (b.lastPlayed || 0) && last.track < b.tracks.length) {
      b.position = { track: last.track, time: last.time };
      b.lastPlayed = last.at;
    }
  }

  await Promise.all(books.map(loadCover));
  sortBooks();
  renderLibrary();

  // Restore the most recently played book (paused) so it's one tap away.
  const recent = books.find((b) => b.lastPlayed);
  if (recent) {
    await loadTrack(recent, recent.position.track, recent.position.time);
    renderLibrary();
  }

  probeQueue.push(...books.filter((b) => !durationsKnown(b)));
  setTimeout(runProbes, 1500);
}

init();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch((err) => console.warn('SW registration failed', err));
  });
}
