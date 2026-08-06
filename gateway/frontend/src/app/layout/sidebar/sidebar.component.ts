import { Component, inject, OnInit, signal } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';
import { IconComponent } from '../../shared/components/icon/icon.component';
import { ApiService } from '../../core/services/api.service';
import { AuthService } from '../../core/services/auth.service';
import { Extension } from '../../core/extensions/extension.model';

@Component({
  selector: 'app-sidebar',
  standalone: true,
  imports: [RouterLink, RouterLinkActive, IconComponent],
  templateUrl: './sidebar.component.html',
  styles: []
})
export class SidebarComponent implements OnInit {
  private api = inject(ApiService);
  private auth = inject(AuthService);
  // Verberg 'Docker permissions' zodra de devcontainer een eigen daemon heeft:
  // de per-actie toggles kunnen daar niets afdwingen (sysbox-modus).
  showDockerPermissions = () => !this.auth.privateDaemon();
  extensions = signal<Extension[]>([]);

  ngOnInit(): void {
    this.api.getExtensions().subscribe({ next: (e) => this.extensions.set(e), error: () => {} });
  }
}
