_CFAPIEMAIL=<use your own damn email>@email.com
_CFIAPIKEY=<get your own damn API key>

curl -sX GET "https://api.cloudflare.com/client/v4/accounts/<any-account-id>/roles?page=1&per_page=1000" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Email: $_CFAPIEMAIL" \
  -H "X-Auth-Key: $_CFIAPIKEY" \
