#!/usr/bin/env -S deno run --allow-read

const COLUMN = 12;
const COLLAPSED = 20;
const NOISE = 0.05;

function readCsv(path) {
  const text = Deno.readTextFileSync(path);
  const [header, ...lines] = text.trim().split("\n");
  const columns = header.split(",");
  return lines.map((line) => {
    const cells = line.split(",");
    return Object.fromEntries(columns.map((name, i) => [name, cells[i]]));
  });
}

function table(headings, widths, columns, rows) {
  const head = headings.map((name, i) => name.padEnd(widths[i])).join("");
  console.log(head + columns.map((name) => name.padStart(COLUMN)).join(""));
  console.log("-".repeat(head.length + COLUMN * columns.length));

  for (const row of rows) {
    const labels = row.labels.map((label, i) => label.padEnd(widths[i])).join("");
    const cells = columns.map((name) => (row.values.get(name) ?? "-").padStart(COLUMN));
    console.log(labels + cells.join(""));
  }
}

function section(title, lines) {
  if (lines.length === 0) return;
  console.log(`\n${title}\n`);
  for (const line of lines) console.log(line);
}

function groupBy(rows, keyOf) {
  const groups = new Map();
  for (const row of rows) {
    const key = keyOf(row);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return groups;
}

const unique = (values) => [...new Set(values)];

function median(numbers) {
  const sorted = [...numbers].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function spread(numbers) {
  const middle = median(numbers);
  return middle ? (Math.max(...numbers) - Math.min(...numbers)) / middle : 0;
}

const caseProfile = (row) => `${row.case}|${row.profile}`;
const cellName = (row) => `${row.server} ${row.profile} ${row.case}`;
const rateOf = (row) => Number(row.requests_per_sec);

function throughputTable(rows, field) {
  return [...groupBy(rows, caseProfile)].map(([key, group]) => {
    const [name, profile] = key.split("|");
    const values = new Map(
      [...groupBy(group, (row) => row.server)].map(([server, repeats]) => [
        server,
        Math.round(median(repeats.map((row) => Number(row[field])))).toLocaleString(),
      ]),
    );
    return { labels: [name, profile], values };
  });
}

function throughput(rows) {
  const servers = unique(rows.map((row) => row.server)).sort();
  const widths = [20, 11];

  console.log("profiles");
  for (const [profile, group] of groupBy(rows, (row) => row.profile)) {
    const { protocol, connections, streams } = group[0];
    console.log(`  ${profile.padEnd(11)}${protocol}, ${connections} connections x ${streams} stream(s)`);
  }

  console.log("\nthroughput req/s\n");
  table(["case", "profile"], widths, servers, throughputTable(rows, "requests_per_sec"));

  const streaming = rows.filter((row) => Number(row.messages) > 1);
  if (streaming.length) {
    console.log("\nmessages/s\n");
    table(["case", "profile"], widths, servers, throughputTable(streaming, "messages_per_sec"));
  }

  warnings(rows);
}

function warnings(rows) {
  const noisy = [];
  const broken = [];
  const collapsed = [];

  const peers = new Map(
    [...groupBy(rows, caseProfile)].map(([key, group]) => [key, median(group.map(rateOf))]),
  );

  for (const [name, group] of groupBy(rows, cellName)) {
    const measured = group.map(rateOf);
    const disagreement = spread(measured);
    if (disagreement > NOISE) {
      noisy.push(`  ${name}: ${(disagreement * 100).toFixed(0)}% apart across repeats`);
    }

    const failed = group.reduce((total, row) => total + Number(row.failed), 0);
    const non2xx = group.reduce((total, row) => total + Number(row.non_2xx), 0);
    if (failed || non2xx) broken.push(`  ${name}: ${failed} failed, ${non2xx} non-2xx`);

    const peer = peers.get(caseProfile(group[0]));
    const rate = median(measured);
    if (peer && rate * COLLAPSED < peer) {
      collapsed.push(
        `  ${name}: ${Math.round(rate).toLocaleString()} req/s against a ` +
        `${Math.round(peer).toLocaleString()} median for this case`,
      );
    }
  }

  section("not answering the case correctly", broken);
  section("collapsed against peers", collapsed);
  section("repeats disagreed by over 5%", noisy);
}

function micros(value) {
  const match = String(value).match(/^([\d.]+)(us|ms|s)?$/);
  if (!match) return 0;
  return Number(match[1]) * ({ us: 1, ms: 1000, s: 1000000 }[match[2]] ?? 1);
}

function latencyOf(value) {
  return micros(value) === 0 ? "-" : value;
}

function hardestRates(rows) {
  const byCaseServer = groupBy(rows, (row) => `${row.case}|${row.server}`);
  return [...byCaseServer.values()].map((group) =>
    group.reduce((hardest, row) =>
      Number(row.target_rate) > Number(hardest.target_rate) ? row : hardest
    )
  );
}

function latency(rows) {
  const servers = unique(rows.map((row) => row.server)).sort();

  console.log("p99 at a fixed offered rate for http1\n");
  for (const [name, forCase] of groupBy(rows, (row) => row.case)) {
    console.log(name);
    table(
      ["target req/s"],
      [14],
      servers,
      [...groupBy(forCase, (row) => row.target_rate)].map(([rate, group]) => ({
        labels: [Number(rate).toLocaleString()],
        values: new Map(group.map((row) => [row.server, latencyOf(row.p99)])),
      })),
    );
    console.log();
  }

  console.log("CO gap at the highest rate\n");
  table(
    ["case"],
    [20],
    servers,
    [...groupBy(hardestRates(rows), (row) => row.case)].map(([name, group]) => ({
      labels: [name],
      values: new Map(
        group.map((row) => {
          const raw = micros(row.p99_raw);
          return [row.server, raw ? `${(micros(row.p99) / raw).toFixed(1)}x` : "-"];
        }),
      ),
    })),
  );
}

function main() {
  const paths = Deno.args;
  if (paths.length === 0) {
    console.error("usage: ./report.js <throughput.csv|latency.csv>...");
    Deno.exit(1);
  }

  for (const path of paths) {
    let rows;
    try {
      rows = readCsv(path);
    } catch {
      console.error(`cannot read ${path}`);
      Deno.exit(1);
    }

    if (rows.length === 0) {
      console.error(`no results in ${path}`);
      Deno.exit(1);
    }

    console.log(`${path}\n`);
    if ("protocol" in rows[0]) throughput(rows);
    else latency(rows);
    console.log();
  }
}

main();
