/**
 * Find P75/P95 Devourer DH parses for Chimaerus with fight-length matching
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

const RANKINGS_QUERY = `
  query Rankings($enc: Int!, $diff: Int!, $spec: String!, $page: Int!) {
    worldData {
      encounter(id: $enc) {
        characterRankings(difficulty: $diff, className: "DemonHunter", specName: $spec, page: $page)
      }
    }
  }
`;

async function fetchRankingsPage(token: string, enc: number, diff: number, spec: string, page: number) {
  const result = await gql(token, RANKINGS_QUERY, { enc, diff, spec, page });
  return result.worldData.encounter.characterRankings;
}

async function fetchSourceData(token: string, reportCode: string, fightId: number, playerName: string) {
  // Get masterData to find sourceID
  const reportResult = await gql(token, `
    query Report($code: String!) {
      reportData {
        report(code: $code) {
          fights { id startTime endTime encounterID }
          masterData { actors(type: "Player") { id name server subType } }
        }
      }
    }
  `, { code: reportCode });

  const report = reportResult.reportData.report;
  const player = report.masterData.actors.find(
    (a: any) => a.name.toLowerCase() === playerName.toLowerCase()
  );
  if (!player) return null;

  const fight = report.fights.find((f: any) => f.id === fightId);
  if (!fight) return null;

  // Fetch combatantInfo
  const ciResult = await gql(token, `
    query CI($code: String!, $fightId: Int!, $sourceId: Int!) {
      reportData {
        report(code: $code) {
          events(fightIDs: [$fightId], sourceID: $sourceId, dataType: CombatantInfo, limit: 1) { data }
        }
      }
    }
  `, { code: reportCode, fightId, sourceId: player.id });

  // Fetch damage table
  const dmgResult = await gql(token, `
    query Dmg($code: String!, $fightId: Int!, $sourceId: Int!) {
      reportData {
        report(code: $code) {
          table(fightIDs: [$fightId], sourceID: $sourceId, dataType: DamageDone)
        }
      }
    }
  `, { code: reportCode, fightId, sourceId: player.id });

  const ci = ciResult.reportData.report.events.data[0];
  const dmgTable = dmgResult.reportData.report.table?.data;

  return { ci, dmgTable, fight, player };
}

async function main() {
  const token = await getToken();

  const ENCOUNTER = 3306;  // Chimaerus
  const DIFFICULTY = 3;    // Normal
  const SPEC = "Devourer";
  const MY_DURATION = 651000; // 651s in ms
  const MY_REPORT = "8Kc4qgA3BDhLTQtJ";

  // --- 1. Find total ranked entries ---
  console.log("1. Finding total ranked Devourer parses for Chimaerus Normal...\n");

  let lo = 1, hi = 200;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    const data = await fetchRankingsPage(token, ENCOUNTER, DIFFICULTY, SPEC, mid);
    if (data?.rankings?.length > 0) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  const lastPage = lo;
  const lastPageData = await fetchRankingsPage(token, ENCOUNTER, DIFFICULTY, SPEC, lastPage);
  const lastPageCount = lastPageData?.rankings?.length || 0;
  const totalEntries = (lastPage - 1) * 100 + lastPageCount;

  console.log(`   Total ranked entries: ${totalEntries}`);
  console.log(`   Last page: ${lastPage} (${lastPageCount} entries)\n`);

  if (totalEntries < 20) {
    console.log("Not enough data for meaningful P75/P95 comparison.");
    return;
  }

  // --- 2. Calculate P75 and P95 positions ---
  const p95Pos = Math.floor(totalEntries * 0.05);
  const p75Pos = Math.floor(totalEntries * 0.25);
  const p95Page = Math.floor(p95Pos / 100) + 1;
  const p75Page = Math.floor(p75Pos / 100) + 1;

  console.log(`   P95 position: ${p95Pos} (page ${p95Page})`);
  console.log(`   P75 position: ${p75Pos} (page ${p75Page})\n`);

  // --- 3. Fetch pages around P75 and P95, find best fight-length match ---
  console.log("2. Finding best fight-length matches...\n");

  // Collect candidates around P95
  const p95Candidates: any[] = [];
  for (let p = Math.max(1, p95Page - 1); p <= Math.min(lastPage, p95Page + 1); p++) {
    const data = await fetchRankingsPage(token, ENCOUNTER, DIFFICULTY, SPEC, p);
    if (data?.rankings) {
      for (let i = 0; i < data.rankings.length; i++) {
        const globalIdx = (p - 1) * 100 + i;
        const pct = 100 - (globalIdx / totalEntries) * 100;
        if (Math.abs(pct - 95) <= 5) {
          p95Candidates.push({ ...data.rankings[i], estimatedPercentile: Math.round(pct * 10) / 10 });
        }
      }
    }
  }

  // Collect candidates around P75
  const p75Candidates: any[] = [];
  for (let p = Math.max(1, p75Page - 1); p <= Math.min(lastPage, p75Page + 1); p++) {
    const data = await fetchRankingsPage(token, ENCOUNTER, DIFFICULTY, SPEC, p);
    if (data?.rankings) {
      for (let i = 0; i < data.rankings.length; i++) {
        const globalIdx = (p - 1) * 100 + i;
        const pct = 100 - (globalIdx / totalEntries) * 100;
        if (Math.abs(pct - 75) <= 5) {
          p75Candidates.push({ ...data.rankings[i], estimatedPercentile: Math.round(pct * 10) / 10 });
        }
      }
    }
  }

  console.log(`   P95 candidates: ${p95Candidates.length}`);
  console.log(`   P75 candidates: ${p75Candidates.length}\n`);

  // Pick best fight-length match
  const pickBest = (candidates: any[]) => {
    return candidates.sort((a, b) =>
      Math.abs(a.duration - MY_DURATION) - Math.abs(b.duration - MY_DURATION)
    )[0];
  };

  const p95Match = pickBest(p95Candidates);
  const p75Match = pickBest(p75Candidates);

  if (!p95Match || !p75Match) {
    console.log("Could not find matches.");
    return;
  }

  console.log(`   P95 match: ${p95Match.name}-${p95Match.server.name} — ${Math.round(p95Match.amount)} DPS, ${(p95Match.duration / 1000).toFixed(0)}s, ~${p95Match.estimatedPercentile}th percentile`);
  console.log(`   P75 match: ${p75Match.name}-${p75Match.server.name} — ${Math.round(p75Match.amount)} DPS, ${(p75Match.duration / 1000).toFixed(0)}s, ~${p75Match.estimatedPercentile}th percentile\n`);

  // --- 4. Fetch full data for Soguhunts, P75, P95 ---
  console.log("3. Fetching full data for all three sources...\n");

  // Soguhunts
  const myData = await fetchSourceData(token, MY_REPORT, 8, "Soguhunts");
  // P75
  const p75Data = await fetchSourceData(token, p75Match.report.code, p75Match.report.fightID, p75Match.name);
  // P95
  const p95Data = await fetchSourceData(token, p95Match.report.code, p95Match.report.fightID, p95Match.name);

  if (!myData || !p75Data || !p95Data) {
    console.log("Failed to fetch some source data.");
    console.log(`  myData: ${!!myData}, p75Data: ${!!p75Data}, p95Data: ${!!p95Data}`);
    return;
  }

  // --- 5. Build comparison ---
  console.log("═══════════════════════════════════════════════════════════════");
  console.log(`  Chimaerus  •  Normal  •  Devourer Demon Hunter`);
  console.log("═══════════════════════════════════════════════════════════════\n");

  const myDuration = (myData.fight.endTime - myData.fight.startTime) / 1000;
  const p75Duration = p75Match.duration / 1000;
  const p95Duration = p95Match.duration / 1000;

  // Find my percentile position
  // Fetch page 1 and find where my DPS would rank
  const myTotalDmg = myData.dmgTable?.entries?.reduce((s: number, e: any) => s + (e.total || 0), 0) || 0;
  const myDps = Math.round(myTotalDmg / myDuration);

  // Binary search for my position in rankings
  let myPage = lastPage;
  for (let p = 1; p <= lastPage; p++) {
    const data = await fetchRankingsPage(token, ENCOUNTER, DIFFICULTY, SPEC, p);
    if (data?.rankings) {
      const lastOnPage = data.rankings[data.rankings.length - 1];
      if (lastOnPage.amount <= myDps) {
        // My DPS is above the last entry on this page, so I'd be on this page or earlier
        // Find exact position
        for (let i = 0; i < data.rankings.length; i++) {
          if (data.rankings[i].amount <= myDps) {
            const globalIdx = (p - 1) * 100 + i;
            const myPct = 100 - (globalIdx / totalEntries) * 100;
            console.log(`  Your parse: ${myDps} DPS — ~${Math.round(myPct)}th percentile • ${myDuration.toFixed(0)}s`);
            break;
          }
        }
        break;
      }
      if (!data.hasMorePages) {
        // Last page, my DPS is below everyone
        const myPct = 0;
        console.log(`  Your parse: ${myDps} DPS — ~${myPct}th percentile • ${myDuration.toFixed(0)}s`);
      }
    }
  }

  console.log(`  P75 match:  ${Math.round(p75Match.amount)} DPS — ~${p75Match.estimatedPercentile}th • ${p75Duration.toFixed(0)}s • ${p75Match.name}-${p75Match.server.name}`);
  console.log(`  P95 match:  ${Math.round(p95Match.amount)} DPS — ~${p95Match.estimatedPercentile}th • ${p95Duration.toFixed(0)}s • ${p95Match.name}-${p95Match.server.name}`);
  console.log();

  // --- STATS ---
  console.log("[1] GEAR & STATS");
  console.log("─────────────────────────────────────────────────────");

  const getIlvl = (ci: any) => {
    const gear = ci?.gear?.filter((g: any) => g.itemLevel > 0) || [];
    return gear.length > 0 ? Math.round(gear.reduce((s: number, g: any) => s + g.itemLevel, 0) / gear.length) : 0;
  };

  const myCI = myData.ci;
  const p75CI = p75Data.ci;
  const p95CI = p95Data.ci;

  const pad = (s: string | number, n: number) => String(s).padStart(n);
  const formatStat = (label: string, my: number, p75: number, p95: number) => {
    const d75 = my - p75;
    const d95 = my - p95;
    const d75Str = d75 >= 0 ? `+${d75}` : `${d75}`;
    const d95Str = d95 >= 0 ? `+${d95}` : `${d95}`;
    console.log(`  ${label.padEnd(16)} ${pad(my, 6)}  ${pad(p75, 6)}  ${pad(p95, 6)}  ${pad(d75Str, 7)}  ${pad(d95Str, 7)}`);
  };

  console.log(`  ${"".padEnd(16)} ${"You".padStart(6)}  ${"P75".padStart(6)}  ${"P95".padStart(6)}  ${"Δ P75".padStart(7)}  ${"Δ P95".padStart(7)}`);
  formatStat("Avg ilvl", getIlvl(myCI), getIlvl(p75CI), getIlvl(p95CI));
  formatStat("Crit", myCI?.critMelee || 0, p75CI?.critMelee || 0, p95CI?.critMelee || 0);
  formatStat("Haste", myCI?.hasteMelee || 0, p75CI?.hasteMelee || 0, p95CI?.hasteMelee || 0);
  formatStat("Mastery", myCI?.mastery || 0, p75CI?.mastery || 0, p95CI?.mastery || 0);
  formatStat("Versatility", myCI?.versatilityDamageDone || 0, p75CI?.versatilityDamageDone || 0, p95CI?.versatilityDamageDone || 0);
  console.log();

  // --- DAMAGE BREAKDOWN ---
  console.log("[2] ABILITY BREAKDOWN (per-minute normalised)");
  console.log("─────────────────────────────────────────────────────");

  const buildAbilityMap = (dmgTable: any, duration: number) => {
    const map: Record<string, { total: number, dps: number, perMin: number, share: number }> = {};
    const totalDmg = dmgTable?.entries?.reduce((s: number, e: any) => s + (e.total || 0), 0) || 1;
    for (const entry of (dmgTable?.entries || [])) {
      map[entry.name] = {
        total: entry.total,
        dps: Math.round(entry.total / duration),
        perMin: Math.round((entry.total / duration) * 60),
        share: entry.total / totalDmg,
      };
    }
    return map;
  };

  const myAbilities = buildAbilityMap(myData.dmgTable, myDuration);
  const p75Abilities = buildAbilityMap(p75Data.dmgTable, p75Duration);
  const p95Abilities = buildAbilityMap(p95Data.dmgTable, p95Duration);

  // Union of all abilities, sorted by P95 damage share
  const allAbilities = new Set([...Object.keys(myAbilities), ...Object.keys(p75Abilities), ...Object.keys(p95Abilities)]);
  const sorted = [...allAbilities].sort((a, b) => (p95Abilities[b]?.share || 0) - (p95Abilities[a]?.share || 0));

  console.log(`  ${"Ability".padEnd(22)} ${"You DPS".padStart(8)}  ${"P75 DPS".padStart(8)}  ${"P95 DPS".padStart(8)}  ${"You %".padStart(6)}  ${"P95 %".padStart(6)}`);
  for (const ability of sorted) {
    const my = myAbilities[ability];
    const p75 = p75Abilities[ability];
    const p95 = p95Abilities[ability];
    if ((p95?.share || 0) < 0.005 && (my?.share || 0) < 0.005) continue;

    const myDpsStr = my ? String(my.dps) : "—";
    const p75DpsStr = p75 ? String(p75.dps) : "—";
    const p95DpsStr = p95 ? String(p95.dps) : "—";
    const myShareStr = my ? `${(my.share * 100).toFixed(1)}%` : "—";
    const p95ShareStr = p95 ? `${(p95.share * 100).toFixed(1)}%` : "—";

    console.log(`  ${ability.padEnd(22)} ${myDpsStr.padStart(8)}  ${p75DpsStr.padStart(8)}  ${p95DpsStr.padStart(8)}  ${myShareStr.padStart(6)}  ${p95ShareStr.padStart(6)}`);
  }
  console.log();

  // --- TALENTS ---
  console.log("[3] TALENTS");
  console.log("─────────────────────────────────────────────────────");

  const myNodes = new Set(myCI?.talentTree?.map((t: any) => t.nodeID) || []);
  const p75Nodes = new Set(p75CI?.talentTree?.map((t: any) => t.nodeID) || []);
  const p95Nodes = new Set(p95CI?.talentTree?.map((t: any) => t.nodeID) || []);

  const missingVsP75 = (p75CI?.talentTree || []).filter((t: any) => !myNodes.has(t.nodeID));
  const extraVsP75 = (myCI?.talentTree || []).filter((t: any) => !p75Nodes.has(t.nodeID));
  const missingVsP95 = (p95CI?.talentTree || []).filter((t: any) => !myNodes.has(t.nodeID));
  const extraVsP95 = (myCI?.talentTree || []).filter((t: any) => !p95Nodes.has(t.nodeID));

  console.log(`  Your nodes: ${myCI?.talentTree?.length || 0}`);
  console.log(`  vs P75: ${missingVsP75.length} missing, ${extraVsP75.length} extra`);
  console.log(`  vs P95: ${missingVsP95.length} missing, ${extraVsP95.length} extra`);

  if (missingVsP75.length > 0) {
    console.log(`\n  Missing vs P75 (node IDs): ${missingVsP75.map((t: any) => t.nodeID).join(", ")}`);
  }
  if (missingVsP95.length > 0) {
    console.log(`  Missing vs P95 (node IDs): ${missingVsP95.map((t: any) => t.nodeID).join(", ")}`);
  }
  console.log();

  // --- VERDICT ---
  console.log("[4] VERDICT");
  console.log("─────────────────────────────────────────────────────");

  // Compare stats
  if (myCI && p75CI) {
    const masteryGap = ((p75CI.mastery - myCI.mastery) / p75CI.mastery * 100);
    const hasteGap = ((p75CI.hasteMelee - myCI.hasteMelee) / p75CI.hasteMelee * 100);
    const critDiff = myCI.critMelee - p75CI.critMelee;

    if (masteryGap > 10) {
      console.log(`  [GEAR] Mastery: you ${myCI.mastery} vs P75 ${p75CI.mastery} — ${masteryGap.toFixed(0)}% behind. Devourer scales hard off mastery.`);
    }
    if (hasteGap > 10) {
      console.log(`  [GEAR] Haste: you ${myCI.hasteMelee} vs P75 ${p75CI.hasteMelee} — ${hasteGap.toFixed(0)}% behind. Stack haste after mastery.`);
    }
    if (critDiff > 100) {
      console.log(`  [GEAR] Crit: you ${myCI.critMelee} vs P75 ${p75CI.critMelee} — you have ${critDiff} excess crit. Restat to mastery/haste.`);
    }
  }

  // Compare abilities
  for (const ability of sorted) {
    const my = myAbilities[ability];
    const p75 = p75Abilities[ability];
    if (!my || !p75 || p75.dps === 0) continue;
    if (p75.share < 0.02) continue; // skip minor abilities

    const gap = (p75.dps - my.dps) / p75.dps;
    if (gap > 0.15) {
      const tag = ability === "Eradicate" || ability === "Void Ray" || ability === "Devour" || ability === "Collapsing Star" || ability === "Voidfall Meteor" ? "PLAY" : "PLAY";
      console.log(`  [${tag}] ${ability}: you ${my.dps} DPS vs P75 ${p75.dps} DPS — ${(gap * 100).toFixed(0)}% behind`);
    }
  }

  console.log();
  console.log("═══════════════════════════════════════════════════════════════");
}

main().catch((err) => {
  console.error("Failed:", err);
  process.exit(1);
});
