# Exports a database schema and user data from a local SQL Server to a BACPAC package (.bacpac file).
function Export-SitecoreAzureSqlDatabase
{
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SqlServerName,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        $SqlServerCredentials,                             
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $SqlServerDatabaseList
  )

  # User's temp directory.
  $tempPath = [System.IO.Path]::GetTempPath() 
  # The disk directory path where the *.bacpac file will be written.
  $outputDirectory = New-Item -ItemType Directory -Path $tempPath -Name "Sitecore\BACPAC\" -Force

  # For more information about the SqlPackage.exe utility, see the MSDN web site https://msdn.microsoft.com/en-us/library/hh550080%28v=vs.103%29.aspx  
  Import-Module sqlps -DisableNameChecking    
  $sqlServerVersion = (Get-Item -Path ("SQLSERVER:\SQL\{0}" -f $SqlServerName)).Version     
  $sqlpackageExe = "{0}\Microsoft SQL Server\{1}{2}\DAC\bin\sqlpackage.exe" -f ${env:ProgramFiles(x86)}, $sqlServerVersion.Major, $sqlServerVersion.Minor

  foreach ($databaseName in $sqlServerDatabaseList)
  {
    $filePath = "{0}\{1}.bacpac" -f $outputDirectory, $databaseName
    
    &$sqlpackageExe /a:Export `
                    /ssn:$SqlServerName `
                    /su:$($SqlServerCredentials.UserName) `
                    /sp:$($SqlServerCredentials.GetNetworkCredential().Password) `
                    /sdn:$databaseName `
                    /tf:$filePath | Out-Host
    
    $info = @{      
      ExportingStatus = "Succeeded";   
      SqlServer = $sqlServerName;
      SqlDatabase = $databaseName;
      File = $filePath    
    }

    Write-Host (New-Object -Type PSObject -Property $info | Format-List -Property @("ExportingState", "SqlServer", "SqlDatabase", "File") | Out-String)
  }
  
  return $outputDirectory
} 

# Gets an Azure Resource Group for keeping resources such as Storage, SQL Server and SQL Database in one scope.
function Get-SitecoreAzureResourceGroup 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Name,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String] 
        $Location
  ) 
    
  # Check if Azure Resource Group exists. If it does not, create it.
  try
  {
    $resourceGroup = Get-AzureRmResourceGroup -Name $Name
  }
  catch [System.ArgumentException]
  {
    $resourceGroup = New-AzureRmResourceGroup -Name $Name `
                                              -Location $Location
  }
  
  Write-Host ($resourceGroup  | Format-List | Out-String)

  return $resourceGroup
} 

# Creates an Azure Storage and uploading a BACPAC packages (*.bacpac files) to a Container.
function Get-SitecoreAzureStorageAccount 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Resources.Models.PSResourceGroup]
        $ResourceGroup,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String] 
        $AccountName,        
        [Parameter(Position=2, Mandatory = $false)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ContainerName = "databases"
  ) 

  $ContainerName = $ContainerName.ToLowerInvariant()

  try
  {
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                                -Name $AccountName 
  }                                           
  catch [Hyak.Common.CloudException]
  {
    $storageAccount = New-AzureRmStorageAccount -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                                -Location $ResourceGroup.Location `
                                                -Name $AccountName `
                                                -Type Standard_LRS                                                                                           
  }
                                          
  $storageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                                    -Name $storageAccount.StorageAccountName                                                  

  $storageAccountContext = New-AzureStorageContext -StorageAccountName $storageAccount.StorageAccountName `
                                                   -StorageAccountKey $storageAccountKey.Key1                                                 

  # Check if Azure Blob Container exists. If it does not, create it.
  try 
  {
    $storageContainer = Get-AzureStorageContainer -Context $storageAccountContext `
                                                  -Name $ContainerName
  }
  catch [Microsoft.WindowsAzure.Commands.Storage.Common.ResourceNotFoundException]
  {                                                  
    $storageContainer = New-AzureStorageContainer -Name $ContainerName `
                                                  -Context $storageAccountContext `
                                                  -Permission Off                                                
  }

  Write-Host ($storageAccount | Format-List | Out-String)
  
  return $storageAccountContext
} 

# Uploads local Sitecore BACPAC packages (*.bacpac files) to a Storage Blob.
function Set-SitecoreAzureBacpacFile 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Directory,
        [Parameter(Position=1, Mandatory = $false)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ContainerName = "databases",        
        [Parameter(Position=2, Mandatory = $true)]  
        [ValidateNotNull()]
        [Microsoft.WindowsAzure.Commands.Common.Storage.AzureStorageContext]
        $StorageAccountContext        
  )

  Get-ChildItem –Path $("{0}\*.bacpac" -f $Directory) | Set-AzureStorageBlobContent -Container $ContainerName `
                                                                                    -Context $StorageAccountContext `
                                                                                    -Force

  Get-AzureStorageBlob -Container $ContainerName -Context $StorageAccountContext | Out-Host  
}

# Creates an Azure SQL Server and setting up the firewall.
function Get-SitecoreAzureSqlServer 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Resources.Models.PSResourceGroup]
        $ResourceGroup,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]        
        [System.String]
        $ServerName,
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        $SqlServerCredentials
  ) 
  
  # Check if Azure SQL Server instance exists. If it does not, create it.
  try
  {
      $sqlServer = Get-AzureRmSqlServer -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                        -ServerName $azureSqlServerName
  }
  catch [Hyak.Common.CloudException]
  {
      # Create Azure SQL Server if it does not exist.
      $sqlServer = New-AzureRmSqlServer -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                        -Location $ResourceGroup.Location `
                                        -ServerName $azureSqlServerName `
                                        -SqlAdministratorCredentials $SqlServerCredentials `
                                        -ServerVersion "12.0"
  }

  Set-SitecoreAzureSqlServerFirewallRule -ResourceGroup $ResourceGroup -SqlServer $sqlServer.ServerName

  Write-Host ($sqlServer | Format-List | Out-String)

  return $sqlServer 
}

# Sets an Azure SQL Server Firewall Rule.
function Set-SitecoreAzureSqlServerFirewallRule 
{ 
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Resources.Models.PSResourceGroup]
        $ResourceGroup,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SqlServerName
  )
  
  # The name of the firewall rule.
  $azureIpAddresssRule = "AllowAllAzureIPs"
  # The name of the firewall rule.
  $clientIpAddressRule = "ClientIPAddress_{0}" -f (Get-Date -format yyyy-M-d_HH-mm-ss)
 
  # Check if access to Azure Services is allowed.
  # If it does not, create Azure SQL Server Firewall Rule.
  try
  {
    Get-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                     -ServerName $SqlServerName `
                                     -FirewallRuleName $azureIpAddresssRule | Out-Host
  }
  catch [Hyak.Common.CloudException]
  {
    New-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                     -ServerName $SqlServerName `
                                     -AllowAllAzureIPs | Out-Host
  }

  # Check if access to client IP address is allowed.
  # If it does not, create Azure SQL Server Firewall Rule.
  try
  {
    Get-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                     -ServerName $SqlServerName `
                                     -FirewallRuleName $clientIpAddressRule | Out-Host
  }
  catch [Hyak.Common.CloudException]
  {
    # Getting external IP address.
    $webclient = New-Object net.webclient
    $curentIpAddress = $webclient.DownloadString("http://checkip.dyndns.com") -replace "[^\d\.]"

    New-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                     -ServerName $SqlServerName `
                                     -FirewallRuleName $clientIpAddressRule `
                                     -StartIpAddress $curentIpAddress `
                                     -EndIpAddress $curentIpAddress | Out-Host                                  
  }
} 

# Imports Azure SQL Databases from a Blob Storage.
function Import-SitecoreAzureSqlDatabase 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Resources.Models.PSResourceGroup]
        $ResourceGroup,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SqlServerName,
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]        
        [System.Management.Automation.PSCredential]
        $SqlServerCredentials,
        [Parameter(Position=3, Mandatory = $false)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ContainerName = "databases",       
        [Parameter(Position=4, Mandatory = $true)]  
        [ValidateNotNull()]
        [Microsoft.WindowsAzure.Commands.Common.Storage.AzureStorageContext]
        $StorageAccountContext
  )

  $blobList = Get-AzureStorageBlob -Context $StorageAccountContext `
                                   -Container $ContainerName

  $importRequestList = New-Object System.Collections.Generic.List[System.Object]
 
  # Import to Azure SQL Database using *.bacpac files from Azure Storage Account.
  foreach ($blob in $blobList)
  {  
    if ($blob.Name.EndsWith(".bacpac"))
    {
      $databaseName = [System.IO.Path]::GetFileNameWithoutExtension($blob.Name)

      # Check if Azure SQL Database exists. If it does not, create it.
      try
      {
        $sqlDatabase = Get-AzureRmSqlDatabase –ResourceGroupName $ResourceGroup.ResourceGroupName `
                                              –ServerName $SqlServerName `
                                              –DatabaseName $databaseName
      }
      catch [Hyak.Common.CloudException]
      {  
        $sqlDatabase = New-AzureRmSqlDatabase –ResourceGroupName $ResourceGroup.ResourceGroupName `
                                              –ServerName $SqlServerName `
                                              –DatabaseName $databaseName `
                                              -RequestedServiceObjectiveName "S2"
      }     
      
      $sqlDatabaseServerContext = New-AzureSqlDatabaseServerContext -ServerName $SqlServerName `
                                                                    -Credential $SqlServerCredentials

      if ($sqlDatabaseServerContext -ne $null)
      {
        $importRequest = Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlDatabaseServerContext `
                                                      -StorageContext $StorageAccountContext `
                                                      -StorageContainerName $ContainerName `
                                                      -DatabaseName $databaseName `
                                                      -BlobName  $blob.Name
        $importRequestList.Add($importRequest)
      }
    }
  }

  return $importRequestList
} 

# Gets a status of the import request.
function Get-SitecoreAzureSqlServerStatus 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [System.Collections.Generic.List[System.Object]]
        $ImportRequestList
  )   

  $totalTasks = $ImportRequestList.Count
  $successfulTaskList = New-Object System.Collections.Generic.List[System.Object]
  $failedTaskList = New-Object System.Collections.Generic.List[System.Object]

  $status = "Total: {0}. Successful: {1}. Failed: {2}. Active: {3}." -f $totalTasks, $successfulTaskList.Count, $failedTaskList.Count, $ImportRequestList.Count 
  Write-Progress -Id 0 -activity "Start-AzureSqlDatabaseImport task status:" -status $status

  do
  {  
    for ($index = 0; $index -lt $ImportRequestList.Count; $index++)
    {      
      $importStatus = Get-AzureSqlDatabaseImportExportStatus -Request $ImportRequestList[$index]

      if ($importStatus.Status -eq "Failed")
      {
        $failedTaskList.Add($importStatus)
        $ImportRequestList.Remove($ImportRequestList[$index])
      }
      elseif ($importStatus.Status -eq "Completed")
      {
        Write-Progress -Id ($index + 1) -activity ("Importing blob '{0}'." -f $importStatus.BlobUri) -status $importStatus.Status -PercentComplete 100
        Write-Progress -Id ($index + 1) -activity ("Importing blob '{0}'." -f $importStatus.BlobUri) -status $importStatus.Status -Completed
        
        $successfulTaskList.Add($importStatus)
        $ImportRequestList.Remove($ImportRequestList[$index])
      }
      elseif ($importStatus.Status.StartsWith("Running"))
      {
        $startIndex = $importStatus.Status.IndexOf("=") + 1
        $endIndex = $importStatus.Status.IndexOf("%")
        $lengh = $endIndex - $startIndex   
        $percentComplete = $importStatus.Status.Substring($startIndex, $lengh).Trim()
        
        Write-Progress -Id ($index + 1) -activity ("Importing blob '{0}'." -f $importStatus.BlobUri) -status $importStatus.Status -PercentComplete $percentComplete
      }
    }
        
    $status = "Total: {0}. Successful: {1}. Failed: {2}. Active: {3}." -f $totalTasks, $successfulTaskList.Count, $failedTaskList.Count, $ImportRequestList.Count 
    Write-Progress -Id 0 -activity "Start-AzureSqlDatabaseImport task status:" -status $status

  }
  until ($ImportRequestList.Count -eq 0)  

  foreach ($failedTask in $failedTaskList)
  {
    $info = @{      
      ImportingStatus = $failedTask.Status;
      AzureSqlServer = $failedTask.ServerName;
      AzureSqlDatabase = $failedTask.DatabaseName;
      BlobUri = $failedTask.BlobUri;
      ErrorMessage = $failedTask.ErrorMessage   
    }     

    Write-Warning (New-Object -Type PSObject -Property $info | Format-List -Property @("ImportingStatus", "AzureSqlServer", "AzureSqlDatabase", "BlobUri", "ErrorMessage") | Out-String)    
  }

  Write-Progress -Id 0 -activity "Start-AzureSqlDatabaseImport task status:" -Completed
}

# Gets Azure SQL Database connection string.
function Get-SitecoreAzureSqlDatabaseConnectionString
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Resources.Models.PSResourceGroup]
        $ResourceGroup,
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SqlServerName,
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        $SqlServerCredentials
  )

  $sqlDatabaseList = Get-AzureRmSqlDatabase -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                            -ServerName $SqlServerName
  
  $connectionStringList = New-Object System.Collections.Generic.List[System.Object]

  foreach ($database in $sqlDatabaseList)
  {
    if ($database.DatabaseName -ne "master")
    {
      $secureConnectionPolicy = Get-AzureRmSqlDatabaseSecureConnectionPolicy -ResourceGroupName $ResourceGroup.ResourceGroupName `
                                                                             -ServerName $SqlServerName `
                                                                             -DatabaseName $database.DatabaseName

      $info = @{      
        DatabaseName = $database.DatabaseName;
        ConnectionString = $secureConnectionPolicy.ConnectionStrings.AdoNetConnectionString.Replace("{your_user_id_here}", $SqlServerCredentials.UserName).Replace("{your_password_here}", $SqlServerCredentials.GetNetworkCredential().Password)
      }

      $connectionStringList.Add((New-Object -Type PSObject -Property $info))
    }
  }
    
  Write-Host ($connectionStringList| Format-List | Out-String)
}

<#
  .SYNOPSIS
    Publishes one or more Sitecore SQL Server databases.
  
  .DESCRIPTION
    The Publish-SitecoreSqlDatabase cmdlet publishes one or more Sitecore SQL Server databases from a local SQL Server to Azure SQL Database Server.    
   
    This command creates the following Azure Resources, which are grouped in a single Resource Group using the same Azure data center location:

      - Resource Group
      - Storage Account
      - SQL Database Server
      - SQL Databases       
  
    This command exports databases from a local SQL Server to a BACPAC packages (.bacpac files), and uploads to a Blob Container of a Storage Account. Initiates an import operation from Azure Blob storage to an Azure SQL Database.

  .Link
    https://github.com/olegburov/Sitecore-Azure-PowerShell/ 
  
  .PARAMETER SqlServerName
    Specifies the name of the local SQL Server the databases are in. The name must be in the following format {ComputerName}\{InstanceName}, for example "Oleg-PC\SQLEXPRESS".

  .PARAMETER SqlServerCredentials
    Specifies the SQL Server administrator credentials for the local server.

  .PARAMETER SqlServerDatabaseList
    Specifies the list of the database names to retrieve from a local server.

  .PARAMETER AzureResourceGroupName
    Specifies the name of the resource group in which to create Storage Account, SQL Server and SQL Databases are created. The resource name must be unique in the subscription.

  .PARAMETER AzureResourceGroupLocation
    Specifies the location of the resource group. Enter an Azure data center location, such as "West US" or "Southeast Asia". You can place a resource group in any location.

  .PARAMETER AzureStorageAccountName
    Specifies the name of the new Storage Account. The storage name must be globally unique.

  .PARAMETER AzureSqlServerName
    Specifies the name of the new SQL Database server. The server name must be globally unique.

  .PARAMETER AzureSqlServerCredential
    Specifies the SQL Database server administrator credentials for the new server.

  .EXAMPLE    
    PS C:\> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" -SqlServerCredentials $credentials -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web")
        
    This command publishes the SQL Server database "sc81initial_core", "sc81initial_master" and "sc81initial_web" from the local SQL Server "Oleg-PC\SQLEXPRESS" to an Azure SQL Database Server.
  


    DatabaseName     : sc81initial_core
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_core;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_master
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_master;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_web
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_web;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

  .EXAMPLE
    PS C:\> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" -SqlServerCredentials $credentials -SqlServerDatabaseList @("sc81initial_web") -AzureResourceGroupName "MyCompanyName" -AzureResourceGroupLocation "Australia East"
        
    This command publishes the SQL Server databases "sc81initial_web" from the local SQL Server "Oleg-PC\SQLEXPRESS" to an Azure SQL Database Server in the Resource Group "MyCompanyName" at the Azure data center "Australia East".



    DatabaseName     : sc81initial_web
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_web;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

  .EXAMPLE    
    PS C:\> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" -SqlServerCredentials $credentials -SqlServerDatabaseList @("sc81initial_core", "sc81initial_web") -AzureStorageAccountName "mycompanyname"
        
    This command publishes the SQL Server databases "sc81initial_core" and "sc81initial_web" from the local SQL Server "Oleg-PC\SQLEXPRESS" to an Azure SQL Database Server using the Azure Storage Account "mycompanyname" for BACPAC packages (.bacpac files).
  


    DatabaseName     : sc81initial_core
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_core;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_web
    ConnectionString : Server=tcp:sitecore-azure-50876f04.database.secure.windows.net,1433;Database=sc81initial_web;User 
                       ID=sitecore@sitecore-azure-50876f04;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30
                       
  .EXAMPLE
    PS C:\> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" -SqlServerCredentials $localSqlServerCredentials -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web") -AzureSqlServerName "sitecore-azure" -AzureSqlServerCredentials $azureSqlServerCredentials
        
    This command publishes the SQL Server databases "sc81initial_core", "sc81initial_master" and "sc81initial_web" from the local SQL Server "Oleg-PC\SQLEXPRESS" to an Azure SQL Database Server with specified credentials.
  


    DatabaseName     : sc81initial_core
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_core;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_master
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_master;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_web
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_web;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

  .EXAMPLE
    PS C:\> Publish-SitecoreSqlDatabase -SqlServerName "Oleg-PC\SQLEXPRESS" -SqlServerCredentials $localSqlServerCredentials -SqlServerDatabaseList @("sc81initial_core", "sc81initial_master", "sc81initial_web", "sc81initial_reporting") -AzureResourceGroupName "MyCompanyName" -AzureResourceGroupLocation "West Europe" -AzureStorageAccountName "mycompanyname" -AzureSqlServerName "sitecore-azure" -AzureSqlServerCredentials $azureSqlServerCredentials 
    
    This command publishes the SQL Server databases "sc81initial_core", "sc81initial_master" and "sc81initial_web" from the local SQL Server "Oleg-PC\SQLEXPRESS" to Azure SQL Database Server "sitecore-azure" in the Resource Group "MyCompanyName" at the Azure data center "West Europe" using the Azure Storage Account "mycompanyname".



    DatabaseName     : sc81initial_core
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_core;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_master
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_master;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_web
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_web;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30

    DatabaseName     : sc81initial_reporting
    ConnectionString : Server=tcp:sitecore-azure.database.secure.windows.net,1433;Database=sc81initial_reporting;User 
                       ID=sitecore@sitecore-azure;Password=Experienc3!;Trusted_Connection=False;Encrypt=True;Connection Timeout=30
#>
function Publish-SitecoreSqlDatabase
{
  param(
    [Parameter(Position=0, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $SqlServerName = "$env:COMPUTERNAME\SQLEXPRESS",

    [Parameter(Position=1, Mandatory = $true)]        
    [ValidateNotNull()]
    [System.Management.Automation.PSCredential]
    $SqlServerCredentials,

    [Parameter(Position=2, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [System.String[]]
    $SqlServerDatabaseList,
    
    [Parameter(Position=3, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureResourceGroupName = "Sitecore-Azure",

    [Parameter(Position=4, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureResourceGroupLocation = 'West US',

    [Parameter(Position=5, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(3, 24)]
    [System.String]
    $AzureStorageAccountName = "sitecoreazure{0}" -f (Get-AzureRmContext).Subscription.SubscriptionId.Substring(0, 8),

    [Parameter(Position=6, Mandatory = $false)]        
    [ValidateNotNullOrEmpty()]        
    [System.String]
    $AzureSqlServerName = "sitecore-azure-{0}" -f (Get-AzureRmContext).Subscription.SubscriptionId.Substring(0, 8),

    [Parameter(Position=7, Mandatory = $false)]        
    [ValidateNotNull()]
    [System.Management.Automation.PSCredential]
    $AzureSqlServerCredentials = (New-Object System.Management.Automation.PSCredential ("sitecore", (ConvertTo-SecureString "Experienc3!" -AsPlainText -Force)))
  )  

  $outputDirectory = Export-SitecoreAzureSqlDatabase -SqlServerName $SqlServerName `
                                                     -SqlServerCredentials $SqlServerCredentials `
                                                     -sqlServerDatabaseList $SqlServerDatabaseList   
    
  $resourceGroup = Get-SitecoreAzureResourceGroup -Name $AzureResourceGroupName `
                                                  -Location $AzureResourceGroupLocation

  $storageAccountContext = Get-SitecoreAzureStorageAccount -ResourceGroup $resourceGroup `
                                                           -AccountName $AzureStorageAccountName
  
  Set-SitecoreAzureBacpacFile -Directory $outputDirectory `
                              -StorageAccountContext $storageAccountContext                        

  $SqlServer = Get-SitecoreAzureSqlServer -ResourceGroup $resourceGroup `
                                          -ServerName $AzureSqlServerName `
                                          -SqlServerCredentials $AzureSqlServerCredentials
  
  $importRequestList = Import-SitecoreAzureSqlDatabase -ResourceGroup $resourceGroup `
                                                       -SqlServerName $AzureSqlServerName `
                                                       -SqlServerCredentials $AzureSqlServerCredentials `
                                                       -StorageAccountContext $storageAccountContext  
 
  Get-SitecoreAzureSqlServerStatus -ImportRequestList $importRequestList

  Get-SitecoreAzureSqlDatabaseConnectionString -ResourceGroup $resourceGroup `
                                               -SqlServerName $AzureSqlServerName `
                                               -SqlServerCredentials $AzureSqlServerCredentials

  Remove-Item $outputDirectory -Recurse -Force
} 

Export-ModuleMember -Function Publish-SitecoreSqlDatabase -Alias *