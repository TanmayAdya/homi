import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { createScfhpEaaResearchProgram } from './scfhp-eaa.ts';
import { createScfhpEaaFormTemplate } from '../forms/scfhp-eaa-template.ts';
import { createHpsmEaaFormTemplate } from '../forms/hpsm-eaa-template.ts';
import { createRtpHomeRepairFormTemplate } from '../forms/rtp-home-repair-template.ts';
import { createHpsmEaaResearchProgram, createRtpResearchProgram } from './team-beta.ts';
import { createFederalPreparationPrograms } from './federal-preparation.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../forms/template-artifact.ts';
import type { VerifiedFormTemplate } from '../forms/field-mapping.ts';
import type { ProgramDefinition } from '../types.ts';

export type BenefitsBundleName = 'disabled' | 'scfhp-eaa-draft-v1' | 'team-beta-drafts-v2' | 'nationwide-preparation-v1'
  | 'team-beta-with-nationwide-v1';

export interface RuntimeBenefitsBundle {
  readonly name: BenefitsBundleName;
  readonly enabled: boolean;
  loadRegistry(): Promise<ProgramDefinition[]>;
  loadFormTemplate(programId: string): Promise<{ template: VerifiedFormTemplate; bytes: Uint8Array } | null>;
}

export interface RuntimeBundleDependencies {
  readTemplateBytes?: () => Promise<Uint8Array>;
}

export class BenefitsBundleConfigurationError extends Error {
  constructor() {
    super('Benefits bundle configuration is unavailable or invalid.');
    this.name = 'BenefitsBundleConfigurationError';
  }
}

function bundleName(value: unknown): BenefitsBundleName {
  if (value === 'disabled' || value === 'scfhp-eaa-draft-v1' || value === 'team-beta-drafts-v2'
    || value === 'nationwide-preparation-v1' || value === 'team-beta-with-nationwide-v1') return value;
  throw new BenefitsBundleConfigurationError();
}

export function benefitsBundleNameFromEnvironment(env: NodeJS.ProcessEnv): BenefitsBundleName {
  return bundleName(env.SAFEATHOME_BENEFITS_BUNDLE ?? 'disabled');
}

async function readTemplateBytes(filename = 'scfhp-41567.pdf'): Promise<Uint8Array> {
  const handle = await open(new URL(`../../assets/forms/${filename}`, import.meta.url),
    constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 8 || stat.size > MAX_TEMPLATE_BYTES) {
      throw new BenefitsBundleConfigurationError();
    }
    const buffer = Buffer.alloc(MAX_TEMPLATE_BYTES + 1);
    let size = 0;
    while (size < buffer.length) {
      const result = await handle.read(buffer, size, buffer.length - size, size);
      if (result.bytesRead === 0) break;
      size += result.bytesRead;
    }
    if (size < 8 || size > MAX_TEMPLATE_BYTES) throw new BenefitsBundleConfigurationError();
    return Uint8Array.from(buffer.subarray(0, size));
  } finally { await handle.close(); }
}

export async function loadRuntimeBenefitsBundle(
  name: BenefitsBundleName, dependencies: RuntimeBundleDependencies = {},
): Promise<RuntimeBenefitsBundle> {
  try {
    const selected = bundleName(name);
    if (selected === 'disabled') {
      return Object.freeze({ name: selected, enabled: false,
        loadRegistry: async () => [], loadFormTemplate: async () => null });
    }
    if (selected === 'nationwide-preparation-v1') {
      const programs = createFederalPreparationPrograms();
      return Object.freeze({ name: selected, enabled: true,
        loadRegistry: async () => structuredClone(programs), loadFormTemplate: async () => null });
    }
    const read = dependencies.readTemplateBytes ?? readTemplateBytes;
    if (typeof read !== 'function') throw new BenefitsBundleConfigurationError();
    const program = structuredClone(createScfhpEaaResearchProgram());
    const template = structuredClone(createScfhpEaaFormTemplate());
    if (program.programId !== 'scfhp-eaa' || program.isDemo !== false || program.rulesVerified !== false
      || program.availability !== 'unverified' || program.recheckAfter !== null
      || template.programId !== program.programId) throw new BenefitsBundleConfigurationError();
    const loaded = await read();
    if (!(loaded instanceof Uint8Array) || loaded.byteLength < 8 || loaded.byteLength > MAX_TEMPLATE_BYTES) {
      throw new BenefitsBundleConfigurationError();
    }
    const bytes = Uint8Array.from(loaded);
    verifyTemplateBytes(bytes, template.templateSha256);
    const entries = [{ program, template, bytes }];
    const withNationwide = selected === 'team-beta-with-nationwide-v1';
    if (selected === 'team-beta-drafts-v2' || withNationwide) {
      for (const item of [
        { program: createHpsmEaaResearchProgram(), template: createHpsmEaaFormTemplate(), filename: 'hpsm-eaa-inert.pdf' },
        { program: createRtpResearchProgram(), template: createRtpHomeRepairFormTemplate(), filename: 'rtp-preparation-worksheet.pdf' },
      ]) {
        const extraBytes = await readTemplateBytes(item.filename);
        verifyTemplateBytes(extraBytes, item.template.templateSha256);
        entries.push({ program: item.program, template: item.template, bytes: Uint8Array.from(extraBytes) });
      }
    }
    const federal = withNationwide ? createFederalPreparationPrograms() : [];
    return Object.freeze({ name: selected, enabled: true,
      loadRegistry: async () => [...entries.map(item => item.program), ...federal].map(program => structuredClone(program)),
      loadFormTemplate: async (programId: string) => {
        const item = entries.find(item => item.program.programId === programId);
        return item ? { template: structuredClone(item.template), bytes: Uint8Array.from(item.bytes) } : null;
      },
    });
  } catch {
    throw new BenefitsBundleConfigurationError();
  }
}
