enum Ensure{
    Absent
    Present
}
enum AuthMode{
    Integrated
    PAT
    Negotiate
    ALT
}
[DscResource()]
class xTfsDscAgent {
    [DscProperty(Key)]
    [string]$AgentFolder
    [DscProperty(Mandatory)]
    [Ensure]$Ensure
    # https://tfs.t-systems.eu/
    [DscProperty(Mandatory)]
    [string] $serverUrl
    # 2.117.2
    [DscProperty()]
    [string] $AgentVersion = "latest"
    [DscProperty()]
    [string] $AgentPlatform = "win7-x64"
    [DscProperty()]
    [string] $AgentPool
    [DscProperty()]
    [string] $AgentName = "default"
    [DscProperty()]
    [int] $AgentAuth = [AuthMode]::Integrated;
    [DscProperty()]
    [bool] $AgentRunAsService = $false
    [DscProperty()]
    [string] $WorkFolder = "_work"    
    [DscProperty()]
    [PsCredential] $AgentUser
    [DscProperty()]
    [string] $UserToken
    [DscProperty()]
    [bool] $ReplaceAgent = $false;
    [void] prepearePowershell() {
        # I don't know why but sometimes the powershell can't create a secure channel.
        # thanks to the help from here: https://stackoverflow.com/questions/41618766/powershell-invoke-webrequest-fails-with-ssl-tls-secure-channel
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls11 -bor `
            [Net.SecurityProtocolType]::Tls                
    }    
    [void] Set() {
        $this.prepearePowershell();
        if ($this.Ensure -eq [Ensure]::Present) {
            if (!(Test-Path $this.AgentFolder)) {
                mkdir $this.AgentFolder -Force;
            }
            if (!(Test-Path $this.AgentFolder) -or (Get-ChildItem $this.AgentFolder).Length -eq 0) {
                #install
                $zipPath = $this.AgentFolder + "\agent.zip";
                $downloadUri = $this.getAgentDownLoadUri($this.serverUrl, $this.AgentVersion, $this.AgentPlatform);
                $this.downloadAgent($downloadUri, $zipPath);
                $this.unpackAgentZip($zipPath);
                $this.installAgent($this.getConfigurationString());
                #If the agent is configure as Service the agent starting after config automatic
                if (!$this.AgentRunAsService) {
                    Write-Verbose "Try to start agent, because it isn't a Windows service."
                    $this.startAgent();    
                }
                else {
                    Write-Verbose "Don't start the agent, because the windows service start automatic.";
                }
            }
            else {
                if (!$this.checkIfCurrentAgentVersionIsInstalled()) {
                    #install newer version
                    #TODO: we don't know how
                }
                else {
                    # reconfiure   
                    $this.installAgent($this.getConfigurationString()); 
                }                
            }        
        }
        else {
            #uninstall
            $this.installAgent($this.getRemoveString());
            Remove-Item $this.AgentFolder -Recurse -Force;
        }
    }
    [bool] Test() {
        $this.prepearePowershell();
        $present = (
            (Test-Path $this.AgentFolder) -and #the dsc have create the folder
            (Get-ChildItem $this.AgentFolder).Length -gt 0 -and # the download was success
            (Test-Path ($this.AgentFolder + "\.agent"))); # the agent is configured
        #TODO we must check the version number!
        if ($this.Ensure -eq [Ensure]::Present) {
            return $present;
        }
        else {
            return -not $present;
        }
        return $false;
    }
    [xTfsDscAgent]Get() {
        $this.prepearePowershell();
        $result = [xTfsDscAgent]::new();         
        $result.AgentFolder = $this.AgentFolder        
        $result.ReplaceAgent = $false    
        $agentJsonpath =  $this.AgentFolder + "\.agent";
        if (Test-Path $agentJsonpath) {
            $agentJsonFile = ConvertFrom-Json -InputObject (Get-Content $agentJsonpath -Raw);
            $result.WorkFolder = $agentJsonFile.workFolder;
            $result.AgentName = $agentJsonFile.agentName;
            $result.serverUrl = $agentJsonFile.serverUrl;
            $result.AgentPool = $agentJsonFile.poolId;
        }
        #Get agentVersion
        $result.AgentVersion = & ($this.AgentFolder + "\config.cmd") ("--version");

        return $result;
    }
    [void] installAgent([string] $configureString) {
        Write-Verbose ("Configure Agent with this parameters: " + $configureString);        
        $fullString = ($this.AgentFolder + "\config.cmd") + " " + $configureString;
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($fullString)
        $encodedCommand = [Convert]::ToBase64String($bytes)
        # & powershell.exe -encodedCommand $encodedCommand;
        Write-Verbose ("Start installation: " + (Get-Date));
        $process = Start-Process ($this.AgentFolder + "\config.cmd") -ArgumentList $configureString -Verbose -Debug -PassThru;
        $process.WaitForExit();  
        $testpath = $this.AgentFolder + ".agent";
        Write-Verbose $testpath;
        while ((Test-Path $testpath) -ne $true) {
            Write-Verbose "Wait while agent will install.";
            Start-Sleep -Seconds 5;   
        }        
        Write-Verbose ("Installation success" + (Get-Date));
    }
    [void] startAgent() {        
        $startProgrammPath = $this.AgentFolder + "run.cmd";    
        Invoke-Command -ScriptBlock {Start-Process $args[0]} -ArgumentList $startProgrammPath -InDisconnectedSession -ComputerName localhost    
        Write-Verbose "Start sucess";
    }
    [string] getRemoveString() {
        $removestring = " remove";
        $removestring += $this.authString();
        $removestring += " --unattended";
        return $removestring;
    }
    [string] getConfigurationString() {
        $configstring = "";
        $configstring += (" --url " + $this.serverUrl);
        $configstring += (" --pool " + $this.AgentPool);
        $configstring += (" --work " + $this.WorkFolder);
        $configstring += $this.authString();
        if ($this.AgentRunAsService) {
            if ($this.AgentAuth -ne [int][AuthMode]::Integrated) {
                throw "To run the agent as service your auth must be set to integrated"
            }
            if ([string]::IsNullOrEmpty($this.AgentUser.UserName) -or [string]::IsNullOrEmpty($this.AgentUser.GetNetworkCredential().Password)) {
                throw "To run the agent as service you need a username and a password"
            }
            $configstring += " --runasservice";
            $configstring += (" --windowslogonaccount " + $this.AgentUser.UserName);
            $configstring += (" --windowslogonpassword " + ($this.AgentUser.GetNetworkCredential().Password));
        }
        if ($this.AgentName -eq "Default") {
            $configstring += (" --agent " + $this.AgentName + "-" + ((New-Guid).ToString()))
        }
        else {
            $configstring += (" --agent " + $this.AgentName);
        }
        if ($this.ReplaceAgent) {
            $configstring += " --replace"
        }
        $configstring += " --unattended";
        #accepteula isn't avaibeld in tfs agents for tfs 2018. The new parameter is --acceptTeeEula and must only use for linux and mac agents.
        #$configstring += " --accepteula";
        return $configstring;
    }
    [string] authString() {
        $configstring = "";
        switch ($this.AgentAuth) {
            ([int][AuthMode]::Integrated) {
                $configstring += " --auth Integrated"
            }
            ([int][AuthMode]::PAT) {
                if ($this.UserToken -eq $null -or $this.UserToken.Length -eq 0) {
                    throw "For PAT Auth you need a UserToken!"
                }
                $configstring += " --auth PAT --token " + $this.UserToken;
            }
            ([int][AuthMode]::Negotiate) {
                if (![string]::IsNullOrEmpty($this.AgentUser.UserName) -and ![string]::IsNullOrEmpty($this.AgentUser.GetNetworkCredential().Password)) {
                    throw "For Negotiate Auth you need a username and a password!";
                }
                $configstring += " --auth Negotitate --username " + $this.AgentUser.UserName + " --password " + $this.AgentUser.GetNetworkCredential().Password;
            }
            ([int][AuthMode]::ALT) {
                if (![string]::IsNullOrEmpty($this.AgentUser.UserName) -and ![string]::IsNullOrEmpty($this.AgentUser.GetNetworkCredential().Password)) {
                    throw "For ALT Auth you need a username and a password!";
                }
                $configstring += " --auth ALT --username " + $this.AgentUser.UserName + " --password " + $this.AgentUser.GetNetworkCredential().Password;
            }
            Default {
                throw "Not know authmode set! Please set a valid authmode!"
            }
        }
        return $configstring;
    }
    [bool] checkIfCurrentAgentVersionIsInstalled() {
        $version = $this.AgentVersion;
        if ($this.AgentVersion -eq "latest") {
            $versionObject = $this.getLatestVersion($this.getAllAgentThatAreAvabiled($this.serverUrl)).version;
            $version = $versionObject.major + "." + $versionObject.minor + "." + $versionObject.patch;
        }
        return $false;
        # we must find a way to do this!
    }
    [void] unpackAgentZip([string] $zipPath) {
        Expand-Archive -Path $zipPath -DestinationPath $this.AgentFolder
        Remove-Item $zipPath
    }
    [void] downloadAgent([string] $url, [string] $zipPath) {        
        Invoke-WebRequest $url -OutFile $zipPath -UseBasicParsing -Verbose;
    }
    [string] getAgentDownLoadUri([string] $serverUrl, [string] $version, [string] $platfrom) {        
        $allagents = $this.getAllAgentThatAreAvabiled($serverUrl);
        if ($version -eq "latest") {
            return $this.getLatestVersion($allagents, $platfrom).downloadUrl;            
        }
        else {
            return $this.getspecifivVersion($allagents, $version, $platfrom).downloadUrl;
        }        
    }
    [PsCustomObject] getLatestVersion([PSCustomObject] $agents, [string] $platfrom) {
        return ($agents | 
                Where-Object {$_.type -eq "agent" -and $_.platform -eq $platfrom} | 
                Sort-Object createdOn -Descending)[0];
    }
    [PsCustomObject] getspecifivVersion([PsCustomObject] $agents, [string] $version, [string] $platform) {
        $splitedVersion = $version.Split(".")
        $result = $agents | 
            Where-Object {$_.type -eq "agent" -and $_.platform -eq $platfrom -and $_.version.major -eq $splitedVersion[0] -and $_.version.minor -eq $splitedVersion[1] -and $_.version.patch -eq $splitedVersion[2] };
        if ($result.Length -eq 0) {
            throw "version are not found! Maybe it is not compatible with your TFS version!";
        }
        return ($result | Sort-Object createdOn -Descending)[0];  
    }
    [PSCustomObject] getAllAgentThatAreAvabiled([string] $serverUrl) {
        $agentVersionsUrl = $serverUrl + "_apis/distributedTask/packages/agent";
        $webResult = Invoke-WebRequest $agentVersionsUrl -Credential $this.AgentUser -UseBasicParsing;
        $agentJson = ConvertFrom-Json -InputObject $webResult.Content;
        return $agentJson.value;
    }
}