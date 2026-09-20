(async () => {
  const status = document.getElementById("health-status");
  try {
    const response = await fetch("../census/health.json", {
      cache: "no-store",
    });
    if (!response.ok) throw new Error("baseline unavailable");
    const health = await response.json();
    if (health.schemaVersion !== 1) throw new Error("unknown baseline format");
    const mining = health.mining;
    status.textContent =
      "Evaluated " +
      health.asOf +
      " · " +
      health.acceptedDays.length +
      " accepted days (" +
      health.acceptedDays[0] +
      " to " +
      health.acceptedDays.at(-1) +
      "). Mining retrieved " +
      (mining.source?.retrievedAt || "unavailable") +
      ". These are different observation windows.";
    const rows = [
      [
        "Endpoint consistency",
        (health.assessedNodeCount || 0).toLocaleString() +
          " / " +
          health.nodeCount.toLocaleString() +
          " endpoints assessed",
        "At least three attempted days per endpoint in a rolling 30-day observed population. Missing attempts are not failures.",
      ],
      [
        "Reported services",
        "Separate from consistency",
        "Advertisements describe capabilities; they do not prove correct responses.",
      ],
      [
        "Estimated hashrate",
        Number.isFinite(mining.currentHashrateEHs)
          ? mining.currentHashrateEHs.toFixed(1) + " EH/s"
          : "Unavailable",
        "Source current estimate; exact averaging window unavailable.",
      ],
      [
        "Difficulty",
        Number.isFinite(mining.currentDifficulty)
          ? (mining.currentDifficulty / 1e12).toFixed(2) + " trillion"
          : "Unavailable",
        "Proof-of-work difficulty reported by the mining source.",
      ],
      [
        "Pool concentration / block intervals",
        "Unavailable",
        "No preserved measurement in this baseline.",
      ],
      [
        "Overall Bitcoin health index",
        "Not yet scored",
        "Requires repeated observations and a published, tested composite model.",
      ],
    ];
    const body = document.querySelector("#health-components tbody");
    if (
      /^health-nodes-[a-f0-9]{64}\.json\.gz$/.test(
        health.nodesArtifact?.file || "",
      )
    ) {
      const link = document.getElementById("health-nodes-link");
      link.href = "../census/" + health.nodesArtifact.file;
      link.hidden = false;
    }
    for (const row of rows) {
      const tr = document.createElement("tr");
      for (const value of row) {
        const td = document.createElement("td");
        td.textContent = value;
        tr.append(td);
      }
      body.append(tr);
    }
    const points = mining.hashrateSeries || [];
    if (!points.length) {
      document.getElementById("mining-trend").parentElement.hidden = true;
      return;
    }
    const svg = document.getElementById("mining-trend"),
      ns = "http://www.w3.org/2000/svg";
    const add = (tag, attrs, text) => {
      const e = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      if (text) e.textContent = text;
      svg.append(e);
    };
    const low =
      Math.floor(Math.min(...points.map((p) => p.hashrateEHs)) / 100) * 100;
    const high =
      Math.ceil(Math.max(...points.map((p) => p.hashrateEHs)) / 100) * 100;
    const first = points[0].timestamp,
      last = points[points.length - 1].timestamp;
    const x = (p) =>
      64 + ((p.timestamp - first) / (last - first || 86400)) * 625;
    const y = (v) => 180 - ((v - low) / (high - low || 100)) * 155;
    for (let i = 0; i <= 4; i++) {
      const value = low + ((high - low) * i) / 4;
      add("line", {
        x1: 64,
        x2: 689,
        y1: y(value),
        y2: y(value),
        stroke: "var(--rule)",
      });
      add(
        "text",
        {
          x: 56,
          y: y(value) + 4,
          "text-anchor": "end",
          fill: "currentColor",
          "font-size": 13,
        },
        value.toFixed(0),
      );
    }
    add(
      "text",
      { x: 64, y: 16, fill: "currentColor", "font-size": 13 },
      "Estimated EH/s",
    );
    points.forEach((p, i) => {
      if (i && p.timestamp - points[i - 1].timestamp === 86400)
        add("line", {
          x1: x(points[i - 1]),
          y1: y(points[i - 1].hashrateEHs),
          x2: x(p),
          y2: y(p.hashrateEHs),
          stroke: "var(--accent)",
          "stroke-width": 2,
        });
      add("circle", {
        cx: x(p),
        cy: y(p.hashrateEHs),
        r: 2.5,
        fill: "var(--accent)",
      });
      if (i % 7 === 0 || i === points.length - 1)
        add(
          "text",
          {
            x: x(p),
            y: 210,
            fill: "currentColor",
            "font-size": 13,
            "text-anchor": "middle",
          },
          new Date(p.timestamp * 1000).toISOString().slice(5, 10),
        );
    });
  } catch (error) {
    status.textContent =
      "Health observations are unavailable. Visit the peer census for daily connection results. " +
      error.message;
    document.getElementById("mining-trend").parentElement.hidden = true;
  }
})();
