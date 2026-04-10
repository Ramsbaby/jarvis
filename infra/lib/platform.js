/**
 * lib/platform.js — Cross-platform abstraction layer
 * Provides OS-agnostic paths and utilities for macOS/Linux/Windows support.
 */

import os from 'os'
import path from 'path'

export const IS_WINDOWS = os.platform() === 'win32'
export const IS_MAC     = os.platform() === 'darwin'
export const IS_LINUX   = os.platform() === 'linux'

/**
 * JARVIS_HOME resolution order:
 * 1. $JARVIS_HOME env var (Docker / CI / custom installs)
 * 2. ~/.jarvis (macOS, Linux, WSL2)
 * 3. %USERPROFILE%\.jarvis (Windows native)
 */
export const JARVIS_HOME = process.env.JARVIS_HOME
  ?? path.join(os.homedir(), '.jarvis')

export const LOGS_DIR    = path.join(JARVIS_HOME, 'logs')
export const INBOX_DIR   = path.join(JARVIS_HOME, 'inbox')
export const RAG_DIR     = path.join(JARVIS_HOME, 'rag')
export const SCRIPTS_DIR = path.join(JARVIS_HOME, 'scripts')

/**
 * Returns the correct shell + flag for the current platform.
 * Windows: uses WSL2 bash if available, else throws.
 */
export function getShell() {
  if (IS_WINDOWS) {
    return { shell: 'wsl', flag: 'bash -c' }
  }
  return { shell: '/bin/bash', flag: '-c' }
}

/**
 * Normalizes a legacy hard-coded path to use JARVIS_HOME.
 * e.g. ~/.jarvis/logs → <JARVIS_HOME>/logs
 */
export function normalizePath(legacyPath) {
  return legacyPath.replace(/\/Users\/[^/]+\/\.jarvis/, JARVIS_HOME)
}
