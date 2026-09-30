#!/usr/bin/env -S deno run --allow-read
//
// Usage: ./report.js results/<stamp>-throughput/throughput.csv [more.csv...]

const NOISE = 0.05;

const LEGEND = `\`~\` runs more than ${NOISE * 100}% apart, ` +
  "`errors` failed or non-2xx responses, " +
  "`stalled` none of the connections completed a second request, " +
  "`overloaded` the server could not keep up with the offered rate, " +
  "`-` no result.";

function readCsv(path) {
  const [header, ...lines] = Deno.readTextFileSync(path).trim().split("\n");
  const columns = header.split(",");
  return lines.map((line) => {
    const cells = line.split(",");
    return Object.fromEntries(columns.map((name, i) => [name, cells[i]]));
  });
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

function median(numbers) {
  const sorted = [...numbers].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const formatCount = (number) => Math.round(number).toLocaleString("en-US");

function formatUs(microseconds) {
  if (microseconds >= 1000000) return `${(microseconds / 1000000).toFixed(2)}s`;
  if (microseconds >= 1000) return `${(microseconds / 1000).toFixed(2)}ms`;
  return `${microseconds}us`;
}

function printTable(header, rows) {
  const widths = header.map((name, i) => Math.max(3, name.length, ...rows.map((row) => row[i].length)));
  const align = (cell, i) => (i === 0 ? cell.padEnd(widths[i]) : cell.padStart(widths[i]));
  const rule = (width, i) => (i === 0 ? "-".repeat(width) : `${"-".repeat(width - 1)}:`);
  const line = (cells) => `| ${cells.join(" | ")} |`;

  console.log(line(header.map(align)));
  console.log(line(widths.map(rule)));
  for (const row of rows) console.log(line(row.map(align)));
  console.log();
}

function serverRows(runs, labelsOf, cellOf) {
  const servers = [...new Set(runs.map((run) => run.server))];
  const groups = groupBy(runs, (run) => labelsOf(run).join("|"));
  const rows = [...groups.values()].map((group) => {
    const byServer = groupBy(group, (run) => run.server);
    return [
      ...labelsOf(group[0]),
      ...servers.map((server) => (byServer.has(server) ? cellOf(byServer.get(server)) : "-")),
    ];
  });
  return { servers, rows };
}

function throughputCell(repeats) {
  const unclean = repeats.find((run) => run.status !== "ok");
  if (unclean) return unclean.status;

  const rates = repeats.map((run) => Number(run.requests_per_sec));
  const middle = median(rates);
  const noisy = (Math.max(...rates) - Math.min(...rates)) / middle > NOISE;
  return formatCount(middle) + (noisy ? " ~" : "");
}

function throughput(runs) {
  const repeats = Math.max(...runs.map((run) => Number(run.repeat)));

  for (const [protocol, forProtocol] of groupBy(runs, (run) => run.protocol)) {
    console.log(`## Throughput over ${protocol}\n`);
    console.log(`Requests per second with the median of ${repeats} runs.\n`);
    const { servers, rows } = serverRows(forProtocol, (run) => [run.case], throughputCell);
    printTable(["case", ...servers], rows);
  }
}

function latencyCell([run]) {
  return run.status === "ok" ? formatUs(Number(run.p99_us)) : run.status;
}

function latency(runs) {
  for (const [protocol, forProtocol] of groupBy(runs, (run) => run.protocol)) {
    console.log(`## Latency over ${protocol}\n`);
    console.log("p99 latency at a fixed offered rate.\n");
    const { servers, rows } = serverRows(
      forProtocol,
      (run) => [run.case, formatCount(Number(run.rate))],
      latencyCell,
    );
    printTable(["case", "req/s", ...servers], rows);
  }
}

function main() {
  if (Deno.args.length === 0) {
    console.error("usage: ./report.js <throughput.csv|latency.csv>...");
    Deno.exit(1);
  }

  for (const path of Deno.args) {
    const runs = readCsv(path);
    if (runs.length === 0) {
      console.error(`no runs found at ${path}`);
      Deno.exit(1);
    }

    if ("repeat" in runs[0]) {
      throughput(runs);
    } else if ("rate" in runs[0]) {
      latency(runs);
    } else {
      console.error(`${path} is not a throughput/latency csv`);
      Deno.exit(1);
    }
  }

  console.log(LEGEND);
}

main();
