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
      "Owners": ["<user email>", ...],       // from config.json's Users
      "Members": ["<user email>", ...],
      "Content": {
        "Documents": [ /* SharePoint documents */ ],
        "MeetingTranscripts": [ /* Teams meeting transcripts */ ],
        "EmailThreads": [ /* Email discussions */ ],
        "Chats": [ /* Teams chats */ ]
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
- `CreatedBy`/`ModifiedBy` are demo user emails from `Configuration/config.json`'s `Users` list.
- For a meeting transcript or a single-session document, `CreatedOffset` and `ModifiedOffset` are the same. For an email thread, use the date of the first message as `Created`/`CreatedBy` and the date of the last message as `Modified`/`ModifiedBy`.

`Chats` keeps its existing shape — `Title`, `Members` (full names), and `Messages` (`Offset`, `Time`, `Sender`, `Message`) — derived directly from the corresponding Teams chat markdown file, so the JSON and the file stay in sync.

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

