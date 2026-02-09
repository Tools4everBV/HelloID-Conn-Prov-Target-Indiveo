#################################################
# HelloID-Conn-Prov-Target-Indiveo-Import
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-GenericScimError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.detail
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}

function ConvertTo-HelloIDAccountObject {
    param (
        [Parameter(Mandatory)]
        [object]$AccountObject
    )

    [PSCustomObject]@{
        id         = $AccountObject.id
        userName   = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.userName
        givenName  = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.name.givenName
        familyName = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.name.familyName
        active     = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.active
    }
}
#endregion

try {
    Write-Information 'Starting Indiveo account entitlement import'

    # Adding headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $($actionContext.Configuration.Token)")

    $take = 20
    $startIndex = 0
    do {
        $splatImportAccountParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/scim/v2/Users?startIndex=$($startIndex)&count=$($take)"
            Method  = 'GET'
            Headers = $headers
        }
        $response = Invoke-RestMethod @splatImportAccountParams

        $result = $response.Resources
        $totalResults = $response.totalResults

        if ($null -ne $result) {
            foreach ($importedAccount in $result) {
                $data = ConvertTo-HelloIDAccountObject -AccountObject $importedAccount

                # Set Enabled based on importedAccount status
                $isEnabled = $false
                if ($importedAccount.'urn:ietf:params:scim:schemas:core:2.0:User'.active -eq $true) {
                    $isEnabled = $true
                }

                # Make sure the displayName has a value
                $displayName = "$($importedAccount.'urn:ietf:params:scim:schemas:core:2.0:User'.displayName)"
                if ([string]::IsNullOrEmpty($displayName)) {
                    $displayName = $importedAccount.Id
                }

                # Make sure the userName has a value
                $UserName =  $importedAccount.userName
                if ([string]::IsNullOrWhiteSpace($UserName)) {
                    $UserName = $importedAccount.Id
                }

                Write-Output @{
                    AccountReference = $importedAccount.Id
                    DisplayName      = $displayName
                    UserName         = $UserName
                    Enabled          = $isEnabled
                    Data             = $data
                }
                $startIndex++
            }
        }
    } while (($result.count -gt 0) -and ($startIndex -lt $totalResults))
    Write-Information 'Indiveo account entitlement import completed'
} catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-GenericScimError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Indiveo account entitlements. Error: $($errorObj.FriendlyMessage)"
    } else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Indiveo account entitlements. Error: $($ex.Exception.Message)"
    }
}