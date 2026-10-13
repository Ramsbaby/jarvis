/**
 * optional-import.js — load a module that may not ship with this repository.
 *
 * Some owner-only modules (e.g. career-coding-mode.js, interview-fast-path.js) are
 * kept out of the public repo. Callers use importOptional() and fall back to a
 * harmless default when the file is absent.
 *
 * Only a missing file counts as "absent". If the file exists but throws while loading
 * (a real bug, or one of its own dependencies is missing), the error propagates.
 */

import { existsSync } from 'node:fs';

/**
 * @param {string} specifier  relative to this directory, e.g. './career-coding-mode.js'
 * @returns {Promise<object|null>} the module namespace, or null if the file does not exist
 */
export async function importOptional(specifier) {
  const url = new URL(specifier, import.meta.url);
  if (!existsSync(url)) return null;
  return import(url.href);
}
