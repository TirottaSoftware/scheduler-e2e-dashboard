const STORAGE_KEY     = 'e2e_sessions';
const LS_KEY          = 'e2e_dashboard_sessions';
const TOAST_DURATION  = 3500;

// ── localStorage bridge ───────────────────────────────────────────────────────

function syncToLocalStorage(sessions) {
  try {
    const current = JSON.parse(localStorage.getItem(LS_KEY) || '{}');
    for (const [id, entry] of Object.entries(sessions)) {
      current[id] = { jsessionid: entry.jsessionid, savedAt: entry.savedAt };
    }
    localStorage.setItem(LS_KEY, JSON.stringify(current));
  } catch { /* storage unavailable */ }
}

// ── Input auto-fill (if run modal is currently open) ─────────────────────────

function tryFillInput(jsessionid) {
  const input = document.getElementById('jsessionidInput');
  if (!input) return;
  input.value = jsessionid;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  const hint = document.getElementById('cachedHint');
  if (hint) { hint.textContent = 'Session captured automatically.'; hint.style.display = 'block'; }
}

// ── Toast notification ────────────────────────────────────────────────────────

function showToast(landscapeName) {
  const existing = document.getElementById('e2e-ext-toast');
  if (existing) existing.remove();

  const toast = document.createElement('div');
  toast.id = 'e2e-ext-toast';
  toast.textContent = `✓ JSESSIONID captured for ${landscapeName}`;
  toast.style.cssText = [
    'position:fixed', 'bottom:24px', 'right:24px', 'z-index:999999',
    'background:#1f2937', 'color:#3fb950', 'border:1px solid #3fb950',
    'padding:10px 16px', 'border-radius:8px',
    'font:600 13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
    'box-shadow:0 4px 16px rgba(0,0,0,0.5)',
    'opacity:0', 'transition:opacity 0.2s',
  ].join(';');

  document.body.appendChild(toast);
  requestAnimationFrame(() => { toast.style.opacity = '1'; });
  setTimeout(() => {
    toast.style.opacity = '0';
    toast.addEventListener('transitionend', () => toast.remove(), { once: true });
  }, TOAST_DURATION);
}

// ── On page load: pull any already-captured sessions into localStorage ────────

chrome.storage.local.get(STORAGE_KEY, result => {
  const sessions = result[STORAGE_KEY];
  if (sessions) syncToLocalStorage(sessions);
});

// ── Real-time: background sends a message when a new session is captured ──────

chrome.runtime.onMessage.addListener(msg => {
  if (msg.type !== 'SESSION_CAPTURED') return;
  syncToLocalStorage({ [msg.landscapeId]: { jsessionid: msg.jsessionid, savedAt: msg.savedAt } });
  showToast(msg.landscapeName);
  tryFillInput(msg.jsessionid);
});

// ── On tab focus: re-sync in case the user just logged in ─────────────────────

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  chrome.storage.local.get(STORAGE_KEY, result => {
    const sessions = result[STORAGE_KEY];
    if (!sessions) return;
    syncToLocalStorage(sessions);
    // If the run modal is currently open, fill the most recently saved session
    const backdrop = document.getElementById('runModalBackdrop');
    if (backdrop?.style.display !== 'none') {
      const subtitle = document.getElementById('modalLandscapeName')?.textContent;
      const entry = Object.values(sessions).find(s => s.landscapeName === subtitle);
      if (entry) tryFillInput(entry.jsessionid);
    }
  });
});
