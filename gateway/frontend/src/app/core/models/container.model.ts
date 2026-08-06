import { Rule } from './rule.model';
import { Grant } from './grant.model';

export type ContainerStatus = 'running' | 'stopped' | 'rogue';

export interface Container {
  id: string;
  name: string;
  image: string;
  status: string;
  created: number;
  workspacePath?: string;
  presentableName?: string;
  inNetwork?: boolean;
  huddleInNetwork?: boolean;
  /** Sysbox-modus: de uid-shift ontbreekt, dus de image staat binnenin op
   *  nobody:nogroup (geen sudo, geen apt). Herstarten helpt niet; de engine host
   *  repareert dit met huddle-sysbox-repair (normaal automatisch bij elke boot). */
  needsRepair?: boolean;
  ipAddress?: string;
  securityScore?: number;
  labels?: Record<string, string>;
  Labels?: Record<string, string>;
  airlocked?: boolean;
}

export interface ContainerDetail extends Container {
  rules: Rule[];
  globalRules: Rule[];
  grant?: Grant;
  huddleInNetwork?: boolean;
}

export interface DockerImage {
  id: string;
  name: string;
  tag: string;
  size: number;
  created: number;
  ide?: 'rider' | 'intellij';
}
