# WorkIQ Starter Pack

Demo sites, users, and content used to explore Work IQ on a demo or developer tenant.

### DO NOT USE THIS IN PRODUCTION.
The installer creates users, Teams, SharePoint content, and **writes email directly into the users' mailboxes** (tagged with the category `WorkIQStarterPack`). Only run it against a demo or developer tenant.

## Overview

The Work IQ Starter Pack is a collection of PowerShell scripts that automate the provisioning of demo users, content, and business data onto a target demo or developer tenant. It provides a consolidated knowledge base for exploring and experimenting with Work IQ, as well as for delivering consistent demos.

The pack has one installer and one cleanup script. Both handle Microsoft 365 and Dynamics 365 content; no separate Dynamics scripts are needed.

| Script | Purpose |
|---|---|
| [InstallWorkIQStarterPack.ps1](./InstallWorkIQStarterPack.ps1) | Installs the selected Microsoft 365, Dynamics 365 Sales & Customer Service, and Finance & Operations content, using shared users and an app registration. |
| [CleanUp.ps1](./CleanUp.ps1) | Selectively removes Microsoft 365 content, Dynamics 365 demo data, the Caldova solution, and Dynamics-linked SharePoint folders, with optional removal of logs and the app registration. |

[Content/content.json](./Content/content.json) describes the Microsoft 365 demo. The installer reads it and uses PnP PowerShell and Microsoft Graph to create:

- Users (optional), their licenses, and profile photos
- Entra security groups named in a site's optional `Groups` array (no site in the shipped `content.json` defines one), containing the same demo or resolved real users used by `Add-Users`. Existing assigned, non-mail-enabled security groups are reused and missing members added; other members are retained. These security groups are not removed by `CleanUp.ps1`.
- Microsoft Teams and their SharePoint sites, with channels
- Documents uploaded with the right authors and dates, and past Teams meetings created on each team's calendar with their transcripts (Word documents) linked from the channel
- SharePoint lists, libraries, content types, views, and managed-metadata term sets
- Teams chat history, imported with the Graph channel migration API
- Email threads, delivered to each recipient's inbox

## Requirements
- PowerShell 7.4.0 or later ([install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)). It is available for Windows, Linux and Mac.
- The `PnP.PowerShell` module. The installer installs it for the current user if it is missing.
- The `Microsoft.PowerApps.Administration.PowerShell` module, used for Dynamics provisioning. It is installed for the current user if it is missing.
- The Work IQ service principal (app ID `fdcc1f02-fc51-4226-8753-f668596af7f7`, set as `WorkIQAppId` in settings.json) must exist and be enabled in the tenant for all content packs. The installer creates it if it is missing and stops if it is disabled.
- A **Global Administrator** account (see [Permissions](#permissions)).
- Licenses for the users (see [Licenses](#licenses)).
- Copilot credits available in the tenant or pay-as-you-go billing enabled, for all content packs (see [Pre-requisite checks](#pre-requisite-checks)).
- An application registration. `InstallWorkIQStarterPack.ps1` can create one for you, or you can enter the client ID of an existing one when prompted.

## Configuration

### Config file
[Configuration/config.json](./Configuration/config.json) contains the default user-editable settings. The installer prompts for most of them and writes the answers back to this file. Pass `-Config <path>` to read the install choices from another JSON file and save updates to that file instead. Relative paths are resolved from your current working directory; absolute paths and files outside the repository are also supported.

```json
{
  "Settings": {
    "TenantPrefix": "contoso",
    "ClientId": "",
    "InstallDemoUsers": true,
    "InstallM365Content": true,
    "InstallDynamicsContent": true,
    "InstallDynamicsFOContent": false,
    "DeployDynamicsDocuments": false,
    "ProvisionUserEmails": true
  }
}
```

| Setting | Description |
|---|---|
| `TenantPrefix` | The prefix of your tenant (e.g. `contoso` for contoso.sharepoint.com). It replaces the `<TENANTPREFIX>` token in `Content/content.json` and `Configuration/settings.json`. |
| `ClientId` | Client ID of an existing app registration. If empty, the installer creates one and saves its ID here. Required by `CleanUp.ps1`. |
| `InstallDemoUsers` | `true` creates the 5 built-in demo users. `false` maps the demo roles onto your own users (see [Users](#users)). |
| `InstallM365Content` | Install the Microsoft 365 content pack. At least one of Microsoft 365, Dynamics 365 Sales & Customer Service, or Finance & Operations must be selected. |
| `InstallDynamicsContent` | Install the Dynamics 365 Sales & Customer Service data, including the Caldova Field Engagement solution, and enable Dynamics license assignment. When Microsoft 365 content is also selected, this adds the Sales Team. |
| `InstallDynamicsFOContent` | Install the Dynamics 365 Finance & Operations data. Can be selected independently of the other packs. |
| `DeployDynamicsDocuments` | Deploy SharePoint documents connected to Sales & Customer Service records. Used when `InstallDynamicsContent` is `true`; prompted interactively or read from the selected file with `-Config`. |
| `ProvisionUserEmails` | Import the demo email threads into the users' inboxes. Always on when demo users are used. |
| `AppRegistrationName` | Optional, unattended mode only. Name for a new app registration (default `WorkIQStarterPack`). |
| `RealUserUpns` | Unattended mode with `InstallDemoUsers: false` only. A list of 5 UPNs (see [Users](#users)). |

The main installer and cleanup use these additional settings for Dynamics operations. See [Dynamics 365 content](#dynamics-365-content).

| Setting | Description |
|---|---|
| `DynamicsEnvironmentUrl` | URL of the Dataverse environment for Sales & Customer Service (for example `https://org.crm.dynamics.com`). |
| `DynamicsEnvironmentId` | ID of the Dataverse environment. Written by the installer when it creates an environment. |
| `DynamicsFOEnvironmentUrl` | URL of the Finance & Operations environment. |
| `DynamicsFOLegalEntityId` | Legal entity (company) used for the F&O data, for example `ITCO`. |
| `DynamicsFOCustomerGroupId`, `DynamicsFOLanguageId` | Customer group and language used when creating F&O customers (language defaults to `en-us`). |
| `DynamicsFOProductTemplateCompany`, `DynamicsFOProductTemplateItemNumber` | Company and item number of the product used as a template for new F&O products. |
| `DynamicsFOShippingCompany`, `DynamicsFOShippingWarehouseId` | Company and warehouse used for F&O sales orders. |
| `DynamicsFOSalesCurrencyCode`, `DynamicsFOShippingSiteId` | Filled in by the installer from the environment; you do not need to set them. |

The Microsoft 365 content pack installs the Market Research, Finance, and Procurement teams from `content.json`. When both Microsoft 365 and Sales & Customer Service content are selected, the installer also adds the Sales Team (the site flagged `DynamicsContent`). Dynamics 365 data is provisioned directly by the same installer, even when Microsoft 365 content is not selected. [Configuration/settings.json](./Configuration/settings.json) holds the static installer data: the app registration permissions, the supported license SKUs, and the demo users.

### Unattended install
Run `./InstallWorkIQStarterPack.ps1 -Config ./Configuration/config.json` to skip every install question and use the values in that file instead. `-Config` replaces the previous `-UseConfig` switch; `-ConfigPath` is also accepted. The browser sign-in is still required. For a new app registration the admin consent URL is printed and the installer does not wait for it.

The settings it reads are `TenantPrefix` (required), `InstallDemoUsers`, `InstallM365Content`, `InstallDynamicsContent`, `InstallDynamicsFOContent`, `DeployDynamicsDocuments`, `ProvisionUserEmails`, and `ClientId` (set = use that existing app registration; empty = create one, named by `AppRegistrationName`). If `InstallDemoUsers` is false, `RealUserUpns` must contain exactly 5 UPNs.

When Sales & Customer Service is selected, configure `DynamicsEnvironmentUrl` for an existing Dataverse environment; `-Config` does not create a new environment. When F&O is selected, configure `DynamicsFOEnvironmentUrl` and the applicable F&O settings above. The SharePoint document deployment choice is read from `DeployDynamicsDocuments` without an additional question.

### Multiple configurations
Keep each tenant's configuration in a separate directory, for example `tenants/tenant-a/config.json` and `tenants/tenant-b/config.json`:

```powershell
./InstallWorkIQStarterPack.ps1 -Config ./tenants/tenant-a/config.json
./CleanUp.ps1 -Config ./tenants/tenant-a/config.json
```

For an alternative configuration, generated files are stored in a `Generated/` directory beside the selected JSON file (see [Generated files and logs](#generated-files-and-logs)). Reusing that configuration reuses its generated files. Alternative configurations in the same directory share `Generated/`; use separate directories for separate tenants. The cleanup reads the same configuration and generated files, and its choices remain interactive.

Selecting the repository's `Configuration/config.json`, either explicitly or by running without `-Config`, keeps the existing generated-file locations. Existing installations require no file migration. [Configuration/settings.json](./Configuration/settings.json), app permissions, original content, documents, and scripts are always read from the repository.

### Users
The demo needs 5 users, one for each role. With `InstallDemoUsers: true` the installer creates these demo users:

| Role | User | Title |
|---|---|---|
| Marketing | Serena Ribeiro | Market Research Analyst |
| Finance | Babak Shammas | Financial Reconciliation Lead |
| Security/Governance | Cassandra Dunn | Compliance Manager |
| Finance 2 | Charlotte Waltson | VP Procurement |
| Sales | David Power | Sales Director |

New users get a temporary password and must change it at first sign-in. The passwords are written to the installation log (see [Generated files and logs](#generated-files-and-logs)). Users that already exist are not recreated or edited (an empty usage location is filled in). Missing Office and Copilot licenses are assigned for every content pack.

To use your own users instead, answer "no" when the installer asks about demo users and enter 5 UPNs, or set `InstallDemoUsers: false` and `RealUserUpns` in the config file. Enter them in the order Marketing, Finance, Security/Governance, Finance 2, Sales. The installer looks them up in Entra ID and replaces the demo names and emails in the content with theirs. Demo user photos are only applied to demo users.

### Licenses
For every content pack, each user needs a Microsoft 365 Copilot license and a Microsoft 365 license that includes Office apps. Dynamics license assignment also runs when Sales & Customer Service content is selected. The installer uses the supported SKUs from this list in [settings.json](./Configuration/settings.json):

- **Copilot:** `Microsoft_365_Copilot`, `M365_Copilot`, `M365_COPILOT_SPECIAL_BENEFIT_PROGRAMS`
- **Office:** `SPE_E5`, `SPE_E3`, `SPB`, `O365_w/o_Teams_Bundle_M5`, `Microsoft_365_E3_(no_Teams)`, `O365_w/o Teams Bundle_M3`, `Microsoft_365_E3_EEA_(no_Teams)_Unattended_License`
- **Dynamics:** `DYN365_ENTERPRISE_SALES_CUSTOMERSERVICE`, `DYN365_ENTERPRISE_SALES`, `DYN365_ENTERPRISE_CUSTOMER_SERVICE`, `DYN365_FINANCE`

For a new set of 5 demo users, you need 5 available seats each of Copilot and Office. For existing users, the prerequisite check counts only the licenses they are missing.

Office and Copilot licenses are assigned through the same process for all content packs, including Dynamics-only installations (`InstallM365Content: false`). Existing supported licenses are retained. The installer verifies that each user has both licenses and stops before provisioning content if user creation or licensing fails. Ensure F&O users have the appropriate Dynamics licenses assigned separately.

### Pre-requisite checks
Before provisioning users, environments, or content, `InstallWorkIQStarterPack.ps1` checks the following for all selected content packs, including Dynamics-only installations.
- **Global Administrator:** the signed-in user holds the Global Administrator role.
- **Licenses:** enough available Copilot and Office seats for users missing those licenses (see [Licenses](#licenses)).
- **Work IQ service principal:** it exists and is enabled (the installer creates it if it is missing).
- **Copilot credits:** the tenant has Copilot credits. The installer calls the Microsoft Graph **beta** `copilot/costmanagement/gettenantcreditbalance()` endpoint and passes if the prepaid balance (purchased minus consumed) is above 0 or pay-as-you-go billing is listed. It needs the `CopilotCostManagement.Read.All` permission; if the call fails the check fails. The beta API can change.

### Permissions
The user running the installer must be a Global Administrator, because the installer creates the app registration, grants admin consent, and runs migration-related imports.

The app registration needs the permissions below. They are defined in [Configuration/appPermissions.json](./Configuration/appPermissions.json), which the installer uses to create the app registration and check it. With an existing app registration, the installer adds any missing permissions and opens the admin consent page for you to approve them. For this to work, the existing app must already have the delegated Graph permission `Application.ReadWrite.All` with admin consent granted. The Graph and SharePoint names are also listed under `AppRegistrationPermissions` in [Configuration/settings.json](./Configuration/settings.json), which is used to verify the token. Keep the two in sync.

#### Graph Delegated Permissions
- Group.ReadWrite.All (also creates the past meetings on the team calendar)
- User.ReadWrite.All
- Directory.ReadWrite.All
- Application.ReadWrite.All
- TeamMember.ReadWrite.All
- TeamsTab.ReadWrite.All (adds the lists and libraries as channel tabs)
- AppCatalog.Read.All
- CopilotCostManagement.Read.All (Copilot credit check)
- CopilotCostManagement-Policy.Read.All (reading Copilot spending policies; optional, the check still works without it)

#### Graph Application Permissions
- Teamwork.Migrate.All (chat import)
- Mail.ReadWrite (email import)

#### SharePoint Delegated Permissions
- AllSites.FullControl

#### Dynamics and Power Platform Delegated Permissions (Dynamics 365 content)
- Dynamics CRM: user_impersonation
- Dynamics ERP: Odata.FullAccess
- Power Platform API: EnvironmentManagement.Environments.Read, EnvironmentManagement.Groups.ReadWrite, EnvironmentManagement.Settings.ReadWrite

#### Certificate
The two application permissions are used with certificate authentication. The installer generates a self-signed certificate (valid for 2 years) in `Installation/.certs/` for the default configuration, or `Generated/.certs/` beside an alternative configuration, and registers the public key on the app registration. The `.pfx` contains a private key. These generated folders are git-ignored within this repository; do not commit or share them.

## Instructions
1. Run `./InstallWorkIQStarterPack.ps1`.
2. Answer the prompts: tenant prefix, demo or real users, content packs (Microsoft 365, Dynamics 365 Sales & Customer Service, and/or Finance & Operations), environment URLs where applicable, and the app registration. For Sales & Customer Service, you can choose to create a new Dataverse environment instead. If you do not already have an app registration with the required permissions above, answer "no" and the installer creates one.
3. Sign in when asked and approve admin consent. Sign-in opens a browser; it happens for several of the steps.
4. Wait for the installer to finish all selected Microsoft 365 and Dynamics operations. Answer any applicable environment creation, F&O setup, and optional Dynamics SharePoint document prompts. Some steps wait for Microsoft 365 to catch up (team and site provisioning, mailbox creation for photos and email, and consent and certificate propagation, which can take a few minutes).
5. Review the installation log at the path printed when the installer finishes.

The installer can be run again. Existing Teams are kept, but their owners and members are reset. Chat history is skipped if the channel was already imported. Emails are deleted and re-delivered.

## What gets installed
- **Market Research Team** (private Team): a "Launch Readiness" channel, 9 documents, 5 past Teams meetings (with transcripts), 5 email threads, and 4 chats.
- **Finance Team** (private Team): a "Financial Investigation Cases" channel, 8 documents, 4 email threads, and 3 chats. It also gets the Supplier Directory, Financial Investigation Cases, and Procurement Exception lists, and the Contract Library. The library uses a "WorkIQ Starter Pack" term group in the tenant term store.
- **Procurement Team** (private Team): a "Capacity Planning" channel, 8 documents, 3 past Teams meetings, 4 email threads, and 3 chats. It also gets the Supplier Directory, Supplier Capacity Tracker, and RFPs lists.
- **Sales Team** (private Team, only when both `InstallM365Content` and `InstallDynamicsContent` are `true`): a "Dynamics - D365 - Sales Hub" channel, 4 documents, 3 email threads, and 2 chats.
- Profile photos for the demo users when Microsoft 365 content is selected.
- **Dynamics 365 data**, when selected: Sales & Customer Service and/or Finance & Operations content (see [Dynamics 365 content](#dynamics-365-content)).

The lists and libraries are added to the first channel as tabs, and the default Notes, Wiki, and Page tabs are removed.

The sample documents live under [Content/Documents](./Content/Documents), in the Demo1 to Demo4 folders used by the sites in `content.json`. To create more, see [Generating new content](#generating-new-content).

## Generating new content
[Prompts/DocumentGenerationPrompt.md](./Content/Documents/Prompts/DocumentGenerationPrompt.md) is the prompt used to author the demo content: documents, meeting transcripts, email threads, and Teams chats. It fixes the product, supplier, and raw-material names so everything stays consistent across the demos.

To generate new content:
1. Open this repository in Claude.
2. Ask it to create documents based on the `Content/Documents/Prompts/DocumentGenerationPrompt.md` prompt, for example: "Create documents based on the DocumentGenerationPrompt.md prompt."
3. Review the generated files under `Content/Documents/<DemoName>/`.
4. Make sure any new items are registered in [Content/content.json](./Content/content.json) so the installer uploads them.
5. Run the installer again (see [Instructions](#instructions)).

To change the scenario or the names used, edit the prompt before asking Claude to generate the content.

## Dynamics 365 content
`InstallWorkIQStarterPack.ps1` installs all selected Dynamics 365 demo data as part of the main installation. No separate installer or second run is needed. It reuses the shared users and app registration; the Dynamics and Power Platform permissions required by the selected operations must be consented.

The installer lets you select Dynamics 365 Sales & Customer Service data, Finance & Operations (F&O) data, or both, independently of the Microsoft 365 content pack. At least one of the three packs must be selected. When run interactively, it prompts for the relevant environment URLs and can create a new Dataverse environment, saving its ID and URL to the selected configuration file. Use `./InstallWorkIQStarterPack.ps1 -Config <path>` to read the configuration instead, including the optional SharePoint document deployment choice (see [Unattended install](#unattended-install)). See [Environment preparation](#environment-preparation) for the existing-environment requirements and interactive creation options.

Dynamics-only labs still require Microsoft 365 and Microsoft 365 Copilot licenses, plus Copilot credits or pay-as-you-go billing. They run the same prerequisite checks and Office and Copilot license assignment as Microsoft 365 installations; see [Licenses](#licenses) and [Pre-requisite checks](#pre-requisite-checks) for the shared requirements and the separate Dynamics license requirements.

Depending on the selected packs, it will:
- Create or resolve the selected users for all packs; synchronize them into Dataverse when Sales & Customer Service is selected.
- Install the Caldova Field Engagement managed solution from [Content/DataverseSolutions](./Content/DataverseSolutions) when Sales & Customer Service is selected.
- Create the Sales & Customer Service data in [Content/contentDynamics.json](./Content/contentDynamics.json): leads, accounts, contacts, price lists, products, opportunities, quotes, orders, invoices, cases, emails, and field engagements.
- Optionally create the F&O customers, products, and sales orders.
- Optionally deploy SharePoint documents connected to the Sales & Customer Service records.

All installation operations are recorded in the installation log (see [Generated files and logs](#generated-files-and-logs)).

Use `./CleanUp.ps1` to remove Dynamics data and optionally Microsoft 365 content in the same run. It asks which parts to remove; see [Cleanup](#cleanup).

### Environment preparation

**Sales & Customer Service (Dataverse)**

1. Create a Sandbox environment with a Dataverse database, or use an existing demo environment. Confirm the required Dynamics licenses and available Dataverse capacity using Microsoft's [environment creation instructions](https://learn.microsoft.com/en-us/power-platform/admin/create-environment). The shared lab licenses and installer permissions are covered in [Licenses](#licenses) and [Permissions](#permissions).
2. Select **Enable Dynamics 365 apps** when creating the database and ensure Sales and Customer Service are installed and ready. Microsoft does not allow this option to be enabled later on a database created without it. Use English (United States, LCID `1033`) to match the English security-role names used by the installer, and select the base currency for your demo.
3. For an existing environment, set `DynamicsEnvironmentUrl` to its HTTPS root URL, for example `https://org.crm.dynamics.com`. Ensure the administrator running the installer can access the environment, import solutions, and assign security roles. If an environment security group is configured, the installer adds the selected users to it.

Alternatively, run the installer interactively and choose to create a new Dataverse environment. Its defaults are Sandbox, English (`1033`), and `USD`; it saves the environment ID and URL to the selected configuration. With `-Config`, an existing environment and `DynamicsEnvironmentUrl` are required. User synchronization, solution installation, and role assignment are handled by the installer for either path.

**Enable Business Applications in Work IQ**

For the Dataverse environment, follow Microsoft's [Work IQ pilot setup (preview)](https://learn.microsoft.com/en-us/power-platform/admin/business-applications-work-iq/quickstart): confirm the demo users are included in the Microsoft 365 admin center's Business Applications in Work IQ availability setting, and turn on Work IQ under **Settings > Product > Features** in the Power Platform admin center. Review [Dataverse search indexing for AI and agent experiences](https://learn.microsoft.com/en-us/power-platform/admin/configure-relevance-search-organization#turn-on-search-indexing-to-support-dataverse-intelligence-work-iq-in-ai-and-agent-experiences) for Dataverse-backed AI experiences. These administrative settings are separate from installing the demo data and are not enabled by the starter pack.

**Finance & Operations**

F&O requires an existing environment; the installer does not create one. Set `DynamicsFOEnvironmentUrl` and confirm that the selected legal entity, customer group, shipping warehouse, and released product used as a setup template are available. See the F&O settings in [Configuration](#configuration) and the license requirements in [Licenses](#licenses). The Dataverse environment creation steps above apply to Sales & Customer Service.

## Generated files and logs
For the default `Configuration/config.json`, these locations are unchanged and git-ignored:
- `Content/content.custom.json`: the content with your tenant prefix and users applied. It also records the imported email message IDs.
- `Configuration/users.custom.json`: your resolved users (real users only).
- `Installation/.certs/`: the certificate.
- `Installation/.state/imported-posts.json`: the record of meeting posts already imported into each channel.
- `Logs/InstallLog.md` and `Logs/CleanUpLog.md`: a run summary, your inputs, and the actions taken for all selected Microsoft 365 and Dynamics operations. The install log also lists the demo user passwords in plain text, so store or delete it securely.

Alternative configurations use the following directory beside the selected JSON file:

```text
Generated/
├── content.custom.json
├── users.custom.json
├── .state/imported-posts.json
├── .certs/
└── Logs/
    ├── InstallLog.md
    └── CleanUpLog.md
```

`Generated/` directories within this repository are git-ignored. Files generated outside this repository need the same care: certificates contain private keys and installation logs can contain temporary passwords. The cleanup uses only the generated paths associated with the selected configuration and retains its existing choices for removing files, logs, and the app registration's certificate.

## Cleanup
Run `./CleanUp.ps1` to selectively remove what the installer created, including Dynamics 365 data. Pass `-Config <path>` to use an alternative configuration and its generated files. It is always interactive and requires PowerShell 7.4 or later and an existing app registration with the required permissions and admin consent already granted. It prompts for the tenant prefix and client ID, using the selected configuration values as defaults. Use `InstallWorkIQStarterPack.ps1` to create or configure the app registration before cleanup if needed.

It asks which operations to perform:
- **Microsoft 365 cleanup:** remove imported emails, delete the Teams in `content.json` with their M365 groups and sites and purge them from the recycle bins, delete and purge the built-in demo users, and delete the generated custom files. This includes the Sales Team site. Real users are not deleted, and the Entra security groups described in [Overview](#overview) are retained.
- **Sales & Customer Service cleanup:** delete the demo records identified in `Content/contentDynamics.json`, including field engagements, emails, cases, invoices, orders, quotes, opportunities, product catalog records, leads, and accounts. You can also choose to uninstall the Caldova Field Engagement managed solution, which removes its custom table, app, and any remaining field engagement records.
- **Finance & Operations cleanup:** delete the demo sales orders and their lines, customers in the configured legal entity, and shared products. Shared products apply across companies.
- **Dynamics SharePoint cleanup:** remove the uploaded account folders and their contents from the Sales & Customer Service SharePoint integration.
- **Optional local and app cleanup:** delete installation logs and/or remove the app registration, its service principal, and the local Teams chat migration certificate. Only delete the app registration if the installer created it, not if you supplied a pre-existing one.

Dynamics cleanup prompts for the relevant environment URLs, using saved values as defaults. F&O cleanup also requires `DynamicsFOLegalEntityId` in the configuration. Selecting Dynamics cleanup does not automatically select Microsoft 365 cleanup or delete users and Teams.

All selected cleanup operations are recorded in the cleanup log (see [Generated files and logs](#generated-files-and-logs)), unless you choose to delete the logs.

If a site cannot be fully removed (it stays active, is not confirmed purged from the recycle bin, or an error occurs), the cleanup lists those sites at the end with the reason. Remove them manually in the SharePoint admin center, from both Active sites and Deleted sites, and purge any matching deleted group in the Microsoft 365 admin center.

## Author(s)
- [Derek Cash-Peterson](https://www.linkedin.com/in/dcashpeterson/), MVP (Sympraxis Consulting)
- [Fabio Franzini](https://www.linkedin.com/in/fabiofranzini/), MVP (Apvee Solutions Srl)
- [Guido Preite](https://www.linkedin.com/in/guidopreite/), MVP (Apvee Solutions Srl)

## Disclaimer
THIS CODE IS PROVIDED AS IS WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.

## Change Log
For a list of issues/updates made in each release see the [CHANGELOG](./CHANGELOG.md).

## Security

Microsoft takes the security of our software products and services seriously, which
includes all source code repositories in our GitHub organizations.

**Please do not report security vulnerabilities through public GitHub issues.**

For security reporting information, locations, contact information, and policies,
please review the latest guidance for Microsoft repositories at
[https://aka.ms/SECURITY.md](https://aka.ms/SECURITY.md).
