const element = id => document.getElementById(id);
let state = { paused: true, position: 0, duration: 0, volume: 100, muted: false, fullscreen: false };
let seekTimer;
let draggingTimeline = false;
const optionSignatures = new Map();

function send(command, value) {
  window.webkit?.messageHandlers?.player?.postMessage({ command, value });
}

function timeLabel(value) {
  const seconds = Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
  const minutes = Math.floor(seconds / 60);
  return minutes >= 60
    ? `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`
    : `${minutes}:${String(seconds % 60).padStart(2, '0')}`;
}

function setRange(id, value) {
  if (Number.isFinite(value) && document.activeElement !== element(id)) element(id).value = String(value);
}

function setOptions(id, options, selected) {
  const select = element(id);
  const signature = JSON.stringify(options);
  if (optionSignatures.get(id) !== signature) {
    select.replaceChildren(...options.map(option => {
      const node = document.createElement('option');
      node.value = String(option.value);
      node.textContent = option.label;
      return node;
    }));
    optionSignatures.set(id, signature);
  }
  if (selected !== undefined && selected !== null) select.value = String(selected);
}

function update(next) {
  if (!next || next.version !== 1) return;
  state = { ...state, ...next };
  const processing = next.processing ?? {};
  const loaded = Number.isFinite(state.duration) && state.duration > 0;
  element('title').textContent = state.title || 'Open a video';
  element('status').textContent = processing.message || (state.loading ? 'Loading video…' : loaded ? 'Native HDR playback' : 'Open a local video to begin');
  element('timeline').disabled = !loaded;
  element('timeline').max = String(Math.max(0.001, state.duration || 0));
  if (!draggingTimeline) {
    setRange('timeline', state.position);
    element('position').textContent = timeLabel(state.position);
  }
  element('duration').textContent = timeLabel(state.duration);
  element('timeline').setAttribute('aria-valuetext', `${timeLabel(state.position)} of ${timeLabel(state.duration)}`);
  element('play').setAttribute('aria-label', state.paused ? 'Play' : 'Pause');
  element('play-icon').replaceChildren();
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  icon.setAttribute('d', state.paused ? 'm8 5 11 7-11 7Z' : 'M7 5h3v14H7ZM14 5h3v14h-3Z');
  element('play-icon').append(icon);
  for (const button of document.querySelectorAll('.transport button')) button.disabled = !loaded;
  setRange('volume', state.volume);
  element('volume-value').textContent = `${Math.round(state.volume ?? 100)}%`;
  element('mute').setAttribute('aria-pressed', String(Boolean(state.muted)));
  element('mute').setAttribute('aria-label', state.muted ? 'Unmute' : 'Mute');
  element('fullscreen').setAttribute('aria-label', state.fullscreen ? 'Exit fullscreen' : 'Enter fullscreen');

  for (const type of ['audio', 'video', 'sub']) {
    const tracks = (next.tracks ?? []).filter(track => track.type === type);
    const options = tracks.map(track => ({ value: track.id, label: track.title || track.language || `${type === 'sub' ? 'Subtitle' : type === 'audio' ? 'Audio' : 'Video'} ${track.id}` }));
    if (type === 'sub') options.unshift({ value: 'no', label: 'Off' });
    if (!options.length) options.push({ value: 'auto', label: 'None available' });
    const selected = tracks.find(track => track.selected)?.id ?? (type === 'sub' ? 'no' : 'auto');
    setOptions(type, options, selected);
    element(type).disabled = !loaded || tracks.length === 0;
    if (type === 'video') element('video-label').hidden = tracks.length <= 1;
  }
  const chapters = next.chapters ?? [];
  setOptions('chapter', chapters.map(chapter => ({ value: chapter.index, label: chapter.title || `Chapter ${chapter.index + 1}` })), next.chapter);
  element('chapter-label').hidden = chapters.length === 0;
  element('mode').value = processing.mode || 'live';
  const availableModes = processing.availableModes ?? [];
  element('mode').disabled = availableModes.length === 0;
  for (const option of element('mode').options) option.disabled = !availableModes.includes(option.value);
  element('enhancement').checked = Boolean(processing.enabled);
  element('enhancement').disabled = !processing.modelAvailable;
  for (const id of ['strength', 'colorStrength']) {
    setRange(id, processing[id] ?? 1);
    element(id).disabled = !processing.modelAvailable || !processing.enabled;
    element(`${id}-value`).textContent = `${Math.round((processing[id] ?? 1) * 100)}%`;
  }
  element('processing-detail').textContent = processing.enabled
    ? `${processing.width ?? '—'} × ${processing.height ?? '—'} · ${processing.status || 'Processing'}`
    : 'Original HDR';
  element('compare').hidden = !next.capabilities?.sameFrameComparison;
  element('compare').textContent = processing.comparison === 'original' ? 'Show enhanced' : 'Compare original';
  element('compare').setAttribute('aria-pressed', String(processing.comparison === 'original'));
  if (document.activeElement !== element('quality')) element('quality').value = `${processing.width ?? 32}x${processing.height ?? 24}`;
  element('quality').disabled = !processing.modelAvailable;
  setRange('subtitleBrightness', processing.subtitleBrightness ?? 1);
  setRange('subtitleScale', next.subtitleScale ?? 1);
  setRange('subtitleDelay', next.subtitleDelay ?? 0);
}

for (const button of document.querySelectorAll('[data-command]')) {
  button.addEventListener('click', () => send(button.dataset.command,
    button.dataset.value === undefined ? undefined : Number(button.dataset.value)));
}
element('mute').addEventListener('click', () => send('mute', !state.muted));
element('fullscreen').addEventListener('click', () => send('fullscreen', !state.fullscreen));
element('volume').addEventListener('input', event => {
  element('volume-value').textContent = `${event.target.value}%`;
  send('volume', Number(event.target.value));
});
for (const type of ['audio', 'video', 'sub']) {
  element(type).addEventListener('change', event => {
    const value = event.target.value;
    send('track', { type, id: value === 'no' || value === 'auto' ? value : Number(value) });
  });
}
element('chapter').addEventListener('change', event => send('chapter', Number(event.target.value)));
element('mode').addEventListener('change', event => send('mode', event.target.value));
element('enhancement').addEventListener('change', event => send('enhancement', event.target.checked));
element('settings-open').addEventListener('click', () => element('settings').showModal());
element('settings-close').addEventListener('click', () => element('settings').close());
element('quality').addEventListener('change', event => {
  const [width, height] = event.target.value.split('x').map(Number);
  if (Number.isInteger(width) && Number.isInteger(height)) send('quality', { width, height });
});
for (const id of ['subtitleBrightness', 'subtitleScale', 'subtitleDelay']) {
  element(id).addEventListener('change', event => {
    const value = Number(event.target.value);
    if (Number.isFinite(value)) send(id, value);
  });
}
for (const id of ['strength', 'colorStrength']) {
  element(id).addEventListener('input', event => { element(`${id}-value`).textContent = `${Math.round(Number(event.target.value) * 100)}%`; });
  element(id).addEventListener('change', event => send(id, Number(event.target.value)));
}
element('timeline').addEventListener('pointerdown', () => { draggingTimeline = true; });
element('timeline').addEventListener('input', event => {
  clearTimeout(seekTimer);
  const position = Number(event.target.value);
  element('position').textContent = timeLabel(position);
  seekTimer = setTimeout(() => send('seek', position), 100);
});
element('timeline').addEventListener('change', event => {
  clearTimeout(seekTimer);
  draggingTimeline = false;
  send('seek', Number(event.target.value));
});
element('timeline').addEventListener('pointercancel', () => { clearTimeout(seekTimer); draggingTimeline = false; });
window.addEventListener('player-state', event => update(event.detail));
window.addEventListener('keydown', event => {
  if (event.metaKey || event.ctrlKey || event.altKey || event.target.matches('input, select, button, textarea')) return;
  const actions = {
    ' ': () => send('togglePause'),
    ArrowLeft: () => send('seek', Math.max(0, state.position - (event.shiftKey ? 30 : 5))),
    ArrowRight: () => send('seek', Math.min(state.duration, state.position + (event.shiftKey ? 30 : 5))),
    m: () => send('mute', !state.muted),
    f: () => send('fullscreen', !state.fullscreen),
    '.': () => send('frameStep', 1),
    ',': () => send('frameStep', -1),
  };
  if (actions[event.key]) { event.preventDefault(); actions[event.key](); }
});

// All available actions are native commands; source strings only enter text nodes.
update({ version: 1, paused: true, duration: 0, processing: { modelAvailable: false } });
