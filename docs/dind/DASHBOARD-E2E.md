# Full-parity autonomous Aspire dashboard test

## Why this exists

Earlier "done" claims for the Aspire path rested on **log-greps and a Blazor-shell
fetch** (`curl … | grep blazor.web.js`, plus absence-of-error greps on the AppHost
log). Those all pass *independently of whether the dashboard actually renders the
SQL Server*. The Aspire dashboard is Blazor Server: the login URL serves a static
shell, and the resource grid + live state only arrive afterward over a SignalR
circuit backed by the resource-service gRPC channel. A grep can't see whether that
circuit populated the grid — so the tests reported green on things a user would see
as broken.

## What replaces it

A single autonomous scenario that mirrors the manual workflow end to end and
verifies the last mile **in a real browser**:

```
bash gateway/test/dind-compat/e2e-aspire-dashboard.sh
```

Steps (each fails loudly if its *user-visible* outcome doesn't happen):

1. build the gateway + devcontainer-base + probe images (cached after first run)
2. `huddle init` a real gateway in DinD mode
3. start a devcontainer
4. write a .NET Aspire AppHost provisioning a `sql` (SqlServer) resource + a
   database + an EF-Core project that references it
5. `dotnet build` + `dotnet run` the AppHost (nuget flows through the Huddle proxy)
6. confirm SqlServer is really up via a project→DB round-trip (`hello-from-ef`)
7. **drive a headless Chromium against the dashboard**: log in via the token URL,
   wait for the SignalR circuit to render the grid, and assert `sql`, `appdb`, and
   `svc` appear with `sql`/`svc` **Running**; open the SqlServer detail and read its
   Health / image / ports. A full-page **screenshot** is written as evidence.

The browser runs in `mcr.microsoft.com/playwright` **joined to the devcontainer's
network namespace** (`--network container:<dc>`), so `http://localhost:<port>` in
the browser is the exact loopback the dashboard binds to in the shared netns.

## Pieces

| File | Role |
|------|------|
| `e2e-aspire-dashboard.sh` | the full autonomous scenario (the user's manual flow) |
| `lib/dashboard.sh` | `assert_dashboard <dc> <login-url> <expect> <running> <shotdir>` — runs the probe container |
| `lib/dashboard-probe.mjs` | Playwright script: login, wait for the grid to populate, assert rendered DOM, screenshot |
| `lib/Dockerfile.probe` | `huddle-dashboard-probe:latest` = playwright image + the `playwright` npm package |

`e2e-aspire-project-ef.sh` now uses the same `assert_dashboard` in place of its old
Blazor-shell grep.

## Dev flags / prereqs

- `KEEP=1` — leave the whole stack running on success and print the container name
  + dashboard login URL, for manual poking / iterating the probe against a live UI.
- `SHOTDIR=<dir>` — where screenshots land (default `.artifacts/aspire-dashboard/`).
- Requires `cli/dist` built (`npm run cli:build`) and Docker with privileged +
  nested-container support, same as the rest of the DinD harness.

Screenshots (`.artifacts/`) are git-ignored — they are run evidence, not fixtures.

---

# Video-recorded web-UI E2E (operator portal)

`e2e-webui-docker-hello.sh` records a **video + per-step screenshots** of an
operator driving the Huddle portal itself, end to end:

```
bash gateway/test/dind-compat/e2e-webui-docker-hello.sh
```

1. open the web UI + log in (token in the pre-hash query string)
2. add a devcontainer via the Start modal (VS Code, default image, empty)
3. enable docker functionalities on the Docker permissions page (Permanent grant
   + Pull toggle)
4. run `docker run hello-world` inside the container
5. **approve the firewall rules the image pull needs, live in the UI**, as each
   registry domain surfaces (`registry-1.docker.io`, `auth.docker.io`,
   `production.cloudfront.docker.com`) — via the radial "pie menu" → Allow globally
6. verify the run printed `Hello from Docker!`

**DinD mode is deliberate**: it is the only mode where the container's own docker
pull egresses through Huddle, so the pull genuinely requires firewall approval in
the UI. (Classic mode pulls on a host-side daemon and never asks; it also blocks
the interactive attach hijack with a 403.)

The browser runs in the probe image with `--network host` so `localhost:<port>`
reaches the gateway's published UI/API port. The host runs `docker run hello-world`
on a retry loop; browser and host coordinate through the shared `.artifacts/`
mount (`hello.done` marker), so the operator keeps approving pending requests until
the pull finally succeeds — the retry-then-succeed pattern in `hello.out` is the
proof the approval unblocked it live.

Output: `.artifacts/webui-docker-hello/ui-demo-flow.webm` + `NN-*.png` step shots.

| File | Role |
|------|------|
| `e2e-webui-docker-hello.sh` | orchestrator: gateway + host hello-world loop + browser |
| `lib/ui-demo-flow.mjs` | Playwright flow: login → add container → enable docker → approve rules → verify (video + screenshots) |

Flags: `REUSE=1` reuse a running gateway; `KEEP=1` leave the stack up.
