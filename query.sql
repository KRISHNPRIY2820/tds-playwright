WITH
-- A. Read every JSONL row. `payload` is text containing another JSON document,
-- so CAST it to DuckDB's JSON type.
raw_events AS (
    SELECT
        event_id,
        invoice_id,
        CAST(sequence AS BIGINT) AS sequence,
        CAST(emitted_at AS TIMESTAMPTZ) AS emitted_at,
        operation,
        CAST(payload AS JSON) AS p
    FROM read_json_auto(
    'q-duckdb-json-ledger-reconciliation-server-events (1).jsonl',
    format = 'newline_delimited'

    )
),

-- B. A transport replay has the same event_id. Keep one copy.
deduped_events AS (
    SELECT *
    FROM raw_events
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY event_id
        ORDER BY emitted_at DESC
    ) = 1
),

-- C. Choose the final event for each invoice.
-- Do NOT filter DELETE or PAID before this step.
latest_event AS (
    SELECT *
    FROM deduped_events
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY invoice_id
        ORDER BY sequence DESC, emitted_at DESC
    ) = 1
),

-- D. Now it is safe to filter to qualifying invoices.
-- COALESCE handles the two alternative schema paths.
eligible_invoices AS (
    SELECT
        invoice_id,
        p,
        COALESCE(
            p ->> '$.customer.region',
            p ->> '$.geography.region_code'
        ) AS region,
        COALESCE(
            p ->> '$.currency',
            p ->> '$.settlement.currency'
        ) AS currency,
        CAST(p ->> '$.issued_at' AS TIMESTAMPTZ) AS issued_at
    FROM latest_event
    WHERE operation <> 'DELETE'
      AND p ->> '$.status' = 'PAID'
      AND COALESCE(
            p ->> '$.customer.region',
            p ->> '$.geography.region_code'
          ) = 'APAC'
      AND CAST(p ->> '$.issued_at' AS TIMESTAMPTZ)
            >= TIMESTAMPTZ '2026-01-01 00:00:00+00'
      AND CAST(p ->> '$.issued_at' AS TIMESTAMPTZ)
            < TIMESTAMPTZ '2026-04-01 00:00:00+00'
),

-- E1. Expand v1's `lines` array.
-- v1 price is major currency text such as "1,234.50".
-- Remove commas, convert to DECIMAL, then multiply by 100 for minor units.
v1_lines AS (
    SELECT
        i.invoice_id,
        i.currency,
        i.issued_at,
        line.value ->> '$.sku' AS sku,
        CAST(
            CAST(
                REPLACE(line.value ->> '$.price', ',', '')
                AS DECIMAL(38, 6)
            ) * 100
            AS DECIMAL(38, 6)
        ) AS local_minor_unit_price,
        CAST(line.value ->> '$.quantity' AS BIGINT) AS quantity,
        CAST(line.value ->> '$.discount' AS DECIMAL(18, 6)) AS discount_percent
    FROM eligible_invoices AS i
    CROSS JOIN json_each(i.p -> '$.lines') AS line
    WHERE i.p -> '$.lines' IS NOT NULL
),

-- E2. Expand v2's `items` array.
-- v2 price is already integer minor units.
v2_lines AS (
    SELECT
        i.invoice_id,
        i.currency,
        i.issued_at,
        item.value ->> '$.sku' AS sku,
        CAST(item.value ->> '$.price' AS DECIMAL(38, 6))
            AS local_minor_unit_price,
        CAST(item.value ->> '$.quantity' AS BIGINT) AS quantity,
        CAST(item.value ->> '$.discount' AS DECIMAL(18, 6))
            AS discount_basis_points
    FROM eligible_invoices AS i
    CROSS JOIN json_each(i.p -> '$.items') AS item
    WHERE i.p -> '$.items' IS NOT NULL
),

-- F. Make both versions have identical columns.
-- Keep the calculation as DECIMAL, not FLOAT/DOUBLE.
normalized_lines AS (
    SELECT
        invoice_id,
        currency,
        issued_at,
        sku,
        local_minor_unit_price * quantity
            * (100 - discount_percent) / 100
            AS local_minor_after_discount
    FROM v1_lines

    UNION ALL

    SELECT
        invoice_id,
        currency,
        issued_at,
        sku,
        local_minor_unit_price * quantity
            * (10000 - discount_basis_points) / 10000
            AS local_minor_after_discount
    FROM v2_lines
),

-- G. Read rates as decimals. all_varchar=true avoids accidental FLOAT inference.
fx AS (
    SELECT
        currency,
        CAST(valid_from AS TIMESTAMPTZ) AS valid_from,
        CAST(usd_per_unit AS DECIMAL(38, 12)) AS usd_per_unit
    FROM read_csv_auto(
    'q-duckdb-json-ledger-reconciliation-server-fx (1).csv',
    all_varchar = true
)
),

-- H. Attach the latest rate with valid_from <= issued_at.
-- local minor units × USD per major unit = USD cents.
converted_lines AS (
    SELECT
        l.invoice_id,
        l.sku,

        -- Round EACH line to whole cents.
        CAST(
            ROUND(
                l.local_minor_after_discount * f.usd_per_unit,
                0
            )
            AS BIGINT
        ) AS usd_cents
    FROM normalized_lines AS l
    ASOF JOIN fx AS f
        ON l.currency = f.currency
       AND l.issued_at >= f.valid_from
),

-- I. Revenue by SKU, kept as integer cents.
sku_revenue AS (
    SELECT
        sku,
        SUM(usd_cents) AS sku_usd_cents
    FROM converted_lines
    GROUP BY sku
),

-- J. Pick the largest revenue. Alphabetical SKU resolves an exact tie.
top_sku AS (
    SELECT
        sku,
        sku_usd_cents
    FROM sku_revenue
    ORDER BY sku_usd_cents DESC, sku ASC
    LIMIT 1
),

-- K. Portfolio totals.
portfolio AS (
    SELECT
        (SELECT COUNT(*) FROM eligible_invoices) AS qualifying_invoice_count,
        COALESCE((SELECT SUM(usd_cents) FROM converted_lines), 0)
            AS total_usd_cents
)

-- L. Produce exactly one JSON object and format money without a currency symbol.
SELECT json_object(
    'qualifying_invoice_count', qualifying_invoice_count,
    'total_usd_revenue',
        CAST(total_usd_cents // 100 AS VARCHAR)
        || '.'
        || LPAD(CAST(total_usd_cents % 100 AS VARCHAR), 2, '0'),
    'top_sku', sku,
    'top_sku_usd_revenue',
        CAST(sku_usd_cents // 100 AS VARCHAR)
        || '.'
        || LPAD(CAST(sku_usd_cents % 100 AS VARCHAR), 2, '0')
) AS result
FROM portfolio
CROSS JOIN top_sku;
