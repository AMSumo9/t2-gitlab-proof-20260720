#!/usr/bin/env bash
set -euo pipefail

[ -f .wheel-meta.json ] || { echo "missing .wheel-meta.json"; exit 1; }
[ -f .deploy-host ] || { echo "missing .deploy-host"; exit 1; }

repo_full="${T2_REPO_FULL:?T2_REPO_FULL missing}"
repo_name="${T2_REPO_NAME:?T2_REPO_NAME missing}"
host="$(tr -d '[:space:]' < .deploy-host)"
wheel_id="$(jq -r '.wheel_id' .wheel-meta.json)"
structure="$(jq -r '.structure // "umbrella"' .wheel-meta.json)"
slug="$(jq -r '.slug' .wheel-meta.json)"
project="$(jq -r '.project // .slug' .wheel-meta.json)"
parent="$(jq -r '.parent_t1_ref' .wheel-meta.json)"
money="$(jq -r '.money_target // ""' .wheel-meta.json)"
kw="$(jq -r '.primary_kw // ""' .wheel-meta.json)"
node_role="$(jq -r '.node_role // "feeder"' .wheel-meta.json)"
intended_url="$(jq -r '.intended_url' .wheel-meta.json)"
jq -c '.links // []' .wheel-meta.json > /tmp/t2-links.json

require_env() {
  local missing=0
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "::error::missing $name"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

resolved_url=""

case "$host" in
  netlify)
    require_env NETLIFY_AUTH_TOKEN
    sid="$(netlify api listSites | grep -B5 "\"name\": \"$project\"" | grep -oE '"site_id": "[0-9a-f-]+"' | head -1 | grep -oE '[0-9a-f-]{36}' || true)"
    if [ -z "$sid" ]; then
      netlify sites:create --name "$project" --account-slug sites-au
      sid="$(netlify api listSites | grep -B5 "\"name\": \"$project\"" | grep -oE '"site_id": "[0-9a-f-]+"' | head -1 | grep -oE '[0-9a-f-]{36}')"
    fi
    [ -n "$sid" ] || { echo "::error::could not resolve Netlify site id for '$project'"; exit 1; }
    netlify deploy --prod --dir=. --site="$sid"
    ;;

  vercel)
    require_env VERCEL_TOKEN
    dep_url="$(vercel deploy --prod --yes --token="$VERCEL_TOKEN" --scope=site-au --name="$project" | tail -1 | tr -d '\r')"
    [ -n "$dep_url" ] || { echo "::error::vercel deploy produced no URL"; exit 1; }
    vercel alias set "$dep_url" "$project.vercel.app" --token="$VERCEL_TOKEN" --scope=site-au
    team_id="$(curl -fsS -H "Authorization: Bearer $VERCEL_TOKEN" https://api.vercel.com/v2/teams | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((t["id"] for t in d.get("teams",[]) if t.get("slug")=="site-au"),""))')"
    [ -n "$team_id" ] || { echo "::error::could not resolve Vercel team site-au"; exit 1; }
    patch_code="$(curl -sS -o /tmp/vercel-project-patch.json -w '%{http_code}' -X PATCH \
      -H "Authorization: Bearer $VERCEL_TOKEN" -H 'Content-Type: application/json' \
      --data '{"ssoProtection":null}' \
      "https://api.vercel.com/v9/projects/$project?teamId=$team_id")"
    [ "$patch_code" = "200" ] || { echo "::error::failed to disable Vercel SSO protection for $project: HTTP $patch_code"; exit 1; }
    ;;

  cloudflare)
    require_env CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
    npx wrangler pages project create "$project" --production-branch=main || true
    npx wrangler pages deploy . --project-name="$project" --branch=main --commit-dirty=true
    ;;

  surge)
    require_env SURGE_LOGIN SURGE_TOKEN
    cp index.html 200.html 2>/dev/null || true
    surge . "$project.surge.sh"
    ;;

  s3)
    require_env AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    PROJECT="$project" python3 - <<'PYEOF'
import glob, os, time, boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError

project = os.environ["PROJECT"]
region = os.environ["AWS_DEFAULT_REGION"]
cfg = Config(signature_version="s3v4", retries={"max_attempts": 2, "mode": "standard"},
             s3={"addressing_style": "path"}, connect_timeout=8, read_timeout=15)
s3 = boto3.client("s3", region_name=region, config=cfg)

def with_retry(fn, *args, attempts=2, delay=3, **kwargs):
    last_err = None
    for i in range(attempts):
        try:
            return fn(*args, **kwargs)
        except EndpointConnectionError as e:
            last_err = e
            print(f"  retry {i+1}/{attempts} after connection error: {e}")
            time.sleep(delay)
    raise last_err

try:
    with_retry(s3.head_bucket, Bucket=project)
except ClientError:
    with_retry(s3.create_bucket, Bucket=project, CreateBucketConfiguration={"LocationConstraint": region})

with_retry(s3.put_public_access_block, Bucket=project, PublicAccessBlockConfiguration={
    "BlockPublicAcls": False, "IgnorePublicAcls": False,
    "BlockPublicPolicy": False, "RestrictPublicBuckets": False,
})
with_retry(s3.put_bucket_policy, Bucket=project, Policy=(
    '{"Version":"2012-10-17","Statement":[{"Sid":"PublicRead","Effect":"Allow",'
    '"Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s/*"}]}' % project
))
with_retry(s3.put_bucket_website, Bucket=project, WebsiteConfiguration={
    "IndexDocument": {"Suffix": "index.html"},
    "ErrorDocument": {"Key": "index.html"},
})

html_files = sorted(glob.glob("*.html"))
if not html_files:
    raise RuntimeError("no html files found for S3 deploy")
for f in html_files:
    with_retry(s3.upload_file, f, project, f, ExtraArgs={"ContentType": "text/html"})
if "index.html" not in html_files:
    # T2 path-host URLs point at /index.html. Keep the keyword HTML too, but
    # publish an index alias so the evidence gate and upstream links are live.
    with_retry(s3.upload_file, html_files[0], project, "index.html", ExtraArgs={"ContentType": "text/html"})
for pattern in ("*.jpg", "*.jpeg", "*.png", "*.webp", "*.txt", "*.xml"):
    for f in glob.glob(pattern):
        if not f.startswith("."):
            with_retry(s3.upload_file, f, project, f)
website_url = f"http://{project}.s3-website-{region}.amazonaws.com/index.html"
print(f"S3 deploy complete: bucket={project}")
print(f"S3_WEBSITE_URL={website_url}")
PYEOF
    resolved_url="$(PROJECT="$project" AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" python3 - <<'PYEOF'
import os
project = os.environ["PROJECT"]
region = os.environ["AWS_DEFAULT_REGION"]
print(f"http://{project}.s3-website-{region}.amazonaws.com/index.html")
PYEOF
)"
    ;;

  render)
    require_env RENDER_API_KEY
    repo_url="https://github.com/$repo_full"
    svcid="$(curl -s -m 25 -H "Authorization: Bearer $RENDER_API_KEY" \
      "https://api.render.com/v1/services?name=$project&type=static_site&limit=1" \
      | jq -r '.[0].service.id // empty')"
    deploy_id=""
    if [ -z "$svcid" ]; then
      owner_id="${RENDER_OWNER_ID:-}"
      if [ -z "$owner_id" ]; then
        owner_id="$(curl -s -m 25 -H "Authorization: Bearer $RENDER_API_KEY" \
          "https://api.render.com/v1/services?limit=1" \
          | jq -r '.[0].service.ownerId // .[0].service.owner.id // .[0].ownerId // .[0].owner.id // empty')"
      fi
      [ -n "$owner_id" ] || { echo "::error::Render ownerId unavailable; set RENDER_OWNER_ID secret"; exit 1; }
      resp="$(jq -n --arg name "$project" --arg ownerId "$owner_id" --arg repo "$repo_url" \
        '{type:"static_site",name:$name,ownerId:$ownerId,repo:$repo,branch:"main",autoDeploy:"yes",serviceDetails:{buildCommand:"",publishPath:"."}}' \
        | curl -s -m 40 -X POST -H "Authorization: Bearer $RENDER_API_KEY" \
          -H "Content-Type: application/json" "https://api.render.com/v1/services" --data @-)"
      svcid="$(echo "$resp" | jq -r '(.service.id // .id) // empty')"
      [ -n "$svcid" ] || { echo "::error::Render create failed: $(echo "$resp" | head -c 300)"; exit 1; }
      deploy_id="$(echo "$resp" | jq -r '(.deploy.id // .service.deploy.id // .service.latestDeploy.id) // empty')"
    else
      deploy_resp="$(curl -s -m 25 -X POST -H "Authorization: Bearer $RENDER_API_KEY" \
        "https://api.render.com/v1/services/$svcid/deploys" -d '{}')"
      deploy_id="$(echo "$deploy_resp" | jq -r '(.deploy.id // .id) // empty')"
    fi
    if [ -z "$deploy_id" ]; then
      deploy_id="$(curl -s -m 25 -H "Authorization: Bearer $RENDER_API_KEY" \
        "https://api.render.com/v1/services/$svcid/deploys?limit=1" \
        | jq -r '.[0].deploy.id // .[0].id // empty')"
    fi
    [ -n "$deploy_id" ] || { echo "::error::Render deploy id unavailable for service $svcid"; exit 1; }

    deploy_status=""
    for _ in $(seq 1 40); do
      deploy_status="$(curl -s -m 25 -H "Authorization: Bearer $RENDER_API_KEY" \
        "https://api.render.com/v1/services/$svcid/deploys/$deploy_id" \
        | jq -r '(.deploy.status // .status) // empty')"
      case "$deploy_status" in
        live) break ;;
        build_failed|update_failed|canceled|deactivated)
          echo "::error::Render deploy $deploy_id failed for $project with status $deploy_status"
          exit 1
          ;;
      esac
      sleep 15
    done
    [ "$deploy_status" = "live" ] || {
      echo "::error::Render deploy $deploy_id not live for $project after wait; status=${deploy_status:-unknown}"
      exit 1
    }

    for _ in $(seq 1 24); do
      service_json="$(curl -s -m 25 -H "Authorization: Bearer $RENDER_API_KEY" \
        "https://api.render.com/v1/services/$svcid" \
        )"
      resolved_url="$(echo "$service_json" | jq -r '.service.serviceDetails.url // .service.url // .serviceDetails.url // .url // empty')"
      service_slug="$(echo "$service_json" | jq -r '.service.slug // .slug // empty')"
      [ -n "$resolved_url" ] && break
      sleep 5
    done
    if [ -z "$resolved_url" ]; then
      if [ -z "${service_slug:-}" ]; then
        service_slug="$project"
      fi
      candidate="https://${service_slug}.onrender.com/"
      if curl -fsS -L --max-time 45 -o /dev/null "$candidate"; then
        resolved_url="$candidate"
      fi
    fi
    [ -n "$resolved_url" ] || { echo "::error::Render service URL unavailable for $project after deploy $deploy_id reached live"; exit 1; }
    resolved_url="${resolved_url%/}/"
    ;;

  digitalocean)
    require_env DIGITAL_OCEAN_API_KEY
    repo_url="https://github.com/$repo_full.git"
    appname="$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-30 | sed -E 's/^-+//; s/-+$//')"
    case "$appname" in
      ""|[0-9]*) appname="t2-$appname" ;;
    esac
    appname="$(printf '%s' "$appname" | cut -c1-30 | sed -E 's/^-+//; s/-+$//')"
    appid="$(curl -s -m 25 -H "Authorization: Bearer $DIGITAL_OCEAN_API_KEY" \
      "https://api.digitalocean.com/v2/apps?per_page=200" \
      | jq -r --arg n "$appname" '.apps[] | select(.spec.name==$n) | .id' | head -1)"
    spec_tmp="$(mktemp)"
    jq -n --arg name "$appname" --arg repo "$repo_url" \
      '{spec:{name:$name,static_sites:[{name:"site",git:{repo_clone_url:$repo,branch:"main"},source_dir:"/",output_dir:"/"}]}}' \
      > "$spec_tmp"
    if [ -z "$appid" ]; then
      resp="$(curl -s -m 40 -X POST -H "Authorization: Bearer $DIGITAL_OCEAN_API_KEY" \
        -H "Content-Type: application/json" "https://api.digitalocean.com/v2/apps" --data @"$spec_tmp")"
      appid="$(echo "$resp" | jq -r '.app.id // empty')"
      [ -n "$appid" ] || { echo "::error::DO app create failed: $(echo "$resp" | head -c 300)"; rm -f "$spec_tmp"; exit 1; }
    else
      curl -s -m 40 -X PUT -H "Authorization: Bearer $DIGITAL_OCEAN_API_KEY" \
        -H "Content-Type: application/json" "https://api.digitalocean.com/v2/apps/$appid" --data @"$spec_tmp" >/dev/null 2>&1 || true
    fi
    rm -f "$spec_tmp"
    for _ in $(seq 1 12); do
      sleep 15
      resolved_url="$(curl -s -m 25 -H "Authorization: Bearer $DIGITAL_OCEAN_API_KEY" \
        "https://api.digitalocean.com/v2/apps/$appid" | jq -r '.app.live_url // .app.default_ingress // empty')"
      [ -n "$resolved_url" ] && break
    done
    [ -n "$resolved_url" ] || { echo "::error::DO app never reported live_url"; exit 1; }
    resolved_url="${resolved_url%/}/"
    ;;

  gitlab)
    require_env GITLAB_PAT
    source_dir="$PWD"
    namespace="sites_26"
    namespace_id="137785918"
    api="https://gitlab.com/api/v4"
    encoded_path="$(jq -rn --arg v "$namespace/$project" '$v|@uri')"
    project_json="$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_PAT" "$api/projects/$encoded_path" || true)"
    project_id="$(printf '%s' "$project_json" | jq -r '.id // empty')"
    if [ -z "$project_id" ]; then
      project_json="$(curl -sf -X POST -H "PRIVATE-TOKEN: $GITLAB_PAT" \
        --data-urlencode "name=$project" --data-urlencode "path=$project" \
        --data-urlencode "namespace_id=$namespace_id" --data-urlencode "visibility=public" \
        "$api/projects")"
      project_id="$(printf '%s' "$project_json" | jq -r '.id // empty')"
    fi
    [ -n "$project_id" ] || { echo "::error::GitLab project create/lookup failed"; exit 1; }
    curl -sf -X PUT -H "PRIVATE-TOKEN: $GITLAB_PAT" -H "Content-Type: application/json" \
      --data '{"visibility":"public"}' "$api/projects/$project_id" >/dev/null

    stage_root="$(mktemp -d)"
    remote="https://oauth2:${GITLAB_PAT}@gitlab.com/${namespace}/${project}.git"
    if git clone -q "$remote" "$stage_root/repo" 2>/dev/null; then
      stage="$stage_root/repo"
      find "$stage" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    else
      stage="$stage_root/repo"
      mkdir -p "$stage"
      git -C "$stage" init -q -b main
      git -C "$stage" remote add origin "$remote"
    fi
    rsync -a --exclude='.git' --exclude='.github' "$source_dir/" "$stage/"
    cat > "$stage/.gitlab-ci.yml" <<'YML'
pages:
  stage: deploy
  script:
    - rm -rf public
    - mkdir -p public
    - |
      find . -mindepth 1 -maxdepth 1 \
        ! -name '.git' ! -name 'public' ! -name '.gitlab-ci.yml' \
        -exec cp -a {} public/ \;
    - rm -rf public/.git public/public
  artifacts:
    paths: [public]
  only: [main]
YML
    git -C "$stage" config user.email "codex-t2@sitesau.local"
    git -C "$stage" config user.name "codex-t2"
    git -C "$stage" add -A
    git -C "$stage" commit -q -m "publish $project" || true
    git -C "$stage" push -q origin HEAD:main

    for _ in $(seq 1 20); do
      sleep 15
      resolved_url="$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_PAT" "$api/projects/$project_id/pages" | jq -r '.url // empty' || true)"
      [ -n "$resolved_url" ] && break
    done
    [ -n "$resolved_url" ] || { echo "::error::GitLab Pages URL was not assigned"; exit 1; }
    curl -sf -X PUT -H "PRIVATE-TOKEN: $GITLAB_PAT" -H "Content-Type: application/json" \
      --data '{"visibility":"public","pages_access_level":"enabled"}' "$api/projects/$project_id" >/dev/null
    resolved_url="${resolved_url%/}/"
    ;;

  firebase)
    require_env AMSUMO_GITHUB_TOKEN
    source_dir="$PWD"
    agg="$(mktemp -d)"
    git clone -q "https://x-access-token:${AMSUMO_GITHUB_TOKEN}@github.com/AMSumo9/firebase-t2-cloudsites.git" "$agg"
    mkdir -p "$agg/public/$slug"
    rsync -a --delete --exclude='.git' --exclude='.github' \
      --exclude='.wheel-meta.json' --exclude='.deploy-host' "$source_dir/" "$agg/public/$slug/"
    key_file="$(find "$source_dir" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{32}\.txt' | head -1 || true)"
    [ -z "$key_file" ] || cp "$key_file" "$agg/public/"
    git -C "$agg" config user.email "codex-t2@sitesau.local"
    git -C "$agg" config user.name "codex-t2"
    git -C "$agg" add -A
    git -C "$agg" commit -q -m "publish firebase path $slug" || true
    pushed=0
    for _ in $(seq 1 5); do
      if git -C "$agg" push -q origin HEAD:main; then pushed=1; break; fi
      git -C "$agg" pull -q --rebase origin main
    done
    [ "$pushed" = 1 ] || { echo "::error::Could not update Firebase T2 aggregator"; exit 1; }
    resolved_url="https://sumo9-cloudsites-t2.web.app/$slug/"
    ;;

  neocities)
    require_env NEOCITIES_API_KEY
    up_args=()
    for f in *; do
      [ -f "$f" ] || continue
      case "$f" in .*|.wheel-meta.json|.deploy-host) continue;; esac
      up_args+=(-F "$project/$f=@$f")
    done
    key_file="$(ls *.txt 2>/dev/null | grep -iE '^[0-9a-f]{32}\.txt$' | head -1 || true)"
    if [ -n "$key_file" ]; then
      up_args+=(-F "$key_file=@$key_file")
    fi
    resp="$(curl -s -m 60 -H "Authorization: Bearer $NEOCITIES_API_KEY" "${up_args[@]}" "https://neocities.org/api/upload")"
    echo "$resp" | grep -q '"result": *"success"' || { echo "::error::Neocities upload failed: $resp"; exit 1; }
    ;;

  ghpages)
    require_env CLOUDSITES_GITHUB_TOKEN
    rm -rf /tmp/ghpages-deploy && mkdir /tmp/ghpages-deploy
    cp -r ./* /tmp/ghpages-deploy/ 2>/dev/null || true
    rm -rf /tmp/ghpages-deploy/.git
    cd /tmp/ghpages-deploy
    git init -q -b gh-pages
    git -c user.name=codex-t2 -c user.email=codex-t2@sitesau.local add -A
    git -c user.name=codex-t2 -c user.email=codex-t2@sitesau.local commit -q -m "deploy"
    git push --force "https://x-access-token:${CLOUDSITES_GITHUB_TOKEN}@github.com/$repo_full.git" gh-pages:gh-pages
    curl -s -w '\nHTTP=%{http_code}\n' -X POST "https://api.github.com/repos/$repo_full/pages" \
      -H "Authorization: Bearer $CLOUDSITES_GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
      -d '{"source":{"branch":"gh-pages","path":"/"}}'
    cd - >/dev/null
    ;;

  gcs)
    echo "::error::cloud_host=gcs blocked; fix after non-GCS path proven"
    exit 1
    ;;

  *)
    echo "::error::unsupported cloud_host '$host'"
    exit 1
    ;;
esac

live_url="${resolved_url:-$intended_url}"
code=0
effective_url="$live_url"
for _ in $(seq 1 20); do
  probe="$(curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}' "$live_url" || echo '000 -')"
  code="${probe%% *}"
  effective_url="${probe#* }"
  if [ "$code" = "200" ] && ! echo "$effective_url" | grep -Eq '^https://vercel\.com/(login|sso-api)'; then
    break
  fi
  sleep 15
done
[ "$code" = "200" ] && ! echo "$effective_url" | grep -Eq '^https://vercel\.com/(login|sso-api)' || {
  echo "::error::live URL not public: $live_url -> $effective_url HTTP $code"
  exit 1
}

if [ "$host" = "firebase" ] || [ "$host" = "gitlab" ]; then
  direct_code="$(curl -sS -D /tmp/t2-live-headers -o /tmp/t2-live-body -w '%{http_code}' "$live_url")"
  [ "$direct_code" = "200" ] || { echo "::error::Direct public URL returned $direct_code (redirect/auth not allowed)"; exit 1; }
  ! grep -qiE '^x-robots-tag:.*noindex' /tmp/t2-live-headers || { echo "::error::X-Robots-Tag blocks indexing"; exit 1; }
  python3 - <<'PY'
import json
from html.parser import HTMLParser

expected = {item["target_url"] for item in json.load(open("/tmp/t2-links.json", encoding="utf-8"))}

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.follow = set()
        self.noindex = False

    def handle_starttag(self, tag, attrs):
        values = {key.lower(): value or "" for key, value in attrs}
        if tag.lower() == "meta" and values.get("name", "").lower() == "robots":
            self.noindex = "noindex" in values.get("content", "").lower()
        if tag.lower() == "a":
            rel = {part.lower() for part in values.get("rel", "").split()}
            if values.get("href") and "nofollow" not in rel:
                self.follow.add(values["href"])

parser = Links()
parser.feed(open("/tmp/t2-live-body", encoding="utf-8", errors="replace").read())
if parser.noindex:
    raise SystemExit("meta robots blocks indexing")
missing = sorted(expected - parser.follow)
if missing:
    raise SystemExit(f"missing dofollow upward links: {missing}")
PY
fi

key_file="$(ls *.txt 2>/dev/null | grep -iE '^[0-9a-f]{32}\.txt$' | head -1 || true)"
if [ -n "$key_file" ]; then
  key="$(basename "$key_file" .txt)"
  live_host="$(echo "$live_url" | sed -E 's#https?://([^/]+).*#\1#')"
  for ep in https://api.indexnow.org/indexnow https://www.bing.com/indexnow https://yandex.com/indexnow; do
    curl -s -o /dev/null -m 20 "$ep?url=$live_url&key=$key&keyLocation=https://$live_host/$key.txt" || true
  done
fi

require_env SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY
rest="${SUPABASE_URL%/}/rest/v1"
retry=(--retry 4 --retry-delay 3 --retry-all-errors)
auth=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" -H "Accept-Profile: deploy" -H "Content-Profile: deploy")

cloud_payload="$(jq -n \
  --arg slug "$slug" --arg money "$money" --arg host "$host" --arg url "$live_url" \
  --arg kw "$kw" --arg parent "$parent" \
  --arg method "cloudlink-t2-$structure" \
  '{slug:$slug,money_target:$money,cloud_host:$host,intended_url:$url,live_url:$url,primary_kw:$kw,tier:"T2",links_up_to:$parent,method:$method,status:"live"}')"
curl -sf "${retry[@]}" -X POST "$rest/cloud_properties" \
  "${auth[@]}" -H "Prefer: resolution=merge-duplicates,return=minimal" \
  -d "$cloud_payload"

curl -sf "${retry[@]}" -X DELETE "$rest/link_edges?source_ref=eq.$slug&source_feed=eq.t2-wheel" "${auth[@]}"

jq -c --arg slug "$slug" --arg url "$live_url" \
  '[.[] | {source_url:$url, target_url:.target_url, source_type:"cloud", source_ref:$slug, target_type:"cloud", anchor:.anchor, rel:(.rel // "follow"), source_feed:"t2-wheel", first_seen: (now|strftime("%Y-%m-%d"))}]
   | unique_by([.source_url, .target_url])' \
  /tmp/t2-links.json > /tmp/t2-link-edges.json

if [ "$(jq 'length' /tmp/t2-link-edges.json)" -gt 0 ]; then
  curl -sf "${retry[@]}" -X POST "$rest/link_edges" "${auth[@]}" -H "Prefer: resolution=merge-duplicates,return=minimal" \
    -d @/tmp/t2-link-edges.json
fi

if [[ "$wheel_id" =~ ^[0-9]+$ ]]; then
  row="$(curl -sf "${retry[@]}" "$rest/t2_build_queue?id=eq.$wheel_id&select=built_slugs,feeder_count" "${auth[@]}")"
  feeder_count="$(echo "$row" | jq -r '.[0].feeder_count')"
  if [ "$node_role" = "feeder" ]; then
    built="$(echo "$row" | jq -c --arg s "$slug" '((.[0].built_slugs // []) + [$s]) | unique')"
  else
    built="$(echo "$row" | jq -c '.[0].built_slugs // []')"
  fi
  count="$(echo "$built" | jq 'length')"
  if [ "$count" -ge "$feeder_count" ]; then
    status="done"
    queue_payload="$(jq -n --argjson built "$built" --arg done_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{built_slugs:$built,status:"done",error:null,done_at:$done_at}')"
  else
    status="in_progress"
    queue_payload="$(jq -n --argjson built "$built" '{built_slugs:$built,status:"in_progress",error:null}')"
  fi
  curl -sf "${retry[@]}" -X PATCH "$rest/t2_build_queue?id=eq.$wheel_id" "${auth[@]}" -H "Prefer: return=minimal" \
    -d "$queue_payload"
else
  echo "Non-numeric proof wheel id '$wheel_id': DB property/link writeback proven; queue update skipped."
fi

echo "T2_DEPLOY_LIVE_URL=$live_url"
