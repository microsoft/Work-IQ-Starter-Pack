# WorkIQ Starter Pack

Demo sites, users, and content used to explore Work IQ on a demo or developer tenant.

### DO NOT USE THIS IN PRODUCTION.
The installer creates users, Teams, SharePoint content, and **writes email directly into the users' mailboxes** (tagged with the category `WorkIQStarterPack`). Only run it against a demo or developer tenant.

## Overview

The Work IQ Starter Pack is a collection of PowerShell scripts that automate the provisioning of demo users, content, and business data onto a target demo or developer tenant. It provides a consolidated knowledge base for exploring and experimenting with Work IQ, as well as for delivering consistent demos.

The pack has two installers and two matching cleanup scripts:

| Script | Purpose |
|---|---|
| `InstallWorkIQStarterPack.ps1` | Installs the users, Teams, SharePoint content, chats, meetings and emails (the Microsoft 365 content). |
| `InstallWorkIQDynamicsPack.ps1` | Installs the Dynamics 365 demo data (see [Dynamics 365 content](#dynamics-365-content)). |
| `CleanUp.ps1` | Removes what `InstallWorkIQStarterPack.ps1` created. |
| `CleanUpDynamics.ps1` | Removes the Dynamics 365 demo data. |

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
- The `Microsoft.PowerApps.Administration.PowerShell` module, used by the Dynamics installer. It is installed for the current user if it is missing.
- The Work IQ service principal (app ID `fdcc1f02-fc51-4226-8753-f668596af7f7`, set as `WorkIQAppId` in settings.json) must exist and be enabled in the tenant. The installer creates it if it is missing and stops if it is disabled.
- A **Global Administrator** account (see [Permissions](#permissions)).
- Licenses for the users (see [Licenses](#licenses)).
- Copilot credits available in the tenant (see [Pre-requisite checks](#pre-requisite-checks)).
- An application registration. `InstallWorkIQStarterPack.ps1` can create one for you, or you can enter the client ID of an existing one when prompted.

## Configuration

### Config file
[Configuration/config.json](./Configuration/config.json) contains the user-editable settings. The installer prompts for most of them and writes the answers back to this file.

```json
{
  "Settings": {
    "TenantPrefix": "contoso",
    "ClientId": "",
    "InstallDemoUsers": true,
    "InstallM365Content": true,
    "InstallDynamicsContent": true,
    "ProvisionUserEmails": true
  }
}
```

| Setting | Description |
|---|---|
| `TenantPrefix` | The prefix of your tenant (e.g. `contoso` for contoso.sharepoint.com). It replaces the `<TENANTPREFIX>` token in `Content/content.json` and `Configuration/settings.json`. |
| `ClientId` | Client ID of an existing app registration. If empty, the installer creates one and saves its ID here. Required by `CleanUp.ps1`. |
| `InstallDemoUsers` | `true` creates the 5 built-in demo users. `false` maps the demo roles onto your own users (see [Users](#users)). |
| `InstallM365Content` | Install the M365 content pack. At least one pack must be selected. |
| `InstallDynamicsContent` | Install the Dynamics 365 content pack. In `InstallWorkIQStarterPack.ps1` this adds the Sales Team and assigns a Dynamics license to the users; the Dynamics data comes from `InstallWorkIQDynamicsPack.ps1`. |
| `ProvisionUserEmails` | Import the demo email threads into the users' inboxes. Always on when demo users are used. |
| `AppRegistrationName` | Optional, unattended mode only. Name for a new app registration (default `WorkIQStarterPack`). |
| `RealUserUpns` | Unattended mode with `InstallDemoUsers: false` only. A list of 5 UPNs (see [Users](#users)). |

The Dynamics installer and cleanup use these additional settings. See [Dynamics 365 content](#dynamics-365-content).

| Setting | Description |
|---|---|
| `InstallDynamicsFOContent` | Install the Dynamics 365 Finance & Operations data. |
| `DynamicsEnvironmentUrl` | URL of the Dataverse environment for Sales & Customer Service (for example `https://org.crm.dynamics.com`). |
| `DynamicsEnvironmentId` | ID of the Dataverse environment. Written by the installer when it creates an environment. |
| `DynamicsFOEnvironmentUrl` | URL of the Finance & Operations environment. |
| `DynamicsFOLegalEntityId` | Legal entity (company) used for the F&O data, for example `ITCO`. |
| `DynamicsFOCustomerGroupId`, `DynamicsFOLanguageId` | Customer group and language used when creating F&O customers (language defaults to `en-us`). |
| `DynamicsFOProductTemplateCompany`, `DynamicsFOProductTemplateItemNumber` | Company and item number of the product used as a template for new F&O products. |
| `DynamicsFOShippingCompany`, `DynamicsFOShippingWarehouseId` | Company and warehouse used for F&O sales orders. |
| `DynamicsFOSalesCurrencyCode`, `DynamicsFOShippingSiteId` | Filled in by the installer from the environment; you do not need to set them. |

The Microsoft 365 content pack installs the Market Research, Finance, and Procurement teams from `content.json`. The Dynamics content pack adds the Sales Team (the site flagged `DynamicsContent`); the Dynamics 365 data itself is installed by `InstallWorkIQDynamicsPack.ps1`. [Configuration/settings.json](./Configuration/settings.json) holds the static installer data: the app registration permissions, the supported license SKUs, and the demo users.

### Unattended install
Run `./InstallWorkIQStarterPack.ps1 -UseConfig` to skip every install question and use the values in config.json instead. The browser sign-in is still required. For a new app registration the admin consent URL is printed and the installer does not wait for it.

The settings it reads are `TenantPrefix` (required), `InstallDemoUsers`, `InstallM365Content`, `InstallDynamicsContent`, `ProvisionUserEmails`, and `ClientId` (set = use that existing app registration; empty = create one, named by `AppRegistrationName`). If `InstallDemoUsers` is false, `RealUserUpns` must contain exactly 5 UPNs.

### Users
The demo needs 5 users, one for each role. With `InstallDemoUsers: true` the installer creates these demo users:

| Role | User | Title |
|---|---|---|
| Marketing | Serena Ribeiro | Market Research Analyst |
| Finance | Babak Shammas | Financial Reconciliation Lead |
| Security/Governance | Cassandra Dunn | Compliance Manager |
| Finance 2 | Charlotte Waltson | VP Procurement |
| Sales | David Power | Sales Director |

New users get a temporary password and must change it at first sign-in. The passwords are written to `Logs/InstallLog.md`. Users that already exist are not recreated or edited (an empty usage location is filled in), but they are licensed.

To use your own users instead, answer "no" when the installer asks about demo users and enter 5 UPNs, or set `InstallDemoUsers: false` and `RealUserUpns` in the config file. Enter them in the order Marketing, Finance, Security/Governance, Finance 2, Sales. The installer looks them up in Entra ID and replaces the demo names and emails in the content with theirs. Demo user photos are only applied to demo users.

### Licenses
Each user needs a Microsoft 365 Copilot license and a Microsoft 365 license that includes Office apps. Dynamics licenses are added when the Dynamics content pack is selected. The installer assigns the first available SKU of each kind from this list in [settings.json](./Configuration/settings.json):

- **Copilot:** `Microsoft_365_Copilot`, `M365_Copilot`, `M365_COPILOT_SPECIAL_BENEFIT_PROGRAMS`
- **Office:** `SPE_E5`, `SPE_E3`, `SPB`, `O365_w/o_Teams_Bundle_M5`, `Microsoft_365_E3_(no_Teams)`, `O365_w/o Teams Bundle_M3`, `Microsoft_365_E3_EEA_(no_Teams)_Unattended_License`
- **Dynamics:** `DYN365_ENTERPRISE_SALES_CUSTOMERSERVICE`, `DYN365_ENTERPRISE_SALES`, `DYN365_ENTERPRISE_CUSTOMER_SERVICE`, `DYN365_FINANCE`

You need at least 5 available seats each of Copilot and Office. `InstallWorkIQDynamicsPack.ps1` does not assign licenses.

### Pre-requisite checks
Before provisioning, `InstallWorkIQStarterPack.ps1` checks the following.
- **Global Administrator:** the signed-in user holds the Global Administrator role.
- **Licenses:** at least 5 available Copilot seats and 5 available Office seats (see [Licenses](#licenses)).
- **Work IQ service principal:** it exists and is enabled (the installer creates it if it is missing).
- **Copilot credits:** the tenant has Copilot credits. The installer calls the Microsoft Graph **beta** `copilot/costmanagement/gettenantcreditbalance()` endpoint and passes if the prepaid balance (purchased minus consumed) is above 0 or pay-as-you-go billing is listed. It needs the `CopilotCostManagement.Read.All` permission; if the call fails the check fails. The beta API can change.
- **Power Platform:** only when Dynamics content is selected. It currently always passes.

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
The two application permissions are used with certificate authentication. The installer generates a self-signed certificate (valid for 2 years) in `Installation/.certs/` and registers the public key on the app registration. The `.pfx` contains a private key. The folder is git-ignored; do not commit or share it.

## Instructions
1. Run `./InstallWorkIQStarterPack.ps1`.
2. Answer the prompts: tenant prefix, demo or real users, content packs, and the app registration. If you do not already have an app registration with the permissions above, answer "no" and the installer creates one.
3. Sign in when asked and approve admin consent. Sign-in opens a browser; it happens for several of the steps.
4. Wait for the installer to finish. Some steps wait for Microsoft 365 to catch up (team and site provisioning, mailbox creation for photos and email, and consent and certificate propagation, which can take a few minutes).
5. Review `Logs/InstallLog.md`.
6. If you want the Dynamics 365 data, run `./InstallWorkIQDynamicsPack.ps1` (see [Dynamics 365 content](#dynamics-365-content)).

The installer can be run again. Existing Teams are kept, but their owners and members are reset. Chat history is skipped if the channel was already imported. Emails are deleted and re-delivered.

## What gets installed
- **Market Research Team** (private Team): a "Launch Readiness" channel, 9 documents, 5 past Teams meetings (with transcripts), 5 email threads, and 4 chats.
- **Finance Team** (private Team): a "Financial Investigation Cases" channel, 8 documents, 4 email threads, and 3 chats. It also gets the Supplier Directory, Financial Investigation Cases, and Procurement Exception lists, and the Contract Library. The library uses a "WorkIQ Starter Pack" term group in the tenant term store.
- **Procurement Team** (private Team): a "Capacity Planning" channel, 8 documents, 3 past Teams meetings, 4 email threads, and 3 chats. It also gets the Supplier Directory, Supplier Capacity Tracker, and RFPs lists.
- **Sales Team** (private Team, only when `InstallDynamicsContent` is `true`): a "Dynamics - D365 - Sales Hub" channel, 4 documents, 3 email threads, and 2 chats.
- Profile photos for the demo users.

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
`InstallWorkIQDynamicsPack.ps1` installs the Dynamics 365 demo data. `InstallWorkIQStarterPack.ps1` does not call it; run it separately (before or after the main installer). It signs in with the app registration, so the Dynamics and Power Platform permissions above must be consented.

It asks whether to install Dynamics 365 Sales & Customer Service data, Finance & Operations (F&O) data, or both (at least one is required), and prompts for the Dataverse and F&O environment URLs. It can also create a new Dataverse environment and save its ID and URL to config.json. Run `./InstallWorkIQDynamicsPack.ps1 -UseConfig` to use the values in config.json instead; it does not create an environment, and it still asks whether to deploy the SharePoint documents. It only checks that you are a Global Administrator and does not assign licenses.

It will:
- Create or look up the demo users and sync them into Dataverse.
- Install the Caldova Field Engagement managed solution from [Content/DataverseSolutions](./Content/DataverseSolutions).
- Create the Sales & Customer Service data in [Content/contentDynamics.json](./Content/contentDynamics.json): leads, accounts, contacts, price lists, products, opportunities, quotes, orders, invoices, cases, emails, and field engagements.
- Optionally create the F&O customers, products, and sales orders.
- Optionally deploy SharePoint documents connected to the Dynamics records.

The log is written to `Logs/InstallMiniLog.md`.

`./CleanUpDynamics.ps1` removes that data. It is always interactive, needs PowerShell 7.4 and an existing app registration, and asks which parts to remove (Sales & Customer Service data, the Caldova solution, F&O data, and the SharePoint integration files). It does not remove the users, Teams, or the Sales Team site; use `CleanUp.ps1` for those. The log is written to `Logs/CleanUpMiniLog.md`.

## Generated files and logs
These are git-ignored:
- `Content/content.custom.json`: the content with your tenant prefix and users applied. It also records the imported email message IDs.
- `Configuration/users.custom.json`: your resolved users (real users only).
- `Installation/.certs/`: the certificate.
- `Logs/InstallLog.md`, `Logs/CleanUpLog.md`, `Logs/InstallMiniLog.md`, and `Logs/CleanUpMiniLog.md`: a run summary, your inputs, and the actions taken. The install log also lists the demo user passwords in plain text, so store or delete it securely.

## Cleanup
Run `./CleanUp.ps1` to remove what the installer created. It is always interactive and requires `TenantPrefix` and `ClientId` in the config file. It will:
1. Remove the imported emails.
2. Delete the Teams in `content.json`, their M365 groups and sites, and purge them from the recycle bins.
3. Delete the demo users (only the ones in `DefaultUsers` in settings.json) and purge them from the deleted items.
4. Delete the generated custom files.
5. Optionally delete the `Logs` folder, the app registration, and the certificate. Only delete the app registration if the installer created it.

`CleanUp.ps1` does not remove the Dynamics 365 data; use `CleanUpDynamics.ps1` for that.

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

