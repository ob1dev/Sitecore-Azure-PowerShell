# Adding the Azure account to Windows PowerShell.
function Login-SitecoreAzureAccount 
{
  [cmdletbinding()]
  param(    
  ) 
  
  try
  {
    $subscription = Get-AzureRmSubscription
  }
  catch
  {
    Login-AzureRmAccount    
    Get-AzureRmSubscription
    
    $subscriptionName = Read-Host -Prompt "Enter Subscription Name that you want to use"
    Get-AzureRmSubscription –SubscriptionName $subscriptionName | Select-AzureRmSubscription
  } 

<#
  Get-AzureSubscription -Default -ErrorAction SilentlyContinue 

  # Hack since the Get-AzureSubscription -Default cmdlet does not throw an exception.
  $lastError = $Error.Item(0).ToString()
  if ($lastError.StartsWith("No default subscription has been designated."))
  {
    Get-AzureRmSubscription
    $subscriptionName = Read-Host -Prompt "Type Subscription Name that you want to use"
    Get-AzureRmSubscription –SubscriptionName $subscriptionName | Select-AzureRmSubscription
  }  
#>
} 

# Exporting a database schema and user data from SQL Server to a BACPAC package (.bacpac file).
function Export-SitecoreAzureSqlDatabase
{
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [String]
        $SqlServerName = ".\SQLEXPRESS",                             
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [String]
        $SqlServerUser = "sa",
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [String]
        $SqlServerPassword = "12345",
        [Parameter(Position=3, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [String[]]
        $SqlServerDatabaseList
  )

  # User's temp directory.
  $tempPath = [System.IO.Path]::GetTempPath() 
  # The disk directory path where the *.bacpac file will be written.
  $outputDirectory = New-Item -ItemType Directory -Path $tempPath -Name "Sitecore\BACPAC\" -Force

  # For more information about the SqlPackage.exe utility, see the MSDN web site
  # https://msdn.microsoft.com/en-us/library/hh550080%28v=vs.103%29.aspx
  $sqlpackageExe = "C:\Program Files (x86)\Microsoft SQL Server\120\DAC\bin\sqlpackage.exe" 

  foreach ($databaseName in $sqlServerDatabaseList)
  {
    $filePath = "{0}\{1}.bacpac" -f $outputDirectory, $databaseName
    
    &$sqlpackageExe /a:Export `
                    /ssn:$SqlServerName `
                    /su:$SqlServerUser `
                    /sp:$SqlServerPassword `
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

# Creating an Azure Resource Group for keeping resources such as Azure Storage, Azure SQL Server and Azure SQL Database.
function Get-SitecoreAzureResourceGroup 
{
  [cmdletbinding()]
  param([Parameter(Position=0, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Name = "Sitecore-Azure",
        [Parameter(Position=1, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String] 
        $Location = "West US"
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

# Creating an Azure Storage and uploading a BACPAC packages (*.bacpac files) to a Container.
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
        $AccountName = "sitecoreazure",        
        [Parameter(Position=3, Mandatory = $false)]        
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

# Upload local Sitecore BACPAC packages (*.bacpac files) to Azure Storage Blob.
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

# Creating an Azure SQL Server and setting up the firewall.
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
        $ServerName = "sitecore-azure",
        [Parameter(Position=2, Mandatory = $true)]        
        [ValidateNotNull()]
        [PSCredential]
        $SqlAdministratorCredentials
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
                                        -SqlAdministratorCredentials $SqlAdministratorCredentials `
                                        -ServerVersion "12.0"
  }

  Set-SitecoreAzureSqlServerFirewallRule -ResourceGroup $ResourceGroup -SqlServer $sqlServer.ServerName

  Write-Host ($sqlServer | Format-List | Out-String)

  return $sqlServer 
}

# Setting an Azure SQL Server Firewall Rule.
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

# Importing Azure SQL Databases from a Blob Storage.
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
        [PSCredential]
        $SqlAdministratorCredentials,
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

  #Import-AzurePublishSettingsFile -PublishSettingsFile "C:\Users\obu\Documents\Sitecore License\USA\Azure\Visual Studio Premium with MSDN-Sitecore US PSS OBU-10-17-2015-credentials.publishsettings" | Out-Host
   
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
                                              -RequestedServiceObjectiveName "S3"
      }     
      
      $sqlDatabaseServerContext = New-AzureSqlDatabaseServerContext -ServerName $SqlServerName `
                                                                    -Credential $SqlAdministratorCredentials

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

# Get a status of the import request.
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
      #[Microsoft.WindowsAzure.Commands.SqlDatabase.Services.ImportExport.StatusInfo]$importStatus = Get-AzureSqlDatabaseImportExportStatus -Request $ImportRequestList[$index]
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
        [ValidateNotNullOrEmpty()]
        [System.String]
        $AzureSqlServerAdminLogin,
        [Parameter(Position=3, Mandatory = $true)]        
        [ValidateNotNullOrEmpty()]
        [System.String]
        $AzureSqlServerPassword
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
        ConnectionString = $secureConnectionPolicy.ConnectionStrings.AdoNetConnectionString.Replace("{your_user_id_here}", $AzureSqlServerAdminLogin).Replace("{your_password_here}", $AzureSqlServerPassword)
      }

      $connectionStringList.Add((New-Object -Type PSObject -Property $info))
    }
  }
    
  Write-Host ($connectionStringList| Format-List | Out-String)
}

<#
  .SYNOPSIS
  Describe the function here
  
  .DESCRIPTION
  Describe the function in more detail
  
  .EXAMPLE
  Give an example of how to use it
  
  .EXAMPLE
  Give another example of how to use it
  
  .PARAMETER computername
  The computer name to query. Just one.
  
  .PARAMETER logname
  The name of a file to write failed computer names to. Defaults to errors.txt.
#>
function Publish-SitecoreSqlDatabase
{
  param(
    [Parameter(Position=0, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $SqlServerName = ".\SQLEXPRESS",

    [Parameter(Position=1, Mandatory = $true)]                             
    [ValidateNotNullOrEmpty()]
    [System.String]
    $SqlServerAdminLogin,
    
    [Parameter(Position=2, Mandatory = $true)]                             
    [ValidateNotNullOrEmpty()]
    [System.String]
    $SqlServerPassword,

    [Parameter(Position=3, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [System.String[]]
    $SqlServerDatabaseList,
    
    [Parameter(Position=4, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureResourceGroupName = "Sitecore-Azure",

    [Parameter(Position=5, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureResourceGroupLocation = 'West US',

    [Parameter(Position=6, Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(3, 24)]
    [System.String]
    $AzureStorageAccountName = "sitecoreazure{0}" -f (Get-Date -format yyyyMd),

    [Parameter(Position=7, Mandatory = $false)]        
    [ValidateNotNullOrEmpty()]        
    [System.String]
    $AzureSqlServerName = "sitecore-azure-{0}" -f (Get-Date -format yyyyMd), #([Guid]::NewGuid().Guid.Substring(0, 8)),

    [Parameter(Position=8, Mandatory = $false)]        
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureSqlServerAdminLogin = "sitecore",

    [Parameter(Position=9, Mandatory = $false)]        
    [ValidateNotNullOrEmpty()]
    [System.String]
    $AzureSqlServerPassword = "Experienc3!"
  )  

  Login-SitecoreAzureAccount
      
  $outputDirectory = Export-SitecoreAzureSqlDatabase -sqlServerName $SqlServerName `
                                                     -sqlServerUser $SqlServerAdminLogin `
                                                     -sqlServerPassword $SqlServerPassword `
                                                     -sqlServerDatabaseList $SqlServerDatabaseList   
    
  $resourceGroup = Get-SitecoreAzureResourceGroup -Name $AzureResourceGroupName `
                                                  -Location $AzureResourceGroupLocation

  $storageAccountContext = Get-SitecoreAzureStorageAccount -ResourceGroup $resourceGroup `
                                                           -AccountName $AzureStorageAccountName
  
  Set-SitecoreAzureBacpacFile -Directory $outputDirectory `
                              -StorageAccountContext $storageAccountContext                        
  
  # The password for Azure SQL Server credentials.
  $securedPassword = ConvertTo-SecureString $AzureSqlServerPassword -AsPlainText -Force
  # The Azure SQL Server credentials.
  $credentials = New-Object System.Management.Automation.PSCredential ($AzureSqlServerAdminLogin, $securedPassword)

  $SqlServer = Get-SitecoreAzureSqlServer -ResourceGroup $resourceGroup `
                                          -ServerName $AzureSqlServerName `
                                          -SqlAdministratorCredentials $credentials
  
  $importRequestList = Import-SitecoreAzureSqlDatabase -ResourceGroup $resourceGroup `
                                                       -SqlServerName $AzureSqlServerName `
                                                       -SqlAdministratorCredentials  $credentials `
                                                       -StorageAccountContext $storageAccountContext  
 
  Get-SitecoreAzureSqlServerStatus -ImportRequestList $importRequestList
  
  Get-SitecoreAzureSqlDatabaseConnectionString -ResourceGroup $resourceGroup `
                                               -SqlServerName $AzureSqlServerName `
                                               -AzureSqlServerAdminLogin $AzureSqlServerAdminLogin `
                                               -AzureSqlServerPassword $AzureSqlServerPassword

  Remove-Item $outputDirectory -Recurse -Force
} 

Export-ModuleMember -Function Publish-SitecoreSqlDatabase -Alias *

<#
$path = "C:\Program Files\WindowsPowerShell\Modules\Sitecore.Azure\Sitecore.Azure.psd1"

$guid = [guid]::NewGuid().guid

$paramHash = @{
 Path = $path
 RootModule = ".\Sitecore.Azure.psm1"
 ModuleVersion = "0.5.0"
 Guid = $guid
 Author = "Oleg Burov"
 CompanyName = "Sitecore Corporation"
 Copyright = "Copyright © 2015 Sitecore Corporation ."
 Description = "Suitecore Azure Module" 
 PowerShellVersion = "3.0"
 PowerShellHostName = ""
 PowerShellHostVersion = $null
 DotNetFrameworkVersion = "4.0"
 CLRVersion="4.0"
 ProcessorArchitecture = "None"
 RequiredModules = @(
   @{ ModuleName = "AzureRM"; ModuleVersion = "0.9.11"},
   @{ ModuleName = "AzureRM"; ModuleVersion = "1.0.1"},
   @{ ModuleName = "AzureRM.Resources"; ModuleVersion = "0.10.0"},
   @{ ModuleName = "AzureRM.Storage"; ModuleVersion = "0.10.1"},
   @{ ModuleName = "AzureRM.Sql"; ModuleVersion = "0.10.0"}
 )
 RequiredAssemblies = @() 
 ScriptsToProcess = @()  
 TypesToProcess = @() 
 FormatsToProcess = @()
 NestedModules = @()
 FunctionsToExport = "Publish-SitecoreSqlDatabase"
 CmdletsToExport = ""
 VariablesToExport = ""
 AliasesToExport = @()
 ModuleList = @()  
 FileList =  @()    
 PrivateData = $null
}
New-ModuleManifest @paramHash
#>