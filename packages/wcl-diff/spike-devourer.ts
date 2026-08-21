/**
 * Spike: Compare Soguhunts (Devourer DH) against top parses
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

  // --- 1. Discover what WCL calls Devourer DH ---
  console.log("=== 1. Finding spec name for Devourer DH in WCL ===\n");

  // Try different specName values
  const specNames = ["Devourer", "Havoc", "Vengeance", "DemonHunter"];
  const testEncounter = 3306; // Chimaerus
  const testDifficulty = 3;  // Normal

  for (const specName of specNames) {
    try {
      const result = await gql(token, `
        query TestSpec($enc: Int!, $diff: Int!, $spec: String!) {
          worldData {
            encounter(id: $enc) {
              characterRankings(difficulty: $diff, className: "DemonHunter", specName: $spec, page: 1)
            }
          }
        }
      `, { enc: testEncounter, diff: testDifficulty, spec: specName });
      const data = result.worldData.encounter.characterRankings;
      const count = data?.rankings?.length || 0;
      const hasMore = data?.hasMorePages;
      console.log(`  DemonHunter/${specName}: ${count} entries on page 1, hasMore=${hasMore}`);
      if (count > 0) {
        console.log(`    First entry: ${data.rankings[0].name} — ${Math.round(data.rankings[0].amount)} DPS, specID would be in combatantInfo`);
      }
    } catch (e: any) {
      console.log(`  DemonHunter/${specName}: ERROR — ${e.message.slice(0, 150)}`);
    }
  }

  // --- 2. Get Soguhunts' data ---
  console.log("\n=== 2. Soguhunts' data ===\n");

  const fightsResult = await gql(token, `
    query Fights($code: String!) {
      reportData {
        report(code: $code) {
          fights(killType: Kills) {
            id
            name
            encounterID
            difficulty
            startTime
            endTime
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
  const sogu = report.masterData.actors.find((a: any) => a.name === "Soguhunts");
  console.log(`Soguhunts: sourceID=${sogu.id}, subType=${sogu.subType}`);

  // Get data for each kill fight
  for (const fight of report.fights) {
    const fightDuration = fight.endTime - fight.startTime;
    console.log(`\n--- ${fight.name} (${(fightDuration / 1000).toFixed(0)}s) ---`);

    // Combatant info
    const ciResult = await gql(token, `
      query CI($code: String!, $fightId: Int!, $sourceId: Int!) {
        reportData {
          report(code: $code) {
            events(fightIDs: [$fightId], sourceID: $sourceId, dataType: CombatantInfo, limit: 1) {
              data
            }
          }
        }
      }
    `, { code: reportCode, fightId: fight.id, sourceId: sogu.id });
    const ci = ciResult.reportData.report.events.data[0];

    // DPS summary
    const dmgResult = await gql(token, `
      query Damage($code: String!, $fightId: Int!, $sourceId: Int!) {
        reportData {
          report(code: $code) {
            table(fightIDs: [$fightId], sourceID: $sourceId, dataType: DamageDone)
          }
        }
      }
    `, { code: reportCode, fightId: fight.id, sourceId: sogu.id });
    const dmgTable = dmgResult.reportData.report.table?.data;

    if (dmgTable) {
      const totalDmg = dmgTable.totalTime ? undefined : dmgTable.entries?.reduce((sum: number, e: any) => sum + (e.total || 0), 0);
      const dps = totalDmg ? Math.round(totalDmg / (fightDuration / 1000)) : "N/A";
      console.log(`  DPS: ${dps}`);

      // Top abilities
      if (dmgTable.entries) {
        const sorted = dmgTable.entries.sort((a: any, b: any) => (b.total || 0) - (a.total || 0));
        console.log(`  Top abilities:`);
        for (const entry of sorted.slice(0, 8)) {
          const pct = totalDmg ? ((entry.total / totalDmg) * 100).toFixed(1) : "?";
          console.log(`    ${entry.name}: ${pct}% (${Math.round(entry.total / (fightDuration / 1000))} DPS)`);
        }
      }
    }

    // Stats
    if (ci) {
      const gear = ci.gear?.filter((g: any) => g.itemLevel > 0) || [];
      const avgIlvl = gear.length > 0 ? Math.round(gear.reduce((s: number, g: any) => s + g.itemLevel, 0) / gear.length) : 0;
      console.log(`  Avg ilvl: ${avgIlvl}`);
      console.log(`  Crit: ${ci.critMelee}, Haste: ${ci.hasteMelee}, Mastery: ${ci.mastery}, Vers: ${ci.versatilityDamageDone}`);
      console.log(`  Agility: ${ci.agility}`);
      console.log(`  Talents: ${ci.talentTree?.length || 0} nodes selected`);
    }

    // Now find top parses for this encounter
    console.log(`\n  --- Top ranked DH parses for ${fight.name} ---`);

    // Try all spec names to find which one has Devourer data
    let bestSpecName = "";
    let bestRankings: any = null;

    for (const specName of ["Devourer", "Havoc", "Vengeance"]) {
      try {
        const rankResult = await gql(token, `
          query Rankings($enc: Int!, $diff: Int!, $spec: String!) {
            worldData {
              encounter(id: $enc) {
                characterRankings(difficulty: $diff, className: "DemonHunter", specName: $spec, page: 1)
              }
            }
          }
        `, { enc: fight.encounterID, diff: fight.difficulty, spec: specName });

        const rankings = rankResult.worldData.encounter.characterRankings;
        if (rankings?.rankings?.length > 0) {
          console.log(`  [${specName}] ${rankings.rankings.length} entries, top DPS: ${Math.round(rankings.rankings[0].amount)}`);
          if (!bestRankings || specName === "Devourer") {
            bestSpecName = specName;
            bestRankings = rankings;
          }
        }
      } catch {}
    }

    if (bestRankings?.rankings?.length > 0) {
      // Grab the top parse and fetch their combatantInfo for comparison
      const topParse = bestRankings.rankings[0];
      console.log(`\n  Top ${bestSpecName} parse: ${topParse.name}-${topParse.server.name} — ${Math.round(topParse.amount)} DPS (${(topParse.duration / 1000).toFixed(0)}s)`);

      // Fetch top player's combatantInfo
      try {
        // First get their sourceID from the report
        const topReport = await gql(token, `
          query TopReport($code: String!) {
            reportData {
              report(code: $code) {
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
        `, { code: topParse.report.code });

        const topPlayer = topReport.reportData.report.masterData.actors.find(
          (a: any) => a.name.toLowerCase() === topParse.name.toLowerCase()
        );

        if (topPlayer) {
          const topCI = await gql(token, `
            query TopCI($code: String!, $fightId: Int!, $sourceId: Int!) {
              reportData {
                report(code: $code) {
                  events(fightIDs: [$fightId], sourceID: $sourceId, dataType: CombatantInfo, limit: 1) {
                    data
                  }
                }
              }
            }
          `, { code: topParse.report.code, fightId: topParse.report.fightID, sourceId: topPlayer.id });

          const topInfo = topCI.reportData.report.events.data[0];
          if (topInfo) {
            const topGear = topInfo.gear?.filter((g: any) => g.itemLevel > 0) || [];
            const topAvgIlvl = topGear.length > 0 ? Math.round(topGear.reduce((s: number, g: any) => s + g.itemLevel, 0) / topGear.length) : 0;
            console.log(`  Top player ilvl: ${topAvgIlvl}`);
            console.log(`  Top player stats — Crit: ${topInfo.critMelee}, Haste: ${topInfo.hasteMelee}, Mastery: ${topInfo.mastery}, Vers: ${topInfo.versatilityDamageDone}`);
            console.log(`  Top player specID: ${topInfo.specID}`);
            console.log(`  Top player talents: ${topInfo.talentTree?.length || 0} nodes`);

            // Talent diff
            if (ci?.talentTree && topInfo.talentTree) {
              const myNodes = new Set(ci.talentTree.map((t: any) => t.nodeID));
              const topNodes = new Set(topInfo.talentTree.map((t: any) => t.nodeID));

              const missing = topInfo.talentTree.filter((t: any) => !myNodes.has(t.nodeID));
              const extra = ci.talentTree.filter((t: any) => !topNodes.has(t.nodeID));

              console.log(`\n  Talent diff vs #1 parse:`);
              console.log(`    You have ${ci.talentTree.length} nodes, they have ${topInfo.talentTree.length} nodes`);
              console.log(`    Missing (they have, you don't): ${missing.length} nodes`);
              for (const m of missing) {
                console.log(`      nodeID=${m.nodeID}, spellID=${m.id}, rank=${m.rank}`);
              }
              console.log(`    Extra (you have, they don't): ${extra.length} nodes`);
              for (const e of extra) {
                console.log(`      nodeID=${e.nodeID}, spellID=${e.id}, rank=${e.rank}`);
              }
            }

            // Top parse damage breakdown
            const topDmg = await gql(token, `
              query TopDmg($code: String!, $fightId: Int!, $sourceId: Int!) {
                reportData {
                  report(code: $code) {
                    table(fightIDs: [$fightId], sourceID: $sourceId, dataType: DamageDone)
                  }
                }
              }
            `, { code: topParse.report.code, fightId: topParse.report.fightID, sourceId: topPlayer.id });

            const topDmgTable = topDmg.reportData.report.table?.data;
            if (topDmgTable?.entries) {
              const topTotalDmg = topDmgTable.entries.reduce((sum: number, e: any) => sum + (e.total || 0), 0);
              const topSorted = topDmgTable.entries.sort((a: any, b: any) => (b.total || 0) - (a.total || 0));
              console.log(`\n  Top parse ability breakdown:`);
              for (const entry of topSorted.slice(0, 8)) {
                const pct = ((entry.total / topTotalDmg) * 100).toFixed(1);
                console.log(`    ${entry.name}: ${pct}% (${Math.round(entry.total / (topParse.duration / 1000))} DPS)`);
              }
            }
          }
        }
      } catch (e: any) {
        console.log(`  Could not fetch top parse details: ${e.message.slice(0, 200)}`);
      }
    }

    // Only do first boss to keep API usage reasonable
    break;
  }

  console.log("\n=== Done ===");
}

main().catch((err) => {
  console.error("Failed:", err);
  process.exit(1);
});
