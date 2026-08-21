/**
 * Spike part 2: Test report fetching + find total rankings count
 * Using Soguhunts from report 8Kc4qgA3BDhLTQtJ
 */

import { readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const envContent = readFileSync(resolve(__dirname, ".env"), "utf-8");
for (const line of envContent.split("\n")) {
  const match = line.match(/^(\w+)=(.*)$/);
  if (match) process.env[match[1]] = match[2];
}

const TOKEN_URL = "https://www.warcraftlogs.com/oauth/token";
const GQL_URL = "https://www.warcraftlogs.com/api/v2/client";

async function getToken(): Promise<string> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: process.env.WCL_CLIENT_ID!,
      client_secret: process.env.WCL_CLIENT_SECRET!,
    }),
  });
  if (!res.ok) throw new Error(`Auth failed: ${res.status}`);
  return (await res.json()).access_token;
}

async function gql(token: string, query: string, variables?: Record<string, unknown>) {
  const res = await fetch(GQL_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`WCL API: ${res.status} ${await res.text()}`);
  const data = await res.json();
  if (data.errors) throw new Error(`GQL: ${JSON.stringify(data.errors, null, 2)}`);
  return data.data;
}

async function main() {
  const token = await getToken();
  const reportCode = "8Kc4qgA3BDhLTQtJ";

  // --- 1. Fetch report fights ---
  console.log("=== 1. Report fights ===");
  const fightsResult = await gql(token, `
    query Fights($code: String!) {
      reportData {
        report(code: $code) {
          title
          fights(killType: Kills) {
            id
            name
            encounterID
            difficulty
            kill
            startTime
            endTime
            friendlyPlayers
          }
          masterData {
            actors(type: "Player") {
              id
              name
              server
              subType
            }
          }
        }
      }
    }
  `, { code: reportCode });

  const report = fightsResult.reportData.report;
  console.log(`Report: ${report.title}`);
  console.log(`Kill fights: ${report.fights.length}`);

  for (const f of report.fights) {
    console.log(`  Fight ${f.id}: ${f.name} (enc=${f.encounterID}, diff=${f.difficulty}, kill=${f.kill})`);
  }

  // Find Soguhunts in masterData
  console.log(`\nPlayers in report:`);
  const players = report.masterData.actors;
  for (const p of players) {
    console.log(`  ID=${p.id} ${p.name} (${p.server}) — ${p.subType}`);
  }

  const sogu = players.find((p: any) => p.name.toLowerCase() === "soguhunts");
  if (!sogu) {
    console.log("Soguhunts not found!");
    return;
  }
  console.log(`\nFound Soguhunts: sourceID=${sogu.id}, spec=${sogu.subType}`);

  // Pick the first kill fight
  const fight = report.fights[0];
  console.log(`\nUsing fight: ${fight.name} (ID=${fight.id})`);

  // --- 2. Fetch combatantInfo ---
  console.log("\n=== 2. CombatantInfo ===");
  const combatantResult = await gql(token, `
    query CombatantInfo($code: String!, $fightId: Int!, $sourceId: Int!) {
      reportData {
        report(code: $code) {
          events(
            fightIDs: [$fightId]
            sourceID: $sourceId
            dataType: CombatantInfo
            limit: 1
          ) {
            data
          }
        }
      }
    }
  `, { code: reportCode, fightId: fight.id, sourceId: sogu.id });

  const combatEvents = combatantResult.reportData.report.events.data;
  if (combatEvents.length > 0) {
    const info = combatEvents[0];
    console.log(`specID: ${info.specID}`);
    console.log(`talentTree (first 80 chars): ${JSON.stringify(info.talentTree)?.slice(0, 80)}...`);
    console.log(`gear count: ${info.gear?.length}`);
    if (info.gear?.[0]) {
      console.log(`First gear slot: ${JSON.stringify(info.gear[0])}`);
    }
    // Check for stats
    if (info.stats) {
      console.log(`Stats: ${JSON.stringify(info.stats)}`);
    }
    // Check for talent string
    if (info.talents) {
      console.log(`talents field: ${JSON.stringify(info.talents)?.slice(0, 200)}`);
    }
    // Full dump of keys
    console.log(`\nCombatantInfo keys: ${Object.keys(info).join(", ")}`);
    // Dump the full thing for reference
    console.log(`\nFull combatantInfo:`);
    console.log(JSON.stringify(info, null, 2).slice(0, 3000));
  }

  // --- 3. Find total rankings count by binary search ---
  console.log("\n=== 3. Total rankings count ===");
  const encounterId = fight.encounterID;
  const difficulty = fight.difficulty;

  // Binary search for last page
  let lo = 1, hi = 200;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    const pageResult = await gql(token, `
      query RankingsPage($encounterId: Int!, $difficulty: Int!, $page: Int) {
        worldData {
          encounter(id: $encounterId) {
            characterRankings(
              difficulty: $difficulty
              className: "Hunter"
              specName: "Beast Mastery"
              page: $page
            )
          }
        }
      }
    `, { encounterId, difficulty, page: mid });

    const data = pageResult.worldData.encounter.characterRankings;
    const hasEntries = data?.rankings?.length > 0;
    console.log(`  Page ${mid}: ${hasEntries ? `${data.rankings.length} entries` : "empty"}`);
    if (hasEntries) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }

  console.log(`  Last page with data: ${lo}`);

  // Get the last page to count entries
  const lastPageResult = await gql(token, `
    query RankingsPage($encounterId: Int!, $difficulty: Int!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          characterRankings(
            difficulty: $difficulty
            className: "Hunter"
            specName: "Beast Mastery"
            page: $page
          )
        }
      }
    }
  `, { encounterId, difficulty, page: lo });
  const lastPageData = lastPageResult.worldData.encounter.characterRankings;
  const totalEntries = (lo - 1) * 100 + (lastPageData.rankings?.length || 0);
  console.log(`  Total ranked entries (approx): ${totalEntries}`);

  // Calculate P75 and P95 positions
  const p95Pos = Math.floor(totalEntries * 0.05);
  const p75Pos = Math.floor(totalEntries * 0.25);
  console.log(`  P95 at position: ${p95Pos} (page ${Math.floor(p95Pos / 100) + 1})`);
  console.log(`  P75 at position: ${p75Pos} (page ${Math.floor(p75Pos / 100) + 1})`);

  // Fetch the P75 entry
  const p75Page = Math.floor(p75Pos / 100) + 1;
  const p75Offset = p75Pos % 100;
  const p75Result = await gql(token, `
    query RankingsPage($encounterId: Int!, $difficulty: Int!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          characterRankings(
            difficulty: $difficulty
            className: "Hunter"
            specName: "Beast Mastery"
            page: $page
          )
        }
      }
    }
  `, { encounterId, difficulty, page: p75Page });
  const p75Entry = p75Result.worldData.encounter.characterRankings.rankings?.[p75Offset];
  if (p75Entry) {
    console.log(`\n  ~P75 parse: ${p75Entry.name}-${p75Entry.server.name} — ${Math.round(p75Entry.amount)} DPS, ${(p75Entry.duration / 1000).toFixed(0)}s`);
    console.log(`  report: ${p75Entry.report.code}#fight=${p75Entry.report.fightID}`);
  }

  console.log("\n=== Spike complete ===");
}

main().catch((err) => {
  console.error("Failed:", err);
  process.exit(1);
});
