param (
        [parameter()]
        [string] $awsprofile
)
$ds = (Get-Date -UFormat "%m-%d-%Y")
$groups = Get-EC2SecurityGroup -ProfileName $awsprofile | Select-Object GroupName
$results = foreach ($group in $groups.GroupName){
    (Get-EC2SecurityGroup -profilename $awsprofile -GroupName $group.group).IpPermissions |
    ForEach-Object {
        [PSCustomObject]@{
            GroupName = $group
            IpProtocol = $_.IpProtocol
            FromPort   = $_.FromPort
            ToPort     = $_.ToPort
            Ipv4Ranges = $_.Ipv4Ranges.CidrIp -join ', '
            }
        }
    }
$results | Export-Csv $($ds + "_" + $awsprofile + "_SGList.csv") -NoTypeInformation