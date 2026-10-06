# Content Creation Instructions

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
Running this prompt should produce two things: the content files themselves under `Content/Documents/<DemoName>/`, and a matching entry in [content.json](Content/content.json) so the installer can actually provision them. `content.json` has one top-level `Sites` array, with one object per demo:

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
      "Owners": ["<user email>", ...],       // from settings.json's Users
      "Members": ["<user email>", ...],
      "Content": {
        "Documents": [ /* SharePoint documents */ ],
        "MeetingTranscripts": [ /* Teams meeting transcripts */ ],
        "EmailThreads": [ /* Email discussions */ ],
        "Chats": [ /* Teams chats */ ],
        "Lists": [ /* Lists */ ],
        "Libraries": [ /* Libraries */ ]
      }
    }
  ]
}
```

`Documents`, `MeetingTranscripts`, and `EmailThreads` all share the same file-entry shape (they're just files uploaded into the site's document library):

```jsonc
{
  "Title": "Clinical Formulation Overview",
  "Path": "Content/Documents/Demo1/SharePoint_Documents/Clinical Formulation Overview.pdf",
  "CreatedOffset": -102,                     // days before install day (always negative)
  "CreatedBy": "charlotte.waltson@sympdcp.onmicrosoft.com",
  "ModifiedOffset": -102,
  "ModifiedBy": "charlotte.waltson@sympdcp.onmicrosoft.com"
}
```

- `Path` is repo-relative (from the repository root, including the `Content/` prefix) and must point at a real file under `Content/Documents/<DemoName>/<Category>/`, where `<Category>` is `SharePoint_Documents`, `Meeting_Transcripts`, or `Email_Threads` to match the folder each content type is saved into.
- `CreatedBy`/`ModifiedBy` are demo user emails from `Configuration/settings.json`'s `Users` list.
- For a meeting transcript or a single-session document, `CreatedOffset` and `ModifiedOffset` are the same. For an email thread, use the date of the first message as `Created`/`CreatedBy` and the date of the last message as `Modified`/`ModifiedBy`.

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

#### No metadata duplication in file bodies
`content.json` is the only place `Title`/`Created*`/`Modified*` lives. Don't also restate it inside the file itself:
- **SharePoint documents**: no "Prepared by" / "Date prepared" / "Last updated" header line, and no "Update Log" section restating those dates. Start straight into the content after the title (a short "Product:" / "Classification:" line is fine — that's not tracked in `content.json`).
- **Meeting transcripts**: no "Date:" line. Keep "Attendees:" (not tracked elsewhere). The transcript's date lives only in its `content.json` `MeetingTranscripts` entry.
- **Email threads** and **Teams chats** are exempt from this rule — the per-message `From`/`Date` (emails) and `Sender`/timestamp (chats) are the actual content, not a redundant summary block, and `content.json`'s entries for them are derived from that content rather than duplicating it.

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
Create a transcript for the teams meeting. Each of these meeting transcripts should be saved as a markdown file.

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
Create a transcript for the teams meeting. Each of these meeting transcripts should be saved as a markdown file.

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

