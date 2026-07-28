'use strict';
(function () {
  const BASE = '/api/ext/sudo-grant';
  const PRESETS = [15, 30, 60];
  const REFRESH_MS = 15000;

  const CSS = `
    :host {
      display: flex; flex-direction: column; height: 100%; overflow: auto;
      background: var(--bg); color: var(--text);
      font-family: 'DM Sans', system-ui, -apple-system, sans-serif;
      font-size: 13px; line-height: 1.5;
    }
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    .wrap { padding: 22px 24px; display: flex; flex-direction: column; gap: 16px; }
    .head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
    .head h1 { font-size: 18px; font-weight: 700; letter-spacing: -.01em; }
    .head .sub { color: var(--text-muted); font-size: 12.5px; }

    .note {
      background: var(--warning-soft); border: 1px solid var(--border);
      border-left: 3px solid var(--warning);
      border-radius: var(--radius-sm, 10px); padding: 10px 13px;
      color: var(--text); font-size: 12.5px;
    }
    .err {
      background: var(--danger-soft); border: 1px solid var(--border);
      border-left: 3px solid var(--danger);
      border-radius: var(--radius-sm, 10px); padding: 10px 13px; font-size: 12.5px;
    }

    .card {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius, 14px); box-shadow: var(--shadow-card, none);
      overflow: hidden;
    }
    table { width: 100%; border-collapse: collapse; }
    th {
      text-align: left; font-size: 11px; text-transform: uppercase;
      letter-spacing: .04em; color: var(--table-head, var(--text-muted));
      padding: 11px 14px; border-bottom: 1px solid var(--border); font-weight: 600;
    }
    td { padding: 11px 14px; border-bottom: 1px solid var(--border); vertical-align: middle; }
    tr:last-child td { border-bottom: none; }
    .name { font-weight: 600; }
    .meta { color: var(--text-muted); font-size: 11.5px; }

    .pill {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 3px 9px; border-radius: 999px;
      font-size: 11.5px; font-weight: 600; white-space: nowrap;
    }
    .pill--on  { background: var(--success-soft); color: var(--success); }
    .pill--off { background: var(--surface-2); color: var(--text-muted); border: 1px solid var(--border); }
    .pill--stopped { background: var(--danger-soft); color: var(--danger); }
    .mono { font-variant-numeric: tabular-nums; font-family: ui-monospace, 'SF Mono', Consolas, monospace; }

    .actions { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: wrap; }
    button {
      padding: 5px 11px; border-radius: var(--radius-sm, 10px);
      border: 1px solid var(--border-strong); background: var(--surface-2);
      color: var(--text); font-family: inherit; font-size: 12.5px; font-weight: 600;
      cursor: pointer; transition: background .1s, border-color .1s, opacity .1s;
    }
    button:hover:not(:disabled) { background: var(--surface-hover); border-color: var(--accent); }
    button:disabled { opacity: .45; cursor: not-allowed; }
    button.danger { color: var(--danger); }
    button.danger:hover:not(:disabled) { border-color: var(--danger); }
    .empty { padding: 22px 14px; color: var(--text-muted); }
  `;

  function fmtCountdown(secondsLeft) {
    if (secondsLeft <= 0) return '0:00';
    const h = Math.floor(secondsLeft / 3600);
    const m = Math.floor((secondsLeft % 3600) / 60);
    const s = secondsLeft % 60;
    const mm = String(m).padStart(h > 0 ? 2 : 1, '0');
    return (h > 0 ? h + ':' : '') + mm + ':' + String(s).padStart(2, '0');
  }

  async function call(method, path, body) {
    const res = await fetch(BASE + path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      credentials: 'same-origin',
    });
    const text = await res.text();
    let data = {};
    try { data = text ? JSON.parse(text) : {}; } catch { /* non-JSON error body */ }
    if (!res.ok) throw new Error(data.error || `${method} ${path} failed (${res.status})`);
    return data;
  }

  class SudoGrantExtension extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this.state = { containers: [], sudoUser: 'vscode', maxMinutes: 120, error: null, busy: null, loaded: false };
      this._tick = null;
      this._poll = null;
    }

    connectedCallback() {
      this.shadowRoot.innerHTML = `<style>${CSS}</style><div class="wrap"></div>`;
      this.root = this.shadowRoot.querySelector('.wrap');
      this.load();
      // Local 1s tick keeps the countdown live without hammering the API.
      this._tick = setInterval(() => this.render(), 1000);
      this._poll = setInterval(() => this.load(), REFRESH_MS);
    }

    disconnectedCallback() {
      clearInterval(this._tick);
      clearInterval(this._poll);
    }

    async load() {
      try {
        const data = await call('GET', '/containers');
        this.state.containers = data.containers || [];
        this.state.sudoUser = data.sudoUser || 'vscode';
        this.state.maxMinutes = data.maxMinutes || 120;
        this.state.error = null;
      } catch (err) {
        this.state.error = err.message;
      }
      this.state.loaded = true;
      this.render();
    }

    async act(container, fn) {
      this.state.busy = container;
      this.render();
      try {
        await fn();
        this.state.error = null;
      } catch (err) {
        this.state.error = err.message;
      }
      this.state.busy = null;
      await this.load();
    }

    grant(container, minutes) {
      return this.act(container, () => call('PUT', `/grants/${encodeURIComponent(container)}`, { minutes }));
    }

    revoke(container) {
      return this.act(container, () => call('DELETE', `/grants/${encodeURIComponent(container)}`));
    }

    render() {
      const now = Math.floor(Date.now() / 1000);
      const s = this.state;

      const rows = s.containers.map((c) => {
        const left = c.until ? c.until - now : 0;
        const active = Boolean(c.until) && left > 0;
        const pill = !c.running
          ? '<span class="pill pill--stopped">stopped</span>'
          : active
            ? `<span class="pill pill--on">root · <span class="mono">${fmtCountdown(left)}</span></span>`
            : '<span class="pill pill--off">no grant</span>';
        const busy = s.busy === c.name;
        const presets = PRESETS.filter((m) => m <= s.maxMinutes)
          .map((m) => `<button data-grant="${c.name}" data-min="${m}" ${!c.running || busy ? 'disabled' : ''}>${active ? '+' : ''}${m}m</button>`)
          .join('');
        const revoke = `<button class="danger" data-revoke="${c.name}" ${!active || busy ? 'disabled' : ''}>Revoke</button>`;
        const label = c.presentableName && c.presentableName !== c.name ? c.presentableName : '';
        return `<tr>
          <td><div class="name">${c.name}</div>${label ? `<div class="meta">${label}</div>` : ''}</td>
          <td class="meta">${c.ide || '—'}</td>
          <td>${pill}</td>
          <td class="meta">${active ? (c.user || s.sudoUser) : s.sudoUser}</td>
          <td><div class="actions">${presets}${revoke}</div></td>
        </tr>`;
      });

      this.root.innerHTML = `
        <div class="head">
          <h1>Sudo</h1>
          <span class="sub">Time-boxed passwordless sudo for <strong>${s.sudoUser}</strong> · max ${s.maxMinutes}m</span>
        </div>
        ${s.error ? `<div class="err">${s.error}</div>` : ''}
        <div class="note">
          A grant bounds <em>when</em> root is available, not what root can do with it. Anything
          running in the container during an active window can persist root past expiry
          (a SUID binary, another sudoers drop-in, a uid-0 account). Host isolation is unchanged:
          the container stays unprivileged behind the Huddle proxy.
        </div>
        <div class="card">
          ${
            !s.loaded
              ? '<div class="empty">Loading…</div>'
              : s.containers.length === 0
                ? '<div class="empty">No devcontainers found.</div>'
                : `<table>
                    <thead><tr><th>Container</th><th>IDE</th><th>Grant</th><th>User</th><th></th></tr></thead>
                    <tbody>${rows.join('')}</tbody>
                  </table>`
          }
        </div>
      `;

      this.root.querySelectorAll('[data-grant]').forEach((b) => {
        b.addEventListener('click', () => this.grant(b.dataset.grant, parseInt(b.dataset.min, 10)));
      });
      this.root.querySelectorAll('[data-revoke]').forEach((b) => {
        b.addEventListener('click', () => this.revoke(b.dataset.revoke));
      });
    }
  }

  if (!customElements.get('ext-sudo-grant')) {
    customElements.define('ext-sudo-grant', SudoGrantExtension);
  }
})();
