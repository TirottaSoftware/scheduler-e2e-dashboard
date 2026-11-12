const STORAGE_KEY = 'e2e_sessions';

function relativeTime(iso) {
  const diff = Date.now() - new Date(iso).getTime();
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function renderEmpty() {
  return `
    <div class="empty">
      <div class="empty-icon">🔒</div>
      <div class="empty-title">No sessions captured</div>
      <div class="empty-desc">Log in to a SAP landscape and the JSESSIONID will be captured automatically.</div>
    </div>
  `;
}

function truncate(str, len = 24) {
  return str.length > len ? str.slice(0, len) + '…' : str;
}

function render(sessions) {
  const list = document.getElementById('sessionsList');
  const clearBtn = document.getElementById('clearBtn');

  const entries = Object.entries(sessions || {});

  if (!entries.length) {
    list.innerHTML = renderEmpty();
    clearBtn.disabled = true;
    return;
  }

  clearBtn.disabled = false;

  list.innerHTML = entries
    .sort(([, a], [, b]) => new Date(b.savedAt) - new Date(a.savedAt))
    .map(([id, entry]) => `
      <div class="session-item">
        <div class="session-info">
          <div class="session-name">
            <span class="session-dot"></span>
            ${entry.landscapeName || id}
          </div>
          <div class="session-age">Captured ${relativeTime(entry.savedAt)}</div>
          <div class="session-id">${truncate(entry.jsessionid, 26)}</div>
        </div>
        <button class="btn-copy" data-id="${id}" data-value="${entry.jsessionid}">Copy</button>
      </div>
    `)
    .join('');

  list.querySelectorAll('.btn-copy').forEach(btn => {
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.value);
        btn.textContent = 'Copied!';
        btn.classList.add('copied');
        setTimeout(() => {
          btn.textContent = 'Copy';
          btn.classList.remove('copied');
        }, 1800);
      } catch {
        btn.textContent = 'Failed';
        setTimeout(() => { btn.textContent = 'Copy'; }, 1800);
      }
    });
  });
}

// Initial load
chrome.storage.local.get(STORAGE_KEY, result => {
  render(result[STORAGE_KEY] || {});
});

// Clear all
document.getElementById('clearBtn').addEventListener('click', () => {
  chrome.storage.local.remove(STORAGE_KEY, () => {
    render({});
  });
});

// Live updates while popup is open
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes[STORAGE_KEY]) {
    render(changes[STORAGE_KEY].newValue || {});
  }
});
