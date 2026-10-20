# Content Creation Instructions
## Version 2: Generate Documents and Connected Dynamics Data

Use this prompt to produce three coordinated deliverables:
1. Demo documents, meeting transcripts, Email threads, and Teams chats under `Content/Documents/<DemoName>/`.
2. `Content/content.json`, containing the matching `Sites` configuration for those artifacts.
3. `Content/contentDynamics.json`, containing the connected Dynamics 365 Sales and Customer Service (D365 Sales & CS) demo records, together with the existing data consumed by Dynamics 365 Finance & Operations (D365 F&O).

All paths in these instructions are relative to the repository root. Read the current `Content/contentDynamics.json` before generating anything. It is both the concrete schema reference and the authoritative demo-data baseline. Do not generate a second unrelated set of Dynamics records, overwrite the baseline with an empty template, or change existing IDs simply to regenerate content. Do not write tenant-specific selections into either source JSON file; `Content/content.custom.json` is installer-generated output.

Preserve the original prompt's document-generation requirements and all four demos. The Dynamics requirements below extend Demo 4, Unified Business Data. Generate Leads, Opportunities, Quotes, Orders, Invoices, and Cases using the actual examples already in `Content/contentDynamics.json`, including their related Accounts, Contacts, Products, Units, Unit Groups, Price Lists, Emails, and Field Engagements. The repeated mention of Quotes does not mean creating a duplicate collection.

For Demo 4 customer transactions, the current Dynamics file's Product names and Product Numbers take precedence over the supplier-focused Product restrictions later in this prompt. Keep the supplier and regulatory rules for the procurement demos. Do not rename existing customer Products merely to force them into a supplier-service name, or invent additional Products for the existing sales transactions.


Use these product names for reference. Do not use any other names for products other than the ones listed here. 
ALLER-10 EU carton / ALLER-20 EU carton (HelioPack, sup-003)
ALLER stability and release testing program (Crescent GMP Labs, sup-005)
ALLER Phase II clinical supply kits (Orchid Clinical Supply, sup-007)
ALLER commercial and clinical temperature-controlled shipments (Valence Cold Chain, sup-008)
BP-ALLER biologic drug substance program (BluePeak Biologics, sup-009)
ALLER device and packaging sterilization lots (LumaSterile, sup-011)
ALLER process development and validation program (Pioneer, sup-012)
ALLER excipient and specialty ingredient supply (Evergreen Excipients, sup-013)
Regional OTC bundles (Atlas Regional Manufacturing, sup-014)
ALLER global regulatory support program (Signal Ridge, sup-015)

Use these names for suppliers and raw materials. Do not use any other names for suppliers or raw materials other than listed here.

| ID | Supplier | Type | Region | Products / Materials | Raw Materials | Active |
|---|---|---|---|---|---|---|
| sup-001 | Aster Ridge Biomanufacturing | Contract manufacturer | North America | ALLER-10 tablets, ALLER-20 tablets | — | true |
| sup-002 | Northstar Fill Finish | Contract manufacturer | North America | ALLER-INJ prefilled syringe program | — | true |
| sup-003 | HelioPack Pharma Services | Packaging partner | Europe | ALLER-10 EU carton, ALLER-20 EU carton | — | true |
| sup-004 | Meridian API Works | API supplier | Asia Pacific | AUR-API-7 active pharmaceutical ingredient | AUR-API-7 (active pharmaceutical ingredient), RM-72 (raw material precursor) | true |
| sup-005 | Crescent GMP Labs | Quality lab | North America | ALLER stability and release testing program | — | true |
| sup-006 | Summit Dose Manufacturing | Contract manufacturer | Europe | ALLER-CAP 25 mg, ALLER-CAP 50 mg | — | true |
| sup-007 | Orchid Clinical Supply | Clinical supply partner | North America | ALLER Phase II clinical supply kits | — | true |
| sup-008 | Valence Cold Chain Logistics | Logistics partner | Global | ALLER commercial and clinical temperature-controlled shipments | — | true |
| sup-009 | BluePeak Biologics | Contract manufacturer | North America | BP-ALLER biologic drug substance program | — | true |
| sup-010 | Keystone Device Assembly | Combination device partner | North America | ALLER auto-injector assembly | — | true |
| sup-011 | LumaSterile Services | Sterilization partner | Europe | ALLER device and packaging sterilization lots | — | true |
| sup-012 | Pioneer Process Development | Process development partner | North America | ALLER process development and validation program | — | true |
| sup-013 | Evergreen Excipients | Materials supplier | North America | ALLER excipient and specialty ingredient supply | Regulated excipient — lot EX-1026-A, Regulated excipient — lot EX-1026-B | true |
| sup-014 | Atlas Regional Manufacturing | Contract manufacturer | Latin America | ALLER-10 tablets, ALLER-20 tablets, regional OTC bundles | — | true |
| sup-015 | Signal Ridge Regulatory Services | Regulatory services partner | Global | ALLER global regulatory support program | — | true |

For financial investigation use the following table. Only use this data.
| Item | Type | Supplier | Product | Raw Materials | Source Reference |
|---|---|---|---|---|---|
| Deviation investigation | Invoice category / risk example | Northstar Fill Finish (sup-002) | ALLER-INJ prefilled syringe program | — | suppliers.json — invoice_categories, risk_examples ("deviation investigation billed without approval") |
| Contamination investigation | Invoice line (actual billed, disputed) | BluePeak Biologics (sup-009) | BP-ALLER biologic drug substance program | — | Invoice INV-SUP-009-2026-Q4-L004, ref DEV-BP-1026-SUPPLIER; scenario scn-sup-009-supplier-caused-investigation; issue_category: quality_deviation_charge; expected_decision_state: escalated |
| Rejected batch rework / investigation / restart charges | Policy clause (cross-supplier) | Applies broadly to contract manufacturers: Aster Ridge (sup-001), Northstar Fill Finish (sup-002), Summit Dose Manufacturing (sup-006), BluePeak Biologics (sup-009), Atlas Regional Manufacturing (sup-014) | ALLER-10/ALLER-20 tablets, ALLER-INJ, ALLER-CAP 25/50 mg, BP-ALLER, regional OTC bundles | — | policies/source-markdown/quality-release-billability-policy.md, Section 4 ("Rejected batches") |
| Fraud prevention | Narrative/industry framing (not a feature or supplier-specific) | N/A | N/A | N/A | modules/corpus/docs/waypoint-narrative-grounding.md ("fraud prevention" cited as a generic procure-to-pay business outcome) |

#### Regulatory agency naming
This demo may be provisioned for tenants in different geographic locations, so content must not name a specific real-world regulatory body (e.g. FDA, EMA, MHRA). Refer to it generically instead — "the regulatory authority" / "regulators" — everywhere a reviewing agency is mentioned (regulatory submission status, dosing claim language approval, etc.). Signal Ridge (the named regulatory support supplier above) is the only proper name to use in this context.

#### Timeline
Author the storyline on a consistent internal calendar (documents, meetings, emails, and chats should all reference the same dates and cross-reference the same events/decisions). The most recent event (typically the executive checkpoint) must not be dated later than "today" — every event needs to convert to a negative day-offset (see below), so nothing in the story can be scheduled in the future relative to whenever this gets installed.

## Content Configuration
Running this prompt should produce three coordinated outputs: the content files under `Content/Documents/<DemoName>/`, matching entries in `Content/content.json`, and the connected demo dataset in `Content/contentDynamics.json` as specified in the Dynamics configuration section below. `content.json` has one top-level `Sites` array, with one object per demo:

#### Clean up before generating
Before generating content for a demo, check whether `Content/Documents/<DemoName>/` already contains files from a previous run. If it does, delete the existing content in that folder first, so the newly generated documents aren't mixed with stale ones.

```json
{
  "Sites": [
    {
      "Title": "Market Research Team",       // SharePoint site name
      "URL": "MarketResearchTeam",           // SharePoint site URL slug
      "Description": "...",
      "EnableMicrosoftTeams": true,
      "IsPublic": false,
      "DynamicsContent": false,
      "Owners": ["<user email>", ...],       // from settings.json's Users
      "Members": ["<user email>", ...],
      "Content": {
        "Documents": [ /* SharePoint documents */ ],
        "Meetings": [ /* Past Teams meetings, each linked to a transcript file */ ],
        "EmailThreads": [ /* Email discussions */ ],
        "Chats": [ /* Teams chats */ ],
        "Lists": [ /* Lists */ ],
        "Libraries": [ /* Libraries */ ]
      }
    }
  ]
}
```

`Documents` and `EmailThreads` share the same file-entry shape (they're just files uploaded into the site's document library):

```jsonc
{
  "Title": "Clinical Formulation Overview",
  "Path": "Content/Documents/Demo1/SharePoint_Documents/Clinical Formulation Overview.pdf",
  "CreatedOffset": -102,                     // days before install day (always negative)
  "CreatedBy": "charlotte.waltson@<TENANTPREFIX>.onmicrosoft.com",
  "ModifiedOffset": -102,
  "ModifiedBy": "charlotte.waltson@<TENANTPREFIX>.onmicrosoft.com"
}
```

- `Path` is repo-relative (from the repository root, including the `Content/` prefix) and must point at a real file under `Content/Documents/<DemoName>/<Category>/`, where `<Category>` is `SharePoint_Documents`, `Meeting_Transcripts`, or `Email_Threads` to match the folder each content type is saved into.
- `CreatedBy`/`ModifiedBy` are demo user emails from `Configuration/settings.json`'s `Users` list.
- For a single-session document, `CreatedOffset` and `ModifiedOffset` are the same. For an email thread, use the date of the first message as `Created`/`CreatedBy` and the date of the last message as `Modified`/`ModifiedBy`.

`Meetings` entries describe a past Teams meeting. The installer creates it on the team calendar, uploads its transcript Word document (`.docx`) to the channel's `Meeting Transcripts` folder, and posts a message in the channel linking to it:

```jsonc
{
  "Title": "Launch Readiness Review",
  "StartOffset": -15,                       // days before install day (always negative, so the meeting is in the past)
  "StartTime": "11:00:08",                  // HH:mm:ss (UTC) - the first [HH:MM:SS] timestamp in the transcript
  "DurationMinutes": 6,                     // from the first to the last transcript timestamp, plus a minute (minimum 5)
  "Organizer": "charlotte.waltson@<TENANTPREFIX>.onmicrosoft.com",
  "TranscriptPath": "Content/Documents/Demo1/Meeting_Transcripts/Launch Readiness Review.docx"
}
```

- `TranscriptPath` follows the same repo-relative rules as `Path` above and must be a `.docx` file in `Meeting_Transcripts`.
- Attendees are read from the transcript's `Attendees:` paragraph, so every attendee must be a demo user from `settings.json`'s `Users` list, written as `Full Name (Job Title)`.
- `StartOffset` must be consistent with the other dates for the site (documents, emails, chats), and never in the future.

`Chats` keeps its existing shape — `Title`, `Members` (full names), and `Messages` (`Offset`, `Time`, `Sender`, `Message`) — derived directly from the corresponding Teams chat markdown file, so the JSON and the file stay in sync.

##### @mentions in chat messages
A message may @mention another member of that same chat by writing `@FirstName LastName` inline (must exactly match one of that chat's `Members` entries) — this renders as a real, notifying Teams mention when installed. Use it naturally, only where a real person would actually tag someone (looping someone in, a direct question, flagging urgency) — not in every message. A chat that's all mentions reads unnaturally.

#### Lists and content types
Every entry in `Lists` and `Libraries` must define a content type using the same `ContentTypes` syntax. Columns belong inside the content type (`ContentTypes[].Columns`), not directly on the list/library.

Content types and site columns each carry two names:
- **Content type**: `InternalName` is the list/library `Title` with spaces removed and camel-cased (e.g. "Supplier Directory" → `supplierDirectory`, "Procurement Exception" → `procurementException`); `DisplayName` is the list/library `Title` exactly (e.g. "Supplier Directory"). The provisioner creates the content type in SharePoint under its `DisplayName`.
- **Site column**: `DisplayName` is the human-readable label (e.g. "Supplier ID"); `InternalName` is that label with spaces removed and camel-cased, with only the first letter of each word capitalised, so "ID" becomes "Id" (e.g. "Supplier ID" → `supplierId`, "Products Materials" → `productsMaterials`). `InternalName` becomes the SharePoint internal name. Every column must have both.
- Everywhere else in `content.json` that refers to a column — keys in `Items`, `FieldRef Name='...'` in view `Query`, and view `Fields` — use the column's `InternalName` (e.g. `supplierId`), never the `DisplayName`.

```jsonc
{
  "Title": "Supplier Directory",
  "Template": "GenericList",
  "ContentTypes": [
    {
      "InternalName": "supplierDirectory",
      "DisplayName": "Supplier Directory",
      "Columns": [
        { "InternalName": "supplierId", "DisplayName": "Supplier ID", "Type": "Text" },
        { "InternalName": "region", "DisplayName": "Region", "Type": "Choice", "Choices": ["North America", "Europe"] },
        { "InternalName": "active", "DisplayName": "Active", "Type": "Boolean" }
      ]
    }
  ],
  "Views": [ /* ... */ ],
  "Items": [ /* ... */ ]
}
```

#### Transcript Word document structure
Meeting transcripts are `.docx` files (so they open in Teams). The installer reads and rewrites them, so keep this exact structure:
- A Heading 1 paragraph: `Meeting Transcript: <Title>`.
- One paragraph: a bold run `Attendees:` followed by a plain run `Full Name (Job Title), Full Name (Job Title), ...`.
- A horizontal rule (paragraph bottom border) separating the header from the dialogue.
- One paragraph per spoken line: a bold run `[HH:MM:SS] Full Name:` followed by a plain run with the spoken text.
- Names appear as unbroken text within a single run (never split a name across runs or formatting changes), because the installer swaps the demo personas' names for the provisioned users' names inside the document.
- No tables, text boxes, headers or footers, and no date line.

#### No metadata duplication in file bodies
`content.json` is the only place `Title`/`Created*`/`Modified*` lives. Don't also restate it inside the file itself:
- **SharePoint documents**: no "Prepared by" / "Date prepared" / "Last updated" header line, and no "Update Log" section restating those dates. Start straight into the content after the title (a short "Product:" / "Classification:" line is fine — that's not tracked in `content.json`).
- **Meeting transcripts**: no "Date:" line. Keep "Attendees:" (not tracked elsewhere). Every spoken line must be its own paragraph in the form `[HH:MM:SS] Full Name: text` with timestamps that only increase - the start time and duration are derived from them. See "Transcript Word document structure" below. The meeting's date and time live only in its `content.json` `Meetings` entry.
- **Email threads** and **Teams chats** are exempt from this rule — the per-message `From`/`Date` (emails) and `Sender`/timestamp (chats) are the actual content, not a redundant summary block, and `content.json`'s entries for them are derived from that content rather than duplicating it.

## Dynamics Content Configuration and Record Generation

### Authoritative schema and baseline

Write one JSON object at `Content/contentDynamics.json`, with the collections listed below. Preserve exact property names and casing. In particular, Cases are stored under `Incidents`, not `Cases`; Orders are stored under `Orders`, not `SalesOrders`. Use display names in prose and existing property names in JSON.

The field inventory below is extracted from the union of fields across every current record, not just the first record. A field present in some examples is not automatically required on every record: retain the existing optional/null behavior and status-specific fields. Preserve current scalar types, nested structures, and accepted values. If the live source has evolved, inspect it and the corresponding provisioning functions before extending this inventory. Do not invent fields that the installer does not consume.
| Collection / Display Name | Baseline Records | Existing Fields |
|---|---:|---|
| `Accounts` / Accounts | 6 | `AccountNumber`, `City`, `Country`, `CreatedOffset`, `Description`, `Id`, `Industry`, `Name`, `Owner`, `Phone`, `PrimaryContactId`, `State`, `Website` |
| `Contacts` / Contacts | 8 | `AccountId`, `CreatedOffset`, `Description`, `Email`, `FirstName`, `Id`, `JobTitle`, `LastName`, `Owner`, `Phone` |
| `Leads` / Leads | 5 | `CompanyName`, `CreatedOffset`, `Description`, `Email`, `FirstName`, `Id`, `LastName`, `LeadSource`, `Owner`, `Rating`, `Status`, `Subject` |
| `UnitGroups` / Unit Groups | 1 | `BaseUnitName`, `Id`, `Name` |
| `Units` / Units | 2 | `Id`, `Name`, `Quantity`, `UnitGroupId` |
| `PriceLists` / Price Lists | 1 | `Description`, `Id`, `Name` |
| `Products` / Products | 10 | `CreatedOffset`, `Description`, `Id`, `Name`, `PriceListId`, `PriceListItemId`, `ProductNumber`, `Status`, `UnitGroupId`, `UnitId`, `UnitPrice` |
| `Opportunities` / Opportunities | 11 | `AccountId`, `ActualCloseOffset`, `ActualRevenue`, `ContactId`, `CreatedOffset`, `Description`, `EstimatedCloseOffset`, `EstimatedRevenue`, `Id`, `Lines`, `Name`, `Owner`, `PriceListId`, `Probability`, `Status` |
| `Quotes` / Quotes | 8 | `AccountId`, `ContactId`, `CreatedOffset`, `Description`, `Id`, `Lines`, `Name`, `OpportunityId`, `Owner`, `PriceListId`, `QuoteNumber`, `Status`, `TotalAmount`, `ValidUntilOffset` |
| `Orders` / Orders | 7 | `AccountId`, `CanceledOffset`, `ContactId`, `CreatedOffset`, `Description`, `FulfilledOffset`, `Id`, `Lines`, `Name`, `OpportunityId`, `OrderNumber`, `Owner`, `PriceListId`, `QuoteId`, `RequestedDeliveryOffset`, `Status`, `TotalAmount` |
| `Invoices` / Invoices | 6 | `AccountId`, `ContactId`, `CreatedOffset`, `Description`, `DueOffset`, `Id`, `InvoiceNumber`, `Lines`, `Name`, `OrderId`, `Owner`, `PriceListId`, `Status`, `StatusReason`, `TotalAmount` |
| `Incidents` / Cases | 6 | `AccountId`, `ContactId`, `CreatedOffset`, `Description`, `Id`, `InvoiceId`, `OrderId`, `Origin`, `Owner`, `Priority`, `ProductId`, `Resolution`, `ResolvedOffset`, `Status`, `TicketNumber`, `Title` |
| `FieldEngagements` / Field Engagements | 8 | `AccountId`, `ContactId`, `CreatedOffset`, `CurrentStatus`, `Description`, `Id`, `Name`, `Priority`, `Type` |
| `Emails` / Emails | 8 | `AccountId`, `Body`, `Cc`, `CreatedOffset`, `Date`, `Direction`, `From`, `Id`, `Owner`, `RegardingId`, `RegardingTable`, `SentOffset`, `Status`, `Subject`, `To` |

### Field types and nested structures

- Every top-level record in every collection has an `Id` that is a nonempty GUID string. Preserve existing GUIDs; allocate a new GUID only for a genuinely new record. Keep IDs stable across reruns and globally unique across entity records and transaction Lines.
- Every `Lines[]` item is also a record with its own unique GUID `Id`. Its current shape is `Id`, `ProductId`, `UnitId`, `Quantity`, `UnitPrice`, and `Amount`. Use numeric quantities and monetary values, not formatted currency strings. Do not reuse a line ID between an Opportunity, Quote, Order, and Invoice.
- `Products[].PriceListItemId` is a separate stable GUID identifying the associated Price List Item; it is not the Product ID. Keep it unique and retain the Product/Price List/Unit relationship.
- `CreatedOffset` and other offset fields are integers in days relative to installation. Preserve negative historical event offsets. Future deadlines such as `DueOffset`, `ValidUntilOffset`, or a requested delivery date may be positive when the baseline supports that scenario. This is an exception to the original prompt's past-event rule for documents and meetings; it does not allow future completed transactions or future sent Emails.
- `Owner` and internal Email participants use the demo identities in `Configuration/settings.json`, preserving `<TENANTPREFIX>`. Do not substitute the generator's personal UPN or a previously selected installation user's UPN. External Contact Email addresses remain the baseline customer addresses.
- Preserve the existing `Emails` structure: `From` is a string or a participant object if already supported, `To` and `Cc` are arrays of participant objects, and the current demo participants use `Email`. These embedded participant values are not standalone entity records and do not require invented IDs. If a participant uses an existing supported `ContactId`, it must resolve to `Contacts[].Id`.
- Preserve `Emails[].Date` as the existing `yyyy-MM-dd HH:mm` string format and keep it consistent with the corresponding story and offsets. Preserve string statuses and numeric custom-app choices; do not convert one into the other.
- Preserve current numeric choice values in `FieldEngagements` (`Priority`, `Type`, `CurrentStatus`) and existing human-readable statuses in the other collections. Derive allowed values from the complete baseline and the installer, not from one sample row.

### Required relationships and ID integrity

Build an ID registry before writing records. Resolve every nonempty lookup against the correct target collection. The IDs of different records must be distinct; it is the lookup value that matches the related record's ID.

| Source lookup | Required target / consistency rule |
|---|---|
| `Accounts[].PrimaryContactId` | `Contacts[].Id`; that Contact's `AccountId` must equal this Account's `Id`. |
| `Contacts[].AccountId` | `Accounts[].Id`. |
| `Units[].UnitGroupId` | `UnitGroups[].Id`. |
| `Products[].UnitGroupId` | `UnitGroups[].Id`. |
| `Products[].UnitId` | `Units[].Id`; the Unit must belong to the Product's Unit Group. |
| `Products[].PriceListId` | `PriceLists[].Id`. |
| `Opportunities[].AccountId`, `Quotes[].AccountId`, `Orders[].AccountId`, `Invoices[].AccountId` | The same `Accounts[].Id` throughout a connected commercial chain. |
| Transaction `ContactId` | `Contacts[].Id`; its `AccountId` must match the transaction Account. Preserve a chain's selected Contact consistently. |
| `Quotes[].OpportunityId` | `Opportunities[].Id`; Account, Contact, and Price List must agree. |
| `Orders[].OpportunityId` | `Opportunities[].Id`, matching the Opportunity referenced by its Quote. |
| `Orders[].QuoteId` | `Quotes[].Id`; Account, Contact, Opportunity, and Price List must agree. |
| `Invoices[].OrderId` | `Orders[].Id`; follow that Order's Quote and Opportunity to recover the same chain. Do not add unsupported `QuoteId` or `OpportunityId` fields to Invoices. |
| Transaction `PriceListId` | `PriceLists[].Id`, consistently across the connected chain. |
| Every `Lines[].ProductId` | `Products[].Id`. |
| Every `Lines[].UnitId` | `Units[].Id`, matching the referenced Product's `UnitId`. |
| `Incidents[].AccountId`, `ContactId`, `ProductId` | Existing Account, Contact, and Product; the Contact belongs to that Account. |
| Nonempty `Incidents[].OrderId`, `InvoiceId` | Existing Order/Invoice for that same Account; if both are supplied, the Invoice's `OrderId` matches the Case's `OrderId`. |
| `FieldEngagements[].AccountId`, `ContactId` | Existing Account and its Contact. |
| `Emails[].AccountId` | Existing Account associated with the discussion. |
| `Emails[].RegardingTable` + `RegardingId` | Resolve the pair together; preserve supported values `Accounts` or `Incidents`, and point to the corresponding record in that collection. Its Account must agree with the Email's `AccountId`. |

The current Lead schema has no `AccountId`, `ContactId`, or `OpportunityId`. Do not invent those properties to imply a relationship the installer does not create. Ground Leads in the existing Account/Contact storyline through `CompanyName`, names, Email, Subject, and Description. Explain the connection narratively where a Lead relates to an existing customer.

Nested Lines inherit their parent relationship from their containing record; do not invent a generic parent-ID field. Corresponding Lines across the commercial chain reference the same Products and Units and use consistent quantities/prices for an unchanged deal, but retain their own distinct line IDs.

### Generate the existing demo story, not disconnected records

Use the actual records in the live baseline as the starting content for each requested category:

- **Accounts and Contacts:** retain Meridian Health Alliance, Lakeshore Regional Health, Northbridge Medical Network, Cedar Valley Healthcare, Harborview Clinical Group, and Pinecrest Community Health, together with their existing Contacts and Primary Contact links.
- **Leads:** preserve the five existing ALLER expansion-interest Leads and their customer/persona details. Do not turn them into duplicate Quotes or silently convert their state.
- **Opportunities:** preserve initial-supply and expansion deals as well as the existing Open and Lost examples. A Lost Opportunity must not acquire a successful downstream fulfillment chain just to fill every collection.
- **Quotes:** preserve the accepted `CAL-QUO-001` through `CAL-QUO-007` Quotes and the Draft `CAL-QUO-008` example. Keep their actual Opportunity references, Lines, statuses, and values.
- **Orders:** preserve `CAL-ORD-001` through `CAL-ORD-007`, including the canceled Harborview Order `CAL-ORD-005`. Keep the Quote and Opportunity references intact.
- **Invoices:** preserve `CAL-INV-001`, `002`, `003`, `004`, `006`, and `007`, their current payment/status reasons, and their real Order links. Do not manufacture `CAL-INV-005` for the canceled Order.
- **Cases:** generate under `Incidents` using the six existing Cases: the cold-chain shipment delay, education-session request, prefilled-syringe delivery clarification, capsule-packaging documentation request, cancellation confirmation, and follow-up. Preserve each Case's actual customer and transaction references, including legitimate absent lookups. A resolved Case keeps its resolution details and resolved offset.
- **Emails and Field Engagements:** retain the existing follow-ups and associations; their subjects, participants, and descriptions must agree with the related customer and Case storyline and the Demo 4 documents.
- **D365 F&O:** retain Account Numbers, Product Numbers, Order Numbers, and Order Lines from this same file. These are source business keys, not replacements for GUIDs. D365 F&O can assign its own Sales Order Number; do not fabricate a Dataverse GUID relationship to that generated number.

Keep the complete live baseline, including examples not listed in the compact chain below. Counts in the schema inventory describe today's baseline, not a mandate to discard records if the source has gained additional examples. Expand narratives only where requested; maintain the original facts, codes, identities, quantities, statuses, and relationships.

### Concrete reference chain from the existing demo

The following IDs are copied from the Meridian initial-supply chain. Use them as cross-reference examples, not as IDs to assign to unrelated new records. `A`, `C`, `O`, `Q`, `S`, and `I` below denote different records:

- Account `A`: `2f4d1a5c-c6e5-42df-b612-128f460d129b` (Meridian Health Alliance).
- Contact `C`: `054e2d30-73ba-4052-9bfb-818263115c77` (Amelia Brooks), with `AccountId = A`; Account `A` has `PrimaryContactId = C`.
- Opportunity `O`: `22fa01ec-4ccd-4ed4-b628-d5b9f7f4723a`, with `AccountId = A` and `ContactId = C`.
- Quote `Q`: `3a596797-5b63-440c-b4e5-b4df76971ec1` (`CAL-QUO-001`), with `OpportunityId = O`, `AccountId = A`, and `ContactId = C`.
- Order `S`: `a44c26f5-b76b-4cb5-99c5-0f7753c548fd` (`CAL-ORD-001`), with `QuoteId = Q`, `OpportunityId = O`, `AccountId = A`, and `ContactId = C`.
- Invoice `I`: `81a52479-358c-47f9-bd0c-f359cce04b2f` (`CAL-INV-001`), with `OrderId = S`, `AccountId = A`, and `ContactId = C`.
- Case: `1a3a7b40-7be9-45fc-bafa-ca271a2be949` (`CAL-CASE-001`), linked to Account `A`, Contact `C`, Order `S`, and Invoice `I`.
- Price List: `e284508a-1e37-4a00-b65a-b4dee4ffd049`, shared by these commercial records.
- The baseline chain has two Lines totaling 2,850: 20 ALLER-10 tablets at 45 and 30 ALLER-20 tablets at 65. Copy the actual Product IDs, Unit IDs, and distinct line IDs from each corresponding baseline record.

### Demo 4: Account-Specific SharePoint Documents

These requirements apply only to **Demo 4 - Unified Business Data**. In addition to its shared documents, generate two documents for every Account in `Content/contentDynamics.json`, preserving the existing directory structure and filename pattern:

```text
Content/Documents/Demo4/SharePoint_Documents/
  Customer Engagement Summary.pdf
  Healthcare Account Strategy.docx
  Accounts/
    <Accounts[].Id>/
      <Accounts[].Name> Engagement Summary.pdf
      <Accounts[].Name> Strategy.docx
```

- Inspect the existing `Accounts/` folder before generating. Each child folder is the exact Account GUID from `Accounts[].Id`, not its name, Account Number, or a newly generated ID. Preserve existing GUID folder names and existing filenames. Include every Account, including Pinecrest Community Health.
- For example, Meridian Health Alliance uses `Accounts/2f4d1a5c-c6e5-42df-b612-128f460d129b/Meridian Health Alliance Engagement Summary.pdf` and `Accounts/2f4d1a5c-c6e5-42df-b612-128f460d129b/Meridian Health Alliance Strategy.docx`.
- Read `Content/Documents/Demo4/SharePoint_Documents/Customer Engagement Summary.pdf` as the content and structure reference for each `<Account Name> Engagement Summary.pdf`.
- Read `Content/Documents/Demo4/SharePoint_Documents/Healthcare Account Strategy.docx` as the content and structure reference for each `<Account Name> Strategy.docx`. Use this exact existing spelling of Healthcare in the reference filename.
- Adapt the references' sections, level of detail, and presentation to the individual company. Do not simply copy the shared multi-customer document or replace only its title. Produce a real PDF and a real Word document in their respective formats.
- **Each generated document must contain only the data and storyline belonging to that Account.** Use its actual name, Account Number, description, location, Contacts, and the Opportunities, Quotes, Orders, Invoices, Cases, Emails, and Field Engagements linked to its Account ID. Trace transaction and Product relationships through the IDs defined above. Mention an internal employee only in their role for this Account; include suppliers or Products only when supported by this Account's connected records.
- Exclude other Accounts' names, Contacts, transactions, figures, Cases, and engagement histories. Do not include portfolio-wide tables, cross-company comparisons, or unrelated customer examples carried over from the reference documents. A Lead may be included only when its CompanyName and Contact details unambiguously match this Account; Leads do not have an AccountId in the current schema.
- Keep amounts, transaction numbers, statuses, dates, decisions, and Contact details consistent with this Account's actual records. If the Account has no record for a section, omit the section or state that no activity is recorded; do not invent company-specific facts or borrow them from another Account.
- The earlier document-folder cleanup instruction must not remove these two shared reference documents before they have been read. Preserve them, the `Accounts/` hierarchy, GUID folder names, and filenames while regenerating each Account's two documents. Do not delete unrelated Demo 4 files or modify source IDs as part of this step.
- Validate that every Account has exactly the two required generated documents in its GUID folder, that both files open in the correct format, and that each document's content contains no unrelated Account data. Preserve any existing repository-relative document references; do not add unsupported document properties to the Dynamics JSON schema. The Account folders are used by the Dynamics SharePoint integration service.

### Validation before delivery

Parse both JSON files and validate the Dynamics dataset before declaring generation complete:

1. Confirm all 14 baseline collections and the `Sites` configuration are present and well-formed. No comments, placeholders masquerading as GUIDs, or trailing commas in generated JSON.
2. Validate every entity `Id`, every Line `Id`, and every Product `PriceListItemId` as a GUID; reject duplicates. Check every nonempty lookup against the correct collection.
3. Check every Contact/Account pairing and every Opportunity -> Quote -> Order -> Invoice chain for consistent customer, Contact, Price List, Product, and Unit relationships. Equal business relationships do not mean equal entity IDs.
4. Check `Amount = Quantity * UnitPrice` and transaction totals against their Lines, subject to any explicit adjustments already supported by the live schema. Preserve the baseline's zero-tax/zero-shipping assumptions; do not silently invent adjustments.
5. Check status transitions and event chronology. Preserve legitimately incomplete pipelines, Draft Quotes, Open/Lost Opportunities, canceled Orders, and the absence of Invoices for canceled Orders. Creation, fulfillment, sent, resolved, and close offsets must agree with the story.
6. Check every referenced document path in `Content/content.json` exists, and align Demo 4 documents/Emails/chats with the same customer names, transaction numbers, Products, Cases, and decisions in `Content/contentDynamics.json`.
7. Do not delete `Content/contentDynamics.json` or regenerate IDs as part of document-folder cleanup. Keep this file's existing demo records available as the baseline throughout generation.
8. Report both JSON output paths, record counts by collection, and the results of ID, relationship, amount, status, timeline, and artifact checks. If the baseline contains an inconsistency, report the exact record and reference; do not silently rewrite business facts or claim validation passed.

## Demo information

### Demo 1 - Navigating Organisational Intelligence
This demo should be provisioned in the Market Research Team site

#### SharePoint documents
Documents should be a mix of DOCX and PDF files.
- Product launch readiness assessment
- Next-generation product launch strategy
- Market access strategy
- Regulatory submission briefing
- Clinical formulation overview
- Product forecasting report
- Launch steering committee meeting notes
- Product risk register
- Commercialisation timeline

#### Teams meetings
Create a transcript for the teams meeting. Each of these meeting transcripts should be saved as a Word document (`.docx`), and each needs a `Meetings` entry in `content.json` (start offset, start time and duration) so the installer can create it as a past Teams meeting in the channel.

- Launch readiness review
- Regulatory strategy review
- Market access planning
- Cross-functional launch alignment
- Executive launch checkpoint

#### Email discussion
Create sample email discussions from the participants. The email threads should mimic the interaction between Caldova's employees. Save the data as markdown files

- Regulatory approval concerns
- Pricing strategy debate
- Market access planning
- Manufacturing readiness issues
- Product launch acceleration request

#### Teams chats
The Teams chats should mimic interaction between Caldova's employees discussing the topics suggested below. Data should be saved as a markdown file.

- Launch War Room
- Regulatory Team
- Marketing & Product Alignment
- Executive Launch Coordination

Users
These are the demo users that should be used when creating the scenarios
- Serena Ribeiro 
- Babak Shammas 
- Cassandra Dunn
- Charlotte Waltson
- David Power 

### Demo 2 - Intelligent Investigation
This demo should be provisioned in the Finance Team

#### SharePoint documents
Documents should be a mix of DOCX and PDF files.
- Supplier master agreement
- Contract manufacturing agreement
- Suppliers spend policy
- Invoice approval policy
- Procurement delegation matrix
- Audit procedures
- Investigation playbook
- Vendor due diligence file

#### Lists
Each list gets a content type per the "Lists and content types" rules.
- Supplier Directory List with view of approved supplies
- Financial Investigation Case list
- Procurement Exception list

#### Libraries
- Contract library with a content type (named per the "Lists and content types" rules) with a managed metadata site column for supplier name

#### Email discussion
Create sample email discussions from the participants. The email threads should mimic the interaction between Caldova's employees. Save the data as markdown files

- Supplier invoice clarification
- Procurement approval discussion
- Escalation to compliance
- Request for contract amendment

#### Teams chats
The Teams chats should mimic interaction between Caldova's employees discussing the topics suggested below. Data should be saved as a markdown file.

- Finance Operations
- Procurement Leadership
- Compliance Review

Users
These are the demo users that should be used when creating the scenarios
- Serena Ribeiro 
- Babak Shammas 
- Cassandra Dunn
- Charlotte Waltson
- David Power 

### Demo 3 - Copilot Cowork / Supplier Capacity Expansion
This demo should be provisioned in the Procurement team

#### SharePoint documents
- Documents should be a mix of DOCX and PDF files.
- Current supplier scorecard
- Supplier performance reviews
- Capacity planning report
- Raw material demand forecast
- Supplier expansion proposal
- RFP package
- Supplier evaluation criteria
- Supplier onboarding checklist

#### Teams meetings
Create a transcript for the teams meeting. Each of these meeting transcripts should be saved as a Word document (`.docx`), and each needs a `Meetings` entry in `content.json` (start offset, start time and duration) so the installer can create it as a past Teams meeting in the channel.

- Supplier Quarterly Review
- Emergency Capacity Review
- Procurement Steering Committee

#### Lists
Each list gets a content type per the "Lists and content types" rules.
- Supplier Directory List with view of approved supplies
- Supplier Capacity Tracker list
- RFPs list with metadata for active RFPs

#### Email discussion
Create sample email discussions from the participants. The email threads should mimic the interaction between Caldova's employees. Save the data as markdown files

- Capacity shortfall alert
- Supplier expansion proposal
- RFP clarification
- Supplier review preparation

#### Teams chats
The Teams chats should mimic interaction between Caldova's employees discussing the topics suggested below. Data should be saved as a markdown file.

- Procurement Operations
- Supply Chain Response Team
- Supplier Review Working Group

Users
These are the demo users that should be used when creating the scenarios
- Serena Ribeiro 
- Babak Shammas 
- Cassandra Dunn
- Charlotte Waltson
- David Power 

### Demo 4 - Unified Business Data
The site collections and teams related to this demo should be created in the Sales divi-sion. The Dynamics 365 records should be created in a dedicated environment.

#### Dynamics Sales

##### Entity
- Leads
- Opportunities
- Quotes
- Orders
- Invoices

#### Dynamics 365 Customer Service

#### Entity
- Account
- Contact
- Case (Incident)
- Activity

#### Finance and Operations

##### Entity
- Customers
- Products
- Sales Orders

#### Dataverse custom app
There should be a very simple custom Model Driven App to keep track of field-engagement records. Just one form to read/write data into a Dataverse table with a pre-defined navigation and usage pattern for demo purposes only.

##### Entity
Field-engagement records

#### SharePoint documents
Documents should be a mix of DOCX and PDF files.
- Healthcare account strategy
- Customer engagement summary
- Territory review
- Renewal strategy

Also generate the two Account-specific documents under `SharePoint_Documents/Accounts/<AccountId>/` for every Account, following **Demo 4: Account-Specific SharePoint Documents** above.

#### Email discussion
Create sample email discussions from the participants. The email threads should mimic the interaction between Caldova's employees. Save the data as markdown files

- Customer escalation
- Renewal discussion
- Product adoption review

#### Teams chats
The Teams chats should mimic interaction between Caldova's employees discussing the topics suggested below. Data should be saved as a markdown file.

- Account Team
- Customer Success

Users
These are the demo users that should be used when creating the scenarios
- Serena Ribeiro 
- Babak Shammas 
- Cassandra Dunn
- Charlotte Waltson
- David Power
