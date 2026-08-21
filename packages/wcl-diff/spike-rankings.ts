/**
 * Spike: Validate WCL rankings query returns report.code + source identification
 * Issue #187 — highest risk assumption in wcl-diff
 *
 * Run: npx tsx spike-rankings.ts
 */

import { readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Parse .env manually — no dependency needed for a spike
const envPath = resolve(__dirname, ".env");
const envContent = readFileSync(envPath, "utf-8");
for (const line of envContent.split("\n")) {
  const match = line.match(/^(\w+)=(.*)$/);
  if (match) process.env[match[1]] = match[2];
}

const WCL_CLIENT_ID = process.env.WCL_CLIENT_ID;
const WCL_CLIENT_SECRET = process.env.WCL_CLIENT_SECRET;
const TOKEN_URL = "https://www.warcraftlogs.com/oauth/token";
const GQL_URL = "https://www.warcraftlogs.com/api/v2/client";

// --- Auth ---

async function getToken(): Promise<string> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: WCL_CLIENT_ID!,
      client_secret: WCL_CLIENT_SECRET!,
    }),
  });

  if (!res.ok) {
    throw new Error(`Auth failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  return data.access_token;
}

// --- GraphQL helper ---

async function gql(token: string, query: string, variables?: Record<string, unknown>) {
  const res = await fetch(GQL_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query, variables }),
  });

  if (!res.ok) {
    throw new Error(`WCL API error: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  if (data.errors) {
    throw new Error(`WCL GQL errors: ${JSON.stringify(data.errors, null, 2)}`);
  }
  return data.data;
}

// --- Spike queries ---

async function main() {
  console.log("=== WCL Rankings Spike (#187) ===\n");

  console.log("1. Authenticating...");
  const token = await getToken();
  console.log("   ✓ Token acquired\n");

  // Skip introspection — WCL returns internal server error on __type queries
  // Go straight to the real rankings query

  // Sikran (Nerub-ar Palace) encounter ID = 2898, Heroic difficulty = 4
  // Using Havoc Demon Hunter as test spec
  console.log("\n4. Querying rankings for a known encounter...");
  console.log("   Encounter: Sikran (2898), Heroic, Havoc Demon Hunter\n");

  const rankingsQuery = `
    query RankingsSpike($encounterId: Int!, $difficulty: Int!, $className: String!, $specName: String!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          name
          characterRankings(
            difficulty: $difficulty
            className: $className
            specName: $specName
            page: $page
          )
        }
      }
    }
  `;

  const rankingsResult = await gql(token, rankingsQuery, {
    encounterId: 2898,
    difficulty: 4,       // heroic
    className: "DemonHunter",
    specName: "Havoc",
    page: 1,
  });

  const rankings = rankingsResult.worldData.encounter;
  console.log(`   Encounter name: ${rankings.name}`);

  // characterRankings returns a JSON blob, let's inspect its structure
  const rankingData = rankings.characterRankings;
  console.log(`   Rankings type: ${typeof rankingData}`);

  if (typeof rankingData === "object" && rankingData !== null) {
    console.log(`   Top-level keys: ${Object.keys(rankingData).join(", ")}`);

    if (rankingData.rankings && Array.isArray(rankingData.rankings)) {
      console.log(`   Number of ranked entries: ${rankingData.rankings.length}`);

      if (rankingData.rankings.length > 0) {
        // Inspect the first entry fully
        const first = rankingData.rankings[0];
        console.log(`\n   === FIRST RANKED ENTRY (full dump) ===`);
        console.log(JSON.stringify(first, null, 4));

        // Check for critical fields
        console.log(`\n   === CRITICAL FIELD CHECK ===`);
        console.log(`   report.code:  ${first.report?.code ?? "❌ MISSING"}`);
        console.log(`   report.fightID: ${first.report?.fightID ?? "❌ MISSING"}`);
        console.log(`   duration:     ${first.duration ?? "❌ MISSING"}`);
        console.log(`   startTime:    ${first.startTime ?? "❌ MISSING"}`);
        console.log(`   rankPercent:  ${first.rankPercent ?? "❌ MISSING"}`);
        console.log(`   name:         ${first.name ?? "❌ MISSING"}`);
        console.log(`   server:       ${JSON.stringify(first.server) ?? "❌ MISSING"}`);

        // Check a few more entries for consistency
        console.log(`\n   === SAMPLE: entries around P75 and P95 ===`);
        const withPercent = rankingData.rankings.filter((r: any) => r.rankPercent != null);
        const near75 = withPercent.filter((r: any) => Math.abs(r.rankPercent - 75) <= 3).slice(0, 2);
        const near95 = withPercent.filter((r: any) => Math.abs(r.rankPercent - 95) <= 3).slice(0, 2);

        if (near75.length > 0) {
          console.log(`\n   ~P75 entry:`);
          console.log(JSON.stringify(near75[0], null, 4));
        } else {
          console.log(`\n   No entries near P75 found on this page`);
        }

        if (near95.length > 0) {
          console.log(`\n   ~P95 entry:`);
          console.log(JSON.stringify(near95[0], null, 4));
        } else {
          console.log(`\n   No entries near P95 found on this page`);
        }
      }
    }

    // Check if there's pagination info
    if (rankingData.page !== undefined || rankingData.hasMorePages !== undefined || rankingData.totalPages !== undefined) {
      console.log(`\n   Pagination: page=${rankingData.page}, hasMore=${rankingData.hasMorePages}, total=${rankingData.totalPages}, count=${rankingData.count}`);
    }
  } else {
    console.log("   Raw rankings data:");
    console.log(JSON.stringify(rankingData, null, 2));
  }

  // --- Additional investigation: find P75/P95 by page math ---
  const count = rankingData.count;
  console.log(`\n5. Total ranked parses: ${count}`);
  console.log(`   Entries per page: ${rankingData.rankings.length}`);
  console.log(`   If sorted by DPS desc, P95 index = ${Math.floor(count * 0.05)}`);
  console.log(`   P95 page = ${Math.floor(Math.floor(count * 0.05) / 100) + 1}`);
  console.log(`   P75 index = ${Math.floor(count * 0.25)}`);
  console.log(`   P75 page = ${Math.floor(Math.floor(count * 0.25) / 100) + 1}`);

  // Try fetching the page that should contain ~P75 entries
  const p75Index = Math.floor(count * 0.25);
  const p75Page = Math.floor(p75Index / 100) + 1;
  console.log(`\n6. Fetching page ${p75Page} (should contain ~P75 entries)...`);

  const p75Result = await gql(token, `
    query RankingsP75($encounterId: Int!, $difficulty: Int!, $className: String!, $specName: String!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          characterRankings(
            difficulty: $difficulty
            className: $className
            specName: $specName
            page: $page
          )
        }
      }
    }
  `, {
    encounterId: 2898,
    difficulty: 4,
    className: "DemonHunter",
    specName: "Havoc",
    page: p75Page,
  });

  const p75Rankings = p75Result.worldData.encounter.characterRankings;
  if (p75Rankings.rankings?.length > 0) {
    const offsetInPage = p75Index % 100;
    const entry = p75Rankings.rankings[Math.min(offsetInPage, p75Rankings.rankings.length - 1)];
    console.log(`   ~P75 entry (index ${p75Index}, page ${p75Page}, offset ${offsetInPage}):`);
    console.log(JSON.stringify(entry, null, 4));
    console.log(`   DPS: ${Math.round(entry.amount)}`);
    console.log(`   Duration: ${(entry.duration / 1000).toFixed(1)}s`);
    console.log(`   report.code: ${entry.report.code}`);
    console.log(`   report.fightID: ${entry.report.fightID}`);
  }

  // Also try the bracket/percentile filter if available
  console.log(`\n7. Testing if characterRankings accepts bracket/percentile params...`);
  try {
    const bracketResult = await gql(token, `
      query RankingsBracket($encounterId: Int!) {
        worldData {
          encounter(id: $encounterId) {
            characterRankings(
              difficulty: 4
              className: "DemonHunter"
              specName: "Havoc"
              bracket: 75
            )
          }
        }
      }
    `, { encounterId: 2898 });
    console.log(`   bracket=75 works! Result keys: ${Object.keys(bracketResult.worldData.encounter.characterRankings).join(", ")}`);
    const bracketData = bracketResult.worldData.encounter.characterRankings;
    console.log(`   Count: ${bracketData.count}, entries: ${bracketData.rankings?.length}`);
    if (bracketData.rankings?.[0]) {
      console.log(`   First entry DPS: ${Math.round(bracketData.rankings[0].amount)}`);
    }
  } catch (e: any) {
    console.log(`   bracket param failed: ${e.message?.slice(0, 200)}`);
  }

  // --- Step 8: Check what bracket=75 actually returned ---
  console.log(`\n8. Dumping bracket=75 response...`);
  try {
    const bracketResult2 = await gql(token, `
      query RankingsBracket($encounterId: Int!) {
        worldData {
          encounter(id: $encounterId) {
            characterRankings(
              difficulty: 4
              className: "DemonHunter"
              specName: "Havoc"
              bracket: 75
            )
          }
        }
      }
    `, { encounterId: 2898 });
    console.log(JSON.stringify(bracketResult2.worldData.encounter.characterRankings, null, 2));
  } catch (e: any) {
    console.log(`   Error: ${e.message?.slice(0, 500)}`);
  }

  // --- Step 9: Try higher pages to estimate total count ---
  console.log(`\n9. Trying page 50 to estimate total count...`);
  const page50Result = await gql(token, `
    query RankingsPage($encounterId: Int!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          characterRankings(
            difficulty: 4
            className: "DemonHunter"
            specName: "Havoc"
            page: $page
          )
        }
      }
    }
  `, { encounterId: 2898, page: 50 });
  const page50 = page50Result.worldData.encounter.characterRankings;
  console.log(`   Page 50: count=${page50.count}, entries=${page50.rankings?.length}, hasMore=${page50.hasMorePages}`);
  if (page50.rankings?.length > 0) {
    console.log(`   First entry DPS: ${Math.round(page50.rankings[0].amount)}`);
    console.log(`   Last entry DPS: ${Math.round(page50.rankings[page50.rankings.length - 1].amount)}`);
  }

  // Try a very high page to find the end
  console.log(`\n10. Trying page 500...`);
  const page500Result = await gql(token, `
    query RankingsPage($encounterId: Int!, $page: Int) {
      worldData {
        encounter(id: $encounterId) {
          characterRankings(
            difficulty: 4
            className: "DemonHunter"
            specName: "Havoc"
            page: $page
          )
        }
      }
    }
  `, { encounterId: 2898, page: 500 });
  const page500 = page500Result.worldData.encounter.characterRankings;
  console.log(`   Page 500: count=${page500.count}, entries=${page500.rankings?.length}, hasMore=${page500.hasMorePages}`);

  // --- Step 11: Check if there's a rankPercentile on the encounter itself ---
  console.log(`\n11. Trying encounter.fightRankings (alternate query)...`);
  try {
    const fightRankings = await gql(token, `
      query FightRankings($encounterId: Int!) {
        worldData {
          encounter(id: $encounterId) {
            fightRankings(
              difficulty: 4
            )
          }
        }
      }
    `, { encounterId: 2898 });
    const fr = fightRankings.worldData.encounter.fightRankings;
    console.log(`   fightRankings keys: ${Object.keys(fr).join(", ")}`);
    console.log(`   count: ${fr.count}`);
    if (fr.rankings?.[0]) {
      console.log(`   First entry keys: ${Object.keys(fr.rankings[0]).join(", ")}`);
      console.log(`   First entry: ${JSON.stringify(fr.rankings[0], null, 4)}`);
    }
  } catch (e: any) {
    console.log(`   fightRankings failed: ${e.message?.slice(0, 300)}`);
  }

  console.log("\n=== Spike complete ===");
}

main().catch((err) => {
  console.error("Spike failed:", err);
  process.exit(1);
});
