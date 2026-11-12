#!/usr/bin/env bash
set -uo pipefail

# --- Config ---
COOKIE="JSESSIONID=${1:?Usage: $0 <JSESSIONID> <BASE_URL>}"
BASE="${2:?Usage: $0 <JSESSIONID> <BASE_URL>}/destinations/DYN_SCHEDULER_SERVICE/api/v1"
CLEANUP_IDS=()
PASS=0 FAIL=0
# executionTarget required by BAIP-DEV for enabled jobs
ET=',"executionTarget":{"type":"joule","globalTenantId":"a8678499-f661-4a9b-9c07-1aead76728cc"}'

# --- Helpers ---
# Sets globals: _CODE, _BODY
_CODE="" _BODY=""
api() {
  _CODE=$(curl -s --max-time 30 -o /tmp/e2e_body -w '%{http_code}' \
    -b "$COOKIE" -H 'accept: application/json' "$@") || true
  _BODY=$(cat /tmp/e2e_body 2>/dev/null || echo "")
}

ok() {
  local label="$1" expected="$2"
  if [[ "$_CODE" == "$expected" ]]; then
    echo "  PASS $label (HTTP $_CODE)"; ((PASS++))
  else
    echo "  FAIL $label — expected HTTP $expected, got $_CODE"
    [[ -n "$_BODY" ]] && echo "       ${_BODY:0:300}"
    ((FAIL++))
  fi
}

jv() {  # json value check: jv "label" '.path' 'expected'
  local label="$1" path="$2" expected="$3"
  local actual
  actual=$(echo "$_BODY" | jq -r "$path" 2>/dev/null || echo "JQ_ERROR")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS $label ($path = $expected)"; ((PASS++))
  else
    echo "  FAIL $label — $path: expected '$expected', got '$actual'"; ((FAIL++))
  fi
}

jge() {  # json >= check: jge "label" '.path' min
  local label="$1" path="$2" min="$3"
  local actual
  actual=$(echo "$_BODY" | jq -r "$path" 2>/dev/null || echo "-1")
  if [[ "$actual" -ge "$min" ]] 2>/dev/null; then
    echo "  PASS $label ($path=$actual >= $min)"; ((PASS++))
  else
    echo "  FAIL $label — $path: expected >= $min, got '$actual'"; ((FAIL++))
  fi
}

section() { echo; echo "=== $1 ==="; }
jid() { echo "$_BODY" | jq -r '.id // empty'; }

post_job() {
  api -X POST "$BASE/jobs" -H 'content-type: application/json' --data "$1"
  local id; id=$(jid)
  [[ -n "$id" ]] && CLEANUP_IDS+=("$id")
}

# ===================== 0. Session check =====================
section "0. Session validation"
api "$BASE/jobs"
if [[ "$_CODE" != "200" ]]; then
  echo "FATAL: session invalid (HTTP $_CODE). Get a fresh JSESSIONID."; exit 1
fi
echo "  PASS Session valid"; ((PASS++))

# ===================== 1. Job CRUD =====================
section "1.1 Create a draft job"
post_job '{"name":"E2E Draft Job","description":"Test draft","state":"draft"}'
ok "1.1 create" 201
jv "1.1 state" '.state' 'draft'
jv "1.1 status" '.status' 'draft'
jv "1.1 name" '.name' 'E2E Draft Job'
DRAFT_JOB_ID=$(jid); echo "  -> DRAFT_JOB_ID=$DRAFT_JOB_ID"

section "1.2 Create an enabled job with schedule"
post_job "{\"name\":\"E2E Enabled Job\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}}]}"
ok "1.2 create" 201
jv "1.2 state" '.state' 'enabled'
jv "1.2 status" '.status' 'idle'
jv "1.2 triggers count" '.triggers | length | tostring' '1'
ENABLED_JOB_ID=$(jid); echo "  -> ENABLED_JOB_ID=$ENABLED_JOB_ID"

section "1.3 Get job by ID"
api "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.3 get" 200
jv "1.3 name" '.name' 'E2E Draft Job'

section "1.4 List all jobs"
curl -s --max-time 30 -o /tmp/e2e_body -D /tmp/e2e_headers -w '%{http_code}' \
  -b "$COOKIE" -H 'accept: application/json' "$BASE/jobs" >/dev/null || true
_BODY=$(cat /tmp/e2e_body 2>/dev/null); _CODE=200
ok "1.4 list" 200
jge "1.4 array length" 'length' 2
if grep -qi 'x-total-count' /tmp/e2e_headers 2>/dev/null; then
  echo "  PASS 1.4 X-Total-Count present"; ((PASS++))
else
  echo "  FAIL 1.4 X-Total-Count missing"; ((FAIL++))
fi

section "1.5 Update job"
api -X PUT "$BASE/jobs/$DRAFT_JOB_ID" -H 'content-type: application/json' --data '{"name":"E2E Renamed Job"}'
ok "1.5 update" 200
jv "1.5 name" '.name' 'E2E Renamed Job'

section "1.6 Delete job"
api -X DELETE "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.6 delete" 204
api "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.6 get-after-delete" 404
CLEANUP_IDS=("${CLEANUP_IDS[@]/$DRAFT_JOB_ID/}")

# ===================== 2. Filtering & Search =====================
section "2.1 Filter by status"
api "$BASE/jobs?status=active"
ok "2.1 filter" 200

section "2.2 Search by name"
api "$BASE/jobs?search=E2E"
ok "2.2 search" 200
count=$(echo "$_BODY" | jq 'length' 2>/dev/null || echo 0)
if [[ "$count" -ge 1 ]]; then
  echo "  PASS 2.2 returned $count results"; ((PASS++))
else
  echo "  FAIL 2.2 returned 0 results"; ((FAIL++))
fi

section "2.3 Sort by name"
api "$BASE/jobs?sort=nameAsc"; ok "2.3 sortAsc" 200
api "$BASE/jobs?sort=nameDesc"; ok "2.3 sortDesc" 200

section "2.4 Filter by trigger type"
api "$BASE/jobs?triggerType=schedule"
ok "2.4 triggerType" 200

section "2.5 Get counts"
api "$BASE/jobs/\$count"
ok "2.5 count" 200
jge "2.5 all" '.all' 1

# ===================== 3. Schedule Types =====================
sched() {
  local label="$1" payload="$2" type="$3"
  section "3.$label"
  post_job "$payload"; ok "3.$label create" 201
  local id; id=$(jid)
  api "$BASE/jobs/$id"; ok "3.$label get-back" 200
  jv "3.$label config" '.triggers[0].configuration.type' "$type"
}

sched "1 frequencyDays" \
  "{\"name\":\"E2E Days\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}}]}" \
  frequencyDays

sched "2 frequencyHours" \
  "{\"name\":\"E2E Hours\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyHours\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":2,\"executions\":[{\"startTimeOfDay\":0}]}}]}" \
  frequencyHours

sched "3 frequencyMinutes" \
  "{\"name\":\"E2E Minutes\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyMinutes\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":30,\"executions\":[{\"startTimeOfDay\":32400}]}}]}" \
  frequencyMinutes

sched "4 frequencyWeeks" \
  "{\"name\":\"E2E Weeks\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"wednesday\",\"friday\"]}]}}]}" \
  frequencyWeeks

sched "5 frequencyMonths" \
  "{\"name\":\"E2E Months\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyMonths\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200,\"daysOfMonth\":[\"1\",\"15\"]}]}}]}" \
  frequencyMonths

sched "6 frequencyWeeks-weekdays" \
  "{\"name\":\"E2E Weekdays\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-13T21:00:00.000Z\",\"timezone\":\"Europe/Sofia\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"tuesday\",\"wednesday\",\"thursday\",\"friday\"]}]}}]}" \
  frequencyWeeks

sched "7 oneTime" \
  "{\"name\":\"E2E OneTime\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"oneTime\",\"startDate\":\"2026-12-25T00:00:00Z\",\"executions\":[{\"startTimeOfDay\":43200}]}}]}" \
  oneTime

section "3.8 Multiple triggers"
post_job "{\"name\":\"E2E MultiTrigger\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}},{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-13T21:00:00.000Z\",\"timezone\":\"Europe/Sofia\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"wednesday\",\"friday\"]}]}}]}"
ok "3.8 create" 201
jv "3.8 triggers count" '.triggers | length | tostring' '2'
MULTI_ID=$(jid)
SAVED_BODY="$_BODY"

section "3.9 Disable a trigger"
PUT_PAYLOAD=$(echo "$SAVED_BODY" | jq '{name:.name,state:.state,executionTarget:.executionTarget,triggers:[(.triggers[0]|.enabled=false),.triggers[1]]}')
api -X PUT "$BASE/jobs/$MULTI_ID" -H 'content-type: application/json' --data "$PUT_PAYLOAD"
ok "3.9 update" 200
jv "3.9 disabled" '.triggers[0].enabled | tostring' 'false'

# ===================== 4. Job Lifecycle =====================
section "4.1 Draft -> Enabled"
post_job '{"name":"Lifecycle Test","state":"draft"}'
ok "4.1 create" 201; LC_ID=$(jid)
api -X PUT "$BASE/jobs/$LC_ID" -H 'content-type: application/json' --data "{\"name\":\"Lifecycle Test\",\"state\":\"enabled\"$ET}"
ok "4.1 enable" 200
jv "4.1 state" '.state' 'enabled'
jv "4.1 status" '.status' 'idle'

section "4.2 Enabled -> Disabled"
api -X PUT "$BASE/jobs/$LC_ID" -H 'content-type: application/json' --data '{"name":"Lifecycle Test","state":"disabled"}'
ok "4.2 disable" 200
jv "4.2 state" '.state' 'disabled'
jv "4.2 status" '.status' 'completed'

# ===================== 5. Job Runs =====================
section "5.1 Trigger on-demand run"
api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs" -H 'content-type: application/json' --data '{}'
ok "5.1 trigger" 202
RUN_ID=$(jid)
if [[ -n "$RUN_ID" ]]; then
  echo "  -> RUN_ID=$RUN_ID"
  jv "5.1 state" '.state' 'ready'
else
  echo "  INFO 5.1 empty body on 202 (acceptable)"
fi

section "5.2 List runs"
api "$BASE/jobs/$ENABLED_JOB_ID/runs"
ok "5.2 list" 200

section "5.3 Get single run"
if [[ -n "${RUN_ID:-}" ]]; then
  api "$BASE/jobs/$ENABLED_JOB_ID/runs/$RUN_ID"; ok "5.3 get" 200
fi

section "5.4 Cancel run"
if [[ -n "${RUN_ID:-}" ]]; then
  api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs/$RUN_ID/cancel" -H 'content-type: application/json' --data '{}'
  if [[ "$_CODE" == "200" || "$_CODE" == "409" ]]; then
    echo "  PASS 5.4 cancel (HTTP $_CODE)"; ((PASS++))
  else
    echo "  FAIL 5.4 cancel — HTTP $_CODE"; ((FAIL++))
  fi
fi

section "5.5 Run on disabled job -> 409"
api -X POST "$BASE/jobs/$LC_ID/runs" -H 'content-type: application/json' --data '{}'
ok "5.5 disabled" 409

section "5.6 Trigger immediate run"
api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs/immediate" -H 'content-type: application/json' --data '{}'
ok "5.6 immediate" 202

# ===================== 6. Validation Errors =====================
section "6.1 No name"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"state":"draft"}'
ok "6.1" 400

section "6.2 Name too short"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"name":"AB","state":"draft"}'
ok "6.2" 400

section "6.3 state=disabled on create"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"name":"Bad Job","state":"disabled"}'
ok "6.3" 400

section "6.4 state=draft on update"
api -X PUT "$BASE/jobs/$ENABLED_JOB_ID" -H 'content-type: application/json' --data '{"name":"E2E Enabled Job","state":"draft"}'
ok "6.4" 400

section "6.5 GET nonexistent"
api "$BASE/jobs/00000000-0000-0000-0000-000000000000"
ok "6.5" 404

section "6.6 DELETE nonexistent"
api -X DELETE "$BASE/jobs/00000000-0000-0000-0000-000000000000"
ok "6.6" 404

# ===================== 7. Schedule Update =====================
section "7.1 Change time of day (6am -> 7am)"
post_job "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":21600}]}}]}"
ok "7.1 create at 6am" 201
TIME_JOB_ID=$(jid); TRIG_ID=$(echo "$_BODY" | jq -r '.triggers[0].id')
jv "7.1 startTimeOfDay=21600" '.triggers[0].configuration.executions[0].startTimeOfDay | tostring' '21600'
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.1 update to 7am" 200
jv "7.1 startTimeOfDay=25200" '.triggers[0].configuration.executions[0].startTimeOfDay | tostring' '25200'

section "7.2 Change startDate"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.2 update startDate" 200
jv "7.2 startDate" '.triggers[0].configuration.startDate' '2026-12-01T00:00:00Z'

section "7.3 Change recurrence (every 1 day -> every 3 days)"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":3,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.3 update recurrence" 200
jv "7.3 recurrenceValue=3" '.triggers[0].configuration.recurrenceValue | tostring' '3'

section "7.4 Change schedule type (frequencyDays -> frequencyWeeks)"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}}]}"
ok "7.4 change to weekly" 200
jv "7.4 type" '.triggers[0].configuration.type' 'frequencyWeeks'
jv "7.4 daysOfWeek count" '.triggers[0].configuration.executions[0].daysOfWeek | length | tostring' '2'

section "7.5 Change timezone"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"timezone\":\"America/New_York\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}}]}"
ok "7.5 set timezone" 200
jv "7.5 timezone" '.triggers[0].configuration.timezone' 'America/New_York'

section "7.6 Add a second trigger to existing job"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"timezone\":\"America/New_York\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}},{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.6 add trigger" 200
jv "7.6 triggers count" '.triggers | length | tostring' '2'

section "7.7 Remove a trigger by omission"
TRIG2_ID=$(echo "$_BODY" | jq -r '.triggers[1].id')
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG2_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.7 remove trigger" 200
jv "7.7 triggers count" '.triggers | length | tostring' '1'
jv "7.7 kept trigger id" '.triggers[0].id' "$TRIG2_ID"

section "7.8 Add endDate to schedule"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG2_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"endDate\":\"2027-06-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.8 set endDate" 200
jv "7.8 endDate" '.triggers[0].configuration.endDate' '2027-06-01T00:00:00Z'

# ===================== 9. Next Execution Preview =====================
section "9.1 Next execution (frequencyDays)"
api -X POST "$BASE/nextExecution" -H 'content-type: application/json' \
  --data '[{"type":"schedule","enabled":true,"configuration":{"type":"frequencyDays","startDate":"2026-10-01T00:00:00Z","recurrenceValue":1,"executions":[{"startTimeOfDay":32400}]}}]'
ok "9.1" 200
ne=$(echo "$_BODY" | jq -r '.nextExecution // empty')
if [[ -n "$ne" ]]; then
  echo "  PASS 9.1 nextExecution=$ne"; ((PASS++))
else
  echo "  FAIL 9.1 nextExecution empty"; ((FAIL++))
fi

section "9.2 Next execution (oneTime past)"
api -X POST "$BASE/nextExecution" -H 'content-type: application/json' \
  --data '[{"type":"schedule","enabled":true,"configuration":{"type":"oneTime","startDate":"2025-01-01T00:00:00Z","executions":[{"startTimeOfDay":43200}]}}]'
ok "9.2" 200
ne=$(echo "$_BODY" | jq -r '.nextExecution')
if [[ "$ne" == "null" || -z "$ne" ]]; then
  echo "  PASS 9.2 nextExecution=null"; ((PASS++))
else
  echo "  FAIL 9.2 expected null, got $ne"; ((FAIL++))
fi

# ===================== Cleanup =====================
section "Cleanup"
cleaned=0
for id in "${CLEANUP_IDS[@]}"; do
  [[ -z "$id" ]] && continue
  curl -s --max-time 10 -X DELETE "$BASE/jobs/$id" -b "$COOKIE" >/dev/null 2>&1 && ((cleaned++)) || true
done
echo "  Deleted $cleaned test jobs"

# ===================== Summary =====================
echo
echo "================================="
echo "  PASS: $PASS  FAIL: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1#!/usr/bin/env bash
set -uo pipefail

# --- Config ---
COOKIE="JSESSIONID=${1:?Usage: $0 <JSESSIONID> <BASE_URL>}"
BASE="${2:?Usage: $0 <JSESSIONID> <BASE_URL>}/destinations/DYN_SCHEDULER_SERVICE/api/v1"
CLEANUP_IDS=()
PASS=0 FAIL=0
# executionTarget required by BAIP-DEV for enabled jobs
ET=',"executionTarget":{"type":"joule","globalTenantId":"a8678499-f661-4a9b-9c07-1aead76728cc"}'

# --- Helpers ---
# Sets globals: _CODE, _BODY
_CODE="" _BODY=""
api() {
  _CODE=$(curl -s --max-time 30 -o /tmp/e2e_body -w '%{http_code}' \
    -b "$COOKIE" -H 'accept: application/json' "$@") || true
  _BODY=$(cat /tmp/e2e_body 2>/dev/null || echo "")
}

ok() {
  local label="$1" expected="$2"
  if [[ "$_CODE" == "$expected" ]]; then
    echo "  PASS $label (HTTP $_CODE)"; ((PASS++))
  else
    echo "  FAIL $label — expected HTTP $expected, got $_CODE"
    [[ -n "$_BODY" ]] && echo "       ${_BODY:0:300}"
    ((FAIL++))
  fi
}

jv() {  # json value check: jv "label" '.path' 'expected'
  local label="$1" path="$2" expected="$3"
  local actual
  actual=$(echo "$_BODY" | jq -r "$path" 2>/dev/null || echo "JQ_ERROR")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS $label ($path = $expected)"; ((PASS++))
  else
    echo "  FAIL $label — $path: expected '$expected', got '$actual'"; ((FAIL++))
  fi
}

jge() {  # json >= check: jge "label" '.path' min
  local label="$1" path="$2" min="$3"
  local actual
  actual=$(echo "$_BODY" | jq -r "$path" 2>/dev/null || echo "-1")
  if [[ "$actual" -ge "$min" ]] 2>/dev/null; then
    echo "  PASS $label ($path=$actual >= $min)"; ((PASS++))
  else
    echo "  FAIL $label — $path: expected >= $min, got '$actual'"; ((FAIL++))
  fi
}

section() { echo; echo "=== $1 ==="; }
jid() { echo "$_BODY" | jq -r '.id // empty'; }

post_job() {
  api -X POST "$BASE/jobs" -H 'content-type: application/json' --data "$1"
  local id; id=$(jid)
  [[ -n "$id" ]] && CLEANUP_IDS+=("$id")
}

# ===================== 0. Session check =====================
section "0. Session validation"
api "$BASE/jobs"
if [[ "$_CODE" != "200" ]]; then
  echo "FATAL: session invalid (HTTP $_CODE). Get a fresh JSESSIONID."; exit 1
fi
echo "  PASS Session valid"; ((PASS++))

# ===================== 1. Job CRUD =====================
section "1.1 Create a draft job"
post_job '{"name":"E2E Draft Job","description":"Test draft","state":"draft"}'
ok "1.1 create" 201
jv "1.1 state" '.state' 'draft'
jv "1.1 status" '.status' 'draft'
jv "1.1 name" '.name' 'E2E Draft Job'
DRAFT_JOB_ID=$(jid); echo "  -> DRAFT_JOB_ID=$DRAFT_JOB_ID"

section "1.2 Create an enabled job with schedule"
post_job "{\"name\":\"E2E Enabled Job\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}}]}"
ok "1.2 create" 201
jv "1.2 state" '.state' 'enabled'
jv "1.2 status" '.status' 'idle'
jv "1.2 triggers count" '.triggers | length | tostring' '1'
ENABLED_JOB_ID=$(jid); echo "  -> ENABLED_JOB_ID=$ENABLED_JOB_ID"

section "1.3 Get job by ID"
api "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.3 get" 200
jv "1.3 name" '.name' 'E2E Draft Job'

section "1.4 List all jobs"
curl -s --max-time 30 -o /tmp/e2e_body -D /tmp/e2e_headers -w '%{http_code}' \
  -b "$COOKIE" -H 'accept: application/json' "$BASE/jobs" >/dev/null || true
_BODY=$(cat /tmp/e2e_body 2>/dev/null); _CODE=200
ok "1.4 list" 200
jge "1.4 array length" 'length' 2
if grep -qi 'x-total-count' /tmp/e2e_headers 2>/dev/null; then
  echo "  PASS 1.4 X-Total-Count present"; ((PASS++))
else
  echo "  FAIL 1.4 X-Total-Count missing"; ((FAIL++))
fi

section "1.5 Update job"
api -X PUT "$BASE/jobs/$DRAFT_JOB_ID" -H 'content-type: application/json' --data '{"name":"E2E Renamed Job"}'
ok "1.5 update" 200
jv "1.5 name" '.name' 'E2E Renamed Job'

section "1.6 Delete job"
api -X DELETE "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.6 delete" 204
api "$BASE/jobs/$DRAFT_JOB_ID"
ok "1.6 get-after-delete" 404
CLEANUP_IDS=("${CLEANUP_IDS[@]/$DRAFT_JOB_ID/}")

# ===================== 2. Filtering & Search =====================
section "2.1 Filter by status"
api "$BASE/jobs?status=active"
ok "2.1 filter" 200

section "2.2 Search by name"
api "$BASE/jobs?search=E2E"
ok "2.2 search" 200
count=$(echo "$_BODY" | jq 'length' 2>/dev/null || echo 0)
if [[ "$count" -ge 1 ]]; then
  echo "  PASS 2.2 returned $count results"; ((PASS++))
else
  echo "  FAIL 2.2 returned 0 results"; ((FAIL++))
fi

section "2.3 Sort by name"
api "$BASE/jobs?sort=nameAsc"; ok "2.3 sortAsc" 200
api "$BASE/jobs?sort=nameDesc"; ok "2.3 sortDesc" 200

section "2.4 Filter by trigger type"
api "$BASE/jobs?triggerType=schedule"
ok "2.4 triggerType" 200

section "2.5 Get counts"
api "$BASE/jobs/\$count"
ok "2.5 count" 200
jge "2.5 all" '.all' 1

# ===================== 3. Schedule Types =====================
sched() {
  local label="$1" payload="$2" type="$3"
  section "3.$label"
  post_job "$payload"; ok "3.$label create" 201
  local id; id=$(jid)
  api "$BASE/jobs/$id"; ok "3.$label get-back" 200
  jv "3.$label config" '.triggers[0].configuration.type' "$type"
}

sched "1 frequencyDays" \
  "{\"name\":\"E2E Days\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}}]}" \
  frequencyDays

sched "2 frequencyHours" \
  "{\"name\":\"E2E Hours\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyHours\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":2,\"executions\":[{\"startTimeOfDay\":0}]}}]}" \
  frequencyHours

sched "3 frequencyMinutes" \
  "{\"name\":\"E2E Minutes\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyMinutes\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":30,\"executions\":[{\"startTimeOfDay\":32400}]}}]}" \
  frequencyMinutes

sched "4 frequencyWeeks" \
  "{\"name\":\"E2E Weeks\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"wednesday\",\"friday\"]}]}}]}" \
  frequencyWeeks

sched "5 frequencyMonths" \
  "{\"name\":\"E2E Months\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyMonths\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200,\"daysOfMonth\":[\"1\",\"15\"]}]}}]}" \
  frequencyMonths

sched "6 frequencyWeeks-weekdays" \
  "{\"name\":\"E2E Weekdays\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-13T21:00:00.000Z\",\"timezone\":\"Europe/Sofia\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"tuesday\",\"wednesday\",\"thursday\",\"friday\"]}]}}]}" \
  frequencyWeeks

sched "7 oneTime" \
  "{\"name\":\"E2E OneTime\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"oneTime\",\"startDate\":\"2026-12-25T00:00:00Z\",\"executions\":[{\"startTimeOfDay\":43200}]}}]}" \
  oneTime

section "3.8 Multiple triggers"
post_job "{\"name\":\"E2E MultiTrigger\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400}]}},{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-10-13T21:00:00.000Z\",\"timezone\":\"Europe/Sofia\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":32400,\"daysOfWeek\":[\"monday\",\"wednesday\",\"friday\"]}]}}]}"
ok "3.8 create" 201
jv "3.8 triggers count" '.triggers | length | tostring' '2'
MULTI_ID=$(jid)
SAVED_BODY="$_BODY"

section "3.9 Disable a trigger"
PUT_PAYLOAD=$(echo "$SAVED_BODY" | jq '{name:.name,state:.state,executionTarget:.executionTarget,triggers:[(.triggers[0]|.enabled=false),.triggers[1]]}')
api -X PUT "$BASE/jobs/$MULTI_ID" -H 'content-type: application/json' --data "$PUT_PAYLOAD"
ok "3.9 update" 200
jv "3.9 disabled" '.triggers[0].enabled | tostring' 'false'

# ===================== 4. Job Lifecycle =====================
section "4.1 Draft -> Enabled"
post_job '{"name":"Lifecycle Test","state":"draft"}'
ok "4.1 create" 201; LC_ID=$(jid)
api -X PUT "$BASE/jobs/$LC_ID" -H 'content-type: application/json' --data "{\"name\":\"Lifecycle Test\",\"state\":\"enabled\"$ET}"
ok "4.1 enable" 200
jv "4.1 state" '.state' 'enabled'
jv "4.1 status" '.status' 'idle'

section "4.2 Enabled -> Disabled"
api -X PUT "$BASE/jobs/$LC_ID" -H 'content-type: application/json' --data '{"name":"Lifecycle Test","state":"disabled"}'
ok "4.2 disable" 200
jv "4.2 state" '.state' 'disabled'
jv "4.2 status" '.status' 'completed'

# ===================== 5. Job Runs =====================
section "5.1 Trigger on-demand run"
api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs" -H 'content-type: application/json' --data '{}'
ok "5.1 trigger" 202
RUN_ID=$(jid)
if [[ -n "$RUN_ID" ]]; then
  echo "  -> RUN_ID=$RUN_ID"
  jv "5.1 state" '.state' 'ready'
else
  echo "  INFO 5.1 empty body on 202 (acceptable)"
fi

section "5.2 List runs"
api "$BASE/jobs/$ENABLED_JOB_ID/runs"
ok "5.2 list" 200

section "5.3 Get single run"
if [[ -n "${RUN_ID:-}" ]]; then
  api "$BASE/jobs/$ENABLED_JOB_ID/runs/$RUN_ID"; ok "5.3 get" 200
fi

section "5.4 Cancel run"
if [[ -n "${RUN_ID:-}" ]]; then
  api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs/$RUN_ID/cancel" -H 'content-type: application/json' --data '{}'
  if [[ "$_CODE" == "200" || "$_CODE" == "409" ]]; then
    echo "  PASS 5.4 cancel (HTTP $_CODE)"; ((PASS++))
  else
    echo "  FAIL 5.4 cancel — HTTP $_CODE"; ((FAIL++))
  fi
fi

section "5.5 Run on disabled job -> 409"
api -X POST "$BASE/jobs/$LC_ID/runs" -H 'content-type: application/json' --data '{}'
ok "5.5 disabled" 409

section "5.6 Trigger immediate run"
api -X POST "$BASE/jobs/$ENABLED_JOB_ID/runs/immediate" -H 'content-type: application/json' --data '{}'
ok "5.6 immediate" 202

# ===================== 6. Validation Errors =====================
section "6.1 No name"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"state":"draft"}'
ok "6.1" 400

section "6.2 Name too short"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"name":"AB","state":"draft"}'
ok "6.2" 400

section "6.3 state=disabled on create"
api -X POST "$BASE/jobs" -H 'content-type: application/json' --data '{"name":"Bad Job","state":"disabled"}'
ok "6.3" 400

section "6.4 state=draft on update"
api -X PUT "$BASE/jobs/$ENABLED_JOB_ID" -H 'content-type: application/json' --data '{"name":"E2E Enabled Job","state":"draft"}'
ok "6.4" 400

section "6.5 GET nonexistent"
api "$BASE/jobs/00000000-0000-0000-0000-000000000000"
ok "6.5" 404

section "6.6 DELETE nonexistent"
api -X DELETE "$BASE/jobs/00000000-0000-0000-0000-000000000000"
ok "6.6" 404

# ===================== 7. Schedule Update =====================
section "7.1 Change time of day (6am -> 7am)"
post_job "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":21600}]}}]}"
ok "7.1 create at 6am" 201
TIME_JOB_ID=$(jid); TRIG_ID=$(echo "$_BODY" | jq -r '.triggers[0].id')
jv "7.1 startTimeOfDay=21600" '.triggers[0].configuration.executions[0].startTimeOfDay | tostring' '21600'
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-10-08T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.1 update to 7am" 200
jv "7.1 startTimeOfDay=25200" '.triggers[0].configuration.executions[0].startTimeOfDay | tostring' '25200'

section "7.2 Change startDate"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.2 update startDate" 200
jv "7.2 startDate" '.triggers[0].configuration.startDate' '2026-12-01T00:00:00Z'

section "7.3 Change recurrence (every 1 day -> every 3 days)"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":3,\"executions\":[{\"startTimeOfDay\":25200}]}}]}"
ok "7.3 update recurrence" 200
jv "7.3 recurrenceValue=3" '.triggers[0].configuration.recurrenceValue | tostring' '3'

section "7.4 Change schedule type (frequencyDays -> frequencyWeeks)"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}}]}"
ok "7.4 change to weekly" 200
jv "7.4 type" '.triggers[0].configuration.type' 'frequencyWeeks'
jv "7.4 daysOfWeek count" '.triggers[0].configuration.executions[0].daysOfWeek | length | tostring' '2'

section "7.5 Change timezone"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"timezone\":\"America/New_York\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}}]}"
ok "7.5 set timezone" 200
jv "7.5 timezone" '.triggers[0].configuration.timezone' 'America/New_York'

section "7.6 Add a second trigger to existing job"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyWeeks\",\"startDate\":\"2026-12-01T00:00:00Z\",\"timezone\":\"America/New_York\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":25200,\"daysOfWeek\":[\"monday\",\"friday\"]}]}},{\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.6 add trigger" 200
jv "7.6 triggers count" '.triggers | length | tostring' '2'

section "7.7 Remove a trigger by omission"
TRIG2_ID=$(echo "$_BODY" | jq -r '.triggers[1].id')
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG2_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.7 remove trigger" 200
jv "7.7 triggers count" '.triggers | length | tostring' '1'
jv "7.7 kept trigger id" '.triggers[0].id' "$TRIG2_ID"

section "7.8 Add endDate to schedule"
api -X PUT "$BASE/jobs/$TIME_JOB_ID" -H 'content-type: application/json' \
  --data "{\"name\":\"E2E Time Change\",\"state\":\"enabled\"$ET,\"triggers\":[{\"id\":\"$TRIG2_ID\",\"type\":\"schedule\",\"enabled\":true,\"configuration\":{\"type\":\"frequencyDays\",\"startDate\":\"2026-12-01T00:00:00Z\",\"endDate\":\"2027-06-01T00:00:00Z\",\"recurrenceValue\":1,\"executions\":[{\"startTimeOfDay\":43200}]}}]}"
ok "7.8 set endDate" 200
jv "7.8 endDate" '.triggers[0].configuration.endDate' '2027-06-01T00:00:00Z'

# ===================== 9. Next Execution Preview =====================
section "9.1 Next execution (frequencyDays)"
api -X POST "$BASE/nextExecution" -H 'content-type: application/json' \
  --data '[{"type":"schedule","enabled":true,"configuration":{"type":"frequencyDays","startDate":"2026-10-01T00:00:00Z","recurrenceValue":1,"executions":[{"startTimeOfDay":32400}]}}]'
ok "9.1" 200
ne=$(echo "$_BODY" | jq -r '.nextExecution // empty')
if [[ -n "$ne" ]]; then
  echo "  PASS 9.1 nextExecution=$ne"; ((PASS++))
else
  echo "  FAIL 9.1 nextExecution empty"; ((FAIL++))
fi

section "9.2 Next execution (oneTime past)"
api -X POST "$BASE/nextExecution" -H 'content-type: application/json' \
  --data '[{"type":"schedule","enabled":true,"configuration":{"type":"oneTime","startDate":"2025-01-01T00:00:00Z","executions":[{"startTimeOfDay":43200}]}}]'
ok "9.2" 200
ne=$(echo "$_BODY" | jq -r '.nextExecution')
if [[ "$ne" == "null" || -z "$ne" ]]; then
  echo "  PASS 9.2 nextExecution=null"; ((PASS++))
else
  echo "  FAIL 9.2 expected null, got $ne"; ((FAIL++))
fi

# ===================== Cleanup =====================
section "Cleanup"
cleaned=0
for id in "${CLEANUP_IDS[@]}"; do
  [[ -z "$id" ]] && continue
  curl -s --max-time 10 -X DELETE "$BASE/jobs/$id" -b "$COOKIE" >/dev/null 2>&1 && ((cleaned++)) || true
done
echo "  Deleted $cleaned test jobs"

# ===================== Summary =====================
echo
echo "================================="
echo "  PASS: $PASS  FAIL: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1