#!/usr/bin/env bash
# Report a deployment to Cursor Rollouts.
# Commands: bootstrap | start | finish
# Reads CHANGE_MONITOR_ENV, CHANGE_MONITOR_SERVICE, DEPLOY_VERSION,
# DEPLOY_SOURCE_URI, DEPLOY_ACTOR, and CURSOR_API_KEY from the environment.
# Always exits 0 so a report cannot fail the deploy.
set -u

trap 'exit 0' EXIT

log() { printf 'change-monitor: %s\n' "$*" >&2; }

COMMAND="${1:-}"
CURSOR_API_KEY="${CURSOR_API_KEY:-}"
CHANGE_MONITOR_ENV="${CHANGE_MONITOR_ENV:-}"
CHANGE_MONITOR_SERVICE="${CHANGE_MONITOR_SERVICE:-}"
DEPLOY_VERSION="${DEPLOY_VERSION:-}"
DEPLOY_SOURCE_URI="${DEPLOY_SOURCE_URI:-}"
DEPLOY_ACTOR="${DEPLOY_ACTOR:-}"
DEPLOY_OUTCOME="${DEPLOY_OUTCOME:-}"
DEPLOY_FAILURE_MESSAGE="${DEPLOY_FAILURE_MESSAGE:-}"
STATE_FILE="${CHANGE_MONITOR_STATE_FILE:-${RUNNER_TEMP:-/tmp}/change-monitor-deployment.name}"

if [[ -z "$CURSOR_API_KEY" ]]; then
  log "CURSOR_API_KEY is unset; skipping"
  exit 0
fi
if [[ -z "$CHANGE_MONITOR_ENV" || -z "$CHANGE_MONITOR_SERVICE" ]]; then
  log "CHANGE_MONITOR_ENV or CHANGE_MONITOR_SERVICE is unset; skipping"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  log "curl and jq are required; skipping"
  exit 0
fi

case "$COMMAND" in
  bootstrap|start|finish) ;;
  *)
    log "unknown command: ${COMMAND:-<empty>}"
    exit 0
    ;;
esac

# POST and leave the status in HTTP_CODE and the body in BODY_FILE.
# AUTH_HEADER is the full Authorization header value.
post() {
  local url="$1" auth="$2" body="$3"
  BODY_FILE="$(mktemp)"
  HTTP_CODE="$(
    curl -sS -o "$BODY_FILE" -w '%{http_code}' \
      --max-time 20 \
      -X POST "$url" \
      -H "Authorization: ${auth}" \
      -H "Content-Type: application/json" \
      -H "Connect-Protocol-Version: 1" \
      --data "$body" 2>/dev/null
  )" || HTTP_CODE="000"
}

exchange_token() {
  local tmp code
  tmp="$(mktemp)"
  code="$(
    curl -sS -o "$tmp" -w '%{http_code}' \
      --max-time 20 \
      -X POST "https://api2.cursor.sh/auth/exchange_user_api_key" \
      -H "Authorization: Bearer ${CURSOR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data '{}' 2>/dev/null
  )" || code="000"
  if [[ "$code" != "200" ]]; then
    log "token exchange failed (HTTP ${code})"
    rm -f "$tmp"
    exit 0
  fi
  TOKEN="$(jq -r '.accessToken // empty' "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  if [[ -z "${TOKEN:-}" ]]; then
    log "token exchange returned no accessToken"
    exit 0
  fi
}

# 200 and 409 (already_exists) are success.
catalog_create() {
  local url="$1" body="$2"
  post "$url" "Bearer ${TOKEN}" "$body"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "409" ]]; then
    rm -f "$BODY_FILE"
    return 0
  fi
  log "catalog call failed (HTTP ${HTTP_CODE}) ${url}"
  rm -f "$BODY_FILE"
  return 1
}

bootstrap() {
  local env_body svc_body
  env_body="$(jq -n --arg id "$CHANGE_MONITOR_ENV" '{environmentId:$id, environment:{displayName:$id}}')"
  svc_body="$(jq -n --arg id "$CHANGE_MONITOR_SERVICE" '{serviceId:$id, service:{displayName:$id}}')"
  catalog_create "https://api.cursor.com/factory.v1.DeploymentsService/CreateEnvironment" "$env_body" || true
  catalog_create "https://api.cursor.com/factory.v1.DeploymentsService/CreateService" "$svc_body" || true
}

require_ship_identity() {
  if [[ -z "$DEPLOY_VERSION" || -z "$DEPLOY_SOURCE_URI" || -z "$DEPLOY_ACTOR" ]]; then
    log "DEPLOY_VERSION, DEPLOY_SOURCE_URI, or DEPLOY_ACTOR is unset; skipping"
    exit 0
  fi
}

list_filter() {
  jq -nr \
    --arg env "environments/${CHANGE_MONITOR_ENV}" \
    --arg ver "$DEPLOY_VERSION" \
    --arg svc "services/${CHANGE_MONITOR_SERVICE}" \
    '"environment = \"" + $env + "\" AND deploy_version = \"" + $ver + "\" AND service = \"" + $svc + "\""'
}

# Writes matching deployments JSON to LIST_FILE. Returns 0 on HTTP 200.
list_deployments() {
  local filter body
  filter="$(list_filter)"
  body="$(jq -n --arg src "$DEPLOY_SOURCE_URI" --arg filter "$filter" \
    '{deploySourceUri:$src, filter:$filter, pageSize:100, readMask:"events"}')"
  post "https://api.cursor.com/factory.v1.DeploymentsService/ListDeployments" "Bearer ${TOKEN}" "$body"
  LIST_FILE="$BODY_FILE"
  if [[ "$HTTP_CODE" != "200" ]]; then
    log "list deployments failed (HTTP ${HTTP_CODE})"
    return 1
  fi
  return 0
}

# Deployment previously opened by this same actor, if any.
deployment_for_actor() {
  jq -r --arg actor "$DEPLOY_ACTOR" '
    [(.deployments // []) | .[] | select(any(.events[]?; .actor == $actor))]
    | .[0].name // empty
  ' "$LIST_FILE" 2>/dev/null || true
}

actor_already_closed() {
  local name="$1"
  jq -r --arg actor "$DEPLOY_ACTOR" --arg name "$name" '
    [(.deployments // []) | .[] | select(.name == $name)]
    | .[0] as $d
    | if $d == null then "no"
      elif any($d.events[]?; .actor == $actor and (has("completed") or has("aborted"))) then "yes"
      else "no"
      end
  ' "$LIST_FILE" 2>/dev/null || echo "no"
}

start_deployment() {
  require_ship_identity
  local name=""
  if list_deployments; then
    name="$(deployment_for_actor)"
    rm -f "$LIST_FILE"
  else
    rm -f "$LIST_FILE"
  fi
  if [[ -n "$name" ]]; then
    printf '%s\n' "$name" > "$STATE_FILE"
    log "reusing ${name}"
    exit 0
  fi
  local body
  body="$(jq -n \
    --arg src "$DEPLOY_SOURCE_URI" \
    --arg env "environments/${CHANGE_MONITOR_ENV}" \
    --arg ver "$DEPLOY_VERSION" \
    --arg svc "services/${CHANGE_MONITOR_SERVICE}" \
    --arg actor "$DEPLOY_ACTOR" \
    '{deployment:{deploySourceUri:$src, environment:$env, deployVersion:$ver, service:$svc}, event:{started:{}, actor:$actor}}')"
  post "https://api.cursor.com/factory.v1.DeploymentsService/CreateDeployment" "Bearer ${TOKEN}" "$body"
  if [[ "$HTTP_CODE" != "200" ]]; then
    log "create deployment failed (HTTP ${HTTP_CODE})"
    rm -f "$BODY_FILE"
    exit 0
  fi
  name="$(jq -r '.deployment.name // .name // empty' "$BODY_FILE" 2>/dev/null || true)"
  rm -f "$BODY_FILE"
  if [[ -z "$name" ]]; then
    log "create deployment returned no name"
    exit 0
  fi
  printf '%s\n' "$name" > "$STATE_FILE"
  log "opened ${name}"
}

finish_deployment() {
  require_ship_identity
  local name="" outcome event
  if [[ -f "$STATE_FILE" ]]; then
    name="$(head -n 1 "$STATE_FILE" || true)"
  fi
  if list_deployments; then
    if [[ -z "$name" ]]; then
      name="$(deployment_for_actor)"
    fi
    if [[ -n "$name" ]] && [[ "$(actor_already_closed "$name")" == "yes" ]]; then
      log "deployment ${name} already closed by this reporter; skipping"
      rm -f "$LIST_FILE"
      exit 0
    fi
    rm -f "$LIST_FILE"
  else
    rm -f "$LIST_FILE"
  fi
  if [[ -z "$name" ]]; then
    log "no deployment name to close; skipping"
    exit 0
  fi
  outcome="$(printf '%s' "$DEPLOY_OUTCOME" | tr '[:upper:]' '[:lower:]')"
  case "$outcome" in
    success|succeeded)
      event="$(jq -n --arg name "$name" --arg actor "$DEPLOY_ACTOR" \
        '{name:$name, event:{completed:{succeeded:{}}, actor:$actor}}')"
      ;;
    failure|failed)
      local msg="${DEPLOY_FAILURE_MESSAGE:-deploy failed}"
      event="$(jq -n --arg name "$name" --arg actor "$DEPLOY_ACTOR" --arg msg "$msg" \
        '{name:$name, event:{completed:{failed:{message:$msg}}, actor:$actor}}')"
      ;;
    cancelled|canceled|skipped|aborted)
      event="$(jq -n --arg name "$name" --arg actor "$DEPLOY_ACTOR" \
        '{name:$name, event:{aborted:{}, actor:$actor}}')"
      ;;
    *)
      log "unrecognized outcome '${DEPLOY_OUTCOME}'; skipping close"
      exit 0
      ;;
  esac
  post "https://api.cursor.com/factory.v1.DeploymentsService/AppendDeploymentEvent" "Bearer ${TOKEN}" "$event"
  if [[ "$HTTP_CODE" != "200" ]]; then
    log "append deployment event failed (HTTP ${HTTP_CODE})"
    rm -f "$BODY_FILE"
    exit 0
  fi
  rm -f "$BODY_FILE"
  log "closed ${name} (${outcome})"
}

exchange_token
case "$COMMAND" in
  bootstrap) bootstrap ;;
  start) start_deployment ;;
  finish) finish_deployment ;;
esac
exit 0
