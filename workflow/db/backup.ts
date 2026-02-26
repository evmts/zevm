import { existsSync, mkdirSync, copyFileSync, readdirSync, statSync, unlinkSync } from "fs";
import { join } from "path";

export function backupDb(dbFile: string, backupDir: string, maxBackups = 10) {
  if (!existsSync(dbFile)) return;

  mkdirSync(backupDir, { recursive: true });
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const backupFile = join(backupDir, `zevm-build-${timestamp}.db`);
  copyFileSync(dbFile, backupFile);

  // Keep only the last N backups
  const backups = readdirSync(backupDir)
    .filter((f) => f.startsWith("zevm-build-") && f.endsWith(".db"))
    .map((f) => join(backupDir, f))
    .sort((a, b) => statSync(b).mtime.getTime() - statSync(a).mtime.getTime());

  backups.slice(maxBackups).forEach((f) => unlinkSync(f));

  console.log(`\nBacked up DB to ${backupFile}`);
}
