_NEWUSEREMAIL=<new-user>@email.com
### MULTIPLE ROLES:
#_NEWUSERROLES=(\"069fe803647ed3609e93d041d5df6050\", \"d1c17a97abf0aa371338074955877ba0\", \"05784afa30c1afe1440e79d9351c7430\")
### SINGLE ROLE:
#_NEWUSERROLES=(\"f2b20eaa1a5d4af42b53ac16238c99c7\")
### ROLES ###
# 05784afa30c1afe1440e79d9351c7430 #Administrator
# 33666b9c79b9a5273fc7344ff42f953d #Super Admin
# 75f36071fa06ebfac6da0c3f8ddbc4df #SSL/TLS, Caching, Performance, Page Rules, and Customization
# 069fe803647ed3609e93d041d5df6050 #DNS
# d1c17a97abf0aa371338074955877ba0 #Cache Purge
# f2b20eaa1a5d4af42b53ac16238c99c7 #Administrator Read Only
# 298ce8e7a2ba08b9d18ce0a32bb458ee #Billing
_NEWUSERROLES=(\"298ce8e7a2ba08b9d18ce0a32bb458ee\") #Billing
_CFAPIEMAIL=<use your own damn email>@inhabit.com
_CFIAPIKEY=<get your own damn API key>

#https://api.cloudflare.com/#user-s-account-memberships-list-memberships
echo "Retrieving all accounts from the Cloudflare API...";
curl -sX GET "https://api.cloudflare.com/client/v4/memberships?page=1&per_page=1000" \
 -H "content-type: application/json" \
 -H "X-Auth-Email: $_CFAPIEMAIL" \
 -H "X-Auth-Key: $_CFIAPIKEY" \
  | jq '.result[].account.id' -r \
  | while read id; do \
    #https://api.cloudflare.com/#account-members-add-member
    echo "Adding user $_NEWUSEREMAIL to the account $id... with role(s) `for i in "${_NEWUSERROLES[*]}"; do echo "$i"; done`";
    curl -sX POST "https://api.cloudflare.com/client/v4/accounts/$id/members" \
     -H "X-Auth-Email: $_CFAPIEMAIL" \
     -H "X-Auth-Key: $_CFIAPIKEY" \
     -H "Content-Type: application/json" \
     --data "{\"email\":\"$_NEWUSEREMAIL\",\"status\":\"accepted\",\"roles\":[`for i in "${_NEWUSERROLES[*]}"; do echo "$i"; done`]}" \
    | jq .;
    sleep 0.25;
   done;
echo -e "\e[93mDone! User added to all accounts."
