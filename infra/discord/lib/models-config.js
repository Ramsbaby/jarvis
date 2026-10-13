/**
 * models-config.js — read the runtime config/models.json.
 *
 * A fresh clone has no runtime copy (only infra/config/models.example.json), so fall back
 * to the example file and say so once instead of crashing at import time.
 */

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXAMPLE_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'config', 'models.example.json');
let _warned = false;

export function loadModelsConfig(botHome) {
  const runtimePath = join(botHome, 'config', 'models.json');
  if (existsSync(runtimePath)) return JSON.parse(readFileSync(runtimePath, 'utf-8'));
  if (!_warned) {
    _warned = true;
    console.warn(`[models-config] ${runtimePath} not found — falling back to ${EXAMPLE_PATH}`);
  }
  return JSON.parse(readFileSync(EXAMPLE_PATH, 'utf-8'));
}
