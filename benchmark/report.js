#!/usr/bin/env -S deno run --allow-read

const COLUMN = 12;
const COLLAPSED = 20;
const NOISE = 0.05;

const REASON = {
  stalled: "no connection completed more than one request",
  overload: "generator could not hold the target rate, server is past capacity",
  errors: "failed or non-2xx responses",
};

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

const measured = (row) => row.status === "ok";

function formatUs(value) {
  const microseconds = Number(value);
  if (!microseconds) return "-";
  if (microseconds >= 1000000) return `${(microseconds / 1000000).toFixed(2)}s`;
  if (microseconds >= 1000) return `${(microseconds / 1000).toFixed(2)}ms`;
  return `${microseconds}us`;
}

function notMeasured(rows, nameOf) {
  return [...groupBy(rows.filter((row) => !measured(row)), nameOf)].map(([name, group]) => {
    const status = unique(group.map((row) => row.status)).join(", ");
    return `  ${name}: ${status}`;
  });
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
  const good = rows.filter(measured);
  const servers = unique(rows.map((row) => row.server)).sort();
  const widths = [20, 11];

  console.log("profiles");
  for (const [profile, group] of groupBy(rows, (row) => row.profile)) {
    const { protocol, connections, streams } = group[0];
    console.log(`  ${profile.padEnd(11)}${protocol}, ${connections} connections x ${streams} stream(s)`);
  }

  console.log("\nthroughput req/s\n");
  table(["case", "profile"], widths, servers, throughputTable(good, "requests_per_sec"));

  const streaming = good.filter((row) => Number(row.messages) > 1);
  if (streaming.length) {
    console.log("\nmessages/s\n");
    table(["case", "profile"], widths, servers, throughputTable(streaming, "messages_per_sec"));
  }

  const noisy = [];
  const collapsed = [];
  const peers = new Map(
    [...groupBy(good, caseProfile)].map(([key, group]) => [key, median(group.map(rateOf))]),
  );

  for (const [name, group] of groupBy(good, cellName)) {
    const rates = group.map(rateOf);
    const disagreement = spread(rates);
    if (disagreement > NOISE) {
      noisy.push(`  ${name}: ${(disagreement * 100).toFixed(0)}% apart across repeats`);
    }

    const peer = peers.get(caseProfile(group[0]));
    const rate = median(rates);
    if (peer && rate * COLLAPSED < peer) {
      collapsed.push(
        `  ${name}: ${Math.round(rate).toLocaleString()} req/s against a ` +
        `${Math.round(peer).toLocaleString()} median for this case`,
      );
    }
  }

  section("excluded from the tables", notMeasured(rows, cellName));
  section("collapsed against peers", collapsed);
  section("repeats disagreed by over 5%", noisy);
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
  const good = rows.filter(measured);
  const servers = unique(rows.map((row) => row.server)).sort();

  console.log("p99 at a fixed offered rate for http1\n");
  for (const [name, forCase] of groupBy(good, (row) => row.case)) {
    console.log(name);
    table(
      ["target req/s"],
      [14],
      servers,
      [...groupBy(forCase, (row) => row.target_rate)]
        .sort(([a], [b]) => Number(a) - Number(b))
        .map(([rate, group]) => ({
          labels: [Number(rate).toLocaleString()],
          values: new Map(group.map((row) => [row.server, formatUs(row.p99_us)])),
        })),
    );
    console.log();
  }

  console.log("highest rung held, req/s\n");
  table(
    ["case"],
    [20],
    servers,
    [...groupBy(rows, (row) => row.case)].map(([name, forCase]) => ({
      labels: [name],
      values: new Map(
        [...groupBy(forCase.filter(measured), (row) => row.server)].map((
          [server, group],
        ) => [
            server,
            Math.max(...group.map((row) => Number(row.target_rate))).toLocaleString(),
          ]),
      ),
    })),
  );

  console.log("\nCO gap at the highest rung held\n");
  table(
    ["case"],
    [20],
    servers,
    [...groupBy(hardestRates(good), (row) => row.case)].map(([name, group]) => ({
      labels: [name],
      values: new Map(
        group.map((row) => {
          const raw = Number(row.p99_raw_us);
          return [row.server, raw ? `${(Number(row.p99_us) / raw).toFixed(1)}x` : "-"];
        }),
      ),
    })),
  );

  section(
    "excluded from the tables",
    notMeasured(rows, (row) => `${row.server} ${row.case} @ ${Number(row.target_rate).toLocaleString()}`),
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

    if (!("status" in rows[0])) {
      console.error(`${path} predates the status column, rerun the benchmark`);
      Deno.exit(1);
    }

    console.log(`${path}\n`);
    if ("protocol" in rows[0]) throughput(rows);
    else latency(rows);
    console.log();
  }
}

main();
