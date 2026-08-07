from playwright.sync_api import sync_playwright

seeds = range(70, 80)
grand_total = 0

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()

    for seed in seeds:
        url = f"https://sanand0.github.io/tdsdata/js_table/?seed={seed}"

        # Open the page and wait until its JavaScript has finished loading
        page.goto(url, wait_until="networkidle")

        # Wait until at least one cell exists in the table
        page.locator("table td").first.wait_for()

        # Read text from every data cell in every table
        cell_texts = page.locator("table td").all_text_contents()

        # Convert text such as "153" into numbers, then add them
        numbers = [int(text.strip()) for text in cell_texts]
        table_total = sum(numbers)

        # Safety check: each page should have 50 rows × 10 columns = 500 cells
        print(f"Seed {seed}: {len(numbers)} values, sum = {table_total}")

        if len(numbers) != 500:
            print(f"Warning: seed {seed} did not return 500 table values.")

        grand_total += table_total

    browser.close()

print("\nTotal sum =", grand_total)
