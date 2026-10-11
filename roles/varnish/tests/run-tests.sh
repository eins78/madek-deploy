#!/usr/bin/env bash
# Offline functional tests of templates/madek.vcl.j2 against a mock backend (mock-backend.js).
# Renders the template with ansible (short TTL, debug headers on), runs it in a throw-away docker
# network (madek-vcl-test) and touches nothing else.
# Usage: roles/varnish/tests/run-tests.sh [--keep]
#        (needs ansible, docker and the images varnish:7, node:24-bookworm-slim)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROLE="$(cd "$HERE/.." && pwd)"
NET=madek-vcl-test; PORT=${PORT:-28891}; B="http://localhost:$PORT"
TMP=$(mktemp -d)
cleanup() { [ "${1:-}" = keep ] || docker rm -f vcltest-varnish vcltest-mock >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
trap 'cleanup ${KEEP:-}' EXIT
[ "${1:-}" = --keep ] && KEEP=keep

# render <out.vcl> [json extra vars]: the role template with test backends and short times
# (TTL 3s, no stale-while-revalidate, so that expiry paths can be tested in seconds)
render() {
  local out="$1" extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  ANSIBLE_LOCALHOST_WARNING=False ansible localhost -c local -m template \
    -a "src=$ROLE/templates/madek.vcl.j2 dest=$out" -e "@$ROLE/defaults/main.yml" \
    -e '{"madek_webapp_port": 3000, "varnish_backend_host": "webapp", "varnish_backend_port": 3000,
         "varnish_ttl": "3s", "varnish_grace_healthy": "0s", "varnish_debug_headers": true}' \
    -e "$extra" </dev/null >"$TMP/render.log" 2>&1 || { cat "$TMP/render.log"; exit 1; }
}
# load <name> <file.vcl>: compile and activate in the running test varnish (cache kept)
load() {
  docker cp "$2" vcltest-varnish:/tmp/$1.vcl >/dev/null
  docker exec vcltest-varnish varnishadm vcl.load "$1" /tmp/$1.vcl >/dev/null \
    && docker exec vcltest-varnish varnishadm vcl.use "$1" >/dev/null || { echo "vcl.load $1 failed"; exit 1; }
}

render "$TMP/test.vcl"
docker network create $NET >/dev/null 2>&1 || true
docker rm -f vcltest-varnish vcltest-mock >/dev/null 2>&1
docker run -d --name vcltest-mock --network $NET --network-alias webapp \
  -v "$HERE/mock-backend.js:/m.js:ro" node:24-bookworm-slim node /m.js >/dev/null
docker run -d --name vcltest-varnish --network $NET -p $PORT:80 -e VARNISH_SIZE=64M \
  -v "$TMP/test.vcl:/etc/varnish/default.vcl:ro" varnish:7 \
  -p http_req_hdr_len=32k -p http_req_size=64k -p workspace_client=128k -p workspace_backend=128k >/dev/null
for i in $(seq 1 30); do curl -s -o /dev/null "$B/status" && break; sleep 0.5; done

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
# req <path> [curl args...]  -> sets H (headers), BODY, CODE
req() { local p="$1"; shift; BODY=$(curl -s -g -D "$TMP/h" "$@" "$B$p"); H=$(tr -d '\r' < "$TMP/h"); CODE=$(awk 'NR==1{print $2}' <<<"$H"); }
hdr() { awk -v k="$(tr A-Z a-z <<<"$1")" -F': ' 'tolower($1)==k{print $2}' <<<"$H" | tail -1; }
expect() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
mode() { curl -s -X POST "$B/__mode?m=$1" >/dev/null; }
count() { curl -s -X POST "$B/__count?path=$1"; }

echo "== basic MISS -> HIT, Set-Cookie"
req /entries/a;  expect "first request"  "$(hdr X-Cache)" MISS
expect "no Set-Cookie on MISS (anonymous)" "$(hdr Set-Cookie)" ""
req /entries/a;  expect "second request" "$(hdr X-Cache)" HIT
expect "no Set-Cookie on HIT" "$(hdr Set-Cookie)" ""
[ -n "$(hdr Age)" ] && ok "Age header present ($(hdr Age))" || bad "Age header missing"
expect "X-Cache-Hits" "$(hdr X-Cache-Hits)" 1
expect "downstream Cache-Control unchanged" "$(hdr Cache-Control)" "max-age=0, private, must-revalidate"
expect "X-Madek-Cache with debug headers" "$(hdr X-Madek-Cache)" anon

echo "== cookies"
req /entries/b -H 'Cookie: _madek_session=abc; other=1'
expect "anonymous with _madek_session: MISS" "$(hdr X-Cache)" MISS
grep -q '"cookie":null' <<<"$BODY" && ok "backend saw no Cookie" || bad "backend saw cookie: $BODY"
req /entries/b -H 'Cookie: _madek_session=zzz'; expect "other anonymous cookie: HIT" "$(hdr X-Cache)" HIT
req /entries/b -H 'Cookie: techaro.lol-anubis-auth=x'; expect "Anubis pass cookie: anonymous HIT" "$(hdr X-Cache)" HIT
req /entries/b2 -H 'Cookie: techaro.lol-anubis-auth=x'
grep -q '"cookie":null' <<<"$BODY" && ok "Anubis cookie not forwarded" || bad "backend saw cookie: $BODY"
req /entries/b -H 'Cookie: _madek_session=abc; madek-session=x'
expect "madek-session cookie: PASS" "$(hdr X-Cache)" PASS
grep -q 'madek-session=x' <<<"$BODY" && ok "backend saw the cookie on PASS" || bad "cookie not forwarded: $BODY"
[ -n "$(hdr Set-Cookie)" ] && ok "Set-Cookie kept on PASS" || bad "Set-Cookie missing on PASS"
req /entries/b -H 'Authorization: Basic eDp5'; expect "Authorization: PASS" "$(hdr X-Cache)" PASS

echo "== pass paths / methods"
for p in /media/x.jpg /files/x /my /my/dashboard /session/sign_in /auth/sign-in /api/x /admin /status \
         /entries/0cd7e1b2-0000-4000-8000-000000000000/image.jpg /entries/x/access/tok \
         /entries/x/embedded /entries/x/fullscreen '/entries/x?accessToken=t' '/entries/x?access=t' \
         /zencoder_jobs/1/notification; do
  req "$p"; expect "GET $p" "$(hdr X-Cache)" PASS
done
req /entries/c -X POST; expect "POST" "$(hdr X-Cache)" PASS
req /entries/c -H 'User-Agent: NOJSPLZ'; expect "NOJSPLZ UA" "$(hdr X-Cache)" PASS

echo "== URL normalisation"
req '/entries?___norender=1&b=2&a=1'; k1=$(hdr X-Cache-Key); expect "junk+unsorted key" "$k1" "/entries?a=1&b=2"
req '/entries?a=1&b=2'; expect "sorted twin: HIT" "$(hdr X-Cache)" HIT
grep -q '"url":"/entries?a=1&b=2"' <<<"$(req '/entries?a=1&b=2&utm_source=x&fbclid=y&e=&f'; echo "$BODY")" ; expect "utm/fbclid/empty dropped" "$(hdr X-Cache-Key)" "/entries?a=1&b=2"
req '/entries/d?lang=de'; expect "lang=de key" "$(hdr X-Cache-Key)" /entries/d
req '/entries/d';          expect "lang=de == none: HIT" "$(hdr X-Cache)" HIT
req '/entries/d?lang=en';  expect "lang=en separate: MISS" "$(hdr X-Cache)" MISS
req '/entries?list[page]=2';     expect "raw brackets -> %5B" "$(hdr X-Cache-Key)" "/entries?list%5Bpage%5D=2"
req '/entries?list%5bpage%5d=2'; expect "lower-case %5b: HIT" "$(hdr X-Cache)" HIT
req '/entries?___sparse=%7B%7D&x=1'; expect "___sparse kept in key" "$(hdr X-Cache-Key)" "/entries?___sparse=%7B%7D&x=1"
req '/entries?list%5Blayout%5D=tiles&list%5Bpage%5D=2'; expect "n3 keeps list[layout]" "$(hdr X-Cache-Key)" "/entries?list%5Blayout%5D=tiles&list%5Bpage%5D=2"
req '/entries?___norender=1'; expect "only junk -> bare path" "$(hdr X-Cache-Key)" /entries
grep -q '"url":"/entries"' <<<"$BODY" && ok "backend got the normalised URL" || bad "backend url: $BODY"
req "/entries/long?q=$(head -c 30000 /dev/zero | tr '\0' x)"
[ "$CODE" != 400 ] && [ "$CODE" != 414 ] && ok "30,000-character query accepted ($CODE)" || bad "long query rejected: $CODE"

echo "== Accept / Vary"
req /entries/e -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
expect "browser Accept MISS" "$(hdr X-Cache)" MISS
req /entries/e -H 'Accept: */*'; expect "*/* folds to text/html: HIT" "$(hdr X-Cache)" HIT
req /entries/e -H 'Accept: application/json'; expect "JSON separate variant: MISS" "$(hdr X-Cache)" MISS
expect "JSON content type" "$(hdr Content-Type)" "application/json; charset=utf-8"
req /entries/e -H 'Accept: application/json, text/javascript, */*; q=0.01'; expect "XHR-style JSON Accept: HIT" "$(hdr X-Cache)" HIT
req /entries/e --compressed; expect "gzip client: HIT" "$(hdr X-Cache)" HIT; expect "Content-Encoding gzip" "$(hdr Content-Encoding)" gzip

echo "== status handling"
req /r404; req /r404; expect "404 cached" "$(hdr X-Cache)" HIT
req /r302; req /r302; expect "302 cached" "$(hdr X-Cache)" HIT
req /r403; req /r403; expect "403 not cached (hit-for-miss)" "$(hdr X-Cache-Detail)" hitmiss
req /always500; expect "uncached 5xx -> synthetic 503" "$CODE" 503
req /always500; expect "5xx not stored (2nd also 503)" "$CODE" 503
expect "backend asked once per client request" "$(count /always500)" 2
[ -z "$(hdr Set-Cookie)" ] && ok "no Set-Cookie on 503" || bad "Set-Cookie on 503"

echo "== Cache-Control from the backend"
req /nostore; expect "no-store: MISS" "$(hdr X-Cache)" MISS
req /nostore; expect "no-store never stored" "$(hdr X-Cache-Detail)" hitmiss
expect "backend asked twice" "$(count /nostore)" 2
req /smaxage; expect "s-maxage: MISS" "$(hdr X-Cache)" MISS
expect "public answer leaves as upstream header" "$(hdr Cache-Control)" "max-age=0, private, must-revalidate"
req /smaxage; expect "s-maxage=1: HIT within 1 s" "$(hdr X-Cache)" HIT
expect "HIT leaves as upstream header" "$(hdr Cache-Control)" "max-age=0, private, must-revalidate"
sleep 2
req /smaxage; expect "s-maxage=1: MISS after 2 s (default TTL 3 s would still hit)" "$(hdr X-Cache)" MISS

echo "== deploy ban"
req /sets/ban1; req /sets/ban1; expect "cached" "$(hdr X-Cache)" HIT
docker exec vcltest-varnish varnishadm ban obj.http.X-Madek-Cache == anon >/dev/null
req /sets/ban1; expect "after ban: MISS" "$(hdr X-Cache)" MISS

echo "== stale-if-error (TTL=3s, SWR=0s in this test)"
req /sets/s1; req /sets/s1; expect "cached" "$(hdr X-Cache)" HIT
sleep 4; mode 500
req /sets/s1; expect "5xx after expiry: status" "$CODE" 200
expect "served stale" "$(hdr X-Cache-Detail)" stale-if-error
mode close
req /sets/s1; expect "backend connection error: status" "$CODE" 200
expect "served stale" "$(hdr X-Cache-Detail)" stale-if-error
req /sets/never-cached; expect "error, nothing cached: 503" "$CODE" 503
mode ok
req /sets/s1; expect "backend back: fresh fetch" "$(hdr X-Cache)" MISS
req /sets/s1; expect "then HIT" "$(hdr X-Cache)" HIT

echo "== sick backend (probe on /status fails) -> full grace at lookup"
req /sets/s2; req /sets/s2; expect "cached" "$(hdr X-Cache)" HIT
mode sick; printf '  (waiting for the probe to mark the backend sick ...)\n'
for i in $(seq 1 70); do docker exec vcltest-varnish varnishadm backend.list 2>/dev/null | grep -q 'webapp_health.*sick' && break; sleep 1; done
docker exec vcltest-varnish varnishadm backend.list | sed -n '1,4p' | sed 's/^/    /'
req /sets/s2; expect "expired object while sick: status" "$CODE" 200
expect "served from grace without a failed fetch first" "$(hdr X-Cache-Detail)" grace
mode ok
for i in $(seq 1 70); do docker exec vcltest-varnish varnishadm backend.list 2>/dev/null | grep -q 'webapp_health.*healthy' && break; sleep 1; done

echo "== background refresh that gets no-store keeps the good copy (TTL=3s, SWR=5s)"
render "$TMP/swr.vcl" '{"varnish_grace_healthy": "5s"}'; load swr "$TMP/swr.vcl"
req /sets/g1; req /sets/g1; expect "cached" "$(hdr X-Cache)" HIT; n_good=$(grep -o '"n":[0-9]*' <<<"$BODY")
sleep 4; mode nostore; n_before=$(count /sets/g1)
req /sets/g1; expect "expired, within SWR: grace" "$(hdr X-Cache-Detail)" grace
expect "old body served" "$(grep -o '"n":[0-9]*' <<<"$BODY")" "$n_good"
sleep 1; expect "background fetch happened" "$(count /sets/g1)" "$((n_before+1))"
req /sets/g1; expect "no-store refresh abandoned, good copy kept" "$(hdr X-Cache-Detail)" grace
expect "still the old body" "$(grep -o '"n":[0-9]*' <<<"$BODY")" "$n_good"
mode ok
render "$TMP/base.vcl"; load base "$TMP/base.vcl"

echo "== presentation params (varnish_presentation_params_redirect)"
render "$TMP/p.vcl" '{"varnish_presentation_params_redirect": true}'; load p "$TMP/p.vcl"
req '/sets/p1?list[layout]=list&list[page]=2'
expect "presentation param: 302" "$CODE" 302
expect "Location: clean URL, values in the fragment" "$(hdr Location)" "/sets/p1?list%5Bpage%5D=2#list%5Blayout%5D=list"
expect "preference cookie" "$(hdr Set-Cookie)" "madek_list=list%5Blayout%5D%3Dlist; Path=/; Max-Age=2592000; SameSite=Lax"
expect "redirect not storable" "$(hdr Cache-Control)" no-store
expect "backend not asked" "$(count /sets/p1)" 0
req '/sets/p1?list[layout]=list&list[page]=2'; expect "repeat: 302 again" "$CODE" 302
req '/sets/p1?list%5bshow_filter%5d=true&list[accordion]={"a":true}&list%5Blayout%5D=tiles' -H 'X-Forwarded-Proto: https'
expect "all three, mixed bracket spellings" "$(hdr Location)" '/sets/p1#list%5Blayout%5D=tiles&list%5Bshow_filter%5D=true&list%5Baccordion%5D=%7B%22a%22%3Atrue%7D'
expect "cookie over https: Secure" "$(hdr Set-Cookie)" "madek_list=list%5Blayout%5D%3Dtiles%26list%5Bshow_filter%5D%3Dtrue%26list%5Baccordion%5D%3D%7B%22a%22%3Atrue%7D; Path=/; Max-Age=2592000; SameSite=Lax; Secure"
req '/sets/p1?list[layout]=bogus'; expect "unknown layout: 302" "$CODE" 302
expect "unknown layout: no cookie" "$(hdr Set-Cookie)" ""
req '/sets/p2?list[layout]=list' -H 'Accept: application/json'; expect "JSON: not redirected" "$CODE" 200
req '/sets/p2?list[layout]=list&___sparse=%7B%7D'; expect "___sparse: not redirected" "$CODE" 200
req '/sets/p2?list[layout]=list' -H 'Cookie: madek-session=x'; expect "signed in: not redirected" "$CODE" 200
expect "signed in: PASS" "$(hdr X-Cache)" PASS
grep -q 'list\[layout\]=list' <<<"$BODY" && ok "signed in: URL untouched" || bad "signed-in url: $BODY"
req '/sets/p2?list[layout]=&list[page]=3'; expect "empty value only: no redirect" "$CODE" 200
req '/sets/p3'; req '/sets/p3'; expect "clean URL without cookie: HIT" "$(hdr X-Cache)" HIT
req '/sets/p3' -H 'Cookie: madek_list=list%5Blayout%5D%3Dlist'
expect "layout cookie: own variant, MISS" "$(hdr X-Cache)" MISS
grep -q '"url":"/sets/p3?list%5Blayout%5D=list"' <<<"$BODY" && ok "backend got the layout from the cookie" || bad "backend url: $BODY"
grep -q '"cookie":null' <<<"$BODY" && ok "backend saw no Cookie" || bad "backend saw cookie: $BODY"
req '/sets/p3' -H 'Cookie: other=1; madek_list=list%5Blayout%5D=list'
expect "same cookie, plain fragment form: HIT" "$(hdr X-Cache)" HIT
expect "no Set-Cookie" "$(hdr Set-Cookie)" ""
req '/sets/p3'; expect "no cookie: still the default variant" "$(hdr X-Cache-Key)" /sets/p3
req '/sets/p3' -H 'Cookie: madek_list=list%5Blayout%5D%3Dlist%26list%5Baccordion%5D%3D%7B%7D'
expect "accordion cookie: PASS" "$(hdr X-Cache)" PASS
grep -q 'list%5Baccordion%5D=%7B%7D' <<<"$BODY" && ok "backend got the accordion" || bad "backend url: $BODY"
expect "no Set-Cookie on anonymous PASS" "$(hdr Set-Cookie)" ""
req '/sets/p3' -H 'Cookie: madek_list=list%5Bfilter%5D%3Dx'
expect "foreign key in cookie ignored" "$(hdr X-Cache-Key)" /sets/p3
req '/sets/p3' -H 'Cookie: madek_list=list%5Blayout%5D%3Dlist' -H 'Accept: application/json'
grep -q '"url":"/sets/p3"' <<<"$BODY" && ok "JSON request ignores the cookie" || bad "backend url: $BODY"

echo; echo "passed $PASS, failed $FAIL"
[ $FAIL = 0 ]
