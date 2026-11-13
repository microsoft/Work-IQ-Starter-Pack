# Work IQ Starter Pack labs

[Back to the Starter Pack](../README.md)

Explore how Work IQ connects organizational knowledge, agent collaboration, enterprise actions, and business data. These four hands-on labs use the fictitious Caldova Pharmaceuticals company and the data deployed by the Work IQ Starter Pack.

Use Copilot Chat directly in Lab 1, create and test agents in Labs 2 and 4, and customize Copilot Cowork with a reusable skill in Lab 3. Each lab includes a scenario, prerequisites, guided exercises, and evidence checks. Responses can vary; judge them by their evidence and behavior rather than by exact wording.

## Choose a lab

The time estimates exclude tenant provisioning, indexing, and administrator approvals. Allow time after provisioning for Microsoft 365 content to become searchable, and verify retrieval before starting. No fixed indexing delay is guaranteed.

| Lab | Scenario | What you build | Main experience | Estimated time |
|---|---|---|---|---|
| [1. Navigating organizational intelligence](./lab-01-organizational-intelligence.md) | Serena prepares an ALLER launch-readiness brief. | A source-backed brief using the supplied prompt; no custom agent required. | Microsoft 365 Copilot Chat | 15-20 minutes |
| [2. Intelligent investigation](./lab-02-intelligent-investigation.md) | Babak investigates a disputed supplier invoice line for Cassandra to review. | An orchestrator with Work IQ MCP evidence retrieval and two published, connected specialists that produce a draft escalation packet. | Copilot Studio, Microsoft Copilot harness | 90-120 minutes |
| [3. From insight to action](./lab-03-insight-to-action.md) | Charlotte arranges a supplier-capacity review. | A custom Cowork skill for supplier research and confirmed meeting creation. | Copilot Cowork with a custom skill | 60-75 minutes |
| [4. A unified view of business data](./lab-04-unified-business-data.md) | David prepares a 360-degree view of Meridian Health Alliance. | A read-only agent combining Sales, Customer Service, Field Engagement, Microsoft 365 context, and F&O data when available. | Copilot Studio, Microsoft Copilot harness, Work IQ Business apps (preview) | 60-90 minutes |

All four labs are independent. Lab 1 is not a prerequisite for Labs 2, 3, or 4; start with any scenario after satisfying its own prerequisites and the applicable shared setup.

## Before you begin

### 1. Prepare a demo tenant

1. Use only a demo or developer tenant. The installer writes emails, creates users and collaboration content, and can write Dynamics 365 data. **Do not run it in production.**
2. Ask the lab administrator to follow the [user manual](../USER-MANUAL.md), including [requirements](../USER-MANUAL.md#requirements), [licenses](../USER-MANUAL.md#licenses), [permissions](../USER-MANUAL.md#permissions), and [configuration](../USER-MANUAL.md#configuration).
3. Install the content packs required for your chosen lab:

   | Labs | Required installation choices |
   |---|---|
   | 1-3 | `InstallM365Content: true`. Dynamics packs are not required. |
   | 4 | `InstallM365Content: true` and `InstallDynamicsContent: true`. Enable `InstallDynamicsFOContent` for the F&O portion. |

4. For Lab 4, complete the [Dynamics 365 preparation](../docs/dynamics-365.md#environment-preparation), including Business Applications in Work IQ enablement, and the [F&O preparation](../docs/finance-and-operations.md) if using F&O. To deploy account-linked SharePoint documents, also enable `DeployDynamicsDocuments` and complete the [SharePoint integration setup](../docs/dynamics-365.md#sharepoint-integration-for-dataverse).
5. Have the administrator review the installation log for failures before starting the labs.

The installer provisions data and supporting resources. It does **not** create the agents, custom Cowork skill, or student meeting used in these exercises, and it does not automatically enable every Work IQ, Cowork, or preview feature.

### 2. Confirm identities and access

Use the [deployed personas or their mapped real-user replacements](../USER-MANUAL.md#users). An administrator account is needed for provisioning, not for ordinary lab conversations.

| Lab role | Built-in persona | Primary lab |
|---|---|---|
| Market research | Serena Ribeiro | 1 |
| Financial reconciliation | Babak Shammas | 2 |
| Compliance review | Cassandra Dunn | 2 |
| Procurement | Charlotte Waltson | 3 |
| Sales | David Power | 4 |

The demo narrative originally describes a sourcing manager and an example healthcare account. These labs use Charlotte for sourcing and Meridian Health Alliance for the account exercise because those identities and records are present in the shipped data. No additional sourcing-manager or customer user account is required.

1. Record your assigned persona's actual UPN and tenant prefix. For Labs 2 and 4, also record the Copilot Studio environment.
2. Confirm that your account can open the appropriate team and its SharePoint site:

   | Lab | Team | SharePoint site path | Teams channel |
   |---|---|---|---|
   | 1 | Market Research Team | `/sites/MarketResearch-Team` | Launch Readiness |
   | 2 | Finance Team | `/sites/Finance-Team` | Financial Investigation Cases |
   | 3 | Procurement Team | `/sites/Procurement-Team` | Capacity Planning |
   | 4 | Sales Team | `/sites/Sales-Team` | Dynamics - D365 - Sales Hub |

3. Open a relevant document and email before querying an agent. The imported "chats" appear as channel discussions, not as one-to-one Teams chats. Meeting transcripts are stored as Word documents; they are not recordings of real meetings you attended.
4. Allow newly provisioned content to become searchable. No fixed indexing delay is guaranteed.
5. Verify the product access required for your chosen lab:
   - **Lab 1:** Microsoft 365 Copilot Chat with access to organizational work data; no Copilot Studio maker access required.
   - **Labs 2 and 4:** Copilot Studio maker access, Microsoft Copilot harness availability, Work IQ MCP, and the required capacity or billing. Lab 2 also needs published connected agents in the same environment. Lab 4 needs Business apps (preview), environment enablement, and the assigned user's Dynamics licenses and security roles.
   - **Lab 3:** Copilot Cowork, custom skill upload, OneDrive storage, and the organizational sources and calendar actions used by the skill; no Copilot Studio maker access required.
   - For consumption, verify Microsoft 365 Copilot licensing, Copilot Credits or applicable usage-based billing, and tenant policy. Feature availability can differ by environment and region.

## Disclaimer

Caldova Pharmaceuticals is a fictitious company created solely for demonstration and testing purposes. All scenario data, including people, organizations, products, documents, communications, and business records, is fictitious. Any resemblance to actual persons, organizations, products, or events is coincidental.

The lab content does not represent real business activity and must not be used to make medical, financial, regulatory, or commercial decisions. Use it only in demo or test environments, not in production.

