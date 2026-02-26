#!/usr/bin/env bun
/**
 * Refreshes the Kimi OAuth access token using the refresh token.
 * Run before Smithers workflows to ensure the 15-minute access token is fresh.
 *
 * Usage:
 *   bun workflow/kimi-refresh.ts          # refresh once
 *   bun workflow/kimi-refresh.ts --daemon  # refresh every 10 minutes (background)
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const SHARE_DIR = process.env.KIMI_SHARE_DIR ?? join(homedir(), ".kimi");
const CREDS_PATH = join(SHARE_DIR, "credentials", "kimi-code.json");
const DEVICE_ID_PATH = join(SHARE_DIR, "device_id");
const CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098";
const AUTH_HOST = "https://auth.kimi.com";
const REFRESH_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes (tokens last 15)

function getDeviceId(): string {
  return readFileSync(DEVICE_ID_PATH, "utf8").trim();
}

function loadCredentials(): { access_token: string; refresh_token: string; expires_at: number; scope: string; token_type: string } {
  return JSON.parse(readFileSync(CREDS_PATH, "utf8"));
}

function saveCredentials(creds: Record<string, unknown>) {
  writeFileSync(CREDS_PATH, JSON.stringify(creds, null, 2), { mode: 0o600 });
}

async function refreshToken(): Promise<boolean> {
  const creds = loadCredentials();
  const now = Date.now() / 1000;
  const remaining = (creds.expires_at ?? 0) - now;

  if (remaining > 120) {
    console.log(`[kimi-refresh] Token still valid for ${(remaining / 60).toFixed(0)} minutes, skipping`);
    return true;
  }

  console.log(`[kimi-refresh] Token expires in ${(remaining / 60).toFixed(0)} minutes, refreshing...`);

  const deviceId = getDeviceId();
  const res = await fetch(`${AUTH_HOST}/api/oauth/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "X-Msh-Platform": "kimi_cli",
      "X-Msh-Version": "1.12.0",
      "X-Msh-Device-Id": deviceId,
    },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      grant_type: "refresh_token",
      refresh_token: creds.refresh_token,
    }),
  });

  const data = await res.json() as Record<string, unknown>;

  if (!res.ok || !data.access_token) {
    console.error(`[kimi-refresh] Failed to refresh:`, data);
    return false;
  }

  // Normalize expires_at
  if (!data.expires_at && typeof data.expires_in === "number") {
    data.expires_at = Date.now() / 1000 + (data.expires_in as number);
  }

  saveCredentials(data);
  const newRemaining = ((data.expires_at as number) - Date.now() / 1000) / 60;
  console.log(`[kimi-refresh] Token refreshed, valid for ${newRemaining.toFixed(0)} minutes`);
  return true;
}

async function main() {
  if (!existsSync(CREDS_PATH)) {
    console.error(`[kimi-refresh] No credentials found at ${CREDS_PATH}. Run 'kimi login' first.`);
    process.exit(1);
  }

  const isDaemon = process.argv.includes("--daemon");

  const ok = await refreshToken();
  if (!ok) process.exit(1);

  if (isDaemon) {
    console.log(`[kimi-refresh] Daemon mode: refreshing every ${REFRESH_INTERVAL_MS / 60000} minutes`);
    setInterval(async () => {
      try {
        await refreshToken();
      } catch (err) {
        console.error("[kimi-refresh] Refresh error:", err);
      }
    }, REFRESH_INTERVAL_MS);
  }
}

main();
