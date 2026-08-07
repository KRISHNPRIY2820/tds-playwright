import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

let total = 0;

for (let seed = 0; seed <= 9; seed++) {
    const url = `https://sanand0.github.io/tdsdata/js_table/?seed=${seed}`;

    console.log(`Opening ${url}`);

    await page.goto(url, {
        waitUntil: "networkidle"
    });

    const numbers = await page.$$eval("table td", cells =>
        cells.map(cell => cell.innerText)
    );

    for (const value of numbers) {
        const n = Number(value);
        if (!isNaN(n))
            total += n;
    }
}

console.log("==========================");
console.log("TOTAL =", total);
console.log("==========================");

await browser.close();
