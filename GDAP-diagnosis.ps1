#region Authentication

try {
    # Authenticate to tenant using MSAL.PS and the "vdwegen - GDAP Management App"
    try {
        $msalTokenSplat = @{
            TenantId = if ($Env:OS -eq "Windows_NT" -OR $IsWindows) { (whoami /upn).Split('@')[1] } else { Read-Host -Prompt "Enter TenantId or verified domain" }
            Scopes = "DelegatedAdminRelationship.ReadWrite.All"
            ClientId = "7146d3ef-b8bf-4d5f-adde-b1b402906326" # Note, I created my own multi-tenant app for this for convenience sake. See the blogpost on the base requirements to use this script. {Insert blogpost link later}
        }

        $graphToken = (Get-MsalToken @msalTokenSplat  -Interactive).CreateAuthorizationHeader()

        $graphHeader = @{
            "Authorization"          = $graphToken
            "Content-type"           = "application/json"
            "X-Requested-With"       = "XMLHttpRequest"
        }
    } catch {
        throw "Failed to authenticate to tenant $($msalTokenSplat.TenantId): $($_.Exception.Message)"
    }
} catch {
    throw $($_.Exception.Message)
}

#endregion

#region static data

$roles = @(
    @{
        displayName = "Application Administrator"
        roleId = "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"
    },
    @{
        displayName = "Authentication Policy Administrator"
        roleId = "0526716b-113d-4c15-b2c8-68e3c22b9f80"
    },
    @{
        displayName = "Cloud App Security Administrator"
        roleId = "892c5842-a9a6-463a-8041-72aa08ca3cf6"
    },
    @{
        displayName = "Cloud Device Administrator"
        roleId = "7698a772-787b-4ac8-901f-60d6b08affd2"
    },
    @{
        displayName = "Exchange Administrator"
        roleId = "29232cdf-9323-42fd-ade2-1d097af3e4de"
    },
    @{
        displayName = "Intune Administrator"
        roleId = "3a2c62db-5318-420d-8d74-23affee5d9d5"
    },
    @{
        displayName = "Privileged Role Administrator"
        roleId = "e8611ab8-c189-46e8-94e1-60213ab1f814"
    },
    @{
        displayName = "Security Administrator"
        roleId = "194ae4cb-b126-40b2-bd5b-6091b380977d"
    },
    @{
        displayName = "SharePoint Administrator"
        roleId = "f28a1f50-f6e7-4571-818b-6a12f2af6b6c"
    },
    @{
        displayName = "Teams Administrator"
        roleId = "69091246-20e8-4a56-aa4d-066075b2a7a8"
    },
    @{
        displayName = "User Administrator"
        roleId = "fe930be7-5e62-47db-91af-98c3a49a38b1"
    },
    @{
        displayName = "Privileged Authentication Administrator"
        roleId = "7be44c8a-adaf-4e2a-84d6-ab2649e08a13"
    },
    @{
        displayName = "Global Reader"
        roleId = "f2ef992c-3afb-46b9-b7cf-a126ee74c451"
    }
)

#endregion

#region retrieve data

try {
    try {
        # Retrieve all tenants if $tenants array is empty
        if (!$tenants) {
            # Page this
            $tenants = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminCustomers").value.tenantId
        }
    } catch {
        throw "Failed to retrieve tenants: $($_.Exception.Message)"
    }

    try {
        # 
        # Page this
        $me = (Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/me?$select=UserPrincipalName' -Headers $graphHeader)
        $memberGroups = (Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/me/memberOf?$select=id,displayName,isAssignableToRole' -Headers $graphHeader).value
    } catch {
        throw "Failed to retrieve group membership: $($_.Exception.Message)"
    }

    try {
        # Retrieve all active relationships
        # Page this
        $relationships = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships?`$filter=(status eq 'active')").value
    
        #
        $totalAvailableRoles = $relationships.accessDetails.unifiedRoles.roleDefinitionId | Sort-Object -Unique

        # Check if any roles are missing in ALL relationships
        $compareTotalRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $totalAvailableRoles
        if ($compareTotalRoles) {
            $missingRoles = ($compareTotalRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                $roles | Where-Object { $_.roleId -eq $_ }
            }

            $missingRoles | ForEach-Object { Write-Host "Role $($_.displayName) is missing from ALL relationships. For optimal functionality you will want to create new relationships for all your tenants." -ForegroundColor Red }
        }
    } catch {
        throw "Failed to retrieve relationships: $($_.Exception.Message)"
    }

} catch {
    throw $($_.Exception.Message)
}

#endregion

#region process pre-reqs

try {
    # Validate if user is a member of AdminAgents
    $AdminAgents = $memberGroups | Where-Object { $_.displayName -eq "AdminAgents" }
    if (!$AdminAgents) {
        Write-Host "User $($me.UserPrincipalName) is not a member of AdminAgents" -ForegroundColor Red
        # Add result to array
    } else {
        Write-Host "User $($me.UserPrincipalName) is a member of the AdminAgents group" -ForegroundColor Green
    }

    # Validate that relationships contain the correct roles
    foreach ($tenantRelationship in $relationships) {

        $tenantDisplayName = $tenantRelationship.customer.displayName
        $tenantId = $tenantRelationship.customer.tenantId

        # Check for missing roles and presence of GA
        try {
            $relationshipRoles = $tenantRelationship.accessDetails.unifiedRoles.roleDefinitionId
            $compareRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $relationshipRoles
            if ($null -eq $compareRoles) {
                Write-Host "Relationship $($tenantRelationship.displayName) contains all the needed roles"
            } else {
                $missingRoles = ($compareRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                    $roles | Where-Object { $_.roleId -eq $_ }
                }

                $missingRoles | ForEach-Object {
                    Write-Host "Role $($_.displayName) is missing from relationship $($tenantRelationship.displayName)" -ForegroundColor Red
                    # Add result to array
                }
            }

            # Check for GA
            if ("62e90394-69f5-4237-9190-012177145e10" -in $relationshipRoles) {
                Write-Warning "Relationship $($tenantRelationship.displayName) contains the Global Administrator role and will not be able to auto extend. It is recommended to create a new relationship with the tenant"
                # Add result to array
            }
        } catch {
            throw $($_.Exception.Message)
        }

        # Auto extend
        try {
            if ($tenantRelationship.autoExtendDuration -eq "PT0S") {
                #$autoExtendBody = @{
                #    autoExtendDuration = 'P730D'
                #}
                #(Invoke-RestMethod -Method PATCH -body (ConvertTo-Json -InputObject $autoExtendBody) -Uri "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)" -Headers $header -ContentType "application/json")
                Write-Warning "Auto-extend is not set on relationship $($tenantRelationship.displayName)"
            }
        } catch {
            throw $($_.Exception.Message)
        }

        #
        try {
            $accessAssignments = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)/accessAssignments?`$filter=(status eq 'active')").value
        
            $totalAssignedRoles = $accessAssignments.accessDetails.unifiedRoles.roleDefinitionId | Sort-Object -Unique

            # Check if any roles are missing in ALL accessAssignments
            $compareTotalAssignedRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $totalAssignedRoles
            if ($compareTotalAssignedRoles) {
                $missingAssignedRoles = ($compareTotalAssignedRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                    $roles | Where-Object { $_.roleId -eq $_ }
                }

                $missingAssignedRoles | ForEach-Object { Write-Host "Role $($_.displayName) has not been mapped on relationship $($tenantRelationship.displayName)." -ForegroundColor Red }
                # add Result to array
            }
        } catch {
            throw $($_.Exception.Message)
        }
    }
} catch {
    throw $($_.Exception.Message)
}

#endregion
