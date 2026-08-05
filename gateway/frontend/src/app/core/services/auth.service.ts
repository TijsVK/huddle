import { Injectable, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';

// Operator-authenticatie voor de portal. De session-cookie is httpOnly (niet
// leesbaar vanuit JS); we kennen dus alleen de status via /api/auth/status. Het
// `authenticated`-signal stuurt de app-shell: null = nog onbekend (laden),
// false = login tonen, true = app tonen. De 401-interceptor zet 'm op false
// zodra een API-call ongeauthenticeerd terugkomt (bv. na cookie-expiry).
@Injectable({ providedIn: 'root' })
export class AuthService {
  private http = inject(HttpClient);
  readonly authenticated = signal<boolean | null>(null);
  // Isolatie-modus van de gateway ('classic' | 'dind' | 'sysbox'). In sysbox- en
  // dind-modus heeft een devcontainer een EIGEN, ongefilterde docker-daemon, dus
  // de per-actie docker-rechten bestaan daar niet.
  readonly mode = signal<'classic' | 'dind' | 'sysbox' | null>(null);
  readonly privateDaemon = () => this.mode() === 'sysbox' || this.mode() === 'dind';

  async refresh(): Promise<boolean> {
    try {
      const res = await firstValueFrom(
        this.http.get<{ authenticated: boolean; mode?: 'classic' | 'dind' | 'sysbox' }>('/api/auth/status'),
      );
      this.authenticated.set(res.authenticated);
      if (res.mode) this.mode.set(res.mode);
      return res.authenticated;
    } catch {
      this.authenticated.set(false);
      return false;
    }
  }

  async login(token: string): Promise<boolean> {
    try {
      await firstValueFrom(this.http.post('/api/auth/login', { token }));
      this.authenticated.set(true);
      // Ook de isolatie-modus ophalen: bij de auto-login (?token=...) werd login()
      // aangeroepen zonder ooit /api/auth/status te lezen, dus bleef `mode` null en
      // toonde de sidebar 'Docker permissions' ook in sysbox-modus.
      void this.refresh();
      return true;
    } catch {
      this.authenticated.set(false);
      return false;
    }
  }

  async logout(): Promise<void> {
    try {
      await firstValueFrom(this.http.post('/api/auth/logout', {}));
    } finally {
      this.authenticated.set(false);
    }
  }
}
