#region modules

$modules = @('MSAL.PS')
$currentModules = Get-Module

$modules | ForEach-Object {
    if ($currentModules.Name -notcontains $_) {
        Install-Module -Name $_
    } else {
        Write-Host "Module $($_) is present" -ForegroundColor Green
    }
}

#endregion

#region Authentication

try {
    # Authenticate to tenant using MSAL.PS and the "vdwegen - GDAP Management" app
    try {
        $msalTokenSplat = @{
            #Scopes = "https://graph.microsoft.com/DelegatedAdminRelationship.ReadWrite.All https://graph.microsoft.com/Group.Read.All" # This doesn't pass through correctly yet
            ClientId = "7146d3ef-b8bf-4d5f-adde-b1b402906326" # Note, I created my own multi-tenant app for this for convenience sake. See the blogpost on the base requirements to use this script. {Insert blogpost link later}
            UseEmbeddedWebView = $false # Webview2 can't read device compliance, only use when your CA requires device compliance
            RedirectUri = 'http://localhost'
        }

        $graphToken = (Get-MsalToken @msalTokenSplat -Interactive).CreateAuthorizationHeader()

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
    }
)

$badRoles = @(
    @{
        displayName = "Global Administrator"
        roleId = "62e90394-69f5-4237-9190-012177145e10"
        message = "Relationship {relationship} contains the Global Administrator role and will not be able to auto extend. It is recommended to create a new relationship with the tenant"
    },
    @{
        displayName = "Directory Synchronization Accounts"
        roleId = "d29b2b05-8046-44ba-8758-1e26182fcf32"
        message = "Relationship {relationship} contains the Directory Synchronization Accounts role. It is HIGHLY recommended to create a new relationship with the tenant. This role should never be available."
    },
    @{
        displayName = "Partner Tier1 Support"
        roleId = "4ba39ca4-527c-499a-b93d-d9b492c50246"
        message = "Relationship {relationship} contains the Partner Tier1 Support role. It is HIGHLY recommended to create a new relationship with the tenant. This role should never be available."
    },
    @{
        displayName = "Partner Tier2 Support"
        roleId = "e00e864a-17c5-4a4b-9c06-f5b95a8d5bd8"
        message = "Relationship {relationship} contains the Partner Tier2 Support role. It is HIGHLY recommended to create a new relationship with the tenant. This role should never be available."
    }
)

#endregion

#region functions

function Save-File ([string]$filename) {
    [void][System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms")

    $SaveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $SaveFileDialog.initialDirectory = "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"
    $SaveFileDialog.filter = 'JSON (*.json)|*.json'
    $SaveFileDialog.FileName = "$filename.json"
    $result = $SaveFileDialog.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true }))

    return [pscustomobject]@{
        path = $SaveFileDialog.filename
        status = $result
    }
}

#endregion

#region retrieve data

try {
    try {
        # Retrieve all tenants if $tenants array is empty
        if ($tenants) {
            # Add a filter here
            $tenants = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminCustomers").value.tenantId 
        } else {
            # Page this
            $tenants = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminCustomers").value.tenantId

        }
    } catch {
        throw "Failed to retrieve tenants: $($_.Exception.Message)"
    }

    try {
        $me = (Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/me?$select=UserPrincipalName' -Headers $graphHeader)
        # Possibly just get all groups with membership?
        # Page this
        $memberGroups = (Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/beta/me/transitiveMemberOf?$select=id,displayName,isAssignableToRole' -Headers $graphHeader).value
        $adminAgentsGroup = (Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq 'AdminAgents'" -Headers $graphHeader).value
    } catch {
        throw "Failed to retrieve group membership: $($_.Exception.Message)"
    }

    try {
        # Retrieve all active relationships
        # Page this
        $relationships = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships?`$filter=(status eq 'active')").value
    } catch {
        throw "Failed to retrieve relationships: $($_.Exception.Message)"
    }

} catch {
    throw $($_.Exception.Message)
}

#endregion

#region process pre-reqs

try {
    try {
        # Validate if user is a member of AdminAgents
        $AdminAgents = $memberGroups | Where-Object { $_.displayName -eq "AdminAgents" }
        if (!$AdminAgents) {
            Write-Host "User $($me.UserPrincipalName) is not a member of AdminAgents" -ForegroundColor Red
            # Add result to array as recommendation?
        } else {
            Write-Host "User $($me.UserPrincipalName) is a member of the AdminAgents group" -ForegroundColor Green
        }
    } catch {
        throw $($_.Exception.Message)
    }

    try {
        $totalAvailableRoles = $relationships.accessDetails.unifiedRoles.roleDefinitionId | Sort-Object -Unique

        # Check if any roles are missing in ALL relationships
        $compareTotalRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $totalAvailableRoles
        if ($compareTotalRoles) {
            $missingRoles = ($compareTotalRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                $missingRole = $_
                $roles | Where-Object { $_.roleId -eq $missingRole }
            }

            if ($missingRoles) {
                $missingRoles | ForEach-Object { Write-Host "Role $($_.displayName) is missing from ALL relationships. For optimal functionality you will want to create new relationships for all your tenants." -ForegroundColor Red }
                # We don't add to array here, we do that later when we go relationship by relationship. This is just a "You're fucked" message.
            }
        }
    } catch {
        throw $($_.Exception.Message)
    }
} catch {
    throw $($_.Exception.Message)
}
#endregion

#region process data

try {
    # Define our results array
    $processedArray = [system.collections.generic.list[PSCustomObject]]::new()

    # Validate that relationships contain the correct roles and are assigned properly
    foreach ($tenantRelationship in $relationships) {

        $relResult = [pscustomobject]@{
            tenantDisplayName = $tenantRelationship.customer.displayName
            tenantId = $tenantRelationship.customer.tenantId
            relationshipDisplayName = $($tenantRelationship.displayName)
            relationshipId = $($tenantRelationship.id)
            # recommendations = [pscustomobject]@{
            #     missingRoles = [array]@()
            #     badRoles = [array]@()
            #     missingAssignedRoles = [array]@()
            #     otherIssues = [system.collections.generic.list[PSCustomObject]]::new()
            # }
            recommendations = [system.collections.generic.list[PSCustomObject]]::new()
        }

        # Define a few variables
        $tenantDisplayName = $tenantRelationship.customer.displayName
        $tenantId = $tenantRelationship.customer.tenantId

        Write-Host "Processing relationship $($tenantRelationship.displayName) for tenant $($tenantDisplayName) | $($tenantId)"

        # Get all AccessAssignments for the relationship
        $accessAssignments = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)/accessAssignments?`$filter=(status eq 'active')" -Verbose:$false).value

        # Check for missing roles
        try {
            $relationshipRoles = $tenantRelationship.accessDetails.unifiedRoles.roleDefinitionId
            $compareRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $relationshipRoles
            if ($compareRoles) {
                $missingRoles = ($compareRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                    $missingRole = $_
                    $roles | Where-Object { $_.roleId -eq $missingRole }
                }

                if ($missingRoles) {
                    $missingRoles | ForEach-Object {
                        # Add result to array as recommendation
                        $relResult.recommendations.Add(
                            [pscustomobject]@{
                                type = "missingRole"
                                role = $($_.displayName)
                                roleId = $($_.roleId)
                                message = "Role $($_.displayName) is missing from relationship $($tenantRelationship.displayName). Replace this relationship with a new one that contains the correct roles."
                            }
                        )
                        #Write-Warning "Role $($_.displayName) is missing from relationship $($tenantRelationship.displayName)"
                    }
                }
            }
        } catch {
            throw "Error while processing missing roles: $($_.Exception.Message)"
        }

        try {
            # Check for "bad" roles
            $compareBadTotalRoles = Compare-Object -ReferenceObject $relationshipRoles -DifferenceObject $badRoles.roleId -IncludeEqual
            if ($compareBadTotalRoles) {
                $foundBadRoles = ($compareBadTotalRoles | Where-Object { $_.SideIndicator -eq "==" }).InputObject | ForEach-Object {
                    $badRole = $_
                    $badRoles | Where-Object { $_.roleId -eq $badRole } | Select-Object -Property roleId,displayName
                }

                if ($foundBadRoles) {
                    $foundBadRoles | ForEach-Object {
                        # Add result to array as recommendation
                        $relResult.recommendations.Add(
                            [pscustomobject]@{
                                type = "badRole"
                                role = $($_.displayName)
                                roleId = $($_.roleId)
                                message = "Role $($_.displayName) is included on relationship $($tenantRelationship.displayName). Replace this relationship with a new one that ONLY contains the correct roles."
                            }
                        )
                        #Write-Warning $($_.message -Replace("{relationship}",$($tenantRelationship.displayName)))
                    }
                }
            }
        } catch {
            throw "Error while processing bad roles: $($_.Exception.Message)"
        }

        # Auto extend
        try {
            if ($tenantRelationship.autoExtendDuration -eq "PT0S") {
                #$autoExtendBody = @{
                #    autoExtendDuration = 'P730D'
                #}
                #(Invoke-RestMethod -Method PATCH -body (ConvertTo-Json -InputObject $autoExtendBody) -Uri "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)" -Headers $header -ContentType "application/json")
                # Add result to array as recommendation
                $relResult.recommendations.Add(
                    [pscustomobject]@{
                        type = "autoExtend"
                        message = "Auto-extend is not enabled on this relationship"
                    }
                )
                #Write-Warning "Auto-extend is not set on relationship $($tenantRelationship.displayName)"
            } else {
                #$relResult.autoExtendEnabled = $true
            }
        } catch {
            throw "Error while processing auto extend: $($_.Exception.Message)"
        }

        #
        try {
            $totalAssignedRoles = $accessAssignments.accessDetails.unifiedRoles.roleDefinitionId | Sort-Object -Unique

            # Check if any roles are missing in ALL accessAssignments
            if ($totalAssignedRoles) {
                $compareTotalAssignedRoles = Compare-Object -ReferenceObject $roles.roleId -DifferenceObject $totalAssignedRoles
                if ($compareTotalAssignedRoles) {
                    $missingAssignedRoles = ($compareTotalAssignedRoles | Where-Object { $_.SideIndicator -eq "<=" }).InputObject | ForEach-Object {
                        $missingRole = $_
                        $roles | Where-Object { $_.roleId -eq $missingRole }
                    }
    
                    if ($missingAssignedRoles) {
                        $missingAssignedRoles | ForEach-Object {
                            # Add result to array as recommendation
                            $relResult.recommendations.Add(
                                [pscustomobject]@{
                                    type = "missingAssignedRole"
                                    role = $($_.displayName)
                                    roleId = $($_.roleId)
                                    message = "Role $($_.displayName) is included on relationship $($tenantRelationship.displayName) but not assigned to a role group."
                                }
                            )
                            #Write-Warning "Role $($_.displayName) has not been mapped on relationship $($tenantRelationship.displayName)."
                        }
                    }
                }
            } else {
                Write-Warning "$($tenantRelationship.displayName) on $($tenantDisplayName) has something funky"
            }
        } catch {
            throw "Error while processing missing roles in all assignments: $($_.Exception.Message)"
        }

        try {
            foreach ($accessAssignment in $accessAssignments) {
                # Check if more than one role is mapped per group
                if ($accessAssignment.accessDetails.unifiedRoles.Count -gt 1) {
                    # Add result to array as recommendation
                    $relResult.recommendations.Add(
                        [pscustomobject]@{
                            type = "otherIssue"
                            message = "More than one role is mapped in assignment $($accessAssignment.accessContainer.accessContainerId) on relationship $($tenantRelationship.displayName), this is not recommended"
                        }
                    )
                }

                # Check if the mapped group is AdminAgents
                if ($accessAssignment.accessContainer.accessContainerId -eq $adminAgentsGroup.id) {
                    # Add result to array as recommendation
                    $relResult.recommendations.Add(
                        [pscustomobject]@{
                            type = "otherIssue"
                            message = "AdminAgents group is mapped in assignment $($accessAssignment.accessContainer.accessContainerId) on relationship $($tenantRelationship.displayName), this is not recommended"
                        }
                    )
                }

                # Do a thing to check if the mapped groups contain weird shit

                # Do a thing to check if too many roles have been assigned
            }
        } catch {
            throw "Error while processing more than one role assigned to group: $($_.Exception.Message)"
        }

        $processedArray.Add($relResult)
    }
} catch {
    throw $($_.Exception.Message)
}

#endregion

# very WIP
$processedArray | ConvertTo-Json -depth 20 | Out-File "C:\temp\gdapstatus.json" -Force
