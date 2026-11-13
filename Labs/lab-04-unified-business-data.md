# Lab 4: A unified view of business data

[Lab directory](./README.md) | [Previous: Insight to action](./lab-03-insight-to-action.md)

## Scenario and objectives

You are David Power, Caldova's Sales Director. Before an account review, you need a 360-degree view of commercial activity, service issues, fulfillment, and field engagement, combined with the account strategy. Build an agent that uses Work IQ to correlate business records with Microsoft 365 context and prepare an explicitly assumption-based demand estimate.

This lab uses **Meridian Health Alliance**, account `CAL-ACC-001`, whose seeded primary contact is **Amelia Brooks**. Use these deployed records rather than creating the example customer or contact from the original demo narrative.

**Estimated time:** 60-90 minutes.

## Prerequisites

1. Complete the [shared setup](./README.md#before-you-begin) with Microsoft 365 and Dynamics 365 Sales and Customer Service content installed.
2. Use David's account or its mapped replacement, with the required Dynamics licenses, app access, and security roles. Verify access as David rather than assuming an administrator's visibility applies to him.
3. Complete [Business Applications in Work IQ enablement](../docs/dynamics-365.md#environment-preparation). Confirm the assigned user is included in the tenant availability setting and the relevant environment is enabled.
4. For the full ERP exercise, install F&O content and complete the [F&O preparation and verification](../docs/finance-and-operations.md). Record the environment URL and selected legal entity.
5. Confirm access to the **Caldova Field Engagement** model-driven app and **Sales Team** documents. Account-linked SharePoint documents require the optional [Dataverse document integration](../docs/dynamics-365.md#sharepoint-integration-for-dataverse); general Sales documents can be used without that integration.

If F&O is not installed or exposed through Work IQ, you can complete a clearly labeled **CRM and Microsoft 365 subset**. Do not mark the full cross-application lab complete.

## Exercise 1: Verify the business records directly

1. Open the assigned Dynamics 365 Sales app. Find **Meridian Health Alliance** by account number `CAL-ACC-001`; verify its primary contact.
2. Inspect its related opportunities, quotes, orders, and invoices. Record identifiers, actual statuses, quantities, units, currencies, and dates for a small sample.
3. Open Customer Service and locate **Meridian Health Alliance - Cold-chain shipment delay**, ticket `CAL-CASE-001`. Read its description and current status.
4. Open the **Caldova Field Engagement** app and locate **Meridian - Cold-chain delivery follow-up**. Record its related account, contact, and current status without editing it.
5. If using F&O:
   1. Open the assigned legal entity.
   2. Find customer `CAL-ACC-001` and its sales orders.
   3. Use the demo reference, such as `CAL-ORD-001`, in **CustomerRequisitionNumber** to correlate the order. F&O generates its own sales order number.
   4. Record the actual F&O order number, company, status, and lines.
6. In the Sales Team SharePoint site (https://[your-tenant-name].sharepoint.com/sites/Sales-Team), open **Healthcare Account Strategy**, **Customer Engagement Summary**, **Territory Review**, and **Renewal Strategy**. If account-linked documents were deployed, also open **Meridian Health Alliance Strategy** and **Meridian Health Alliance Engagement Summary** in the account's document location.
7. In Outlook, find **Meridian Health Alliance - delivery concern**. Read the **Account Team** and **Customer Success** discussions in the Sales Team channel.

## Exercise 2: Create the account-intelligence agent

1. Follow the [shared Work IQ connection steps](./README.md#3-connect-work-iq-in-copilot-studio) to create **Caldova Account Intelligence**.
2. In the agent's **Settings > Work IQ**, turn on **Enable preview workloads**.
3. On **Build**, open **Work IQ** and select **Business apps (preview)**, **SharePoint**, **Outlook mail**, and **Teams**. Include OneDrive if needed for your assigned documents.
4. Confirm the Work IQ connection uses David's approved identity. Business apps selection does not grant Dynamics privileges.
5. Add the complete content of [the account-intelligence agent instructions](./lab-04-account-intelligence-instructions.txt) to the agent's instructions. Before pasting, replace `<DATAVERSE_ENVIRONMENT_URL>` and `<SALES_SITE_URL>` with your assigned environment and Sales Team site URLs. If F&O is available, also replace `<FO_ENVIRONMENT_URL>` and `<FO_COMPANY>` with the assigned F&O environment URL and legal entity. Otherwise, replace the optional F&O configuration line with `F&O: Not available; use the CRM and Microsoft 365 subset.`

6. Publish the agent.
7. In Preview, ask:

   ```text
   Find Meridian Health Alliance, account CAL-ACC-001, in the assigned
   business environment. Return its account number, primary contact,
   source environment, and record identifier. Do not change anything.
   ```

8. Inspect the activity trace for business-application discovery and retrieval. Compare the result with Exercise 1. If only documents are returned, resolve business-app access before continuing.

## Exercise 3: Produce the 360-degree account view

1. Now, still in Preview, create a new chat and provide the following prompt:

   ```text
   Create a 360-degree view of Meridian Health Alliance (CAL-ACC-001).
   Include Sales opportunities, quotes, orders, and invoices; Customer Service cases; Field Engagement records; and F&O customer and sales-order data if available in the configured legal entity.
   Combine these with Healthcare Account Strategy, Customer Engagement
   Summary, Meridian-specific strategy documents if deployed, the delivery concern email thread, and related Sales Team discussions.
   Present record-level findings in a table by source system, with record ID, finding, actual status, and source link where available.
   ```

2. Open at least one referenced record in each available business app and one Microsoft 365 citation.
3. Compare the agent's case status with the app. A reassuring email does not automatically close an in-progress case.
4. Verify the field engagement is linked to the selected account, not merely a similarly named customer.

## Product references

- [Work IQ in Copilot Studio: configure workloads, enable preview workloads, and test your agent](https://learn.microsoft.com/en-us/microsoft-copilot-studio/agents-experience/add-work-iq)
- [Business Applications in Work IQ documentation (preview)](https://learn.microsoft.com/en-us/power-platform/business-applications-work-iq/)
- [Business Applications in Work IQ quickstart](https://learn.microsoft.com/en-us/power-platform/admin/business-applications-work-iq/quickstart)
- [Ownership-based security in Microsoft Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/wp-security-cds)

## Congratulations!

You've completed Lab 4! You configured Caldova Account Intelligence to combine business records with Microsoft 365 context, produced a source-backed account view, and checked its findings against the underlying applications. You distinguished recorded facts from narrative statements while keeping the agent read-only.

If F&O was available, your assessment also included customer and sales-order data from the configured legal entity. Otherwise, you've completed the **CRM and Microsoft 365 subset**.

Return to the [lab directory](./README.md) to review the other labs.
