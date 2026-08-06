import { Component, inject, effect } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ModalService } from '../../../core/services/modal.service';
import { ApiService } from '../../../core/services/api.service';
import { StateService } from '../../../core/services/state.service';
import { AuthService } from '../../../core/services/auth.service';
import { DockerImage } from '../../../core/models/container.model';
import { FmtBytesPipe } from '../../pipes/fmt-bytes.pipe';

@Component({
  selector: 'app-start-container-modal',
  standalone: true,
  imports: [FormsModule, FmtBytesPipe],
  templateUrl: './start-container-modal.component.html',
  styles: [`
    .mount-warning {
      margin: 8px 0 4px;
      padding: 10px 12px;
      border-radius: 8px;
      background: var(--warning-soft);
      border: 1px solid color-mix(in srgb, var(--warning) 35%, transparent);
      color: var(--text);
      font-size: 12.5px;
      line-height: 1.5;
    }
    .mount-warning strong { display: block; color: var(--warning); margin-bottom: 2px; }
    .mount-warning__extra {
      display: block;
      margin-top: 8px;
      padding-top: 8px;
      border-top: 1px solid color-mix(in srgb, var(--warning) 25%, transparent);
    }
    .mount-warning code {
      font-family: var(--font-mono, monospace);
      font-size: 12px;
      padding: 0 3px;
      border-radius: 3px;
      background: color-mix(in srgb, var(--warning) 18%, transparent);
    }
  `]
})
export class StartContainerModalComponent {
  modalService = inject(ModalService);
  private api = inject(ApiService);
  private state = inject(StateService);
  private auth = inject(AuthService);

  images: DockerImage[] = [];
  baseImage = '';
  selectedImage = '';
  ide: 'rider' | 'intellij' | 'vscode' = 'intellij';
  workspace = '';
  containerName = '';
  nameTouched = false;
  // Standaard leeg: een devcontainer zonder host-map is de veilige keuze. Een
  // bind mount is een gat in de sandbox, dus dat hoort een bewuste actie te zijn
  // en niet de default.
  empty = true;
  error = '';
  status = '';
  loading = false;

  get open() { return this.modalService.startOpen(); }

  constructor() {
    effect(() => {
      if (this.modalService.startOpen()) {
        this.onOpen();
      }
    });
  }

  onOpen(): void {
    this.selectedImage = '';
    this.ide = 'intellij';
    this.workspace = '';
    this.nameTouched = false;
    this.empty = true;
    this.containerName = 'devcontainer-empty';
    this.error = '';
    this.status = '';
    this.loading = false;
    this.loadImagesForIde();
  }

  // The IDE choice drives both the default base image and the snapshot filter.
  // Both endpoints are now IDE-specific; this method fetches them again.
  onIdeChange(): void {
    this.selectedImage = '';
    this.loadImagesForIde();
  }

  private loadImagesForIde(): void {
    this.api.getImages(this.ide).subscribe({ next: imgs => { this.images = imgs; }, error: () => {} });
    this.api.getBaseImage(this.ide).subscribe({
      next: b => { this.baseImage = b.imageName; if (!this.selectedImage) this.selectedImage = b.imageName; },
      error: () => { this.baseImage = ''; }
    });
  }

  /** Sysbox-modus: alleen dan kan een map van een Windows-schijf binnenin op
   *  nobody uitkomen (drvfs kan niet ID-mapped worden). */
  get sysboxMode(): boolean { return this.auth.privateDaemon(); }

  /** C:\... of /mnt/c/... - een pad dat op een Windows-schijf staat. */
  get workspaceOnWindowsDrive(): boolean {
    return /^([a-z]:|\/mnt\/[a-z]\/)/i.test(this.workspace.trim());
  }

  onWorkspaceInput(): void {
    if (!this.nameTouched) {
      const leaf = this.workspace.replace(/\\/g, '/').split('/').filter(Boolean).pop() ?? '';
      this.containerName = leaf ? `devcontainer-${leaf}` : '';
    }
  }

  onEmptyToggle(): void {
    if (this.empty) {
      this.workspace = '';
      if (!this.nameTouched) { this.containerName = 'devcontainer-empty'; }
    } else if (!this.nameTouched) {
      // De naam kwam van de lege-default; laat hem weer volgen uit de workspace.
      this.containerName = '';
    }
  }

  confirm(): void {
    if (!this.selectedImage || !this.containerName || (!this.empty && !this.workspace)) {
      this.error = 'All fields are required'; return;
    }
    this.error = '';
    this.loading = true;
    this.status = 'Starting container…';
    this.api.startContainer({
      image: this.selectedImage,
      ide: this.ide,
      workspace: this.workspace,
      containerName: this.containerName,
      empty: this.empty,
    }).subscribe({
      next: () => { this.loading = false; this.modalService.closeStart(); this.state.loadAll(); },
      error: (err) => { this.error = err.message; this.status = ''; this.loading = false; },
    });
  }

  close(): void { this.modalService.closeStart(); }
}
