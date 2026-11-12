const STORAGE_KEY  = 'e2e_dashboard_config';
const SESSIONS_KEY = 'e2e_dashboard_sessions';
const WORKFLOW_FILE = 'e2e-tests.yml';

const GH_HOST  = 'github.com';
const GH_OWNER = 'TirottaSoftware';
const GH_REPO  = 'scheduler-e2e-dashboard';

// ── Config ────────────────────────────────────────────────────────────────────

function loadConfig() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; }
  catch { return {}; }
}
function saveConfig(cfg) { localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg)); }
function isConfigured() { return !!loadConfig().token; }

// ── Session cache (JSESSIONID per landscape) ──────────────────────────────────

function loadSessions() {
  try { return JSON.parse(localStorage.getItem(SESSIONS_KEY)) || {}; }
  catch { return {}; }
}
function saveSession(landscapeId, jsessionid) {
  const s = loadSessions();
  s[landscapeId] = { jsessionid, savedAt: new Date().toISOString() };
  localStorage.setItem(SESSIONS_KEY, JSON.stringify(s));
}
function getCachedSession(landscapeId) {
  return loadSessions()[landscapeId] || null;
}

// ── Bookmarklet ───────────────────────────────────────────────────────────────

function buildBookmarkletHref() {
  const code = String.raw`(function(){
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
      alert('No JSESSIONID cookie found.\nMake sure you are logged into this SAP landscape.');
    }
  })();`.replace(/\s+/g, ' ');
  return 'javascript:' + code; // NOSONAR — bookmarklet intentionally uses javascript: protocol
}

// ── Run state ─────────────────────────────────────────────────────────────────

// { [landscapeId]: { runId, runNumber, status, conclusion, url, startedAt, pass, fail } }
const runState = {};

// ── GitHub API ────────────────────────────────────────────────────────────────

function apiBase() {
  return GH_HOST === 'github.com' ? 'https://api.github.com' : `https://${GH_HOST}/api/v3`;
}

async function ghFetch(path, options = {}) {
  const { token } = loadConfig();
  return fetch(`${apiBase()}${path}`, {
    ...options,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      ...(options.headers),
    },
  });
}

async function getLatestRunId() {
  const res = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/runs?event=workflow_dispatch&per_page=1`);
  if (!res.ok) return null;
  const data = await res.json();
  return data.workflow_runs?.[0]?.id ?? null;
}

async function dispatchWorkflow(jsessionid, landscapeUrl, landscapeName) {
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
  for (let i = 0; i < 20; i++) {
    await sleep(3000);
    let res;
    try {
      res = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/runs?event=workflow_dispatch&per_page=5`);
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
  return {
    run: null,
    error: lastError ? `Runs API error: ${lastError}` : 'No new run appeared within 60 s.',
  };
}

async function pollRun(runId) {
  const res = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/runs/${runId}`);
  if (!res.ok) return null;
  return res.json();
}

// ── Log fetching ──────────────────────────────────────────────────────────────

async function fetchJobLogs(runId) {
  const jobsRes = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/runs/${runId}/jobs`);
  if (!jobsRes.ok) return null;
  const { jobs } = await jobsRes.json();
  if (!jobs?.length) return null;
  const logsRes = await ghFetch(`/repos/${GH_OWNER}/${GH_REPO}/actions/jobs/${jobs[0].id}/logs`);
  if (!logsRes.ok) return null;
  return logsRes.text();
}

function parseLogs(raw) {
  const lines = [];
  let pass = 0, fail = 0;
  const tsRe = /^\d{4}-\d{2}-\d{2}T[\d:.]+Z /;
  const annotRe = /^##\[.*?\]/;
  const ansiRe = /\x1b\[[0-9;]*[mGKH]/g;

  for (const line of raw.split('\n')) {
    const text = line.replace(tsRe, '').replace(annotRe, '').replace(ansiRe, '').trimEnd();
    if (!text) continue;

    let cls = 'log-line';
    if (/^\s+PASS /.test(text))          { cls = 'log-pass';    pass++; }
    else if (/^\s+FAIL /.test(text))     { cls = 'log-fail';    fail++; }
    else if (/^=== .+ ===$/.test(text.trim())) cls = 'log-section';
    else if (text.trim().startsWith('---'))   cls = 'log-summary';

    lines.push({ text, cls });
  }
  return { lines, pass, fail };
}

// ── Log sidebar ───────────────────────────────────────────────────────────────

let logSidebarRunId  = null;
let logSidebarRunUrl = null;

function openLogSidebar(landscapeId, runId, runUrl) {
  logSidebarRunId  = runId;
  logSidebarRunUrl = runUrl;

  const l = (window._landscapes || []).find(x => x.id === landscapeId);
  const state = runState[landscapeId];

  document.getElementById('logSidebarTitle').textContent = 'Run Logs';
  document.getElementById('logSidebarSub').textContent = l?.name ?? '';
  document.getElementById('logToolbar').style.display = 'none';

  const ghLink = document.getElementById('logSidebarGhLink');
  if (runUrl) { ghLink.href = runUrl; ghLink.style.display = 'inline-flex'; }
  else { ghLink.style.display = 'none'; }

  const terminal = document.getElementById('logTerminal');
  terminal.innerHTML = '';
  const loading = document.createElement('div');
  loading.className = 'log-loading';
  loading.id = 'logLoading';
  loading.innerHTML = '<div class="spinner"></div><span>Loading logs…</span>';
  terminal.appendChild(loading);

  document.getElementById('logSidebar').classList.add('open');
  document.getElementById('logOverlay').classList.add('open');

  // If logs already cached on state, render immediately
  if (state?.logLines) {
    renderLogLines(state.logLines, state.pass, state.fail);
    return;
  }

  if (!runId) {
    terminal.innerHTML = '<div class="log-empty">No run ID available.</div>';
    return;
  }

  fetchJobLogs(runId).then(raw => {
    if (!raw) {
      terminal.innerHTML = `<div class="log-empty">Could not load logs. <a href="${escHtml(runUrl)}" target="_blank" rel="noopener">View on GitHub →</a></div>`;
      return;
    }
    const { lines, pass, fail } = parseLogs(raw);
    if (runState[landscapeId]) {
      runState[landscapeId].logLines = lines;
      runState[landscapeId].pass = pass;
      runState[landscapeId].fail = fail;
      renderTable(window._landscapes);
    }
    renderLogLines(lines, pass, fail);
  }).catch(() => {
    terminal.innerHTML = `<div class="log-empty">Failed to fetch logs. <a href="${escHtml(runUrl)}" target="_blank" rel="noopener">View on GitHub →</a></div>`;
  });
}

function renderLogLines(lines, pass, fail) {
  const terminal = document.getElementById('logTerminal');
  terminal.innerHTML = lines.map(({ text, cls }) =>
    `<div class="${cls}">${escHtml(text)}</div>`
  ).join('');

  // Toolbar
  const toolbar = document.getElementById('logToolbar');
  toolbar.style.display = 'flex';
  document.getElementById('logStatPass').textContent = `${pass} passed`;
  document.getElementById('logStatFail').textContent = fail ? `${fail} failed` : '';
  document.getElementById('logStatFail').style.display = fail ? 'inline' : 'none';

  const jumpBtn = document.getElementById('jumpToErrorBtn');
  if (fail) {
    jumpBtn.style.display = 'inline-flex';
    jumpBtn.onclick = () => {
      const firstFail = terminal.querySelector('.log-fail');
      firstFail?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    };
  } else {
    jumpBtn.style.display = 'none';
  }

  terminal.scrollTop = terminal.scrollHeight;
}

function closeLogSidebar() {
  document.getElementById('logSidebar').classList.remove('open');
  document.getElementById('logOverlay').classList.remove('open');
}

// ── Rendering ─────────────────────────────────────────────────────────────────

function relativeTime(iso) {
  if (!iso) return '—';
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1)  return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24)  return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

function renderBadge(state) {
  if (!state) return `<span class="badge badge-idle"><span class="badge-dot"></span>Idle</span>`;
  const { status, conclusion } = state;
  if (status === 'queued')      return `<span class="badge badge-queued"><span class="badge-dot"></span>Queued</span>`;
  if (status === 'in_progress') return `<span class="badge badge-running"><span class="badge-dot"></span>Running</span>`;
  if (conclusion === 'success') return `<span class="badge badge-success"><span class="badge-dot"></span>Passed</span>`;
  if (conclusion === 'failure' || conclusion === 'timed_out') return `<span class="badge badge-failure"><span class="badge-dot"></span>Failed</span>`;
  return `<span class="badge badge-idle"><span class="badge-dot"></span>${conclusion || status}</span>`;
}

function rowState(state) {
  if (!state) return '';
  if (state.status === 'queued' || state.status === 'in_progress') return 'running';
  if (state.conclusion === 'success') return 'success';
  if (state.conclusion === 'failure' || state.conclusion === 'timed_out') return 'failure';
  return '';
}

function renderTable(landscapes) {
  const tbody = document.getElementById('landscapeTableBody');
  tbody.innerHTML = landscapes.map(l => {
    const state = runState[l.id];
    const rs    = rowState(state);
    const hasRun = !!(state?.runId);
    const failSpan = state?.fail ? `<span class="pf-fail">✗ ${state.fail}</span>` : '';
    const pfHtml = (state?.pass != null)
      ? `<div class="pf-pill"><span class="pf-pass">✓ ${state.pass}</span>${failSpan}</div>`
      : '';

    return `
    <tr data-state="${rs}">
      <td>
        <div class="env-name">${escHtml(l.name)}</div>
        <div class="env-url" title="${escHtml(l.baseUrl)}">${escHtml(l.baseUrl)}</div>
      </td>
      <td>${renderBadge(state)}</td>
      <td class="last-run-cell">
        <div>${state?.url ? `<a href="${escHtml(state.url)}" target="_blank" rel="noopener" class="run-link">${relativeTime(state.startedAt)}</a>` : relativeTime(state?.startedAt)}</div>
        ${pfHtml}
      </td>
      <td class="td-actions">
        ${hasRun ? `<button class="btn btn-ghost btn-sm" data-logs-id="${escHtml(l.id)}">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
          Logs
        </button>` : ''}
        <button class="btn btn-primary btn-sm" data-landscape-id="${escHtml(l.id)}">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>
          Run
        </button>
      </td>
    </tr>`;
  }).join('');
}

function escHtml(str) {
  return String(str).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// ── Modal helpers ─────────────────────────────────────────────────────────────

let activeLandscape  = null;
let runPollingTimer  = null;
let activeRunId      = null;
let activeRunUrl     = null;

function openRunModal(landscape) {
  activeLandscape = landscape;
  activeRunId     = null;
  activeRunUrl    = null;

  document.getElementById('modalLandscapeName').textContent = landscape.name;
  document.getElementById('runStatus').style.display = 'none';
  document.getElementById('stepsSection').style.display = 'block';
  document.getElementById('runBtn').disabled = true;
  document.getElementById('openLogsBtn').style.display = 'none';
  document.getElementById('runStatusLink').style.display = 'none';

  // Pre-fill from cached session
  const cached = getCachedSession(landscape.id);
  const input  = document.getElementById('jsessionidInput');
  const hint   = document.getElementById('cachedHint');
  if (cached) {
    input.value = cached.jsessionid;
    hint.textContent = `Using session from ${relativeTime(cached.savedAt)} — re-login if it expired.`;
    hint.style.display = 'block';
    document.getElementById('runBtn').disabled = false;
  } else {
    input.value = '';
    hint.style.display = 'none';
  }

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

function setRunStatus({ title, desc, link, showSpinner, showLogs }) {
  document.getElementById('runStatus').style.display = 'flex';
  document.getElementById('runStatusTitle').textContent = title;
  document.getElementById('runStatusDesc').textContent  = desc || '';
  document.getElementById('runSpinner').style.display   = showSpinner ? 'block' : 'none';

  const linkEl = document.getElementById('runStatusLink');
  if (link) { linkEl.href = link; linkEl.style.display = 'inline-flex'; }
  else       { linkEl.style.display = 'none'; }

  const logsBtn = document.getElementById('openLogsBtn');
  logsBtn.style.display = showLogs ? 'inline-flex' : 'none';
}

// ── Run flow ──────────────────────────────────────────────────────────────────

async function startRun(jsessionid) {
  const l = activeLandscape;

  saveSession(l.id, jsessionid);

  const prevRunId = await dispatchWorkflow(jsessionid, l.baseUrl, l.name);

  setRunStatus({ title: 'Finding run…', desc: 'Waiting for GitHub to register the workflow run.', showSpinner: true });
  document.getElementById('runBtn').disabled = true;

  const { run, error } = await findRunAfter(prevRunId);
  if (!run) {
    setRunStatus({ title: 'Could not find run', desc: error, link: `https://${GH_HOST}/${GH_OWNER}/${GH_REPO}/actions` });
    return;
  }

  activeRunId  = run.id;
  activeRunUrl = run.html_url;
  runState[l.id] = { runId: run.id, runNumber: run.run_number, status: run.status, conclusion: run.conclusion, url: run.html_url, startedAt: run.created_at };
  renderTable(window._landscapes);

  setRunStatus({ title: 'Running…', desc: `Run #${run.run_number} in progress.`, link: run.html_url, showSpinner: true });
  pollUntilDone(l.id, run.id, run.html_url, run.run_number);
}

function pollUntilDone(landscapeId, runId, runUrl, runNumber) {
  runPollingTimer = setTimeout(async () => {
    const run = await pollRun(runId);
    if (!run) { pollUntilDone(landscapeId, runId, runUrl, runNumber); return; }

    runState[landscapeId] = { ...runState[landscapeId], status: run.status, conclusion: run.conclusion };
    renderTable(window._landscapes);

    if (run.status !== 'completed') {
      setRunStatus({ title: 'Running…', desc: `Run #${runNumber} in progress.`, link: runUrl, showSpinner: true });
      pollUntilDone(landscapeId, runId, runUrl, runNumber);
      return;
    }

    const ok = run.conclusion === 'success';
    setRunStatus({
      title: ok ? 'Tests passed ✓' : 'Tests failed ✗',
      desc:  `Run #${runNumber} · finished ${relativeTime(run.updated_at)}`,
      link:  runUrl,
      showLogs: true,
    });

    // Fetch logs to populate pass/fail counts in table
    fetchJobLogs(runId).then(raw => {
      if (!raw) return;
      const { lines, pass, fail } = parseLogs(raw);
      runState[landscapeId] = { ...runState[landscapeId], logLines: lines, pass, fail };
      renderTable(window._landscapes);
    }).catch(() => {});

  }, 8000);
}

// ── Init ──────────────────────────────────────────────────────────────────────

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function init() {
  const bookmarkletEl = document.getElementById('bookmarkletInlineLink');
  if (bookmarkletEl) bookmarkletEl.href = buildBookmarkletHref();

  let landscapes = [];
  try {
    landscapes = await fetch('landscapes.json').then(r => r.json());
  } catch {
    document.getElementById('landscapeTableBody').innerHTML =
      '<tr><td colspan="4" class="loading-cell" style="color:var(--red)">Failed to load landscapes.json</td></tr>';
    return;
  }
  window._landscapes = landscapes;
  renderTable(landscapes);

  if (!isConfigured()) document.getElementById('configBanner').style.display = 'flex';

  // ── Table delegation ──

  document.getElementById('landscapeTableBody').addEventListener('click', e => {
    // Run button
    const runBtn = e.target.closest('[data-landscape-id]');
    if (runBtn) {
      if (!isConfigured()) { openSettingsModal(); return; }
      const l = landscapes.find(x => x.id === runBtn.dataset.landscapeId);
      if (l) openRunModal(l);
      return;
    }
    // Logs button
    const logsBtn = e.target.closest('[data-logs-id]');
    if (logsBtn) {
      const id    = logsBtn.dataset.logsId;
      const state = runState[id];
      if (state?.runId) openLogSidebar(id, state.runId, state.url);
    }
  });

  // ── Run modal ──

  document.getElementById('openLoginBtn').addEventListener('click', () => {
    if (activeLandscape) window.open(activeLandscape.loginUrl, '_blank', 'noopener');
  });

  document.getElementById('jsessionidInput').addEventListener('input', e => {
    document.getElementById('runBtn').disabled = !e.target.value.trim();
    if (e.target.value.trim()) document.getElementById('cachedHint').style.display = 'none';
  });

  document.getElementById('pasteBtn').addEventListener('click', async () => {
    try {
      const text = await navigator.clipboard.readText();
      document.getElementById('jsessionidInput').value = text;
      document.getElementById('runBtn').disabled = !text.trim();
      document.getElementById('cachedHint').style.display = 'none';
    } catch { document.getElementById('jsessionidInput').focus(); }
  });

  document.getElementById('runBtn').addEventListener('click', async () => {
    const jsessionid = document.getElementById('jsessionidInput').value.trim();
    if (!jsessionid) return;
    document.getElementById('runBtn').disabled = true;
    document.getElementById('stepsSection').style.display = 'none';
    setRunStatus({ title: 'Dispatching…', desc: 'Triggering GitHub Actions workflow.', showSpinner: true });
    try {
      await startRun(jsessionid);
    } catch (err) {
      setRunStatus({ title: 'Dispatch failed', desc: err.message });
      document.getElementById('runBtn').disabled = false;
      document.getElementById('stepsSection').style.display = 'block';
    }
  });

  document.getElementById('openLogsBtn').addEventListener('click', () => {
    if (activeRunId && activeLandscape) openLogSidebar(activeLandscape.id, activeRunId, activeRunUrl);
  });

  document.getElementById('cancelBtn').addEventListener('click', closeRunModal);
  document.getElementById('modalClose').addEventListener('click', closeRunModal);
  document.getElementById('runModalBackdrop').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeRunModal();
  });

  document.getElementById('scrollToBookmarklet')?.addEventListener('click', () => {
    closeRunModal();
  });

  // ── Settings ──

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

  // ── Log sidebar ──

  document.getElementById('logSidebarClose').addEventListener('click', closeLogSidebar);
  document.getElementById('logOverlay').addEventListener('click', closeLogSidebar);

  // ── Escape key ──

  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (document.getElementById('logSidebar').classList.contains('open')) { closeLogSidebar(); return; }
    if (document.getElementById('runModalBackdrop').style.display !== 'none') { closeRunModal(); return; }
    if (document.getElementById('settingsModalBackdrop').style.display !== 'none') { closeSettingsModal(); }
  });
}

document.addEventListener('DOMContentLoaded', init);
