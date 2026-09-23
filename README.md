# WorkIQ Starter Pack

Site templates used as demos from Microsoft

## Overview

The Work IQ Starter Pack is a collection of scripts designed to automate the provisioning of demo users, content, and business data onto a target demo or developer tenant. It provides a consolidated knowledge base for exploring and experimenting with Work IQ, as well as for delivering consistent demos

This repo contains demo sites. The sites are built using PnP Provisioning templates, which allow us to create a site with a specific configuration and content in a repeatable way. The templates are applied using PowerShell scripts, which also perform some additional configuration tasks that cannot be contained in the template for technical reasons.

## Requirements
You need PowerShell 7.4.0 or later to use PnP PowerShell. It is available for Windows, Linux and Mac and can be [installed through here](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
The PnPPowerShell module is required to run this sample
You will need an application registration to install this sample. It will require the following permissions. InstallWorkIQStarterPack.ps1 can create one for you, or you can enter the client ID of an existing one when prompted.
You Must be a XXX admin in order to create the application registration and approve the api permissions.

## Configuration

### Config file
The configuration file contains all the user editable settings. You can edit the [config.json file](./Configuration/config.json)
```json
{
  "Settings": {
    "InstallM365Content": true, - True installs the M365 Content Pack
    "InstallDynamicsContent": true, - True installs the Dynamics 365 Content Pack
    "TenantPrefix": "caldova", - The prefix for your tenant (e.g. caldova.sharepoint.com)
    "ClientId": "d73d41ad-fdd8-5r4g-8537-4a81c0360986" - If you are using an existing app registration enter the ClientId here. The installation script will update this value if you don't enter it. 
  }
}
```
### Users
This demo requires 5 users. The installation will create these users in your tenant. If you would like to use your own users edit the [config.json file](./Configuration/config.json) and replace the user information with your existing users. If the users already exist they will not be recreated or edited. If the installation creates new users the passwords for the users will be output in the console. 

### Licenses
Put somethign in here about what licenses are supported

### Permissions
This solution requires the user installing the solution to be a Global Administrator on the tenant. This is because we need to create and approve application the registration and do migration related content. The permissions required for the application registration are as followed. These are created by the installation script, and are defined under `AppRegistrationPermissions` in Configuration/settings.json. If you have an existing app registration, the installer checks it and adds any missing permissions, then opens the admin consent page for you to approve them. For this to work, the existing app registration must already have the delegated Graph permission Application.ReadWrite.All with admin consent granted.

#### Graph Delegated Permissions
- Group.ReadWrite.All
- User.ReadWrite.All
- Directory.ReadWrite.All
- Application.ReadWrite.All

#### Graph Application Permissions
- Teamwork.Migrate.All

#### SharePoint Delegated Permissions
- AllSites.FullControl

## Instructions
- Ensure you meet the critera for enabling Work IQ in your tenant (Azure Subscription, )
- [Enable Work IQ in your tenant](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/enable-work-iq?tabs=entra-admin).
- Run InstallWorkIQStarterPack.ps1. If you do not already have an application registration with XXX permissions, answer "no" when asked and the installer will create one.
- You will be asked to authenticate.


### If you want to use your own users edit the config file with the selected user names. 


## Author(s)
- [Derek Cash-Peterson](https://www.linkedin.com/in/dcashpeterson/), MVP (Sympraxis Consulting)
- [Fabio Franzini](https://www.linkedin.com/in/fabiofranzini/), MVP (Apvee Solutions Srl)
- [Guido Preite](https://www.linkedin.com/in/guidopreite/), MVP (Apvee Solutions Srl)

## Disclaimer
THIS CODE IS PROVIDED AS IS WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.

## Change Log
For a list of issues/updates made in each release see the [CHANGELOG](./CHANGELOG.md).


