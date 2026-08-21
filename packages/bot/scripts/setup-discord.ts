/**
 * Class Codex — Discord server setup script
 *
 * Creates the full channel/role/permission structure in one go.
 *
 * Usage:
 *   1. Go to https://discord.com/developers/applications → New Application
 *   2. Bot tab → Reset Token → copy token
 *   3. Bot tab → enable "Server Members Intent" and "Message Content Intent"
 *   4. OAuth2 → URL Generator → select "bot" scope + "Administrator" permission
 *   5. Open the generated URL to invite the bot to your server
 *   6. Run:
 *        DISCORD_TOKEN=your-bot-token GUILD_ID=your-server-id pnpm --filter @classcodex/bot setup
 *
 *   To get the Guild ID: enable Developer Mode in Discord settings,
 *   right-click your server name → Copy Server ID.
 *
 *   After the script finishes you can remove the bot from the server —
 *   everything it created persists.
 */

import {
  Client,
  GatewayIntentBits,
  GuildDefaultMessageNotifications,
  GuildExplicitContentFilter,
  GuildVerificationLevel,
  ChannelType,
  PermissionFlagsBits,
  type Guild,
  type Role,
  type TextChannel,
} from "discord.js";

const TOKEN = process.env.DISCORD_TOKEN;
const GUILD_ID = process.env.GUILD_ID;

if (!TOKEN || !GUILD_ID) {
  console.error(
    "Missing env vars. Usage:\n  DISCORD_TOKEN=... GUILD_ID=... pnpm --filter @classcodex/bot setup"
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function createRoles(guild: Guild) {
  console.log("Creating roles...");

  const supporter = await guild.roles.create({
    name: "Supporter",
    color: 0xf96854, // Patreon coral
    hoist: true,
    reason: "Class Codex setup",
  });
  console.log(`  ✓ @Supporter (${supporter.id})`);

  const champion = await guild.roles.create({
    name: "Champion",
    color: 0xffd700, // gold
    hoist: true,
    reason: "Class Codex setup",
  });
  console.log(`  ✓ @Champion (${champion.id})`);

  const developer = await guild.roles.create({
    name: "Developer",
    color: 0x00ccff, // Class Codex blue
    hoist: true,
    permissions: [PermissionFlagsBits.Administrator],
    reason: "Class Codex setup",
  });
  console.log(`  ✓ @Developer (${developer.id})`);

  const moderator = await guild.roles.create({
    name: "Moderator",
    color: 0x5865f2, // blurple
    hoist: true,
    permissions: [
      PermissionFlagsBits.ManageMessages,
      PermissionFlagsBits.ModerateMembers,
      PermissionFlagsBits.ManageThreads,
    ],
    reason: "Class Codex setup",
  });
  console.log(`  ✓ @Moderator (${moderator.id})`);

  return { developer, supporter, champion, moderator };
}

async function createInfoChannels(guild: Guild, everyone: Role) {
  console.log("\nCreating INFO category...");
  const category = await guild.channels.create({
    name: "📋 Info",
    type: ChannelType.GuildCategory,
  });

  const readOnly = [
    { id: everyone.id, deny: [PermissionFlagsBits.SendMessages] },
  ];

  const welcome = await guild.channels.create({
    name: "welcome",
    type: ChannelType.GuildText,
    parent: category,
    topic: "What is Class Codex and where to find it",
    permissionOverwrites: readOnly,
  });
  console.log("  ✓ #welcome (read-only)");

  const rules = await guild.channels.create({
    name: "rules",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Server rules",
    permissionOverwrites: readOnly,
  });
  console.log("  ✓ #rules (read-only)");

  const announcements = await guild.channels.create({
    name: "announcements",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Addon updates and notable changes",
    permissionOverwrites: readOnly,
  });
  console.log("  ✓ #announcements (read-only)");

  return { welcome, rules, announcements };
}

async function createCommunityChannels(guild: Guild) {
  console.log("\nCreating COMMUNITY category...");
  const category = await guild.channels.create({
    name: "💬 Community",
    type: ChannelType.GuildCategory,
  });

  await guild.channels.create({
    name: "general",
    type: ChannelType.GuildText,
    parent: category,
    topic: "General Class Codex discussion",
  });
  console.log("  ✓ #general");

  await guild.channels.create({
    name: "suggestions",
    type: ChannelType.GuildForum,
    parent: category,
    topic: "Feature requests and ideas — create a post, others vote with 👍",
    availableTags: [
      { name: "Enhancement" },
      { name: "New Feature" },
      { name: "UI/UX" },
      { name: "Data/Specs" },
      { name: "Accepted" },
      { name: "Completed" },
    ],
  });
  console.log("  ✓ #suggestions (forum channel)");

  await guild.channels.create({
    name: "bug-reports",
    type: ChannelType.GuildForum,
    parent: category,
    topic: "Found a bug? Create a post with steps to reproduce",
    availableTags: [
      { name: "Bug" },
      { name: "Display Issue" },
      { name: "Data Issue" },
      { name: "Confirmed" },
      { name: "Fixed" },
    ],
  });
  console.log("  ✓ #bug-reports (forum channel)");
}

async function createSupportChannels(guild: Guild) {
  console.log("\nCreating SUPPORT category...");
  const category = await guild.channels.create({
    name: "🔧 Support",
    type: ChannelType.GuildCategory,
  });

  await guild.channels.create({
    name: "help",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Need help with the addon? Ask here",
  });
  console.log("  ✓ #help");
}

async function createSupporterChannels(
  guild: Guild,
  everyone: Role,
  supporter: Role,
  champion: Role
) {
  console.log("\nCreating SUPPORTERS category...");
  const category = await guild.channels.create({
    name: "⭐ Supporters",
    type: ChannelType.GuildCategory,
    permissionOverwrites: [
      { id: everyone.id, deny: [PermissionFlagsBits.SendMessages] },
      { id: supporter.id, allow: [PermissionFlagsBits.SendMessages] },
      { id: champion.id, allow: [PermissionFlagsBits.SendMessages] },
    ],
  });

  await guild.channels.create({
    name: "supporter-chat",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Patreon supporters lounge",
  });
  console.log("  ✓ #supporter-chat (supporter-only write)");

  await guild.channels.create({
    name: "polls",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Vote on what gets built next",
  });
  console.log("  ✓ #polls (supporter-only write)");
}

async function seedWelcome(guild: Guild, welcome: TextChannel) {
  console.log("\nSeeding #welcome...");

  const suggestions = guild.channels.cache.find((c) => c.name === "suggestions");
  const bugReports = guild.channels.cache.find((c) => c.name === "bug-reports");
  const help = guild.channels.cache.find((c) => c.name === "help");

  await welcome.send({
    embeds: [
      {
        title: "Welcome to the Class Codex Discord!",
        description: [
          "Class Codex gives you stat priorities, talent builds, rotation guides, " +
            "and gearing recommendations for every WoW spec — right inside the game.",
          "",
          "**Get the addon:**",
          "• [CurseForge](https://www.curseforge.com/wow/addons/class-codex)",
          "• [Wago](https://addons.wago.io/addons/classcodex)",
          "",
          "**Useful channels:**",
          `• <#${suggestions?.id}> — Request features`,
          `• <#${bugReports?.id}> — Report bugs`,
          `• <#${help?.id}> — Get help`,
        ].join("\n"),
        color: 0x00ccff,
      },
    ],
  });
  console.log("  ✓ Welcome message sent");
}

async function createAdminChannels(guild: Guild, everyone: Role, developer: Role) {
  console.log("\nCreating ADMIN category...");
  const category = await guild.channels.create({
    name: "🔒 Admin",
    type: ChannelType.GuildCategory,
    permissionOverwrites: [
      { id: everyone.id, deny: [PermissionFlagsBits.ViewChannel] },
      { id: developer.id, allow: [PermissionFlagsBits.ViewChannel] },
    ],
  });

  await guild.channels.create({
    name: "server-log",
    type: ChannelType.GuildText,
    parent: category,
    topic: "Member joins, leaves, and server activity",
  });
  console.log("  ✓ #server-log (developer-only)");

  return { serverLog: guild.channels.cache.find((c) => c.name === "server-log")! };
}

async function enableCommunity(
  guild: Guild,
  rules: TextChannel,
  announcements: TextChannel
) {
  console.log("\nEnabling Community Server...");
  // Enable Community via REST (discord.js misses field mapping when features is set)
  await guild.client.rest.patch(`/guilds/${guild.id}`, {
    body: {
      features: [...guild.features, "COMMUNITY"],
      rules_channel_id: rules.id,
      public_updates_channel_id: announcements.id,
      default_message_notifications: 1, // OnlyMentions
      explicit_content_filter: 2,       // AllMembers
      verification_level: 1,            // Low
    },
  });
  console.log("  ✓ Community Server enabled");
  console.log("    To make #announcements followable: Server Settings → Channels → announcements → toggle Announcement Channel");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

client.once("ready", async () => {
  console.log(`Logged in as ${client.user!.tag}`);
  const guild = await client.guilds.fetch(GUILD_ID!);
  console.log(`Setting up server: ${guild.name}\n`);

  const everyone = guild.roles.everyone;
  const { developer, supporter, champion } = await createRoles(guild);

  const { welcome, rules, announcements } = await createInfoChannels(guild, everyone);
  await createCommunityChannels(guild);
  await createSupportChannels(guild);
  await createSupporterChannels(guild, everyone, supporter, champion);
  const { serverLog } = await createAdminChannels(guild, everyone, developer);
  await enableCommunity(guild, rules, announcements);
  await seedWelcome(guild, welcome);

  // Set server-log as the system channel for join/leave messages
  await guild.edit({ systemChannelId: serverLog.id });
  console.log("\n  ✓ System messages (joins/leaves) routed to #server-log");

  console.log("\n✅ Discord server setup complete!");
  console.log("\nNext steps:");
  console.log("  1. Assign yourself the @Developer role");
  console.log("  2. Edit #rules with your server rules");
  console.log("  3. Connect Patreon: Patreon → Benefits → Advanced → Connect Discord");
  console.log("  4. Map Patreon tiers to @Supporter / @Champion roles");
  console.log("  5. Optional: convert #announcements to Announcement Channel in Server Settings for cross-server following");
  console.log("  6. You can now remove this bot from the server — everything persists");

  client.destroy();
});

client.login(TOKEN);
