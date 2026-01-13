
# SharePoint List Items — Export & Import Manual Test Checklist

Focus: verify exporting SharePoint lists to the export format and importing list rows into Altus tables. These cases cover common SharePoint field types and mapping behaviors.

## Export (SharePoint -> Export folder)

- [x] L-E1 — Simple single-row export
  - Verify: Single list item exported; `metadata.json` (or manifest) records field names and values.

- [x] L-E2 — Text fields
  - Verify: `Single line of text` and `Multiple lines of text` fields exported correctly (line breaks preserved for multi-line).

- [x] L-E3 — Choice and Multi-choice
  - Verify: `Choice` fields exported as single value; `Multi-choice` exported as array or delimiter-separated values in manifest.

- [x] L-E4 — Number, Currency, and Percent
  - Verify: Numeric fields preserve numeric type/format in the export manifest (not just string), including decimal places and currency symbols if applicable.

- [x] L-E5 — Date and DateTime
  - Verify: Date-only and DateTime fields exported in ISO-8601 with timezone info where applicable.

- [x] L-E6 — Lookup fields
  - Verify: Lookup fields export the target item ID and display value (e.g., `LookupId`, `LookupValue`) in the manifest.

- [x] L-E7 — Person/Group fields
  - Verify: Author/Editor and custom `Person` fields export principal info (`LoginName`, `Email`, `Title`).

- [x] L-E8 — Yes/No fields
  - Verify: Boolean fields exported as true/false values in manifest.

## Import (Export folder -> Altus tables)

- [x] L-I1 — Create single row in Altus table
  - Verify: Exported row maps to a new record in the Altus table with matching field values.

- [x] L-I2 — Text fields mapping
  - Verify: Single and multi-line text mapped to Altus column types; multi-line preserved.

- [x] L-I3 — Choice and Multi-choice mapping
  - Verify: Choice maps to single-value Altus enum/lookup; multi-choice maps to multi-value column or related child table as defined.

- [x] L-I4 — Numeric mapping
  - Verify: Number/Currency/Percent fields map to numeric Altus columns and preserve precision.

- [x] L-I5 — Date/DateTime mapping
  - Verify: Dates imported in UTC or tenant-expected timezone; time component maintained for DateTime fields.

- [x] L-I6 — Lookup mapping
  - Verify: Lookup fields map to Altus foreign keys (match by ID or by specified display value); missing referenced records are either created or reported.

- [x] L-I7 — Person/Group mapping
  - Verify: Person fields map to Altus user references (by email or login); if user not found, import flags as unresolved and logs it.

- [x] L-I8 — Boolean mapping
  - Verify: Yes/No fields map to boolean columns in Altus.
