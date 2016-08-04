# Sitecore Azure PowerShell

This repository contains a set of PowerShell cmdlets for developers and administrators to deploy Sitecore solutions.

[![NuGet version](https://img.shields.io/badge/powershell-0.5.1-blue.svg)](https://www.powershellgallery.com/packages/Sitecore.Azure/)

## Requirements

It is very easy to get started with Sitecore.Azure module to deploy Sitecore databases to Microsoft Azure. You just need the following components and 10 minutes of your time.

- A work or school account / Microsoft account and a Microsoft Azure subscription with the following Azure services enabled:
  - Azure Resource Group
  - Azure Storage
  - Azure SQL Database
  - Azure SQL Database Server
- Windows PowerShell ISE or Microsoft Azure PowerShell (available on [PowerShell Gallery](https://www.powershellgallery.com/profiles/azure-sdk/) and [WebPI](http://aka.ms/webpi-azps/)).
- Microsoft SQL Server 2014 or higher
- Sitecore® Experience Platform™ 8.0 or higher

> **Note:** For basic instructions about using Windows PowerShell, see [Using Windows PowerShell](http://go.microsoft.com/fwlink/p/?LinkId=321939).

## Instructions

The recommended approach to deploy Sitecore databases to the [Microsoft Azure SQL Database](https://azure.microsoft.com/en-us/documentation/articles/sql-database-technical-overview/) service is as follows:

1. Run either the Windows PowerShell ISE or Microsoft Azure PowerShell.

   > **Note:** You must run as an Administrator the very first time to install a module.

2. Install the Windows PowerShell [Sitecore.Azure](https://www.powershellgallery.com/packages/Sitecore.Azure/) module:

   ```PowerShell
   PS> Install-Module -Name Sitecore.Azure 
   ```
   
   > **Note:** The `Sitecore.Azure` module depends on the Azure Resource Manager modules, which will be installed automatically if any needed.
   
3. Log in to authenticate cmdlets with Azure Resource Manager (ARM):

   ```PowerShell
   PS> Login-AzureRmAccount
   ```

4. Import a Publishing Settings file (*.publishsettings) to authenticate cmdlets with Azure Service Management (ASM):

   ```PowerShell
   PS> Import-AzurePublishSettingsFile -PublishSettingsFile "C:\Users\Oleg\Desktop\Visual Studio Premium with MSDN.publishsettings"
   ```
   
   > **Note:** To downloads a publish settings file for a Microsoft Azure subscription, use the `Get-AzurePublishSettingsFile` cmdlet.

5. Now you can use the `Publish-SitecoreSqlDatabase` cmdlet to publish one or more Sitecore SQL Server databases. 

## Examples
   
- **Example 1:** Publish the SQL Server databases `sc81initial_core`, `sc81initial_master`, `sc81initial_web` from the local SQL Server `Oleg-PC\SQLEXPRESS` to an Azure SQL Database Server.

  ```PowerShell
  PS> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" `
                                  -SqlServerCredentials $credentials `
                                  -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web")
  ```
      
- **Example 2:** Publish the SQL Server databases `sc81initial_web` from the local SQL Server `Oleg-PC\SQLEXPRESS` to an Azure SQL Database Server in the Resource Group `MyCompanyName` at the Azure data center `Australia East`.
   
  ```PowerShell
  PS> $credentials = Get-Credential
     
  PS> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" `
                                  -SqlServerCredentials $credentials ` 
                                  -SqlServerDatabaseList @("sc81initial_web") `
                                  -AzureResourceGroupName "MyCompanyName" `
                                  -AzureResourceGroupLocation AustraliaEast
  ```
     
  > **Important:** The Australia Regions are available to customers with a business presence in Australia or New Zealand.
     
- **Example 3:** Publish the SQL Server databases `sc81initial_core` and `sc81initial_web` from the local SQL Server `Oleg-PC\SQLEXPRESS` to an Azure SQL Database Server using the Azure Storage Account `mycompanyname` for BACPAC packages (.bacpac files).
   
  ```PowerShell
  PS> $password = ConvertTo-SecureString "12345" -AsPlainText -Force 
  PS> $credentials = New-Object System.Management.Automation.PSCredential ("sa", $password) 
     
  PS> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" `
                                  -SqlServerCredentials $credentials `
                                  -SqlServerDatabaseList @("sc81initial_core", "sc81initial_web") `
                                  -AzureStorageAccountName "mycompanyname" `
                                  -AzureStorageAccountType Standard_GRS
  ```
     
- **Example 4:** Publish the SQL Server databases `sc81initial_core`, `sc81initial_master` and `sc81initial_web` from the local SQL Server `Oleg-PC\SQLEXPRESS` to an Azure SQL Database Server with specified administrator credentials and "P1 Premium" price tier.
   
  ```PowerShell
  PS> $password = ConvertTo-SecureString "12345" -AsPlainText -Force 
  PS> $azureSqlServerCredentials = New-Object System.Management.Automation.PSCredential ("sa", $password) 
     
  PS> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" `
                                  -SqlServerCredentials $localSqlServerCredentials `
                                  -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web") `
                                  -AzureSqlServerName "sitecore-azure" `
                                  -AzureSqlServerCredentials $azureSqlServerCredentials `
                                  -AzureSqlDatabasePricingTier "P1"
  ```
   
- **Example 5:** Publish the SQL Server databases `sc81initial_core`, `sc81initial_master`, `sc81initial_web` and `sc81initial_reporting` from the local SQL Server `Oleg-PC\SQLEXPRESS` to Azure SQL Database Server `sitecore-azure` in the Resource Group `MyCompanyName` at the Azure data center `Japan East` using the Azure Storage Account `mycompanyname`.
   
  ```PowerShell
  PS> $localPassword = ConvertTo-SecureString "12345" -AsPlainText -Force 
  PS> $localSqlServerCredentials = New-Object System.Management.Automation.PSCredential ("sa", $localPassword) 
     
  PS> $azurePassword = ConvertTo-SecureString "Experienc3!" -AsPlainText -Force 
  PS> $azureSqlServerCredentials = New-Object System.Management.Automation.PSCredential ("sitecore", $azurePassword)
     
  PS> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" `
                                  -SqlServerCredentials $localSqlServerCredentials `
                                  -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web", "sc81initial_reporting") `
                                  -AzureResourceGroupName "MyCompanyName" `
                                  -AzureResourceGroupLocation JapanEast `
                                  -AzureStorageAccountName "mycompanyname" `
                                  -AzureSqlServerName "sitecore-azure" `
                                  -AzureSqlServerCredentials $azureSqlServerCredentials 
  ```