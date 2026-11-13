# Lab 3: From insight to action

[Lab directory](./README.md) | [Previous: Intelligent investigation](./lab-02-intelligent-investigation.md) | [Next: Unified business data](./lab-04-unified-business-data.md)

## Scenario and objectives

Demand for ALLER products is increasing, and Caldova must review supplier capacity. You are Charlotte Waltson, VP of Procurement, acting as the sourcing lead. Use **Copilot Cowork** with a **custom skill** to research the situation, prepare an agenda, and schedule an internal review after your confirmation.

You will create and load a reusable supplier-review skill, test it in Cowork, and move from source-backed research to a verified calendar action. This lab does not use a custom Copilot Studio agent and does not require Lab 1 or Lab 2.

**Estimated time:** 60-75 minutes.

## Prerequisites

1. Complete the [shared setup](./README.md#before-you-begin) with Microsoft 365 content installed.
2. Use Charlotte's account or its mapped replacement, with access to Procurement Team, its SharePoint site, and an Outlook calendar.
3. Obtain the actual UPNs of Babak Shammas and David Power demo accounts. No real supplier or external customer is invited in this lab.
4. Agree on a future date, explicit time zone, working-hours window, and 30-minute duration for a test meeting.
5. Confirm that **Copilot Cowork**, custom skill upload, and the organizational sources and calendar actions required for this exercise are enabled for your assigned account. OneDrive must be available to store the uploaded skill. Copilot Studio maker access is not required.

The Starter Pack does not create an additional sourcing-manager persona. Charlotte performs that function in this lab.

## Exercise 1: Inspect supplier and capacity evidence

1. Open **Procurement Team > Capacity Planning** in Teams. Read **Procurement Operations**, **Supply Chain Response Team**, and **Supplier Review Working Group** discussions.
2. In the Procurement SharePoint site (https://[your-tenant-name].sharepoint.com/sites/Procurement-Team), inspect the following lists: **Supplier Directory**, **Supplier Capacity Tracker**, and **RFPs**. In the **RFPs** list, open the active **ALLER tablet capacity expansion** item and inspect its content.
3. Locate these documents in the **Capacity Planning** channel:
   - Current Supplier Scorecard
   - Capacity Planning Report
   - Raw Material Demand Forecast
   - Supplier Expansion Proposal
   - RFP Package
   - Supplier Evaluation Criteria
   - Supplier Onboarding Checklist
4. Open the **Emergency Capacity Review** and **Procurement Steering Committee** transcript documents available in the subfolder **Meeting Transcripts** and read their content.
5. In Outlook, find **ALERT: AUR-API-7 and tablet capacity shortfall** and **RFP questions from Atlas Regional Manufacturing** e-mails.
6. Record the site URL, proposed meeting participants, and links to the capacity tracker, RFP item, and key documents.

**Checkpoint:** The shipped data separates tablet manufacturing capacity from raw-material constraints. It also distinguishes ALLER tablet RFP scope from existing regional OTC bundle agreements.

## Exercise 2: Create and load the supplier-review skill

1. Open the supplied [supplier-review skill template](./skills/caldova-supplier-review/SKILL.md). Save a local copy named `SKILL.md` in your own `caldova-supplier-review` folder.
2. Read its YAML frontmatter and procedure. The `name` identifies the skill, and the `description` tells Cowork when to select it. Review its evidence requirements and confirmation boundary before uploading it.
3. Customize your copy by adding a lab-specific instruction, such as requiring a five-minute decision summary at the end of the agenda. Keep the name, description, source-checking rules, and action safeguards.
4. Open **Copilot Cowork** as your assigned Charlotte identity. Select **Plugins > Skills**.
5. Select the arrow next to **Add**, then **Upload skill**, and choose your `SKILL.md`. For this single-file skill, no ZIP archive or plugin package is required.
6. Wait for validation and OneDrive synchronization. Confirm **caldova-supplier-review** appears under **Your skills**, then open its details and verify the imported instructions. If you upload the same name again, Cowork may create a numbered duplicate; do not assume it updated the existing skill.
7. Start a **new Cowork conversation**. Use the conversation **Sources** picker to select your skill and the authorized organizational sources or plugins required for SharePoint, email, Teams, people, and calendar access.
8. Provide the Procurement site URL through **Add work context** or as a link in your request. The skill does not install Work IQ, add connectors, or grant access. Verify the signed-in identity and required sources with the instructor if anything is unavailable.
9. Submit a smoke-test request:

   ```text
   Use my selected caldova-supplier-review skill.
   Procurement site: <PROCUREMENT_SITE_URL>.
   Find Supplier Expansion Proposal and provide its source link.
   Stay in research-only mode; do not create or send anything.
   ```

10. Inspect Cowork's progress and source references, and open the citation. Confirm that the selected skill is available to the conversation rather than merely attaching its Markdown as background text.

**Checkpoint:** The custom skill is installed and selected in Cowork, and an authorized source can be retrieved. If custom skills or the required sources are unavailable, stop and resolve the prerequisite; a plain chat without the skill does not complete this exercise.

## Exercise 3: Research and prepare the meeting

1. In the Cowork conversation with your skill selected, submit:

   ```text
   Use my caldova-supplier-review skill with <PROCUREMENT_SITE_URL>.
   Prepare an internal supplier-capacity review for the ALLER demand increase.
   Use Procurement Team's Supplier Capacity Tracker, active RFPs,
   Raw Material Demand Forecast, Supplier Expansion Proposal,
   Supplier Evaluation Criteria, the Emergency Capacity Review transcript, and related email and Teams discussions.

   Compare the following suppliers: Aster Ridge Biomanufacturing, Atlas Regional Manufacturing, and Meridian API Works. Show capacity utilization and RFP status from actual list fields, with source links. Explain the raw-material constraint separately from tablet manufacturing. Identify the latest RFP scope clarification and any conflict with earlier planning documents.

   Draft a 30-minute agenda, decisions required, and pre-read links for
   Charlotte Waltson (myself), Babak Shammas, and David Power. Do not create or send anything yet.
   ```

2. Review Cowork's plan and clarify the scope if needed. Let it complete the research-only task, then compare the returned utilization values with **Supplier Capacity Tracker**. In the unchanged seed data, Aster Ridge is 94%, Atlas is 68%, and Meridian API Works is 96%; the deployed list is the authority if the instructor has changed it.
3. Verify that Cowork identifies the active tablet-capacity RFP and its invited suppliers, using actual list fields. If the available connection cannot read those fields, record a blocked data-access check instead of accepting inferred values.
4. Check that the agenda covers capacity options, raw-material allocation, qualification or regulatory dependencies, commercial scope, and next-step ownership.
5. Open the RFP clarification email. Ensure the response does not silently expand the tablet RFP to OTC bundles.

## Exercise 4: Confirm and create the meeting

1. Continue in Cowork with the custom skill selected. Replace every placeholder and submit:

   ```text
   Propose a 30-minute internal review titled:
   "[Caldova-Lab-03-<YOUR_INITIALS>] ALLER supplier capacity review".
   Date: <YYYY-MM-DD>.
   Time zone: <EXPLICIT_TIME_ZONE>.
   Working-hours window: <START_TIME> to <END_TIME>.
   Organizer: my signed-in Charlotte account.
   Attendees: <BABAK_DEMO_UPN> and <DAVID_DEMO_UPN>.
   Use the grounded agenda and pre-read links from this conversation.
   Check calendar availability if supported. If it cannot be checked, say so and ask me to choose a time after checking Outlook.
   Show the complete proposed event and wait for confirmation.
   ```

2. Review the resolved recipients, subject, date, time zone, duration, and agenda. Correct anything ambiguous before proceeding.
3. Open Outlook and confirm no matching event has been created yet.
4. When the proposal is correct, respond: "I confirm the displayed meeting details. Create this one internal demo meeting now."
5. Respond to any Cowork action-approval request only after checking its details. Inspect the task's action result and record the returned event ID and link if available.
6. Open Outlook as Charlotte and locate the event by its unique subject. Verify its date, time zone, attendees, agenda, and source links.

**Checkpoint:** Completion requires a real event in the assigned calendar, not just generated invitation text. A policy-denied action is a blocked test, not a successful meeting.

## Product references

- [Customize Cowork and upload a skill](https://learn.microsoft.com/en-us/copilot/cowork/cowork-customize)
- [Use Cowork, work context, and action approvals](https://learn.microsoft.com/en-us/copilot/cowork/use-cowork)

## Congratulations!

You've completed Lab 3! You created and loaded a reusable supplier-review skill in Copilot Cowork, researched supplier capacity using organizational evidence, and turned a source-backed agenda into a verified calendar event after explicit confirmation.

Continue to [Lab 4: Unified business data](./lab-04-unified-business-data.md).
