[cmdletbinding()]
param (
    
  #String. The IP Address or DNS name of the vCenter Server machine.
  [Parameter(Mandatory,HelpMessage='vCenter Name or IP Address')]
  [String]$Computer
)

Begin {

  ## InfluxDB Prefs
  $InfluxStruct = New-Object -TypeName PSObject -Property @{
    InfluxDbServer             = '172.16.200.90'                                   #IP Address,DNS Name, or 'localhost'
    InfluxDbPort               = 8086                                          #default for InfluxDB is 8086
    InfluxDbName               = 'datastorestats'                                        #to follow my examples, set to 'compute' here and run "CREATE DATABASE compute" from Influx CLI
    InfluxDbUser               = 'esx'                                         #to follow my examples, set to 'esx' here and run "CREATE USER esx WITH PASSWORD esx WITH ALL PRIVILEGES" from Influx CLI
    InfluxDbPassword           = 'esx'                                         #to follow my examples, set to 'esx' here [see above example to create InfluxDB user and set password at the same time]
    MetricsString              = ''                                            #empty string that we populate later
  }

  ## stat preferences
  $DatastoreStatTypes  = 'disk.used.latest'

  ## Create the variables that we consume with Invoke-RestMethod later.
  $authheader = 'Basic ' + ([Convert]::ToBase64String([Text.encoding]::ASCII.GetBytes(('{0}:{1}' -f $InfluxStruct.InfluxDbUser, $InfluxStruct.InfluxDbPassword))))
  $uri = ('http://{0}:{1}/write?db={2}' -f $InfluxStruct.InfluxDbServer, $InfluxStruct.InfluxDbPort, $InfluxStruct.InfluxDbName)

} #End Begin

Process {

  #Import PowerCLI module/snapin if needed
  If(-Not(Get-Module -Name VMware.PowerCLI -ListAvailable -ErrorAction SilentlyContinue)){
    $vMods = Get-Module -Name VMware.* -ListAvailable -Verbose:$false
    If($vMods) {
      foreach ($mod in $vMods) {
        Import-Module -Name $mod -ErrorAction Stop -Verbose:$false
      }
      Write-Verbose -Message 'PowerCLI 6.x Module(s) imported.'
    }
    Else {
      If(!(Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) {
        Try {
          Add-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction Stop
          Write-Verbose -Message 'PowerCLI 5.x Snapin added; recommend upgrading to PowerCLI 6.x'
        }
        Catch {
          Write-Warning -Message 'Could not load PowerCLI'
          Throw 'PowerCLI 5 or later required'
        }
      }
    }
  }

  ## Connect to vCenter
  try {
    $null = Connect-VIServer -Server $Computer -WarningAction Continue -ErrorAction Stop
  }
  Catch {
    Write-Warning -Message ('{0}' -f $_.Exception.Message)
  }

  If (!$Global:DefaultVIServer -or ($Global:DefaultVIServer -and !$Global:DefaultVIServer.IsConnected)) {
    Throw 'vCenter Connection Required!'
  }
  Else {
    Write-Verbose -Message ('Connected to {0}' -f ($Global:DefaultVIServer))
    Write-Verbose -Message 'Beginning stat collection.'
  }

  ## Start script execution timer
  $vCenterStartDTM = (Get-Date)

  ## Enumerate Datastore list
  $Datastores = Get-Datastore | Sort-Object -Property Name

  ## Iterate through Datastore list
    foreach ($datastore in $Datastores) {
    
      ## Gather desired stats
      $stats = Get-Stat -Entity $datastore -Stat $DatastoreStatTypes -Realtime -MaxSamples 1
      
      foreach ($stat in $stats) {
            
        ## Create and populate variables for the purpose of writing to InfluxDB Line Protocol
        $measurement = $stat.MetricId
        $name = $stat.Entity.Name.Replace(' ','_')
        $type = 'Datastore'
        $free = $stat.Entity.FreeSpaceGB
        $capacity = $stat.Entity.CapacityGB
        $used_space = $capacity - $free
        $vc = ($global:DefaultVIServer).Name
        [long]$timestamp = (([datetime]::UtcNow)-(Get-Date -Date '1/1/1970')).TotalMilliseconds * 1000000 #nanoseconds since Unix epoch

        ## handle instance
        $instance = $stat.Instance
                
        ## build it
        If(-Not($instance) -or ($instance -eq '')) {
          #do not return instance
          $InfluxStruct.MetricsString = ''
          $InfluxStruct.MetricsString += ('{0},datastore={1},type={2},vc={3},freespace={4},capacity={5} value={6} {7}' -f $measurement, $name, $type, $vc, $free, $capacity, $used_space, $timestamp)
          $InfluxStruct.MetricsString += "`n"
        }
        Else {
          #return instance (i.e. cpucores, vmnics, etc.)
          $InfluxStruct.MetricsString = ''
          $InfluxStruct.MetricsString += ('{0},datastore={1},type={2},vc={3},instance={4},freespace={5},capacity={6} value={7} {8}' -f $measurement, $name, $type, $vc, $instance, $free, $capacity, $used_space, $timestamp)
          $InfluxStruct.MetricsString += "`n"
        }

        Write-Host $InfluxStruct.MetricsString

        ## write it
        Try {
          Invoke-RestMethod -Headers @{Authorization=$authheader} -Uri $uri -Method POST -Body $InfluxStruct.MetricsString -Verbose:$ShowRestConnections -ErrorAction Stop
        }
        Catch {
          Write-Warning -Message ('Problem writing {0} for {1} at {2}' -f ($measurement), ($vm), (Get-Date))
          Write-Warning -Message ('{0}' -f $_.Exception.Message)
        }
                           
        ## view it
        If($ShowStats){
          If(-Not($PSCmdlet.MyInvocation.BoundParameters['Verbose'])) {
            Write-Output -InputObject ''
            Write-Output -InputObject ('Measurement: {0}' -f $measurement)
            Write-Output -InputObject ('Value: {0}' -f $value)
            Write-Output -InputObject ('Name: {0}' -f $Name)
            Write-Output -InputObject ('Unix Timestamp: {0}' -f $timestamp)
          }
          Else {
            #verbose
            Write-Verbose -Message ''
            Write-Verbose -Message ('Measurement: {0}' -f $measurement)
            Write-Verbose -Message ('Value: {0}' -f $value)
            Write-Verbose -Message ('Name: {0}' -f $Name)
            Write-Verbose -Message ('Unix Timestamp: {0}' -f $timestamp)
          } #End Else
        } #End If show stats
      } #end foreach stat
    } #end reportvm loop

    ## Runtime Summary
    $vCenterEndDTM = (Get-Date)
    $ElapsedTotal = ($vCenterEndDTM-$vCenterStartDTM).totalseconds

} #End Process

End {
  $null = Disconnect-VIServer -Server '*' -Confirm:$false -Force -ErrorAction SilentlyContinue
  Write-Verbose -Message 'Script complete.'
  If ($Logging -eq 'On') { Stop-Transcript }
} #End End
