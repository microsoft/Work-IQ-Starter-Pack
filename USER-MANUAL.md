# WorkIQ Starter Pack

Demo sites, users, and content used to explore Work IQ on a demo or developer tenant.

### DO NOT USE THIS IN PRODUCTION.
The installer creates users, Teams, SharePoint sites, and **writes emails directly into the users' mailboxes** (tagged with the category `WorkIQStarterPack`), chat messages into the Teams channels, and uploads documents in SharePoint Online and Teams channels. It can also upload business data in Dynamics 365 (Sales, Customer Service, and Finance and Operations).
Only run it against a demo or developer tenant.

## Overview

The Work IQ Starter Pack is a collection of PowerShell scripts that automate the provisioning of demo users, content, and business data onto a target demo or developer tenant. It provides a consolidated knowledge base for exploring and experimenting with Work IQ, as well as for delivering consistent demos. The whole content is based on the fictitious Caldova Pharmaceuticals company used by Microsft as demo company.

The pack has one installer and one cleanup script. Both handle Microsoft 365 and Dynamics 365 content; no separate Dynamics scripts are needed.

| Script | Purpose |
|---|---|
| [InstallWorkIQStarterPack.ps1](./InstallWorkIQStarterPack.ps1) | Installs the selected Microsoft 365, Dynamics 365 Sales, Customer Service, and Finance and Operations content, using shared users and an app registration. |
| [CleanUp.ps1](./CleanUp.ps1) | Selectively removes Microsoft 365 content, Dynamics 365 demo data, the Caldova solution, and Dynamics-linked SharePoint folders, with optional removal of logs and the app registration. |

[Content/content.json](./Content/content.json) describes the Microsoft 365 demo. The installer reads it and uses PnP PowerShell and Microsoft Graph to create:

- Users (5 demo users, or your own existing users), their licenses, and profile photos
- Microsoft Teams and their SharePoint sites, with channels
- Documents uploaded with the right authors and dates, and past Teams meetings created on each team's calendar with their transcripts (Word documents) linked from the channel
- SharePoint lists, libraries, content types, views, and managed-metadata term sets
- Teams chat history, imported with the Graph channel migration API
- Email threads, delivered to each recipient's inbox
- Dynamics 365 Sales, Customer Service, and Finance and Operations data plus a custom Power App with persistence storage on Microsoft Dataverse

## Requirements
- PowerShell 7.4.0 or later ([install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)). It is available for Windows, Linux and Mac.
- The `PnP.PowerShell` module. The installer installs it for the current user if it is missing. It is required to have version 3.4.1 or later.
- The `Microsoft.PowerApps.Administration.PowerShell` module, used for Dynamics provisioning. It is installed for the current user if it is missing.
- The Work IQ service principal (app ID `fdcc1f02-fc51-4226-8753-f668596af7f7`) gets enabled in the course of the set up in case it is missing. It is required for this demo.
- A **Global Administrator** account (see [Permissions](#permissions)).
- Licenses for the users (see [Licenses](#licenses)).
- Copilot credits available in the tenant or pay-as-you-go billing enabled, for all content packs (see [Pre-requisite checks](#pre-requisite-checks)).
- An application registration. `InstallWorkIQStarterPack.ps1` can create one for you, or you can enter the client ID of an existing one when prompted.

## Configuration

### Config file
[Configuration/config.json](./Configuration/config.json) contains the default user-editable settings. The installer prompts for most of them and writes the answers back to this file. Pass `-Config <path>` to read the install choices from another JSON file and save updates to that file instead. Relative paths are resolved from your current working directory; absolute paths and files outside the repository are also supported. This is useful when you provision the Work IQ Starter Pack on multiple dev/test tenants and you want to keep dedicated configuration files for each tenant.

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
    "ProvisionUserEmails": true,
    "TapLifetimeInMinutes": 480,
    "TapIsUsableOnce": false,
    "AppRegistrationName": "WorkIQStarterPack",
    "RealUserUpns": [
      "user1@contoso.onmicrosoft.com",
      "user2@contoso.onmicrosoft.com",
      "user3@contoso.onmicrosoft.com",
      "user4@contoso.onmicrosoft.com",
      "user5@contoso.onmicrosoft.com"
    ],
    "DynamicsEnvironmentUrl": "https://org.crm.dynamics.com",
    "DynamicsEnvironmentId": "",
    "DynamicsFOEnvironmentUrl": "https://org.operations.dynamics.com",
    "DynamicsFOLegalEntityId": "ITCO",
    "DynamicsFOCustomerGroupId": "STD",
    "DynamicsFOLanguageId": "en-us",
    "DynamicsFODeliveryTerms": "",
    "DynamicsFODeliveryMode": "",
    "DynamicsFOSalesTaxGroup": "",
    "DynamicsFOPaymentTerms": "",
    "DynamicsFOProductTemplateCompany": "ITCO",
    "DynamicsFOProductTemplateItemNumber": "ITEM",
    "DynamicsFOShippingCompany": "ITCO",
    "DynamicsFOShippingWarehouseId": "11",
    "DynamicsFOSalesCurrencyCode": "",
    "DynamicsFOShippingSiteId": ""
  }
}
```

| Setting | Description |
|---|---|
| `TenantPrefix` | The prefix of your tenant (e.g. `contoso` for contoso.sharepoint.com). It replaces the `<TENANTPREFIX>` token in `Content/content.json` and `Configuration/settings.json`. |
| `ClientId` | Client ID of an existing app registration. If empty, the installer creates one and saves its ID here. Required by `CleanUp.ps1`. |
| `InstallDemoUsers` | `true` creates the 5 built-in demo users. `false` maps the demo roles onto your own users (see [Users](#users)). |
| `InstallM365Content` | Install the Microsoft 365 content pack. At least one of Microsoft 365, Dynamics 365 Sales & Customer Service, or Finance and Operations must be selected. |
| `InstallDynamicsContent` | Install the Dynamics 365 Sales & Customer Service data, including the Caldova Field Engagement solution, and enable Dynamics license assignment. When Microsoft 365 content is also selected, this adds the Sales Team. |
| `InstallDynamicsFOContent` | Install the Dynamics 365 Finance and Operations data. Can be selected independently of the other packs. See [Finance and Operations](./docs/finance-and-operations.md) for environment preparation. |
| `DeployDynamicsDocuments` | Deploy SharePoint documents connected to Sales & Customer Service records. Used when `InstallDynamicsContent` is `true`; prompted interactively or read from the selected file with `-Config`. Requires [SharePoint integration for Dataverse](./docs/dynamics-365.md#sharepoint-integration-for-dataverse). |
| `ProvisionUserEmails` | Import the demo email threads into the users' inboxes. Always on when demo users are used. |
| `TapLifetimeInMinutes` | Used by `IssueTemporaryAccessPass.ps1`. Lifetime of each Temporary Access Pass in minutes (default `480`). Limited to the range the tenant policy allows. |
| `TapIsUsableOnce` | Used by `IssueTemporaryAccessPass.ps1`. `true` makes each Temporary Access Pass single use (default `false`, multi use). Forced to `true` if the tenant policy requires it. |
| `AppRegistrationName` | Optional, used with `-Config` only. Name for a new app registration (default `WorkIQStarterPack`). |
| `RealUserUpns` | Used with `-Config` and `InstallDemoUsers: false` only. A list of 5 UPNs (see [Users](#users)). |

The main installer and cleanup use these additional settings for Dynamics operations. See [Dynamics 365 content](./docs/dynamics-365.md).

| Setting | Description |
|---|---|
| `DynamicsEnvironmentUrl` | URL of the Dataverse environment for Sales & Customer Service (for example `https://org.crm.dynamics.com`). |
| `DynamicsEnvironmentId` | ID of the Dataverse environment. Written by the installer when it creates an environment. |

See [F&O configuration](./docs/finance-and-operations.md#fo-configuration) for the Finance and Operations settings in the example above.

The Microsoft 365 content pack installs the Market Research, Finance, and Procurement teams from `content.json`. When both Microsoft 365 and Sales & Customer Service content are selected, the installer also adds the Sales Team (the site flagged `DynamicsContent`). Dynamics 365 data is provisioned directly by the same installer, even when Microsoft 365 content is not selected. [Configuration/settings.json](./Configuration/settings.json) holds the static installer data: the app registration permissions, the supported license SKUs, and the demo users.

### Unattended install
Run `./InstallWorkIQStarterPack.ps1 -Config ./Configuration/config.json` to read installation choices from that file instead of entering them at the configuration prompts, `-ConfigPath` is also accepted.

This mode still requires interactive authentication. Browser sign-in is used when creating or updating the app registration and when starting provisioning, including with an existing app registration. Microsoft 365 SharePoint operations can request additional sign-ins. If users are missing from Dataverse, their synchronization can also require a Power Platform browser sign-in. See [Permissions](#permissions) for app registration and admin consent requirements.

A fully non-interactive installation is not currently supported. Supporting it would require a separate assessment of authentication flows, API permissions, and user-dependent operations.

The settings it reads are `TenantPrefix` (required), `InstallDemoUsers`, `InstallM365Content`, `InstallDynamicsContent`, `InstallDynamicsFOContent`, `DeployDynamicsDocuments`, `ProvisionUserEmails`, and `ClientId` (set = use that existing app registration; empty = create one, named by `AppRegistrationName`). If `InstallDemoUsers` is false, `RealUserUpns` must contain exactly 5 UPNs.

When Sales & Customer Service is selected, configure `DynamicsEnvironmentUrl` for an existing Dataverse environment; `-Config` does not create a new environment. When F&O is selected, configure `DynamicsFOEnvironmentUrl` and the applicable [F&O settings](./docs/finance-and-operations.md#fo-configuration).

The SharePoint document deployment choice is read from `DeployDynamicsDocuments`. If enabled and SharePoint integration or document management for the Account table is not ready, the installer prompts you to configure it or skip document deployment, even with `-Config`. Follow [SharePoint integration for Dataverse](./docs/dynamics-365.md#sharepoint-integration-for-dataverse) before continuing.

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

To use your own users instead, answer "no" when the installer asks about demo users and enter 5 UPNs, or set `InstallDemoUsers: false` and `RealUserUpns` in the config file. Enter them in the following order: Marketing, Finance, Security/Governance, Finance 2, Sales. The installer looks them up in Entra ID and replaces the demo names and emails in the content with theirs. Demo user photos are only applied to demo users created by the provisioning script, not to already existing users.

### Temporary Access Pass
By default each demo user has to set up Microsoft Authenticator (or another MFA method) at first sign-in. To avoid that, run the separate `IssueTemporaryAccessPass.ps1` script after the installer to issue a [Temporary Access Pass](https://learn.microsoft.com/entra/identity/authentication/howto-authentication-temporary-access-pass) (TAP). It is not part of the installation and it is useful only for demo scenarios.

```powershell
./IssueTemporaryAccessPass.ps1              # uses Configuration/config.json
./IssueTemporaryAccessPass.ps1 -Config <path>
```

- The script reads `InstallDemoUsers` from the config. If it is `true`, it lists the built-in demo users and asks you to confirm enabling TAP for all of them (default yes). If it is `false`, it asks which accounts (UPNs) to enable TAP on, defaulting to `RealUserUpns`, and confirms the list. Answering "no" ends the script without changing anything.
- The script only reads the tenant's TAP policy; it never changes it. If the Temporary Access Pass method is not enabled for the selected users in **Entra ID > Authentication methods > Policies**, the script skips them with a warning. Ask a tenant administrator (Authentication Policy Administrator or Global Administrator) to enable it if you want to use it.
- The code, its expiry, and whether it is single or multi use are printed once and written to its own log, `Logs/TapLog-YYYYMMDDXX.md` (see [Generated files and logs](#generated-files-and-logs)). Graph does not reveal the code again, so keep the log secure and delete it once the codes are distributed.
- A user can only have one Temporary Access Pass. If a selected user already has one (the prompt shows whether it is still valid or expired), the script asks whether to replace it. Yes deletes the old code and creates a new one; no keeps it, and its code is not shown again. Account passwords are not changed.
- The signed-in user needs a role that can manage authentication methods, for example Privileged Authentication Administrator (Global Administrator, already required, also works).
- Existing app registrations pick up the `UserAuthenticationMethod.ReadWrite.All` and `Policy.Read.All` permissions the next time the installer runs and grants admin consent. Run the installer once before the TAP script so the app registration exists.

### Licenses
For every content pack, each user needs Office apps and Microsoft 365 Copilot. These requirements can be met by separate licenses or a single Microsoft 365 E7 license. Dynamics license assignment also runs when Sales & Customer Service content is selected. The installer uses the supported SKUs from this list in [settings.json](./Configuration/settings.json):

- **Copilot:** `Microsoft_365_Copilot`, `M365_Copilot`, `M365_COPILOT_SPECIAL_BENEFIT_PROGRAMS`, `MICROSOFT_365_E7`
- **Office:** `SPE_E5`, `SPE_E3`, `SPB`, `O365_w/o_Teams_Bundle_M5`, `Microsoft_365_E3_(no_Teams)`, `O365_w/o Teams Bundle_M3`, `Microsoft_365_E3_EEA_(no_Teams)_Unattended_License`, `Microsoft_365_E5_(no_Teams)`, `MICROSOFT_365_E7`
- **Teams:** `Microsoft_Teams_Enterprise_New`, `Microsoft_Teams_EEA_New`, `Teams_Ess`, `TEAMS_ESSENTIALS_AAD`, `TEAMS_EXPLORATORY`, `MS_TEAMS_IW`, `M365_TEAMS_PREMIUM` and others listed in settings.json. Only needed when the Office license does not include Teams (its name contains `(no_Teams)` or `w/o Teams`).
- **Dynamics:** `DYN365_SALES_PREMIUM`, `D365_SALES_PRO` `D365_SALES_PRO_IW`, `DYN365_ENTERPRISE_SALES_CUSTOMERSERVICE`, `DYN365_ENTERPRISE_SALES`, `DYN365_ENTERPRISE_CUSTOMER_SERVICE`, `DYN365_FINANCE`

For a new set of 5 demo users, you need 5 available seats each of Copilot and Office, or 5 Microsoft 365 E7 seats (plus Teams if your Office SKU has no Teams). The prerequisite check counts only missing licenses and reserves each new SKU once per user, even when it covers several requirements. Existing supported licenses are checked before selecting new SKUs in the configured order.

Office and Copilot licenses are assigned through the same process for all content packs, including Dynamics-only installations (`InstallM365Content: false`). Existing supported licenses are retained, including when using your own users (`InstallDemoUsers: false`). A SKU is assigned at most once per user, and users whose requirements are already covered receive no license assignment request. The installer verifies actual assignments and stops before provisioning content if user creation or licensing fails. Ensure F&O users have the appropriate Dynamics licenses assigned separately.

### Pre-requisite checks
Before provisioning users, environments, or content, `InstallWorkIQStarterPack.ps1` checks the following for all selected content packs, including Dynamics-only installations.
- **Global Administrator:** the signed-in user holds the Global Administrator role.
- **Licenses:** enough available Copilot and Office seats for users missing those licenses (see [Licenses](#licenses)).
- **Work IQ service principal:** it exists and is enabled (the installer creates it if it is missing).
- **Copilot credits:** the tenant has Copilot credits. The installer calls the Microsoft Graph **beta** `copilot/costmanagement/gettenantcreditbalance()` endpoint and passes if the prepaid balance (purchased minus consumed) is above 0 or pay-as-you-go billing is listed. It needs the `CopilotCostManagement.Read.All` permission; if the call fails the check fails. The beta API can change.

### Permissions
The user running the installer must be a **Global Administrator**, because the installer creates the app registration, grants admin consent, and runs migration-related imports.

The app registration needs the permissions below. They are defined in [Configuration/appPermissions.json](./Configuration/appPermissions.json), which the installer uses to create the app registration and check it. After browser sign-in as a Global Administrator, the installer creates a new app registration or adds missing permissions to the existing one, checks existing admin consent, and grants any missing consent through Microsoft Graph REST APIs. It stops if consent cannot be completed. The Graph and SharePoint names are also listed under `AppRegistrationPermissions` in [Configuration/settings.json](./Configuration/settings.json), which is used to verify the token. Keep the two in sync.

#### Graph Delegated Permissions
- Group.ReadWrite.All (also creates the past meetings on the team calendar)
- User.ReadWrite.All
- Directory.ReadWrite.All
- Application.ReadWrite.All
- TeamMember.ReadWrite.All
- TeamsTab.ReadWrite.All (adds the lists and libraries as channel tabs)
- TeamSettings.ReadWrite.All
- AppCatalog.Read.All
- CopilotCostManagement.Read.All (Copilot credit check)
- CopilotCostManagement-Policy.Read.All (reading Copilot spending policies; optional, the check still works without it)
- UserAuthenticationMethod.ReadWrite.All (Temporary Access Pass via `IssueTemporaryAccessPass.ps1`; optional)
- Policy.Read.All (checking whether Temporary Access Pass is enabled, via `IssueTemporaryAccessPass.ps1`; optional)

#### Graph Application Permissions
- Teamwork.Migrate.All (chat import)
- Mail.ReadWrite (email import)

#### SharePoint Delegated Permissions
- AllSites.FullControl
- TermStore.ReadWrite.All

#### Dynamics and Power Platform Delegated Permissions (Dynamics 365 content)
- Dynamics CRM: user_impersonation
- Dynamics ERP: Odata.FullAccess
- Power Platform API: EnvironmentManagement.Environments.Read, EnvironmentManagement.Groups.ReadWrite, EnvironmentManagement.Settings.ReadWrite

#### Certificate
The two application permissions are used with certificate authentication. The installer generates a self-signed certificate (valid for 2 years) in `Installation/.certs/` for the default configuration, or `Generated/.certs/` beside an alternative configuration, and registers the public key on the app registration. The `.pfx` contains a private key. These generated folders are git-ignored within this repository; do not commit or share them.

## Instructions
1. Run `./InstallWorkIQStarterPack.ps1`.
2. Answer the prompts: tenant prefix, demo or real users, content packs (Microsoft 365, Dynamics 365 Sales & Customer Service, and/or Finance and Operations), environment URLs where applicable, and the app registration. For Sales & Customer Service, you can choose to create a new Dataverse environment instead. If you do not already have an app registration with the required permissions above, answer "no" and the installer creates one.
3. Sign in through the browser when asked, using a Global Administrator account (see [Permissions](#permissions)). Sign-in can occur at several steps.
4. Wait for the installer to finish all selected Microsoft 365 and Dynamics operations. Answer any applicable environment creation, F&O setup, and optional Dynamics SharePoint document prompts. Some steps wait for Microsoft 365 to catch up (team and site provisioning, mailbox creation for photos and email, and consent and certificate propagation, which can take a few minutes).
5. Review the install log in `Logs/` (`InstallLog-YYYYMMDDXX.md`).

The installer can be run again. Existing Teams are kept, but their owners and members are reset. Chat history is skipped if the channel was already imported. Emails are deleted and re-delivered.

## What gets installed
- **Market Research Team** (private Team): a "Launch Readiness" channel, 9 documents, 5 past Teams meetings (with transcripts), 5 email threads, and 4 chats.
- **Finance Team** (private Team): a "Financial Investigation Cases" channel, 8 documents, 4 email threads, and 3 chats. It also gets the Supplier Directory, Financial Investigation Cases, and Procurement Exception lists, and the Contract Library. The library uses a "WorkIQ Starter Pack" term group in the tenant term store.
- **Procurement Team** (private Team): a "Capacity Planning" channel, 8 documents, 3 past Teams meetings, 4 email threads, and 3 chats. It also gets the Supplier Directory, Supplier Capacity Tracker, and RFPs lists.
- **Sales Team** (private Team, only when both `InstallM365Content` and `InstallDynamicsContent` are `true`): a "Dynamics - D365 - Sales Hub" channel, 4 documents, 3 email threads, and 2 chats.
- Profile photos for the demo users when Microsoft 365 content is selected.
- **Dynamics 365 data**, when selected: Sales & Customer Service and/or Finance and Operations content (see [Dynamics 365 content](./docs/dynamics-365.md) and [Finance and Operations](./docs/finance-and-operations.md)).

The lists and libraries are added to the first channel as tabs, and the default Notes, Wiki, and Page tabs are removed.

The sample documents live under [Content/Documents](./Content/Documents), in the Demo1 to Demo4 folders used by the sites in `content.json`. To create more, see [Generating new content](#generating-new-content).

## Generating new content
[Prompts/DocumentGenerationPrompt.md](./Content/Documents/Prompts/DocumentGenerationPrompt.md) is the prompt used to author the demo content: documents, meeting transcripts, email threads, and Teams chats. It fixes the product, supplier, and raw-material names so everything stays consistent across the demos.

You can use this prompt with GitHub Copilot, Microsoft 365 Copilot, Claude, Codex, or another assistant.

To generate new content:

1. Give the assistant the generation prompt, [Configuration/settings.json](./Configuration/settings.json) for the demo users, and [Content/content.json](./Content/content.json) for the existing content structure. With repository access, reference these files in your request. In a chat without file access, paste the prompt and the relevant JSON sections instead.
2. Ask it to generate the selected demo under `Content/Documents/<DemoName>/` and prepare the matching entries in `Content/content.json`, keeping the other demos unchanged. An example request is provided below.
3. If the assistant only returns content in chat, save or export the files into the target demo folder and apply the proposed JSON changes yourself. Use actual Word (`.docx`) and PDF files for documents, Word (`.docx`) files for meeting transcripts, and Markdown for email threads and chats, as required by the prompt.
4. Review the generated files and transcript structure against the prompt. Check that `Content/content.json` is valid JSON, references the actual files using repository-relative paths, and uses the configured demo users and consistent dates in the past.
5. Run the installer again (see [Instructions](#instructions)).

Example request (replace `<DemoName>` with the target demo folder name):

> Use the instructions in `Content/Documents/Prompts/DocumentGenerationPrompt.md`, the demo users in `Configuration/settings.json`, and the structure in `Content/content.json` to generate content for `<DemoName>`. Create the files in the required formats under `Content/Documents/<DemoName>/` and update the corresponding `Content/content.json` entries. Keep other demos unchanged. If you cannot edit the repository, return the content and proposed JSON entries for me to save and apply.

Choose the workflow for your assistant:

| Assistant | How to use it |
|---|---|
| GitHub Copilot | Open the repository in your IDE and use [agent mode](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/use-copilot-agents/use-agent-mode). Reference the three files above and ask it to create the demo files and update the matching JSON entries. |
| Microsoft 365 Copilot | Use [Copilot Chat](https://support.microsoft.com/en-us/microsoft-365-copilot/create-content-using-microsoft-365-copilot-chat), paste the prompt and relevant JSON sections, and ask for the content and proposed entries. Save or export the files and apply the JSON changes in the repository as described above. |
| Claude | Start [Claude Code](https://code.claude.com/docs/en/quickstart) from the repository directory and reference the three files above in your request. |
| Codex | Start [Codex](https://learn.chatgpt.com/docs/projects) from the repository directory with `codex`, or open the repository in the Codex IDE extension. Reference the three files above in your request. |

To change the scenario or the names used, edit the prompt before generating the content. When regenerating an existing demo, the prompt instructs the assistant to remove the existing files in that demo folder first.

## Dynamics 365 content

For Dynamics 365 Sales & Customer Service setup, including Dataverse environment preparation and optional SharePoint document integration, see the [Dynamics 365 guide](./docs/dynamics-365.md).

## Finance and Operations

For F&O environment preparation, configuration, and provisioning verification, see the [Finance and Operations guide](./docs/finance-and-operations.md).

## Generated files and logs
For the default `Configuration/config.json`, these locations are unchanged and git-ignored:
- `Content/content.custom.json`: the content with your tenant prefix and users applied. It also records the imported email message IDs.
- `Configuration/users.custom.json`: your resolved users (real users only).
- `Installation/.certs/`: the certificate.
- `Logs/TapLog-YYYYMMDDXX.md` (one file per run of `IssueTemporaryAccessPass.ps1`): the inputs, actions, and the Temporary Access Pass codes in plain text, so store or delete it securely.
- `Logs/InstallLog-YYYYMMDDXX.md` and `Logs/CleanUpLog-YYYYMMDDXX.md` (one file per run): a run summary, your inputs, and the actions taken for all selected Microsoft 365 and Dynamics operations. The install log also lists the demo user passwords in plain text, so store or delete it securely.
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
- **Finance and Operations cleanup:** delete the demo sales orders and their lines, customers in the configured legal entity, and shared products. Shared products apply across companies. F&O users and their **Sales Clerk** role assignments are retained.
- **Dynamics SharePoint cleanup:** remove the uploaded account folders and their contents from the Sales & Customer Service SharePoint integration.
- **Optional local and app cleanup:** delete installation logs and/or remove the app registration, its service principal, and the local Teams chat migration certificate. Only delete the app registration if the installer created it, not if you supplied a pre-existing one.

Dynamics cleanup prompts for the relevant environment URLs, using saved values as defaults. F&O cleanup also requires `DynamicsFOLegalEntityId` in the configuration. Selecting Dynamics cleanup does not automatically select Microsoft 365 cleanup or delete users and Teams.

All selected cleanup operations are recorded in `Logs/CleanUpLog-YYYYMMDDXX.md`, unless you choose to delete the logs.

If a site cannot be fully removed (it stays active, is not confirmed purged from the recycle bin, or an error occurs), the cleanup lists those sites at the end with the reason. Remove them manually in the SharePoint admin center, from both Active sites and Deleted sites, and purge any matching deleted group in the Microsoft 365 admin center.
