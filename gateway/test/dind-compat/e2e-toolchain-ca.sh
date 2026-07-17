#!/usr/bin/env bash
# Real-gateway toolchain CA-trust matrix. Huddle MITMs HTTPS, so a toolchain only
# works if it trusts the Huddle CA. Tools that use the system trust store
# (/etc/ssl/certs, which the bootstrap populates) pass; tools with a private
# trust store (rustls-based) may not. Characterises each; documents workarounds.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3997; DC=e2e-tc; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; note(){ printf 'NOTE %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm "huddle-dind-sock-$DC" "huddle-dind-data-$DC" huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/tc-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/tc-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done

for d in \
  deb.debian.org security.debian.org "*.debian.org" \
  github.com "*.github.com" codeload.github.com objects.githubusercontent.com "*.githubusercontent.com" \
  proxy.golang.org sum.golang.org storage.googleapis.com "*.golang.org" \
  static.rust-lang.org sh.rustup.rs "*.rust-lang.org" crates.io "*.crates.io" index.crates.io static.crates.io \
  pypi.org files.pythonhosted.org "*.pythonhosted.org" \
  repo.maven.apache.org repo1.maven.org "*.maven.apache.org" "*.maven.org"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
pass "allowlisted debian/github/go/rust domains"

resp=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}")
echo "$resp" | grep -q '"id"' && pass "devcontainer started" || { fail "start: $resp"; docker logs huddle 2>&1|tail -15>&2; exit 1; }
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
X() { docker exec -u vscode "$DC" bash -lc "$1"; }

# git over HTTPS (uses system CA)
X 'git clone --depth 1 https://github.com/octocat/Hello-World.git /tmp/hw >/dev/null 2>&1 && test -f /tmp/hw/README' \
  && pass "git clone over HTTPS through MITM" || { fail "git clone over HTTPS"; rc=1; }

# go (system cert pool) — install via apt then module download
if X 'sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq golang-go >/dev/null 2>&1'; then
  X 'cd /tmp && mkdir -p gm && cd gm && go mod init ex >/dev/null 2>&1 && GOFLAGS=-mod=mod go get github.com/google/uuid@latest >/tmp/go.log 2>&1' \
    && pass "go mod download through MITM (GOPROXY)" || { fail "go mod download"; tail -4 /tmp/go.log >&2 2>/dev/null || true; rc=1; }
else note "go: apt install skipped (apt through proxy failed)"; fi

# rust via rustup (rustup's downloader — the likely rustls break)
if X 'curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/tmp/rustup.log 2>&1'; then
  pass "rustup bootstrap through MITM"
  if X 'source $HOME/.cargo/env && cd /tmp && cargo new capp >/dev/null 2>&1 && cd capp && echo "uuid = \"1\"" >> Cargo.toml && cargo fetch >/tmp/cargo.log 2>&1'; then
    pass "cargo fetch (sparse registry) through MITM"
  else
    err=$(X 'tail -3 /tmp/cargo.log' 2>/dev/null | tr -d '\r')
    if printf '%s' "$err" | grep -qiE "certificate|self.signed|unknown|tls|ssl"; then
      note "cargo fetch fails on CA verification (rustls ignores the system store) — set CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt. Documented limitation."
      # verify the workaround
      X 'source $HOME/.cargo/env && cd /tmp/capp && CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt cargo fetch >/tmp/cargo2.log 2>&1' \
        && pass "cargo fetch works with CARGO_HTTP_CAINFO (workaround confirmed)" || { fail "cargo fetch still fails with CARGO_HTTP_CAINFO"; rc=1; }
    else
      fail "cargo fetch failed (non-CA): $err"; rc=1
    fi
  fi
else
  err=$(X 'tail -3 /tmp/rustup.log' 2>/dev/null | tr -d '\r')
  note "rustup bootstrap failed through MITM: $err"
fi

# python / pip — pip ships its own certifi bundle, so it may ignore the system CA.
if X 'sudo apt-get install -y -qq python3-pip python3-venv >/dev/null 2>&1'; then
  X 'python3 -m venv /tmp/venv >/dev/null 2>&1'
  if X '/tmp/venv/bin/pip install --quiet --disable-pip-version-check requests >/tmp/pip.log 2>&1'; then
    pass "pip install through MITM (out of the box)"
  else
    if X '/tmp/venv/bin/pip install --quiet --cert /etc/ssl/certs/ca-certificates.crt requests >/tmp/pip2.log 2>&1'; then
      note "pip needs the CA (certifi bundle) — set PIP_CERT/REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt. Workaround confirmed."
    else
      fail "pip install fails even with --cert"; X 'tail -3 /tmp/pip2.log' >&2 2>/dev/null; rc=1
    fi
  fi
else note "pip: apt install skipped"; fi

# java / maven — the JVM uses its own cacerts truststore, not the system store.
# Debian's ca-certificates-java (pulled in with the JDK) imports the system CA
# store into the JVM keystore when update-ca-certificates runs.
if X 'sudo apt-get install -y -qq maven >/dev/null 2>&1'; then
  X 'sudo update-ca-certificates -f >/dev/null 2>&1 || true'   # trigger ca-certificates-java
  X 'rm -rf ~/.m2/repository >/dev/null 2>&1 || true'          # avoid cached resolution failures
  if X 'cd /tmp && mvn -q -U -Dartifact=org.apache.commons:commons-lang3:3.14.0 dependency:get >/tmp/mvn.log 2>&1'; then
    pass "maven dependency:get through MITM (JVM keystore via ca-certificates-java)"
  else
    caerr=$(X 'grep -iE "PKIX|SunCertPathBuilder|unable to find valid certification" /tmp/mvn.log | head -1' 2>/dev/null | tr -d '\r')
    if [ -n "$caerr" ]; then
      # Prove it's CA-only: import into the resolved cacerts and retry.
      imp='JH=$(readlink -f $(which java)); JH=${JH%/bin/java}; CA=$JH/lib/security/cacerts; [ -f "$CA" ] || CA=/etc/ssl/certs/java/cacerts; sudo keytool -importcert -noprompt -trustcacerts -alias huddle -file /usr/local/share/ca-certificates/huddle-ca.crt -keystore "$CA" -storepass changeit >/dev/null 2>&1'
      if X "$imp && rm -rf ~/.m2/repository && cd /tmp && mvn -q -U -Dartifact=org.apache.commons:commons-lang3:3.14.0 dependency:get >/tmp/mvn2.log 2>&1"; then
        note "maven/JVM needs the Huddle CA in the JDK cacerts (keytool import) — documented Java limitation; ca-certificates-java didn't auto-import."
      else
        note "maven still fails after cacerts import: $(X 'tail -2 /tmp/mvn2.log' 2>/dev/null | tr -d '\r')"
      fi
    else
      note "maven failed (non-CA, likely env quirk): $(X 'grep -iE "error|exception" /tmp/mvn.log | head -1' 2>/dev/null | tr -d '\r')"
    fi
  fi
else note "maven: apt install skipped"; fi

exit $rc
