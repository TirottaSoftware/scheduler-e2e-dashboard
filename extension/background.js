const STORAGE_KEY = 'e2e_sessions';

const LANDSCAPES = [
  {
    id: 'baip-dev',
    name: 'BAIP-DEV',
    hostPattern: '0210933322.eu12.sapdas-dev.cloud.sap',
  },
];

function matchLandscape(url) {
  try {
    const host = new URL(url).hostname;
    return LANDSCAPES.find(l => host.includes(l.hostPattern)) || null;
  } catch {
    return null;
  }
}

async function captureSession(tabId, url) {
  const landscape = matchLandscape(url);
  if (!landscape) return;

  const cookie = await chrome.cookies.get({ url, name: 'JSESSIONID' });
  if (!cookie?.value) return;

  const stored = (await chrome.storage.local.get(STORAGE_KEY))[STORAGE_KEY] || {};
  const entry = { jsessionid: cookie.value, savedAt: new Date().toISOString(), landscapeName: landscape.name };

  // Only update (and notify) if the value changed
  if (stored[landscape.id]?.jsessionid === cookie.value) return;

  stored[landscape.id] = entry;
  await chrome.storage.local.set({ [STORAGE_KEY]: stored });

  chrome.action.setBadgeText({ text: '✓' });
  chrome.action.setBadgeBackgroundColor({ color: '#3fb950' });

  // Notify any open dashboard tabs
  const tabs = await chrome.tabs.query({ url: 'https://tirottasoftware.github.io/scheduler-e2e-dashboard/*' });
  for (const tab of tabs) {
    chrome.tabs.sendMessage(tab.id, {
      type: 'SESSION_CAPTURED',
      landscapeId: landscape.id,
      landscapeName: landscape.name,
      jsessionid: cookie.value,
      savedAt: entry.savedAt,
    }).catch(() => {}); // tab may not have content script ready yet
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && tab.url) {
    captureSession(tabId, tab.url);
  }
});
