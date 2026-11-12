# SAP E2E Test Dashboard

A browser-based dashboard for triggering and monitoring E2E tests against SAP landscape environments — no local tooling required. Tests run on GitHub Actions; you watch the results in real time from any browser.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Prerequisites](#prerequisites)
3. [First-Time Setup](#first-time-setup)
   - [Step 1 — Fork / clone the repo](#step-1--fork--clone-the-repo)
   - [Step 2 — Create a GitHub Personal Access Token](#step-2--create-a-github-personal-access-token)
   - [Step 3 — Enter your PAT in the dashboard](#step-3--enter-your-pat-in-the-dashboard)
4. [Getting Your JSESSIONID](#getting-your-jsessionid)
   - [Option A — Chrome Extension (recommended)](#option-a--chrome-extension-recommended)
   - [Option B — Browser DevTools (manual)](#option-b--browser-devtools-manual)
5. [Running Tests](#running-tests)
6. [Reading Results](#reading-results)
7. [Adding a New Landscape](#adding-a-new-landscape)
8. [Architecture Overview](#architecture-overview)
9. [Troubleshooting](#troubleshooting)

---

## How It Works

```
You (browser)
    │
    ├─ 1. Authenticate on SAP landscape → get JSESSIONID
    │
    ├─ 2. Click RUN on dashboard → POST to GitHub Actions API
    │
    └─ 3. Workflow runs tests.sh on GitHub-hosted runner
           └─ Results stream back → dashboard shows pass/fail counts + logs
```

The dashboard is a static site (GitHub Pages). Every "run" dispatches a `workflow_dispatch` event to a GitHub Actions workflow that calls `tests.sh` with your JSESSIONID and the landscape URL. No backend required.

---

## Prerequisites

- A modern browser (Chrome, Edge, Arc, or any Chromium-based browser for the extension; Firefox works for manual flow)
- A GitHub account with access to the repository
- SAP credentials for the landscape(s) you want to test

---

## First-Time Setup

### Step 1 — Fork / clone the repo

If you are setting this up for your own team:

1. Fork `TirottaSoftware/scheduler-e2e-dashboard` (or create a new repo from these files)
2. Make sure GitHub Actions is enabled on the repo:
   - Go to **Settings → Actions → General** and set it to **"Allow all actions"**
3. Push the code to your repo and enable GitHub Pages:
   - **Settings → Pages → Source**: `Deploy from a branch` → `main` → `/ (root)`
4. Your dashboard will be live at `https://<your-username>.github.io/<repo-name>/`

> If you are joining an existing team setup, skip to [Step 2](#step-2--create-a-github-personal-access-token).

---

### Step 2 — Create a GitHub Personal Access Token

The dashboard calls the GitHub API on your behalf. It needs a **fine-grained PAT** (Personal Access Token) with permission to trigger and read Actions workflows.

1. Go to **https://github.com/settings/personal-access-tokens/new** (github.com account required)
2. Give it a name, e.g. `e2e-dashboard`
3. Set **Expiration** — 90 days is a reasonable default
4. Under **Repository access**, choose **Only select repositories** and pick your repo
5. Under **Permissions → Repository permissions**, set:
   - **Actions** → `Read and write`
6. Click **Generate token** and **copy it immediately** — you won't see it again

---

### Step 3 — Enter your PAT in the dashboard

1. Open the dashboard: `https://tirottasoftware.github.io/scheduler-e2e-dashboard/`
2. Click the **Settings** button (top right — the gear/sliders icon)
3. Paste your PAT into the **GitHub Token** field
4. Click **Save**

Your token is stored only in your browser's `localStorage` — it is never sent anywhere except directly to `api.github.com`.

---

## Getting Your JSESSIONID

SAP landscapes use an `HttpOnly` session cookie called `JSESSIONID`. Because of the `HttpOnly` flag, normal JavaScript on a page cannot read it — you need one of the two approaches below.

### Option A — Chrome Extension (recommended)

The extension silently captures the JSESSIONID in the background whenever you log into a SAP landscape, and injects it automatically into the dashboard's run modal. **Zero extra steps after installation.**

#### Install

1. In Chrome, go to `chrome://extensions`
2. Enable **Developer mode** (toggle in the top-right corner)
3. Click **Load unpacked**
4. Select the `extension/` folder from this repository

The extension icon appears in your toolbar (pin it for easy access).

#### How it works

- When you navigate to a SAP landscape tab and log in, the extension reads the `JSESSIONID` cookie via the privileged `chrome.cookies` API and stores it locally
- The extension badge shows **✓** to confirm a session was captured
- When you switch to the dashboard tab, the session syncs automatically
- When you open the **Run** modal, the JSESSIONID field is **pre-filled** — just click **Run Tests**

#### Extension popup

Click the extension icon at any time to:
- See all captured sessions with timestamps ("captured 3m ago")
- Copy a JSESSIONID to clipboard
- Clear all stored sessions

#### Adding a new landscape to the extension

When you add a new landscape to `landscapes.json`, also add it to the `LANDSCAPES` array in `extension/background.js`:

```js
const LANDSCAPES = [
  {
    id: 'baip-dev',
    name: 'BAIP-DEV',
    hostPattern: '0210933322.eu12.sapdas-dev.cloud.sap',
  },
  // Add new landscapes here — id must match the id in landscapes.json
  {
    id: 'your-landscape-id',
    name: 'YOUR-LANDSCAPE',
    hostPattern: 'hostname.of.your.sap.landscape',
  },
];
```

Then reload the extension at `chrome://extensions`.

---

### Option B — Browser DevTools (manual)

Use this if you are on Firefox, or prefer not to install the extension.

1. Open the SAP landscape URL in a new tab and log in with your credentials
2. Open DevTools:
   - **Chrome / Edge**: `F12` or `Cmd+Option+I` (Mac) / `Ctrl+Shift+I` (Windows)
   - **Firefox**: `F12` or `Cmd+Option+I` / `Ctrl+Shift+I`
3. Go to the **Application** tab (Chrome/Edge) or **Storage** tab (Firefox)
4. In the left sidebar, expand **Cookies** → click the SAP landscape URL
5. Find the row named **`JSESSIONID`** and copy the **Value** column

   > The value is a long alphanumeric string, e.g. `D3A1F2B7C9E04...`

6. Switch back to the dashboard, click **Run** on the landscape row, and paste the value into the JSESSIONID field

**Note:** JSESSIONID values expire after your SAP session ends (typically on logout or after inactivity). If tests fail with an authentication error, log in again and grab a fresh value.

---

## Running Tests

1. Make sure you have a valid JSESSIONID (see above)
2. Open the dashboard
3. Click **Run** on the landscape row you want to test
4. The run modal opens:
   - If you have the extension installed, the JSESSIONID field is **already filled** — you'll see *"Session captured automatically"* or *"Captured X ago"*
   - If not, paste your JSESSIONID manually and click **Paste** or use `Ctrl+V`
5. Click **Run Tests**
6. The row status changes to **Running** (pulsing yellow dot)
7. Once the workflow completes, the status updates to **Success** or **Failure** with pass/fail counts

---

## Reading Results

### Status badges

| Badge | Meaning |
|---|---|
| **Running** (yellow, pulsing) | Workflow is currently executing |
| **Success** (green) | All test assertions passed |
| **Failure** (red) | One or more assertions failed, or the workflow errored |
| **—** (grey) | No run triggered yet this session |

### Pass / fail counts

Below the badge you'll see a pill like `✓ 12  ✗ 1` — these are parsed directly from the test output (lines matching `PASS:` / `FAIL:`).

### Log sidebar

Click **Logs** on any completed row to open the log sidebar:
- Full raw output from `tests.sh` in a terminal-style view
- Lines are colour-coded: green for passing assertions, red for failures, blue for section headers
- **Copy logs** button copies the full output to clipboard
- **View on GitHub** opens the Actions run page directly

---

## Adding a New Landscape

1. Edit `landscapes.json` and add an entry:

```json
{
  "id": "my-landscape",
  "name": "MY-LANDSCAPE",
  "baseUrl": "https://<host>.sapdas-dev.cloud.sap",
  "loginUrl": "https://<host>.sapdas-dev.cloud.sap"
}
```

- `id` — unique slug, used as a key in storage and in the extension config
- `name` — display name shown in the table and modal
- `baseUrl` — passed to `tests.sh` as `$2`; the script appends `/destinations/DYN_SCHEDULER_SERVICE/api/v1`
- `loginUrl` — the URL the "Open SAP Login" button opens (can be the same as `baseUrl`)

2. If you use the Chrome extension, also add the landscape to `extension/background.js` (see [extension section](#adding-a-new-landscape-to-the-extension)) and reload the extension.

3. Commit and push — the dashboard reloads `landscapes.json` on every page load, so the new row appears immediately after deploy.

---

## Architecture Overview

```
scheduler-e2e-dashboard/
├── index.html            # Single-page app shell + modals
├── app.js                # All UI logic, GitHub API calls, polling
├── styles.css            # Dark theme (GitHub-style)
├── landscapes.json       # Landscape config (edit to add environments)
├── tests.sh              # The actual E2E test script (curl-based)
│
├── .github/
│   └── workflows/
│       └── e2e-tests.yml # workflow_dispatch workflow — runs tests.sh
│
└── extension/            # Chrome extension (optional, recommended)
    ├── manifest.json
    ├── background.js     # Service worker: cookie capture + storage
    ├── content.js        # Injected into dashboard: storage → localStorage
    ├── popup.html/js/css # Extension toolbar popup
    └── icons/            # 16, 48, 128px PNGs
```

### Data flow

```
[User logs into SAP tab]
        │
        ▼
extension/background.js
  chrome.tabs.onUpdated
  → chrome.cookies.get('JSESSIONID')
  → chrome.storage.local  ←──────────────── source of truth for sessions
        │
        ▼
extension/content.js  (runs in dashboard page)
  chrome.storage.onChanged
  → localStorage['e2e_dashboard_sessions']  ◄── app.js reads from here
        │
        ▼
app.js: openRunModal()
  → getCachedSession(landscape.id)
  → pre-fills #jsessionidInput
        │
        ▼
[User clicks Run Tests]
  → POST /repos/.../actions/workflows/e2e-tests.yml/dispatches
  → polls for new run ID
  → streams status + logs
```

### Session storage shape

```js
// localStorage key: 'e2e_dashboard_sessions'
{
  "baip-dev": {
    "jsessionid": "D3A1F2...",
    "savedAt": "2026-11-12T10:00:00.000Z"
  }
}
```

### GitHub API calls made by the dashboard

| Action | Endpoint |
|---|---|
| Trigger run | `POST /repos/{owner}/{repo}/actions/workflows/e2e-tests.yml/dispatches` |
| Find new run | `GET /repos/{owner}/{repo}/actions/runs?event=workflow_dispatch&per_page=5` |
| Poll run status | `GET /repos/{owner}/{repo}/actions/runs/{run_id}` |
| Fetch logs | `GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs` |

All calls use your PAT for auth (`Authorization: Bearer <token>`).

---

## Troubleshooting

### "Bad credentials" when clicking Run

Your PAT is missing, expired, or was created for the wrong GitHub host.

- Open **Settings** in the dashboard and re-enter your token
- Make sure the PAT was created at **github.com** (not a GitHub Enterprise instance)
- Verify the PAT has **Actions: Read and write** permission on this repo

### "Could not find run" after dispatching

The workflow was dispatched but the dashboard couldn't locate the resulting run within 60 seconds.

- Check the Actions tab on GitHub (`github.com/{owner}/{repo}/actions`) — the run may be queued but slow to start
- Make sure GitHub Actions is **enabled** on the repo (Settings → Actions → General)
- If the repo is in an organization, confirm the org hasn't disabled Actions site-wide

### JSESSIONID field not pre-filling (extension installed)

- Check the extension badge — if it shows no `✓`, the session hasn't been captured yet
- Log out and back into the SAP landscape to force a fresh session capture
- Make sure the SAP landscape URL matches the `hostPattern` in `extension/background.js`
- Open `chrome://extensions`, find "SAP E2E Session Capture", and check for errors

### Tests fail with authentication error

Your JSESSIONID has expired. SAP sessions typically expire on logout or after a period of inactivity.

- Log back into the SAP landscape (the extension will re-capture automatically, or copy a fresh value from DevTools)
- Click **Run** again — the modal will show the updated session

### Dashboard shows "Loading landscapes…" indefinitely

The browser can't fetch `landscapes.json`. This usually means:
- You're opening `index.html` directly from the filesystem (`file://` URL) — use a local server or the GitHub Pages URL instead
- The GitHub Pages deploy hasn't completed yet (wait ~60s after pushing)

### PAT scope: what minimum permissions are needed?

For a fine-grained PAT on a **private** repo:
- Repository access: the specific repo
- Permissions → Actions: **Read and write**

For a classic PAT: the `repo` scope is sufficient (it includes Actions access).
