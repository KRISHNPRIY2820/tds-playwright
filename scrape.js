const { chromium } = require("playwright");

async function main() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  let grandTotal = 0;

  for (let seed = 0; seed <= 9; seed++) {
    const url = `https://sanand0.github.io/tdsdata/js_table/?seed=${seed}`;

    console.log(`\nOpening seed ${seed}: ${url}`);

    await page.goto(url, { waitUntil: "networkidle" });

    // Wait until at least one table cell appears after JavaScript renders the page.
    await page.locator("table td").first().waitFor();

    const cellTexts = await page.locator("table td").allTextContents();

    let pageTotal = 0;

    for (const text of cellTexts) {
      // Finds integers and decimals, including negative numbers.
      const numbers = text.match(/-?\d+(?:\.\d+)?/g) || [];

      for (const value of numbers) {
        pageTotal += Number(value);
      }
    }

    grandTotal += pageTotal;
    console.log(`SEED_${seed}_TOTAL=${pageTotal}`);
  }

  console.log("\n====================================");
  console.log(`FINAL_TABLE_SUM=${grandTotal}`);
  console.log("====================================");

  await browser.close();
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
