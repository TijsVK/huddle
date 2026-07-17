import { Component, DestroyRef, OnInit, PLATFORM_ID, computed, effect, inject, input, signal } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { StateService } from '../../../core/services/state.service';
import { ApiService } from '../../../core/services/api.service';
import { DockerActionDef, DockerActionGroup, DockerActionKind } from '../../../core/models/docker-action.model';
import { PERMANENT_UNTIL } from '../../../core/models/grant.model';

interface GroupMeta {
  title: string;
  colorClass: string;
  iconId: string;
  tempSubtitle: string;
  alwaysSubtitle: string;
}

interface ActionGroupVm {
  group: DockerActionGroup;
  title: string;
  subtitle: string;
  colorClass: string;
  iconId: string;
  actions: DockerActionDef[];
}

const GROUP_ORDER: DockerActionGroup[] = ['containers', 'images', 'volumes', 'networks', 'system'];

const GROUP_META: Record<DockerActionGroup, GroupMeta> = {
  containers: {
    title: 'Containers', colorClass: 'ic-green', iconId: 'container',
    tempSubtitle: 'Manage and modify containers.', alwaysSubtitle: 'View and monitor containers.',
  },
  images: {
    title: 'Images', colorClass: 'ic-purple', iconId: 'cube',
    tempSubtitle: 'Build, pull, and manage images.', alwaysSubtitle: 'View and inspect images.',
  },
  volumes: {
    title: 'Volumes', colorClass: 'ic-blue', iconId: 'db',
    tempSubtitle: 'Manage persistent storage.', alwaysSubtitle: 'View and inspect volumes.',
  },
  networks: {
    title: 'Networks', colorClass: 'ic-blue', iconId: 'network',
    tempSubtitle: 'Manage network connections.', alwaysSubtitle: 'View and inspect networks.',
  },
  system: {
    title: 'System', colorClass: 'ic-gray', iconId: 'gear',
    tempSubtitle: 'System information and status.', alwaysSubtitle: 'System information and status.',
  },
};

const ACTION_ICONS: Record<string, string> = {
  'container.create': 'plus',
  'container.start': 'play',
  'container.stop': 'stop',
  'container.restart': 'refresh',
  'container.remove': 'trash',
  'container.update': 'refresh',
  'container.exec': 'terminal',
  'image.pull': 'download',
  'image.build': 'hammer',
  'image.push': 'upload',
  'image.remove': 'trash',
  'image.tag': 'tag',
  'volume.create': 'plus',
  'volume.remove': 'trash',
  'volume.prune': 'hammer',
  'network.create': 'plus',
  'network.remove': 'trash',
  'network.connect': 'link',
  'network.disconnect': 'link',
  'container.list': 'list',
  'container.inspect': 'search',
  'container.logs': 'file',
  'container.stats': 'stats',
  'image.list': 'list',
  'image.inspect': 'search',
  'volume.list': 'list',
  'volume.inspect': 'search',
  'network.list': 'list',
  'network.inspect': 'search',
  'system.ping': 'activity',
  'system.version': 'search',
  'system.events': 'bell',
};

const DURATION_STORE_PREFIX = 'huddle.dockerActions.duration.';

/**
 * Reusable panel with the fine-grained Docker permissions for one devcontainer:
 * timer hero + temporary actions + always-allowed actions + proxy explainer.
 * Host ports deliberately do not belong here.
 */
@Component({
  selector: 'app-docker-rights-panel',
  standalone: true,
  templateUrl: './docker-rights-panel.component.html',
  styleUrl: './docker-rights-panel.component.css',
})
export class DockerRightsPanelComponent implements OnInit {
  private state = inject(StateService);
  private api = inject(ApiService);
  private destroyRef = inject(DestroyRef);
  private platformId = inject(PLATFORM_ID);

  /** Name of the devcontainer the permissions and timer apply to. */
  container = input.required<string>();

  catalog = signal<DockerActionDef[]>([]);
  policies = signal<Record<string, boolean>>({});
  policiesLoading = signal(false);
  error = signal<string | null>(null);

  /** Server grant (unix seconds) for the container, or null. */
  grantUntil = signal<number | null>(null);
  /** Last configured duration (seconds) — basis for the ring percentage. */
  durationSeconds = signal(0);
  private now = signal(Math.floor(Date.now() / 1000));

  /** Root grant (`until` unix seconds) for the container, or null when off. */
  rootUntil = signal<number | null>(null);

  rootPermanent = computed(() => {
    const until = this.rootUntil();
    return until !== null && until >= PERMANENT_UNTIL;
  });
  rootRemainingSeconds = computed(() => {
    const until = this.rootUntil();
    if (until === null || until >= PERMANENT_UNTIL) return 0;
    return Math.max(0, until - this.now());
  });
  rootActive = computed(() => this.rootPermanent() || this.rootRemainingSeconds() > 0);
  rootStatus = computed(() => {
    if (this.rootPermanent()) return 'root: permanent';
    const remaining = this.rootRemainingSeconds();
    if (remaining <= 0) return 'root: off';
    const minutes = Math.ceil(remaining / 60);
    return `root: ${minutes}m left`;
  });

  /** Docker grant never expires (sentinel `until`). */
  isPermanent = computed(() => {
    const until = this.grantUntil();
    return until !== null && until >= PERMANENT_UNTIL;
  });
  remainingSeconds = computed(() => {
    const until = this.grantUntil();
    if (until === null || until >= PERMANENT_UNTIL) return 0;
    return Math.max(0, until - this.now());
  });
  timerExpired = computed(() => !this.isPermanent() && this.remainingSeconds() <= 0);
  timerHours = computed(() => this.format2(Math.floor(this.remainingSeconds() / 3600)));
  timerMinutes = computed(() => this.format2(Math.floor((this.remainingSeconds() % 3600) / 60)));
  timerSecondsDisplay = computed(() => this.format2(this.remainingSeconds() % 60));
  ringStyle = computed(() => {
    if (this.isPermanent()) return 'conic-gradient(var(--sec) 0 360deg)';
    const remaining = this.remainingSeconds();
    const duration = this.durationSeconds();
    if (remaining <= 0) return 'conic-gradient(var(--ring-empty) 0 360deg)';
    const pct = duration > 0 ? Math.max(0, Math.min(1, remaining / duration)) : 1;
    const deg = Math.round(pct * 360);
    return `conic-gradient(var(--sec) 0 ${deg}deg, var(--ring-empty) ${deg}deg 360deg)`;
  });

  temporaryGroups = computed(() => this.buildGroups('temporary'));
  alwaysGroups = computed(() => this.buildGroups('always').filter(g => g.group !== 'system'));
  systemGroup = computed(() => this.buildGroups('always').find(g => g.group === 'system') ?? null);

  constructor() {
    if (isPlatformBrowser(this.platformId)) {
      const tick = setInterval(() => this.now.set(Math.floor(Date.now() / 1000)), 1000);
      this.destroyRef.onDestroy(() => clearInterval(tick));
    }
    // When the container input is (re)set: reload policies + grant + root grant.
    effect(() => {
      const container = this.container();
      this.grantUntil.set(null);
      this.durationSeconds.set(0);
      this.policies.set({});
      this.rootUntil.set(null);
      if (container) {
        this.loadPolicies(container);
        this.loadRootGrant(container);
      }
    });
  }

  ngOnInit(): void {
    this.api.getDockerActionCatalog().subscribe({
      next: (res) => this.catalog.set(res.actions),
      error: (e) => this.error.set(`Could not load the action catalog: ${e.message}`),
    });
    // Keep the timer in sync with server pushes (WS/poll). Deliberately in
    // ngOnInit and not in the constructor: grants$ is a BehaviorSubject that
    // emits synchronously on subscribe, and the required input `container` only
    // has a value after the first binding (reading it in the constructor throws NG0950).
    this.state.grants$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(grants => {
        const c = this.container();
        if (!c) return;
        this.grantUntil.set(grants[c]?.until ?? null);
      });
  }

  private loadPolicies(container: string): void {
    this.policiesLoading.set(true);
    this.api.getDockerActionPolicies(container).subscribe({
      next: (res) => {
        this.policies.set(res.policies);
        this.grantUntil.set(res.grant?.until ?? null);
        const stored = this.getStoredDuration(container);
        const remaining = res.grant ? Math.max(0, res.grant.until - Math.floor(Date.now() / 1000)) : 0;
        this.durationSeconds.set(stored ?? remaining);
        this.policiesLoading.set(false);
      },
      error: (e) => {
        this.policiesLoading.set(false);
        this.error.set(`Could not load permissions for ${container}: ${e.message}`);
      },
    });
  }

  isEnabled(def: DockerActionDef): boolean {
    return this.policies()[def.action] ?? def.defaultEnabled;
  }

  toggleAction(def: DockerActionDef): void {
    const container = this.container();
    if (!container) return;
    const current = this.isEnabled(def);
    const next = !current;
    // Optimistic update; roll back on error.
    this.policies.update(p => ({ ...p, [def.action]: next }));
    this.api.setDockerActionPolicy(container, def.action, next).subscribe({
      error: (e) => {
        this.policies.update(p => ({ ...p, [def.action]: current }));
        this.error.set(`Could not save '${def.label}' (${def.action}): ${e.message}`);
      },
    });
  }

  // ── Timer ────────────────────────────────────────────────────────────────────
  setTimer(minutes: number): void {
    const container = this.container();
    if (!container) return;
    this.api.setGrant(container, minutes).subscribe({
      next: (grant) => {
        this.grantUntil.set(grant.until);
        this.durationSeconds.set(minutes * 60);
        this.setStoredDuration(container, minutes * 60);
        this.state.loadAll();
      },
      error: (e) => this.error.set(`Could not set the timer: ${e.message}`),
    });
  }

  setPermanentTimer(): void {
    const container = this.container();
    if (!container) return;
    this.api.setGrant(container, 0, true).subscribe({
      next: (grant) => {
        this.grantUntil.set(grant.until);
        this.durationSeconds.set(0);
        this.state.loadAll();
      },
      error: (e) => this.error.set(`Could not set a permanent grant: ${e.message}`),
    });
  }

  stopTimer(): void {
    const container = this.container();
    if (!container) return;
    this.api.deleteGrant(container).subscribe({
      next: () => {
        this.grantUntil.set(null);
        this.state.loadAll();
      },
      error: (e) => this.error.set(`Could not stop the timer: ${e.message}`),
    });
  }

  // ── Root access ──────────────────────────────────────────────────────────────
  private loadRootGrant(container: string): void {
    this.api.getRootGrant(container).subscribe({
      next: (g) => this.rootUntil.set(g.until > 0 ? g.until : null),
      error: () => this.rootUntil.set(null),
    });
  }

  setRoot(minutes: number): void {
    const container = this.container();
    if (!container) return;
    this.api.setRootGrant(container, minutes).subscribe({
      next: (g) => this.rootUntil.set(g.until),
      error: (e) => this.error.set(`Could not grant root access: ${e.message}`),
    });
  }

  setRootPermanent(): void {
    const container = this.container();
    if (!container) return;
    this.api.setRootGrant(container, 0, true).subscribe({
      next: (g) => this.rootUntil.set(g.until),
      error: (e) => this.error.set(`Could not grant permanent root access: ${e.message}`),
    });
  }

  revokeRoot(): void {
    const container = this.container();
    if (!container) return;
    this.api.deleteRootGrant(container).subscribe({
      next: () => this.rootUntil.set(null),
      error: (e) => this.error.set(`Could not revoke root access: ${e.message}`),
    });
  }

  dismissError(): void {
    this.error.set(null);
  }

  actionIcon(action: string): string {
    return ACTION_ICONS[action] ?? 'gear';
  }

  private buildGroups(kind: DockerActionKind): ActionGroupVm[] {
    const actions = this.catalog().filter(a => a.kind === kind);
    const groups: ActionGroupVm[] = [];
    for (const group of GROUP_ORDER) {
      const groupActions = actions.filter(a => a.group === group);
      if (groupActions.length === 0) continue;
      const meta = GROUP_META[group];
      groups.push({
        group,
        title: meta.title,
        subtitle: kind === 'temporary' ? meta.tempSubtitle : meta.alwaysSubtitle,
        colorClass: meta.colorClass,
        iconId: meta.iconId,
        actions: groupActions,
      });
    }
    return groups;
  }

  private format2(value: number): string {
    return String(value).padStart(2, '0');
  }

  private getStoredDuration(container: string): number | null {
    if (!isPlatformBrowser(this.platformId)) return null;
    const raw = localStorage.getItem(DURATION_STORE_PREFIX + container);
    const parsed = raw ? Number(raw) : NaN;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  }

  private setStoredDuration(container: string, seconds: number): void {
    if (!isPlatformBrowser(this.platformId)) return;
    localStorage.setItem(DURATION_STORE_PREFIX + container, String(seconds));
  }
}
