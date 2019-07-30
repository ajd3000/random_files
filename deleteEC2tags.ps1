param (
        [parameter()]
        [string] $awsprofile
)

Set-AWSCredentials -ProfileName $awsprofile
#Getting the list of all the instances in the Tenant

$instances = (Get-EC2Instance).Instances

$tagkeytoremove = 'OsPatchDate' # Declaring the TAG Key to remove / modify

#$tagvaluetoremove = '' # Declaring the Tag Value to Remove / Modify. Uncomment if you have a value you want to compare

#$NewTagValue = "NewTagValue" # Declaring the new tag value. Uncomment if you need to change a value

Foreach ( $instance in $instances ) # Looping through all the instances
{
    $OldTagList = $instance.tags
    foreach ($tag in $OldTagList) # Looping through all the Tags
    {
        if($tag.key -ceq $tagkeytoremove ) # Comparing the TAG Key. Comment out if you want to compare both Key and Value.
        #if($tag.key -ceq $tagkeytoremove -and $tag.Value -ceq $tagvaluetoremove ) # Comparing the TAG Key and Values. Uncomment if you have a value you want to compare.
        {
            Remove-EC2Tag -Resource $instances.instanceid -Tag $tag -Force # Removing the Old Tag Key Value Pair
            # Uncomment to update tag
            #New-EC2Tag -Resource $instances.instanceid -Tag @{ Key=$tag.key;Value=$NewTagValue} -Force #Adding the New Tag Key Value pair.

        }
    }
} # Loop Ends