#!/usr/bin/env node
// Prints the relay's and the edge Worker's anonymous counts for the last days (default 7) as plain tables, read
// from Workers Analytics Engine's SQL API (relay/README.md, "What is counted"). Read-only.
//
//   CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… node scripts/metrics.mjs [--days 7] [--json]
//
// The token needs only "Account Analytics: Read". METRICS_DATASET names another dataset (default yardlet_metrics).

const args = process.argv.slice(2);
const daysIndex = args.indexOf("--days");
const days = daysIndex >= 0 ? Number(args[daysIndex + 1]) : 7;
const asJSON = args.includes("--json");
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
const dataset = process.env.METRICS_DATASET ?? "yardlet_metrics";

if (!account || !token) {
  console.error("Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (Account Analytics: Read).");
  process.exit(2);
}
if (!Number.isInteger(days) || days < 1 || days > 90) {
  console.error("--days takes a whole number from 1 to 90 (Analytics Engine keeps 3 months).");
  process.exit(2);
}
if (!/^[A-Za-z0-9_]+$/.test(dataset)) {
  console.error("METRICS_DATASET takes letters, digits and underscores.");
  process.exit(2);
}

const RELAY_EVENTS = ["relay.host", "relay.client", "relay.close", "relay.push"];
const ACCOUNT_EVENTS = ["account.signUp", "account.signIn", "account.signInFailed", "account.mac", "account.deleted"];
// Each point counts double1, and a sampled point stands for _sample_interval of them.
const n = "SUM(_sample_interval * double1) AS n";
const since = `timestamp > NOW() - INTERVAL '${days}' DAY`;
const day = "formatDateTime(toStartOfInterval(timestamp, INTERVAL '1' DAY), '%Y-%m-%d') AS day";
const events = (names) => `blob1 IN (${names.map((name) => `'${name}'`).join(", ")})`;

const sections = [
  {
    title: "Relay connections and pushes",
    columns: ["event", "label1", "label2", "label3", "n"],
    sql: `SELECT blob1 AS event, blob2 AS label1, blob3 AS label2, blob4 AS label3, ${n} FROM ${dataset}
          WHERE ${since} AND ${events(RELAY_EVENTS)} GROUP BY event, label1, label2, label3 ORDER BY event, n DESC`,
  },
  {
    title: "Relay connections by day",
    columns: ["day", "event", "label1", "n"],
    sql: `SELECT ${day}, blob1 AS event, blob2 AS label1, ${n} FROM ${dataset}
          WHERE ${since} AND ${events(["relay.host", "relay.client"])} GROUP BY day, event, label1 ORDER BY day, event, label1`,
  },
  {
    title: "Accounts (sign-ups, sign-ins, failures, registered Macs)",
    columns: ["event", "label1", "label2", "n"],
    sql: `SELECT blob1 AS event, blob2 AS label1, blob3 AS label2, ${n} FROM ${dataset}
          WHERE ${since} AND ${events(ACCOUNT_EVENTS)} GROUP BY event, label1, label2 ORDER BY event, n DESC`,
  },
  {
    title: "Update checks by version (a Mac checks about once a day, so n / days approximates active installs)",
    columns: ["version", "arch", "n", "perDay"],
    sql: `SELECT blob2 AS version, blob3 AS arch, ${n} FROM ${dataset}
          WHERE ${since} AND blob1 = 'update.check' GROUP BY version, arch ORDER BY n DESC`,
    derive: (row) => ({ ...row, perDay: Number(row.n) / days }),
  },
  {
    title: "Update checks by day",
    columns: ["day", "arch", "n"],
    sql: `SELECT ${day}, blob3 AS arch, ${n} FROM ${dataset}
          WHERE ${since} AND blob1 = 'update.check' GROUP BY day, arch ORDER BY day, arch`,
  },
  {
    title: "Downloads by channel and architecture (crawlers and HEAD requests not counted)",
    columns: ["channel", "arch", "kind", "n"],
    sql: `SELECT blob2 AS channel, blob3 AS arch, blob4 AS kind, ${n} FROM ${dataset}
          WHERE ${since} AND blob1 = 'download' GROUP BY channel, arch, kind ORDER BY n DESC`,
  },
  {
    title: "Downloads by day",
    columns: ["day", "arch", "n"],
    sql: `SELECT ${day}, blob3 AS arch, ${n} FROM ${dataset}
          WHERE ${since} AND blob1 = 'download' GROUP BY day, arch ORDER BY day, arch`,
  },
];

async function query(sql) {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/analytics_engine/sql`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: `${sql.replace(/\s+/g, " ")} FORMAT JSON`,
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`Analytics Engine answered ${response.status}: ${text.slice(0, 500)}`);
  return JSON.parse(text).data ?? [];
}

function table(columns, rows) {
  if (rows.length === 0) return "  (none)";
  const cells = rows.map((row) =>
    columns.map((column) => {
      const value = row[column];
      if (column === "n" || column === "perDay") {
        const number = Number(value);
        return Number.isInteger(number) ? String(number) : number.toFixed(1);
      }
      return String(value ?? "");
    }),
  );
  const widths = columns.map((column, i) => Math.max(column.length, ...cells.map((row) => row[i].length)));
  const line = (values) => `  ${values.map((value, i) => value.padEnd(widths[i])).join("  ")}`.trimEnd();
  return [line(columns), line(widths.map((width) => "-".repeat(width))), ...cells.map(line)].join("\n");
}

const results = [];
for (const section of sections) {
  const rows = await query(section.sql);
  results.push({ title: section.title, columns: section.columns, rows: section.derive ? rows.map(section.derive) : rows });
}

if (asJSON) {
  console.log(JSON.stringify({ days, sections: results.map(({ title, rows }) => ({ title, rows })) }, null, 2));
} else {
  console.log(`Yardlet counts, last ${days} days (UTC)\n`);
  for (const { title, columns, rows } of results) console.log(`${title}\n${table(columns, rows)}\n`);
}
