(() => {
  const field = document.getElementById("doc-search");
  const results = document.getElementById("search-results");
  if (!field || !results) return;

  const base = document.querySelector('meta[name="site-baseurl"]')?.content ?? "";
  let pages = [];
  fetch(`${base}/search-index.json`)
    .then((response) => {
      if (!response.ok) throw new Error(`Search index request failed: ${response.status}`);
      return response.json();
    })
    .then((index) => { pages = index; })
    .catch((error) => {
      results.textContent = `Search is unavailable: ${error.message}`;
    });

  field.addEventListener("input", () => {
    results.replaceChildren();
    const query = field.value.trim().toLocaleLowerCase();
    if (!query) return;
    const terms = query.split(/\s+/);
    for (const page of pages) {
      const text = `${page.title} ${page.text}`.toLocaleLowerCase();
      if (!terms.every((term) => text.includes(term))) continue;
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = `${base}${page.url}`;
      link.textContent = page.title;
      item.append(link);
      results.append(item);
    }
    if (!results.childElementCount) results.textContent = "No matching pages.";
  });
})();
