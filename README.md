# WorkIQ Starter Pack

Demo sites, users, and content used to explore Work IQ on a demo or developer tenant.

### DO NOT USE THIS IN PRODUCTION.
The installer creates users, Teams, SharePoint content, and **writes email directly into the users' mailboxes** (tagged with the category `WorkIQStarterPack`). Only run it against a demo or developer tenant.

## Overview

The Work IQ Starter Pack is a collection of PowerShell scripts that automate the provisioning of demo users, content, and business data onto a target demo or developer tenant. It provides a consolidated knowledge base for exploring and experimenting with Work IQ, as well as for delivering consistent demos.

[Content/content.json](./Content/content.json) describes the demo. The installer reads it and uses PnP PowerShell and Microsoft Graph to create:

- Users (optional), their licenses, and profile photos
- Microsoft Teams and their SharePoint sites, with channels
- Documents and meeting transcripts uploaded with the right authors and dates
- SharePoint lists, libraries, content types, views, and managed-metadata term sets
- Teams chat history, imported with the Graph channel migration API
- Email threads, delivered to each recipient's inbox

## Requirements
- PowerShell 7.4.0 or later ([install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)). It is available for Windows, Linux and Mac.
- The `PnP.PowerShell` module. The installer installs it for the current user if it is missing.
- A **Global Administrator** account (see [Permissions](#permissions)).
- Work IQ enabled in your tenant. The Work IQ service principal (app ID `fdcc1f02-fc51-4226-8753-f668596af7f7`) must exist and be enabled, otherwise the installer stops.
- Licenses for the users (see [Licenses](#licenses)).
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
    "ProvisionUserEmails": true,
    "SkipPreReqCheck": false
  }
}
```

| Setting | Description |
|---|---|
| `TenantPrefix` | The prefix of your tenant (e.g. `contoso` for contoso.sharepoint.com). It replaces the `<TENANTPREFIX>` token in `Content/content.json` and `Configuration/settings.json`. |
| `ClientId` | Client ID of an existing app registration. If empty, the installer creates one and saves its ID here. Required by `CleanUp.ps1`. |
| `InstallDemoUsers` | `true` creates the 5 built-in demo users. `false` maps the demo roles onto your own users (see [Users](#users)). |
| `InstallM365Content` | Install the M365 content pack. At least one pack must be selected. |
| `InstallDynamicsContent` | Install the Dynamics 365 content pack. This also assigns a Dynamics license to the users. |
| `ProvisionUserEmails` | Import the demo email threads into the users' inboxes. Always on when demo users are used. |
| `SkipPreReqCheck` | Skip the Global Administrator, license, and Power Platform checks. The Work IQ service principal check is always enforced. |
| `AppRegistrationName` | Optional, unattended mode only. Name for a new app registration (default `WorkIQStarterPack`). |
| `RealUserUpns` | Unattended mode with `InstallDemoUsers: false` only. A list of 5 UPNs (see [Users](#users)). |

Both content packs currently install the same `content.json`. [Configuration/settings.json](./Configuration/settings.json) holds the static installer data: the app registration permissions, the supported license SKUs, and the demo users.

### Unattended install
Run `./InstallWorkIQStarterPack.ps1 -UseConfig` to skip every install question and use the values in config.json instead. The browser sign-in is still required. For a new app registration the admin consent URL is printed and the installer does not wait for it.

The settings it reads are `TenantPrefix` (required), `InstallDemoUsers`, `InstallM365Content`, `InstallDynamicsContent`, `ProvisionUserEmails`, `SkipPreReqCheck`, and `ClientId` (set = use that existing app registration; empty = create one, named by `AppRegistrationName`). If `InstallDemoUsers` is false, `RealUserUpns` must contain exactly 5 UPNs.

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

You need at least 5 available seats each of Copilot and Office.

### Permissions
The user running the installer must be a Global Administrator, because the installer creates the app registration, grants admin consent, and runs migration-related imports.

The app registration needs the permissions below. The installer creates them, as defined under `AppRegistrationPermissions` in [Configuration/settings.json](./Configuration/settings.json). With an existing app registration, the installer adds any missing permissions and opens the admin consent page for you to approve them. For this to work, the existing app must already have the delegated Graph permission `Application.ReadWrite.All` with admin consent granted.

#### Graph Delegated Permissions
- Group.ReadWrite.All
- User.ReadWrite.All
- Directory.ReadWrite.All
- Application.ReadWrite.All
- TeamMember.ReadWrite.All

#### Graph Application Permissions
- Teamwork.Migrate.All (chat import)
- Mail.ReadWrite (email import)

#### SharePoint Delegated Permissions
- AllSites.FullControl

#### Certificate
The two application permissions are used with certificate authentication. The installer generates a self-signed certificate (valid for 2 years) in `Installation/.certs/` and registers the public key on the app registration. The `.pfx` contains a private key. The folder is git-ignored; do not commit or share it.

## Instructions
1. Make sure your tenant meets the requirements for Work IQ and [enable Work IQ in your tenant](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/enable-work-iq?tabs=entra-admin).
2. Run `./InstallWorkIQStarterPack.ps1`.
3. Answer the prompts: tenant prefix, demo or real users, content packs, and the app registration. If you do not already have an app registration with the permissions above, answer "no" and the installer creates one.
4. Sign in when asked and approve admin consent. Sign-in opens a browser; it happens for several of the steps.
5. Wait for the installer to finish. Some steps wait for Microsoft 365 to catch up (team and site provisioning, mailbox creation for photos and email, and consent and certificate propagation, which can take a few minutes).
6. Review `Logs/InstallLog.md`.

The installer can be run again. Existing Teams are kept, but their owners and members are reset. Chat history is skipped if the channel was already imported. Emails are deleted and re-delivered.

## What gets installed
- **Market Research Team** (private Team): a "Launch Readiness" channel, 9 documents, 5 meeting transcripts, 5 email threads, and 4 chats.
- **Finance Team** (private Team): a "Financial Investigation Cases" channel, 8 documents, 4 email threads, and 3 chats. It also gets the Supplier Directory, Financial Investigation Cases, and Procurement Exception lists, and the Contract Library. The library uses a "WorkIQ Starter Pack" term group in the tenant term store.
- Profile photos for the demo users.

The sample documents live under [Content/Documents](./Content/Documents). Only Demo1 and Demo2 are used by `content.json`; Demo3 and Demo4 are not wired in. [Prompts/DocumentGenerationPrompt.md](./Content/Documents/Prompts/DocumentGenerationPrompt.md) is the prompt used to author content.

## Generated files and logs
These are git-ignored:
- `Content/content.custom.json`: the content with your tenant prefix and users applied. It also records the imported email message IDs.
- `Configuration/users.custom.json`: your resolved users (real users only).
- `Installation/.certs/`: the certificate.
- `Logs/InstallLog.md` and `Logs/CleanUpLog.md`: a run summary, your inputs, and the actions taken. The install log also lists the demo user passwords in plain text, so store or delete it securely.

## Cleanup
Run `./CleanUp.ps1` to remove what the installer created. It is always interactive and requires `TenantPrefix` and `ClientId` in the config file. It will:
1. Remove the imported emails.
2. Delete the Teams, their M365 groups and sites, and purge them from the recycle bins.
3. Delete the demo users (only the ones in `DefaultUsers` in settings.json) and purge them from the deleted items.
4. Delete the generated custom files.
5. Optionally delete the `Logs` folder, the app registration, and the certificate. Only delete the app registration if the installer created it.

If a site is left orphaned after a failed cleanup, `./DeleteDeadSiteGroups.ps1` takes the site ID and purges its deleted group.

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
