



# Selenium / WebDriver DLLs
Add-Type -Path "G:\VSCode\data\lib\selenium.webdriverbackedselenium.4.0.0-alpha01\lib\net45\Selenium.WebDriverBackedSelenium.dll"
Add-Type -Path "G:\VSCode\data\lib\selenium.webdriver.4.0.0-alpha01\lib\net45\WebDriver.dll"
Add-Type -Path "G:\VSCode\data\lib\selenium.support.4.0.0-alpha01\lib\net45\WebDriver.Support.dll"

# Npgsql libraries
Add-Type -Path "G:\VSCode\data\lib\npgsql-4.0.6\Npgsql.dll"


<#  [Function]
    
    Name: Get-ProxyList
    Purpose: To gather recent, "valid" HTTP proxies, through which to tunnel

    Input:<None>
    Output: List of Proxy addresses, in the format 'http://12.3.4.5:6789'
#>
function Get-ProxyList {

  <#
      Scrape the most recent Proxy list from hidemyna.me
      [TODO] add other ways, this is only one...
  #>


  # Chrome, headless
  $chromeOptions = New-Object -TypeName "OpenQA.Selenium.Chrome.ChromeOptions"
  $chromeOptions.AddArgument("--headless")

  $dr = New-Object -TypeName "OpenQA.Selenium.Chrome.ChromeDriver" -ArgumentList $chromeOptions

  # go to website for proxy list
  $dr.url = "https://hidemyna.me/en/proxy-list/?type=h&anon=34#list"

  # [TODO] conditional here instead of a static wait time
  Start-Sleep 15

  # grab the actual list table
  $hmnRawList = $dr.FindElementsByClassName("proxy__t") | Select-Object -ExpandProperty Text

  # get the second page
  $dr.url = "https://hidemyna.me/en/proxy-list/?type=h&anon=34&start=64#list"
  Start-Sleep 15
  $hmnRawList += $dr.FindElementsByClassName("proxy__t") | Select-Object -ExpandProperty Text

  # [TODO] make sure the grab was successful, retry if not...

  # close browser connection to website
  $dr.Close()

  # break into individual elements
  $hmnWithProperties = ConvertFrom-String $hmnRawList -Delimiter '[0-9]+\s*(?:minutes|seconds).*\n'

  # individuate proxy entries
  $entriesOnly = $hmnWithProperties | Get-Member | Where-Object MemberType -eq 'NoteProperty'

  # grab IP and Port information
  $hmnFinalList = foreach($entry in $entriesOnly) { $entry.Definition | Select-String '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s*\d{2,5}' | ForEach-Object { $_.Matches.Value } | ForEach-Object { $_ -replace '\s+', ':' } }

  $hmnFinalList | ForEach-Object { 'http://' + $_ }
  
} # end function Get-ProxyList


#--------------------------------------------------------------------------------------------------------------------------



<#  [Function]

    Name: Get-WebData
    Purpose: Using a List of Proxy addresses, (attempt to) gather all webpage data from a target List.
                Loop until all targets are found, or all Proxies are exhausted.
                Replies are returned as-is. It will be the responsibility of the receiving Function to parse the data.

    Input:  ProxyList[] (a segment of the total, ~30-50 maybe)
            TargetList[] (also a segment of the total, ~20-40 maybe)
    Output: Replies[] (Web replies, Error replies, Status Codes, etc. for successes and failures)
#>
function Get-WebData {
  param (
    [Parameter(mandatory=$true)][Collections.ArrayList]$ProxyList,
    [Parameter(mandatory=$true)][Collections.ArrayList]$TargetList,
    [Parameter(mandatory=$true)][Collections.ArrayList]$UserAgents
  )


  # find a working Proxy
  $proxyAttemptReplies = New-Object 'System.Collections.ArrayList'
  $targetReplies = New-Object 'System.Collections.ArrayList'

  for ( $($i=0;$j=0); ( ($i -lt $ProxyList.Count) -and ($j -lt $TargetList.Count) ); $i++ ) {
            
    $curProxy = $ProxyList[$i]
    $curAgent = Get-Random -InputObject $UserAgents
           
    try { $proxyAttemptReply = Invoke-WebRequest -Uri $TargetList[$j] -TimeoutSec 15 -Method Head -Proxy $curProxy -UserAgent $curAgent | ForEach-Object { @{ Status = 'Success'; Proxy = $curProxy; } } }
    catch { $proxyAttemptReply = @{ Status = 'Failure'; Proxy = $curProxy; Exception = $_.Exception.Message; } }
    if( $proxyAttemptReply.Status -eq 'Failure' ) { $proxyAttemptReplies.Add($proxyAttemptReply) | Out-Null }
    

    # once a successful Proxy is found, deploy payload
    if( $proxyAttemptReply.Status -eq 'Success' ) {

      # loop over each target webpage, retry 'timeout' once, after 2x or any other error, resume cycling Proxies
      :allTargetsLabel for( ; $j -lt $TargetList.Count; $j++ )
      {
      
        try { $targetReply = Invoke-WebRequest -Uri $TargetList[$j] -TimeoutSec 30 -Proxy $curProxy -UserAgent $curAgent }
        catch { $targetReply = @{ Status = 'Failure'; Proxy = $curProxy; Exception = $_.Exception.Message; } }

        # add page content to return list and wait if successful
        if( $targetReply.StatusCode -eq 200 ) {
          $targetReplies.Add($targetReply) | Out-Null
          Start-Sleep -Seconds 5
        }

        # handle errors
        elseif( $targetReply.Exception -match 'timeout' ) {
          
            try { $targetReply = Invoke-WebRequest -Uri $TargetList[$j] -TimeoutSec 30 -Proxy $curProxy -UserAgent $curAgent }
            catch { $targetReply = @{ Status = 'Failure'; Proxy = $curProxy; Exception = $_.Exception.Message; } }

            if( $targetReply.StatusCode -eq 200 ) {
              $targetReplies.Add($targetReply) | Out-Null
              Start-Sleep -Seconds 5
            }

        } # end: "if timeout error"

          
        # if this Proxy timed out 2x, or failed for any other reason, resume cycling Proxies
        elseif( $targetReply.StatusCode -ne 200 ) {
          $proxyAttemptReplies.Add($targetReply) | Out-Null
          break allTargetsLabel }

      } # end: "for all targets"
    
    } # end: "if successful Proxy found"
    
  } # end: "for all Proxies"


  # add Proxy attempt information and output all results
  if( $proxyAttemptReplies ) { $targetReplies.Add($proxyAttemptReplies) | Out-Null }
  

  # final output
  $targetReplies

} # end function Get-WebData


#--------------------------------------------------------------------------------------------------------------------------




<#  [Function]

    Name: Get-RealtorDotComScrape
    Purpose: Individual module to scrape Realtor.com

    Input:  WebResponseObject[] (all webpage replies from Get-WebData)
    Output: Target data, tabular formatted

        $testReply = Invoke-WebRequest -Uri 'https://www.realtor.com/realestateagents/miami_fl/photo-1'

        2..332 | %{
            $testReply = $body = $null
            $testReply = Invoke-WebRequest -Uri ('https://www.realtor.com/realestateagents/miami_fl/photo-1/pg-{0}' -f $_)
            $body = $testReply.ParsedHtml.body
            $body.getElementsByClassName('agent-list-card clearfix') | % { $_.attributes } | where -Property localName -eq 'data-url' | select -ExpandProperty value | % { $realtorListMiami.Add($_) }
            Start-Sleep -Seconds 3
        }

        $realtorListMiami | Out-File 'C:\RealtorSearchResults_Miami.txt'
#>
function Get-RealtorDotComScrape {
  param (
    [Parameter(mandatory=$true)][Microsoft.PowerShell.Commands.HtmlWebResponseObject][ref]$webResponses,
    [Parameter(mandatory=$true)]$pgCreds
  )

  $scrapeOutput = New-Object 'System.Collections.ArrayList'

  $user = $pgCreds.UserName
  $passwd = $pgCreds.GetNetworkCredential().Password

  foreach( $webResponse in $webResponses ) {
    try {
      $body = $null
      $body = ([ref]$webResponse).Value.ParsedHtml.body
      $breadCrumbs = @($body.getElementsByClassName('breadcrumbs-link ellipsis'))

      try { $agentName = $breadCrumbs[$breadCrumbs.Count-1].innerText } catch { $agentName = '' }
      try { $agentLocation = $breadCrumbs[$breadCrumbs.Count-2].innerText } catch { $agentLocation = '' }
      try { $agentDesc = @($body.getElementsByClassName('agent-description'))[0].innerText } catch { $agentDesc = '' }
      try { $specialties = ($body.getElementsByClassName('word-wrap-break') | Where-Object -Property outerHTML -match 'specialization_set').innerText } catch { $specialties = '' }
      try { $areasServed = ($body.getElementsByClassName('word-wrap-break') | Where-Object -Property outerHTML -match 'area_served_set').innerText } catch { $areasServed = '' }
      try { $certList = ($body.getElementsByClassName('certification-list') | Select-Object -ExpandProperty innerHTML) -replace '.+<i.+/i>(.+)</h.+','$1' } catch { $certList = '' }
      try { $experience = @($body.getElementsByTagName('li') | Where-Object { $_.getElementsByClassName('list-label') } | Where-Object -Property innerText -match 'Experience:')[0] | ForEach-Object { $_.innerText -replace '.*Experience: ','' } } catch { $experience = '' }
      try { $brokerage = $body.getElementsByTagName('li') | Where-Object { $_.getElementsByClassName('list-label block') } | Where-Object -Property innerText -match 'Brokerage' | ForEach-Object { $_.innerText -replace 'Brokerage ','' -replace 'View Website.*\r\n','' } } catch { $brokerage = '' }
      try { $slogan = $body.getElementsByTagName('li') | Where-Object { $_.getElementsByClassName('list-label block') } | Where-Object -Property innerText -match 'Slogan' | ForEach-Object { $_.innerText -replace 'Slogan ','' } } catch { $slogan = '' }
      try { $priceRange = $body.getElementsByTagName('li') | Where-Object { $_.getElementsByClassName('list-label block') } | Where-Object -Property innerText -match 'Price Range' | ForEach-Object { $_.innerText -replace 'Price Range \(last 24 months\) ','' } } catch { $priceRange = '' }
      try { $pageLink = ([ref]$webResponse).Value.BaseResponse.ResponseUri.AbsoluteUri } catch { $pageLink = '' }
    }
    catch {
      Write-Host 'Error gathering breadcrumbs'
    }
    
    $tmpOut =
      @{  agentName = $agentName
          agentLocation = $agentLocation
          agentDesc = $agentDesc
          specialties = $specialties
          areasServed = $areasServed
          certList = $certList
          experience = $experience
          brokerage = $brokerage
          slogan = $slogan
          priceRange = $priceRange
          pageLink = $pageLink }

    $scrapeOutput.Add($tmpOut) | Out-Null

  }

  $DBConn = New-Object Npgsql.NpgsqlConnection;
  $DBConnectionString = "server='127.0.0.1';port=5432;user id=$user;password=$passwd;database='postgres'"
  $DBConn.ConnectionString = $DBConnectionString
  $DBConn.Open() | Out-Null
  $writer = $DBConn.BeginBinaryImport("COPY dbo.realtorinfo ( agentname, agentlocation, agentdescription, specializations, areasserved, certifications, experience, brokerage, slogan, pricerange, pagelink ) FROM STDIN (FORMAT BINARY)")

  foreach( $result in $scrapeOutput ) {
    try {
      $writer.StartRow() | Out-Null
      $writer.Write([string]$result.agentName) | Out-Null
      $writer.Write([string]$result.agentLocation) | Out-Null
      $writer.Write([string]$result.agentDesc) | Out-Null
      $writer.Write([string]$result.specialties) | Out-Null
      $writer.Write([string]$result.areasServed) | Out-Null
      $writer.Write([string]$result.certList) | Out-Null
      $writer.Write([string]$result.experience) | Out-Null
      $writer.Write([string]$result.brokerage) | Out-Null
      $writer.Write([string]$result.slogan) | Out-Null
      $writer.Write([string]$result.priceRange) | Out-Null
      $writer.Write([string]$result.pageLink) | Out-Null
    }
    catch {}
  }

  $writer.Complete()
  $writer.Dispose() | Out-Null
  $DBConn.Close | Out-Null
  $DBConn.Dispose() | Out-Null

  # $scrapeOutput
  
} # end function Get-RealtorDotComScrape


#--------------------------------------------------------------------------------------------------------------------------


<#

    main execution area

#>


# variables
$MAXPROXIES = 8
$MAXTARGETS = 10
$MAXTHREADS = 16


# get username and password for Postgres
$creds = Get-Credential




# User Agents, Targets, Proxies
$userAgentReply = Invoke-WebRequest -Uri 'https://techblog.willshouse.com/2012/01/03/most-common-user-agents/'
[Collections.ArrayList]$UserAgents = (@($userAgentReply.ParsedHtml.body.getElementsByClassName('get-the-list'))[1].innerText | ConvertFrom-Json).useragent
[Collections.ArrayList]$targetList = Get-Content -Path 'C:\RealtorSearchResults_Miami.txt' | ForEach-Object { 'https://www.realtor.com' + $_ }
[Collections.ArrayList]$proxyList = Get-ProxyList





# break target list into sections
$allTargets = New-Object 'System.Collections.ArrayList'

for( $i=0; $i -lt $targetList.Count; $i += $MAXTARGETS ) {

  $currentTargets = New-Object 'System.Collections.ArrayList'

  $targetList[$i..($i+$MAXTARGETS-1)] | ForEach-Object { $currentTargets.Add($_) }
  $allTargets.Add($currentTargets)

}


# send off all sections, processing them as they come back
foreach( $target in $allTargets ) {

  if( $proxyList.Count -le 20 ) { $proxyList = Get-ProxyList }

  
  # start runspace job
  Start-RSJob -FunctionsToImport Get-WebData,Get-RealtorDotComScrape -Batch 'FetchBatch' -Throttle $MAXTHREADS -ScriptBlock {

    $innerProxyList = $Using:proxyList | Get-Random -Count $Using:MAXPROXIES
  
    $webReplies = Get-WebData -proxyList $innerProxyList -targetList $Using:target -UserAgents $Using:UserAgents

    if( ($webReplies | Where-Object -Property StatusCode -eq 200).Count -gt 0 ) {
      $webReplies | Where-Object -Property StatusCode -eq 200 | ForEach-Object { Get-RealtorDotComScrape -webResponses ([ref]$_) -pgCreds $Using:creds }
    }

    $webReplies | Where-Object { ($_.GetType()).Name -eq 'ArrayList' }

  }


  # limit running jobs to the maximum (+2)
  while( (Get-RSJob | Where-Object { $_.HasErrors -ne $true }).Count -ge ($MAXTHREADS + 2) )
  {
    Start-Sleep -Seconds 20;
    Write-Host ('Proxies remaining: {0}' -f $proxyList.Count);
    Get-RSJob

    # grab any completed jobs
    if( (Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasMoreData -eq $true }).Count -gt 0 ) {
  
      $rsJobResults = New-Object 'System.Collections.ArrayList'
    
      # receive and remove completed jobs
      $rsJobResults = Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasMoreData -eq $true } | Receive-RSJob

      # scrape good results and update proxy and target lists
      $rsJobResults | ForEach-Object { $_.Proxy } | ForEach-Object { $proxyList.Remove($_) }

      Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true } | Remove-RSJob | Out-Null

    }
    elseif( (Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true }).Count -gt 0 ) { Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true } | Remove-RSJob | Out-Null }
  }
}


# catch remaining jobs
while( (Get-RSJob | Where-Object { $_.HasErrors -ne $true }).Count -gt 0 ) {
# while jobs exist that aren't completed, OR there are jobs with data that has yet to be ingested

  if( $proxyList.Count -le 20 ) { $proxyList = Get-ProxyList }

  if( (Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasMoreData -eq $true }).Count -gt 0 ) {
  
    $rsJobResults = New-Object 'System.Collections.ArrayList'

    # receive and remove completed jobs
    $rsJobResults = Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasMoreData -eq $true } | Receive-RSJob

    # scrape good results and update proxy and target lists
    $rsJobResults | ForEach-Object { $_.Proxy } | ForEach-Object { $proxyList.Remove($_) }
    
    Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true } | Remove-RSJob | Out-Null
    
  }
  elseif( (Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true }).Count -gt 0 ) { Get-RSJob | Where-Object { $_.State -eq 'Completed' -and $_.HasErrors -ne $true } | Remove-RSJob | Out-Null }
  else { Start-Sleep -Seconds 20; $proxyList.Count; Get-RSJob }

}



