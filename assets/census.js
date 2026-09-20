(async () => {
  const number = (n) =>
    Number.isFinite(n) ? n.toLocaleString("en-US") : "Unavailable";
  const share = (n, d) =>
    Number.isFinite(n) && d > 0
      ? ((100 * n) / d).toFixed(1) + "%"
      : "Unavailable";
  const element = (tag, text) => {
    const e = document.createElement(tag);
    e.textContent = text;
    return e;
  };
  const row = (id, values) => {
    const r = document.createElement("tr");
    values.forEach((v, i) => {
      const cell = element("td", v);
      if (i) cell.className = "num";
      r.append(cell);
    });
    document.querySelector("#" + id + " tbody").append(r);
  };
  const get = async (path) => {
    const r = await fetch(path, { cache: "no-store" });
    if (!r.ok) throw Error("Artifact unavailable");
    return r.json();
  };
  try {
    const index = await get("census/index.json");
    const days = index.days
      .filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d.date))
      .sort((a, b) => a.date.localeCompare(b.date));
    if (!days.length) throw Error("No observations have been published.");
    const last = days.at(-1),
      latest = await get("census/" + last.date + ".json");
    const observedAt = Date.parse(latest.generatedAt);
    if (!Number.isFinite(observedAt))
      throw Error("Observation date is invalid.");
    const age = Math.max(0, Math.floor((Date.now() - observedAt) / 86400000));
    const dateLabel = new Date(observedAt).toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
      timeZone: "UTC",
    });
    const freshness = document.getElementById("freshness");
    freshness.textContent =
      "Observed " +
      dateLabel +
      " (UTC) · " +
      (age === 0 ? "Today" : age === 1 ? "1 day ago" : age + " days ago") +
      " · " +
      (latest.completeRun === true
        ? "Accepted full run"
        : "Historical run; full-run provenance unavailable");
    if (age > 7) {
      freshness.textContent += " · Catalog too old for a wallet refresh.";
      freshness.classList.add("warning");
    }
    const near = Object.values(latest.networks || {}).reduce(
      (sum, n) =>
        Number.isFinite(n.atTip) && Number.isFinite(sum) ? sum + n.atTip : NaN,
      0,
    );
    const tiles = [
      [latest.dialled, "endpoints attempted"],
      [
        latest.usable,
        "advertised compact filters · " +
          share(latest.usable, latest.dialled) +
          " of attempts",
      ],
      [near, "filter peers within 100 blocks of the reference tip"],
    ];
    document.getElementById("run-context").textContent =
      "Reference height: " +
      number(latest.observedTip) +
      " · Median probe duration: " +
      (Number.isFinite(latest.handshakeLatencyMsMedian)
        ? number(latest.handshakeLatencyMsMedian / 1000) + " s"
        : "Unavailable") +
      " · Median announced fee filter: " +
      (latest.medianFeeFilterSatPerKvB == null
        ? "Unavailable"
        : number(latest.medianFeeFilterSatPerKvB / 1000) + " sat/vB") +
      ". Near-tip counts are before catalog limits.";
    for (const [n, label] of tiles) {
      const tile = element("div", "");
      tile.className = "tile";
      const count = element("div", number(n));
      count.className = "n";
      const caption = element("div", label);
      caption.className = "l";
      tile.append(count, caption);
      document.getElementById("tiles").append(tile);
    }
    const outcomeLabels = {
      ok: "Handshake with compact filters",
      noCompactFilters: "Answered without compact filters",
      timeout: "Timed out",
      unreachable: "Connection failed",
    };
    for (const [name, n] of Object.entries(latest.outcomes || {}).sort())
      row("outcomes", [
        outcomeLabels[name] || name,
        number(n),
        share(n, latest.dialled),
      ]);
    for (const [name, n] of Object.entries(latest.networks || {}).sort())
      row("networks", [
        { clearnet: "Clearnet (IPv4 + IPv6)", tor: "Tor", i2p: "I2P" }[name] ||
          name,
        number(n.dialled),
        number(n.usable) + " (" + share(n.usable, n.dialled) + ")",
        number(n.noCompactFilters),
        share(n.atTip, n.usable),
      ]);
    const families = [
      ...new Set([
        ...Object.keys(latest.families || {}),
        ...Object.keys(latest.wholeNetworkFamilies || {}),
      ]),
    ].sort();
    for (const name of families) {
      const f = latest.families?.[name] || {};
      row("families", [
        name,
        number(latest.wholeNetworkFamilies?.[name]),
        number(f.usable),
        share(f.atTip, f.usable),
        f.medianFeeFilterSatPerKvB == null
          ? "Unavailable"
          : number(f.medianFeeFilterSatPerKvB / 1000) + " sat/vB",
      ]);
    }
    for (const [url, title] of [
      ["census/" + last.date + ".json", "Latest aggregate JSON"],
      ["census/index.json", "Daily index JSON"],
      ["census/peers.json", "Wallet candidate catalog JSON"],
      ["census/peers.json.sig", "Catalog signature"],
      ["census/signing-public-key.txt", "Publisher public key"],
      [
        "https://github.com/winnowwallet/census/actions/workflows/peer-census.yml",
        "Source snapshots, raw observations and run logs",
      ],
    ]) {
      const a = element("a", title);
      a.href = url;
      const li = element("li", "");
      li.append(a);
      document.getElementById("artifacts").append(li);
    }
    document.getElementById("provenance").textContent =
      "Observation window: " +
      latest.generatedAt +
      " to " +
      (latest.observationEndedAt || "end time unavailable") +
      ". Input SHA-256: " +
      (latest.inputSHA256 || "not recorded") +
      ". Processing revision: " +
      (latest.processingRevision || "not recorded") +
      ". Processed at: " +
      (latest.processedAt || "not recorded") +
      ".";
    const svg = document.getElementById("trend"),
      ns = "http://www.w3.org/2000/svg";
    const add = (tag, attrs, text) => {
      const e = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      if (text) e.textContent = text;
      svg.append(e);
    };
    const start = Date.parse(days[0].date),
      end = Date.parse(last.date),
      span = end - start || 86400000;
    const x = (d) => 48 + ((Date.parse(d.date) - start) / span) * 655,
      y = (v) => 184 - v * 1.55;
    for (let n = 0; n <= 100; n += 25) {
      add("line", {
        x1: 48,
        x2: 703,
        y1: y(n),
        y2: y(n),
        stroke: "var(--rule)",
      });
      add(
        "text",
        {
          x: 42,
          y: y(n) + 4,
          "text-anchor": "end",
          fill: "currentColor",
          "font-size": 13,
        },
        n + "%",
      );
    }
    const series = [
      {
        color: "var(--blue)",
        value: (d) =>
          d.dialled > 0 && Number.isFinite(d.usable)
            ? (100 * d.usable) / d.dialled
            : null,
      },
      {
        color: "var(--red)",
        value: (d) =>
          d.usable > 0 && Number.isFinite(d.stuckAtSplit)
            ? (100 * d.stuckAtSplit) / d.usable
            : null,
      },
    ];
    for (const s of series) {
      let previous = null;
      for (const d of days) {
        const v = s.value(d);
        if (v == null) {
          previous = null;
          continue;
        }
        if (
          previous &&
          Date.parse(d.date) - Date.parse(previous.date) === 86400000
        )
          add("line", {
            x1: x(previous),
            y1: y(s.value(previous)),
            x2: x(d),
            y2: y(v),
            stroke: s.color,
            "stroke-width": 2,
          });
        add("circle", { cx: x(d), cy: y(v), r: 3, fill: s.color });
        previous = d;
      }
    }
    days.forEach((d, i) => {
      if (
        i % Math.max(1, Math.ceil(days.length / 7)) === 0 ||
        i === days.length - 1
      )
        add(
          "text",
          {
            x: x(d),
            y: 210,
            fill: "currentColor",
            "font-size": 13,
            "text-anchor": "middle",
          },
          d.date.slice(5),
        );
    });
  } catch (error) {
    const status = document.getElementById("freshness");
    status.textContent =
      "Census data could not be loaded. Please try again or use the source and run logs linked below. " +
      error.message;
    status.classList.add("warning");
  }
})();
