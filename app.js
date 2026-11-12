const STORAGE_KEY = 'e2e_dashboard_config';
const WORKFLOW_FILE = 'e2e-tests.yml';

const GH_HOST  = 'github.tools.sap';
const GH_OWNER = 'I759727';
const GH_REPO  = 'E2E-Testing-Dashboard';

// ── Config (stored in localStorage — token only) ──────────────────────────────

function loadConfig() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; }
  catch { return {}; }
}

function saveConfig(cfg) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
}

function isConfigured() {
  return !!loadConfig().token;
}

// ── Bookmarklet ───────────────────────────────────────────────────────────────

function buildBookmarkletHref() {
  const code = `(function(){
    var c=document.cookie.split(';').find(function(s){return s.trim().startsWith('JSESSIONID=');});
    if(c){
      var v=c.trim().split('=').slice(1).join('=');
      navigator.clipboard.writeText(v).then(function(){
        var b=document.createElement('div');
        b.style.cssText='position:fixed;top:20px;right:20px;z-index:999999;background:#2f81f7;color:#fff;padding:10px 16px;border-radius:6px;font:600 13px/1.4 sans-serif;box-shadow:0 4px 12px rgba(0,0,0,0.4)';
        b.textContent='✓ JSESSIONID copied to clipboard';
        document.body.appendChild(b);
        setTimeout(function(){b.remove();},2500);
      }).catch(function(){prompt('Copy your JSESSIONID:',v);});
    } else {
      alert('No JSESSIONID cookie found.\\nMake sure you are logged into this SAP landscape.');
    }
  })();`.replace(/\s+/g, ' ');
  return 'javascript:' + code;
}

// ── Run state ─────────────────────────────────────────────────────────────────

// keyed by landscape id: { runId, status, conclusion, url, startedAt }
const runState = {};

// ── GitHub API ────────────────────────────────────────────────────────────────

function apiBase() {
  if (GH_HOST === 'github.com') return 'https://api.github.com';
  return `https://${GH_HOST}/api/v3`;
}

async function ghFetch(path, options = {}) {
  const { token } = loadConfig();
  const res = await fetch(`${apiBase()}${path}`, {
    ...options,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      ...(options.headers || {}),
    },
  });
  return res;
}

async function getLatestRunId() {
  const res = await ghFetch(
    `/repos/${GH_OWNER}/${GH_REPO}/actions/runs?event=workflow_dispatch&per_page=1`
  );
  if (!res.ok) return null;
  const data = await res.json();
  return data.workflow_runs?.[0]?.id ?? null;
}

async function dispatchWorkflow(landscapeId, jsessionid, landscapeUrl, landscapeName) {
  const prevRunId = await getLatestRunId();

  const res = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/workflows/${WORKFLOW_FILE}/dispatches`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      ref: 'main',
      inputs: { jsessionid, landscape_url: landscapeUrl, landscape_name: landscapeName },
    }),
  });

  if (res.status !== 204) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.message || `GitHub API error ${res.status}`);
  }

  return prevRunId;
}

async function findRunAfter(prevRunId) {
  let lastError = null;
  // 20 attempts × 3s = 60s total
  for (let i = 0; i < 20; i++) {
    await sleep(3000);
    let res;
    try {
      res = await ghFetch(
        `/repos/${GH_OWNER}/${GH_REPO}/actions/runs?event=workflow_dispatch&per_page=5`
      );
    } catch (e) {
      lastError = e.message;
      continue;
    }
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      lastError = body.message || `HTTP ${res.status}`;
      continue;
    }
    const data = await res.json();
    const run = (data.workflow_runs || []).find(r => !prevRunId || r.id > prevRunId);
    if (run) return { run, error: null };
  }
  const reason = lastError
    ? `Runs API error: ${lastError}`
    : 'No new run appeared within 60 s — the workflow may not have a runner available.';
  return { run: null, error: reason };
}

async function pollRun(runId) {
  const res = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/runs/${runId}`);
  if (!res.ok) return null;
  return res.json();
}

// ── Rendering ─────────────────────────────────────────────────────────────────

function formatTime(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function renderBadge(state) {
  if (!state) return `<span class="badge badge-idle"><span class="badge-dot"></span>Idle</span>`;
  const { status, conclusion } = state;
  if (status === 'queued' || status === 'in_progress') {
    return `<span class="badge badge-running"><span class="badge-dot"></span>${status === 'queued' ? 'Queued' : 'Running'}</span>`;
  }
  if (conclusion === 'success') return `<span class="badge badge-success"><span class="badge-dot"></span>Passed</span>`;
  if (conclusion === 'failure' || conclusion === 'timed_out') return `<span class="badge badge-failure"><span class="badge-dot"></span>Failed</span>`;
  return `<span class="badge badge-idle"><span class="badge-dot"></span>${conclusion || status || 'Unknown'}</span>`;
}

function renderTable(landscapes) {
  const tbody = document.getElementById('landscapeTableBody');
  tbody.innerHTML = landscapes.map(l => {
    const state = runState[l.id];
    const lastRunAt = state ? formatTime(state.startedAt) : '—';
    return `
    <tr>
      <td>
        <div class="landscape-name">${escHtml(l.name)}</div>
      </td>
      <td>
        <div class="landscape-url" title="${escHtml(l.baseUrl)}">${escHtml(l.baseUrl)}</div>
      </td>
      <td class="last-run-cell">
        ${state?.url
          ? `<a href="${escHtml(state.url)}" target="_blank" rel="noopener" style="color:inherit;text-decoration:none;">${lastRunAt}</a>`
          : lastRunAt}
      </td>
      <td>${renderBadge(state)}</td>
      <td class="td-actions">
        <button class="btn btn-primary btn-sm" data-landscape-id="${escHtml(l.id)}">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>
          Run
        </button>
      </td>
    </tr>`;
  }).join('');
}

function escHtml(str) {
  return String(str).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}

// ── Modal helpers ─────────────────────────────────────────────────────────────

let activeLandscape = null;
let runPollingTimer = null;

function openRunModal(landscape) {
  activeLandscape = landscape;
  document.getElementById('modalLandscapeName').textContent = landscape.name;
  document.getElementById('jsessionidInput').value = '';
  document.getElementById('runBtn').disabled = true;
  document.getElementById('runStatus').style.display = 'none';
  document.getElementById('runModalBackdrop').style.display = 'flex';
}

function closeRunModal() {
  document.getElementById('runModalBackdrop').style.display = 'none';
  activeLandscape = null;
  if (runPollingTimer) clearTimeout(runPollingTimer);
}

function openSettingsModal() {
  document.getElementById('ghToken').value = loadConfig().token || '';
  document.getElementById('settingsModalBackdrop').style.display = 'flex';
}

function closeSettingsModal() {
  document.getElementById('settingsModalBackdrop').style.display = 'none';
}

function setRunStatus(title, desc, link) {
  const el = document.getElementById('runStatus');
  el.style.display = 'flex';
  document.getElementById('runStatusTitle').textContent = title;
  document.getElementById('runStatusDesc').textContent = desc || '';
  const spinner = document.getElementById('runSpinner');
  const linkEl = document.getElementById('runStatusLink');
  if (link) {
    linkEl.href = link;
    linkEl.style.display = 'inline-flex';
  } else {
    linkEl.style.display = 'none';
  }
  spinner.style.display = title.includes('…') || title.includes('Running') ? 'block' : 'none';
}

// ── Run flow ──────────────────────────────────────────────────────────────────

async function startRun(jsessionid) {
  const l = activeLandscape;
  const prevRunId = await dispatchWorkflow(l.id, jsessionid, l.baseUrl, l.name);

  setRunStatus('Finding run…', 'Waiting for GitHub to register the workflow run.');
  document.getElementById('runBtn').disabled = true;

  const { run, error } = await findRunAfter(prevRunId);
  if (!run) {
    const actionsUrl = `https://${GH_HOST}/${GH_OWNER}/${GH_REPO}/actions`;
    setRunStatus('Could not find run', error, actionsUrl);
    return;
  }

  const runUrl = run.html_url;
  runState[l.id] = { status: run.status, conclusion: run.conclusion, url: runUrl, startedAt: run.created_at };
  renderTable(window._landscapes);

  setRunStatus('Running…', `Run #${run.run_number} queued.`, runUrl);
  pollUntilDone(l.id, run.id, runUrl);
}

function pollUntilDone(landscapeId, runId, runUrl) {
  runPollingTimer = setTimeout(async () => {
    const run = await pollRun(runId);
    if (!run) return;

    runState[landscapeId] = { status: run.status, conclusion: run.conclusion, url: runUrl, startedAt: run.created_at };
    renderTable(window._landscapes);

    if (run.status !== 'completed') {
      setRunStatus('Running…', `Run #${run.run_number} in progress.`, runUrl);
      pollUntilDone(landscapeId, runId, runUrl);
    } else {
      const ok = run.conclusion === 'success';
      setRunStatus(ok ? 'Tests passed ✓' : 'Tests failed ✗', `Finished at ${formatTime(run.updated_at)}`, runUrl);
    }
  }, 8000);
}

// ── Init ──────────────────────────────────────────────────────────────────────

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function init() {
  // Set up bookmarklet
  document.getElementById('bookmarkletLink').href = buildBookmarkletHref();

  // Load landscapes
  let landscapes = [];
  try {
    const res = await fetch('landscapes.json');
    landscapes = await res.json();
  } catch {
    document.getElementById('landscapeTableBody').innerHTML =
      '<tr><td colspan="5" class="loading-cell" style="color:#f85149">Failed to load landscapes.json</td></tr>';
    return;
  }
  window._landscapes = landscapes;

  renderTable(landscapes);

  // Config banner
  if (!isConfigured()) {
    document.getElementById('configBanner').style.display = 'flex';
  }

  // ── Event listeners ──

  // RUN buttons (delegated)
  document.getElementById('landscapeTableBody').addEventListener('click', e => {
    const btn = e.target.closest('[data-landscape-id]');
    if (!btn) return;
    if (!isConfigured()) { openSettingsModal(); return; }
    const l = landscapes.find(x => x.id === btn.dataset.landscapeId);
    if (l) openRunModal(l);
  });

  // Open SAP login
  document.getElementById('openLoginBtn').addEventListener('click', () => {
    if (activeLandscape) window.open(activeLandscape.loginUrl, '_blank', 'noopener');
  });

  // JSESSIONID input — enable Run button when non-empty
  document.getElementById('jsessionidInput').addEventListener('input', e => {
    document.getElementById('runBtn').disabled = e.target.value.trim().length === 0;
  });

  // Paste button
  document.getElementById('pasteBtn').addEventListener('click', async () => {
    try {
      const text = await navigator.clipboard.readText();
      document.getElementById('jsessionidInput').value = text;
      document.getElementById('runBtn').disabled = text.trim().length === 0;
    } catch {
      document.getElementById('jsessionidInput').focus();
    }
  });

  // Run button
  document.getElementById('runBtn').addEventListener('click', async () => {
    const jsessionid = document.getElementById('jsessionidInput').value.trim();
    if (!jsessionid) return;
    document.getElementById('runBtn').disabled = true;
    setRunStatus('Dispatching…', 'Triggering GitHub Actions workflow.');
    try {
      await startRun(jsessionid);
    } catch (err) {
      setRunStatus('Dispatch failed', err.message);
      document.getElementById('runBtn').disabled = false;
    }
  });

  // Cancel / close run modal
  document.getElementById('cancelBtn').addEventListener('click', closeRunModal);
  document.getElementById('modalClose').addEventListener('click', closeRunModal);
  document.getElementById('runModalBackdrop').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeRunModal();
  });

  // Settings
  document.getElementById('settingsBtn').addEventListener('click', openSettingsModal);
  document.getElementById('configBannerBtn').addEventListener('click', openSettingsModal);
  document.getElementById('settingsClose').addEventListener('click', closeSettingsModal);
  document.getElementById('settingsCancelBtn').addEventListener('click', closeSettingsModal);
  document.getElementById('settingsModalBackdrop').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeSettingsModal();
  });

  document.getElementById('settingsSaveBtn').addEventListener('click', () => {
    const token = document.getElementById('ghToken').value.trim();
    if (!token) return;
    saveConfig({ token });
    document.getElementById('configBanner').style.display = 'none';
    closeSettingsModal();
  });

  // Scroll-to-bookmarklet hint inside modal
  document.getElementById('scrollToBookmarklet').addEventListener('click', () => {
    closeRunModal();
    document.querySelector('.bookmarklet-card').scrollIntoView({ behavior: 'smooth', block: 'center' });
  });
}

document.addEventListener('DOMContentLoaded', init);
