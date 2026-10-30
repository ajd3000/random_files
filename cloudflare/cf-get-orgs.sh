_CFAPIEMAIL=<use your own damn email>@email.com
_CFIAPIKEY=<get your own damn API key>

curl --request GET \
  --url https://api.cloudflare.com/client/v4/user/organizations?per_page=1000 \
  --header "Content-Type: application/json" \
  --header "X-Auth-Key: $_CFIAPIKEY" \
  --header "X-Auth-Email: $_CFAPIEMAIL"
