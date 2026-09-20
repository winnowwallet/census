/* Load endpoint history only when a reader asks to explore a selection. */
(() => {
  const state = { outcome: "", network: "", date: "" };
  let nodes, loading, originalFamilies;
  let selectionVersion = 0;
  const number = (n) => n.toLocaleString("en-US");
  const outcomeNames = {
    ok: "Handshake with compact filters",
    noCompactFilters: "Answered without compact filters",
    timeout: "Timed out",
    unreachable: "Connection failed",
  };
  const networkNames = {
    clearnet: "Clearnet (IPv4 + IPv6)",
    tor: "Tor",
    i2p: "I2P",
  };
  const family = (ua) =>
    !ua
      ? "Unknown"
      : /Knots:/i.test(ua)
        ? "Knots"
        : /Satoshi:/i.test(ua)
          ? "Core"
          : /btcd/i.test(ua)
            ? "btcd"
            : "Other";
  const el = (tag, text) => {
    const e = document.createElement(tag);
    e.textContent = text;
    return e;
  };
  const panel = document.getElementById("explorer");
  const status = document.getElementById("explorer-status");
  const select = document.getElementById("explorer-date");
  const clear = document.getElementById("explorer-clear");
  const families = document.getElementById("families");
  const matching = (n) => {
    const network =
      n.network === "ipv4" || n.network === "ipv6" ? "clearnet" : n.network;
    const observation = n.observations.find((o) => o.date === state.date);
    if (
      !observation ||
      (state.network && network !== state.network) ||
      (state.outcome && observation.outcome !== state.outcome)
    )
      return null;
    const last = [...n.observations]
      .filter((o) => o.date <= state.date && o.userAgent)
      .sort((a, b) => b.date.localeCompare(a.date))[0];
    return { node: n, observation, last, family: family(last?.userAgent) };
  };
  function render() {
    if (!nodes) return;
    const selected = nodes.map(matching).filter(Boolean);
    status.textContent =
      number(selected.length) +
      " endpoints · " +
      state.date +
      " · " +
      (outcomeNames[state.outcome] || "All outcomes") +
      " · " +
      (networkNames[state.network] || "All transports");
    document.getElementById("explorer-chips").replaceChildren();
    for (const key of ["outcome", "network"])
      if (state[key]) {
        const b = el(
          "button",
          (key === "outcome" ? outcomeNames : networkNames)[state[key]] + " ×",
        );
        b.type = "button";
        b.onclick = () => {
          state[key] = "";
          render();
        };
        document.getElementById("explorer-chips").append(b);
      }
    const counts = new Map();
    for (const row of selected) {
      const c = counts.get(row.family) || { total: 0, current: 0, previous: 0 };
      c.total++;
      if (row.last) {
        if (row.last.date === state.date) c.current++;
        else c.previous++;
      }
      counts.set(row.family, c);
    }
    const head = document.createElement("thead"),
      hr = document.createElement("tr");
    for (const label of [
      "Last reported software",
      "Endpoints",
      "Reported on selected day",
      "From an earlier day",
    ])
      hr.append(el("th", label));
    head.append(hr);
    const body = document.createElement("tbody");
    for (const [name, c] of [...counts].sort(
      (a, b) => b[1].total - a[1].total,
    )) {
      const tr = document.createElement("tr");
      for (const v of [
        name,
        number(c.total),
        number(c.current),
        number(c.previous),
      ])
        tr.append(el("td", v));
      body.append(tr);
    }
    if (!selected.length) {
      const tr = document.createElement("tr"),
        td = el("td", "No endpoints match these filters.");
      td.colSpan = 4;
      tr.append(td);
      body.append(tr);
    }
    families.replaceChildren(head, body);
    document.getElementById("software-note").textContent =
      "Filtered to the selection above. Software is the most recent user agent reported on or before this day. Earlier reports are historical claims; no report is shown as Unknown.";
    const list = document.getElementById("endpoint-list");
    list.replaceChildren();
    // Bound DOM work for large selections. The download retains all endpoints.
    for (const { node, observation, last } of selected.slice(0, 100)) {
      const details = document.createElement("details");
      details.className = "endpoint";
      details.append(el("summary", node.endpoint));
      details.append(
        el(
          "p",
          (outcomeNames[observation.outcome] || observation.outcome) +
            " · " +
            (last
              ? last.userAgent + " — reported " + last.date
              : "Software unknown"),
        ),
      );
      const history = document.createElement("ul");
      for (const o of [...node.observations]
        .filter((o) => o.date <= state.date)
        .sort((a, b) => b.date.localeCompare(a.date))) {
        history.append(
          el(
            "li",
            o.date +
              " · " +
              (outcomeNames[o.outcome] || o.outcome) +
              (o.userAgent ? " · " + o.userAgent : ""),
          ),
        );
      }
      details.append(history);
      list.append(details);
    }
    document.getElementById("endpoint-count").textContent =
      "Showing " +
      number(Math.min(100, selected.length)) +
      " of " +
      number(selected.length) +
      " matching endpoints. Expand an address for its observation history.";
    document.getElementById("endpoint-details").hidden = false;
    for (const button of document.querySelectorAll("[data-filter]"))
      button.setAttribute(
        "aria-pressed",
        String(state[button.dataset.filter] === button.dataset.value),
      );
  }
  async function load() {
    if (nodes) return;
    if (loading) return loading;
    loading = (async () => {
      status.textContent = "Loading endpoint history…";
      const r = await fetch("census/health.json", { cache: "no-store" });
      if (!r.ok) throw Error("Endpoint history unavailable");
      const h = await r.json();
      if (
        h.schemaVersion !== 1 ||
        !/^health-nodes-[a-f0-9]{64}\.json\.gz$/.test(
          h.nodesArtifact?.file || "",
        )
      )
        throw Error("Unknown endpoint history format");
      const response = await fetch("census/" + h.nodesArtifact.file);
      if (!response.ok) throw Error("Endpoint download unavailable");
      const bytes = new Uint8Array(await response.arrayBuffer());
      let text;
      if (bytes[0] === 31 && bytes[1] === 139) {
        if (typeof DecompressionStream === "undefined")
          throw Error(
            "This browser cannot open compressed history; use the JSON.gz download",
          );
        text = await new Response(
          new Blob([bytes])
            .stream()
            .pipeThrough(new DecompressionStream("gzip")),
        ).text();
      } else {
        text = new TextDecoder().decode(bytes);
      }
      const report = JSON.parse(text);
      if (report.schemaVersion !== 1 || !Array.isArray(report.nodes))
        throw Error("Unknown endpoint history format");
      const days = [...new Set(h.acceptedDays)].sort().reverse();
      if (!days.length) throw Error("No accepted history days");
      select.replaceChildren();
      for (const d of days) {
        const o = el("option", d);
        o.value = d;
        select.append(o);
      }
      state.date = days[0];
      select.value = state.date;
      const link = document.getElementById("explorer-download");
      link.href = "census/" + h.nodesArtifact.file;
      link.hidden = false;
      nodes = report.nodes;
      select.disabled = false;
    })();
    try {
      await loading;
    } finally {
      loading = null;
    }
  }
  async function choose(key, value) {
    const version = ++selectionVersion;
    panel.hidden = false;
    state[key] = state[key] === value ? "" : value;
    try {
      await load();
      if (version !== selectionVersion) return;
      render();
    } catch (error) {
      if (version !== selectionVersion) return;
      status.textContent = error.message + ". Try selecting an outcome again.";
    }
  }
  select.addEventListener("change", () => {
    state.date = select.value;
    render();
  });
  clear.addEventListener("click", () => {
    selectionVersion++;
    state.outcome = "";
    state.network = "";
    panel.hidden = true;
    document.getElementById("endpoint-details").hidden = true;
    if (originalFamilies) {
      families.innerHTML = originalFamilies;
      document.getElementById("software-note").textContent = originalNote;
    }
    for (const b of document.querySelectorAll("[data-filter]"))
      b.setAttribute("aria-pressed", "false");
  });
  const originalNote = document.getElementById("software-note").textContent;
  // Census rendering is asynchronous; enhance only once its tables exist.
  const observer = new MutationObserver(enhance);
  observer.observe(document.querySelector("#outcomes tbody"), {
    childList: true,
  });
  function enhance() {
    if (!document.querySelector("#families tbody tr")) return;
    originalFamilies = families.innerHTML;
    for (const [id, key, names] of [
      ["outcomes", "outcome", outcomeNames],
      ["networks", "network", networkNames],
    ]) {
      for (const cell of document.querySelectorAll(
        "#" + id + " tbody tr td:first-child",
      )) {
        const value = Object.keys(names).find(
          (k) => names[k] === cell.textContent,
        );
        if (!value) continue;
        const b = el("button", cell.textContent);
        b.type = "button";
        b.dataset.filter = key;
        b.dataset.value = value;
        b.setAttribute("aria-pressed", "false");
        b.onclick = () => choose(key, value);
        cell.replaceChildren(b);
      }
    }
    observer.disconnect();
  }
  enhance();
})();
